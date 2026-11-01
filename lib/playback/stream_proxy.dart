import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import '../domain/models.dart';
import '../domain/downloads.dart';
import '../domain/playback.dart';
import '../core/json.dart';
import 'playback_failure.dart';

class _ReadCancelled implements Exception {}

class _Reader {
  _Reader(
    this.first,
    this.last,
    this.metadata,
    this.generation,
    this.byteStart,
    this.byteEnd,
  ) : cursor = first;
  final int first, last, generation;
  final int byteStart, byteEnd;
  final bool metadata;
  int cursor;
  final cancelled = Completer<void>();
  final pending = <int, _Segment>{};
  void Function()? _abortWait;
  bool get stopped => cancelled.isCompleted;
  void check() {
    if (stopped) throw _ReadCancelled();
  }

  // Keep a single cancellation callback instead of retaining a Future.any
  // listener for every packet until a long-running HTTP response ends.
  Future<T> wait<T>(Future<T> action) {
    check();
    final result = Completer<T>();
    void abort() {
      if (!result.isCompleted) result.completeError(_ReadCancelled());
    }

    _abortWait = abort;
    unawaited(
      action.then<void>(
        (value) {
          if (identical(_abortWait, abort)) _abortWait = null;
          if (!result.isCompleted) result.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_abortWait, abort)) _abortWait = null;
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
    return result.future;
  }

  void stop() {
    if (stopped) return;
    cancelled.complete();
    _abortWait?.call();
    _abortWait = null;
  }
}

class _Segment {
  _Segment(this.index, this.start, this.generation, this.size) {
    // Speculative work can outlive the HTTP reader that originally requested it.
    unawaited(result.future.then<void>((_) {}, onError: (Object _) {}));
  }
  final int index, start, generation, size;
  (int, int) get key => (start, size);
  final result = Completer<Uint8List>();
  final owners = <_Reader>{}, demanders = <_Reader>{};
  Uint8List? bytes, buffer;
  int received = 0;
  Object? _error;
  StackTrace? _stack;
  Completer<void> _progress = Completer<void>();
  HttpClientRequest? request;
  void Function()? cancelBody;
  bool started = false, cancelled = false;
  int touched = 0;
  void check() {
    if (cancelled) throw _ReadCancelled();
  }

  // Hold the last byte until the HTTP body completes. Earlier bytes may be
  // consumed as soon as the range and file identity headers have been checked.
  int get availableBytes =>
      bytes != null ? received : math.min(received, size - 1);

  void _wake() {
    final previous = _progress;
    _progress = Completer<void>();
    previous.complete();
  }

  void advance(int count) {
    received = count;
    _wake();
  }

  Future<int> availableAfter(int offset, _Reader reader) async {
    while (true) {
      reader.check();
      check();
      if (_error != null) {
        Error.throwWithStackTrace(_error!, _stack ?? StackTrace.empty);
      }
      if (availableBytes > offset) return availableBytes;
      await _progress.future;
    }
  }

  void complete(Uint8List value) {
    bytes = value;
    result.complete(value);
    _wake();
  }

  void fail(Object error, [StackTrace? stack]) {
    if (result.isCompleted) return;
    _error = error;
    _stack = stack;
    result.completeError(error, stack);
    _wake();
  }

  void cancel() {
    if (cancelled || bytes != null) return;
    cancelled = true;
    request?.abort(_ReadCancelled());
    cancelBody?.call();
    fail(_ReadCancelled());
  }
}

/// Session-wide Range scheduling: metadata probes and nearby reads share work;
/// a real seek supersedes old work. The first 256 KiB use two media requests,
/// then demand can fill the byte-bounded read-ahead window independently of
/// connection count. Metadata takes priority within the same budget. Validated
/// response bodies stream incrementally; cached AND in-flight bytes are bounded.
class PlaybackStreamProxy {
  PlaybackStreamProxy(
    this.source, {
    int connections = 8,
    this.chunkBytes = 3 * 1024 * 1024,
    int maxCacheBytes = 48 * 1024 * 1024,
    this.warmupBytes = 256 * 1024,
    this.onFailure,
    this.readCache,
  }) : _connections = _limitConnections(source, connections),
       _maxCacheBytes = maxCacheBytes {
    assert(chunkBytes > 0 && maxCacheBytes >= chunkBytes && warmupBytes >= 0);
  }

  final DownloadSpec source;
  final void Function(PlaybackFailure)? onFailure;
  final Future<Uint8List?> Function(
    int start,
    int end,
    RemoteIdentity identity,
  )?
  readCache;
  final int chunkBytes, warmupBytes;
  int _maxCacheBytes;
  int get maxCacheBytes => _maxCacheBytes;
  bool resizeCache(int bytes) {
    if (_closed || bytes < chunkBytes || !_makeRoom(0, limit: bytes)) {
      return false;
    }
    _maxCacheBytes = bytes;
    for (final reader in _readers.toList()) {
      _trimWindow(reader);
      _scheduleAhead(reader);
    }
    _pump();
    return true;
  }

  int _connections;
  int get connections => _connections;
  static int _limitConnections(DownloadSpec source, int value) {
    final maximum = source.maxPlaybackConnections;
    return value.clamp(
      PlaybackPreferences.minConnections,
      maximum != null && maximum > 0
          ? math.min(maximum, PlaybackPreferences.maxConnections)
          : PlaybackPreferences.maxConnections,
    );
  }

  set connections(int value) {
    final next = _limitConnections(source, value);
    if (_connections == next) return;
    _connections = next;
    _fetchClient?.maxConnectionsPerHost = _connections;
    for (final reader in _readers.toList()) {
      _trimWindow(reader);
      _scheduleAhead(reader);
    }
    _pump();
  }

  final _segments = <(int, int), _Segment>{};
  final _readers = <_Reader>{};
  final _handlers = <Future<void>>{}, _fetches = <Future<void>>{};
  final _path = '/video/${newId()}/${newId()}';
  HttpServer? _server;
  HttpClient? _probeClient, _fetchClient;
  late Uri _upstream, _sourceUri;
  Map<String, String> _headers = {};
  Map<String, String> _sourceHeaders = {};
  Future<void>? _redirectRefresh;
  int _routeRevision = 0, _redirectRefreshes = 0;
  String? _etag, _modified;
  String _contentType = 'application/octet-stream';
  int _length = 0, _cachedBytes = 0, _reservedBytes = 0;
  int _active = 0, _pausedAllowance = 0, _generation = 0;
  int _deliveredBytes = 0, _cursor = 0, _clock = 0;
  bool _closed = false, _paused = false, _started = false;
  bool _seekPending = false;
  bool _interleavedReads = false;
  int? _lastMediaFirst, _previousMediaFirst;
  final _probeWatch = Stopwatch();
  String _probeResult = 'not_started';
  String? _probeErrorType;
  int? _probeStatus, _lastUpstreamStatus;
  int _requestsSeen = 0, _upstreamAttempts = 0, _completedSegments = 0;
  int _segmentFailures = 0, _servedBytes = 0;
  int _receivedBytes = 0;
  int _reusedBytes = 0;
  final _streamWatch = Stopwatch();
  int? _firstUpstreamByteMs, _firstPlayerByteMs;
  _Segment? _metadataPreemption;
  Future<void>? _closing;
  int get length => _length;
  int get cachedBytes => _cachedBytes;
  int get bufferedBytes => _cachedBytes + _reservedBytes;
  int get activeRequests => _active;
  int get receivedBytes => _receivedBytes;
  int get segmentFailures => _segmentFailures;
  int? get lastUpstreamStatus => _lastUpstreamStatus;
  int get generation => _generation;
  bool get supported => _server != null && !_closed;

  /// Only protocol outcomes and counters; no URLs, paths or account data.
  Map<String, Object?> get diagnosticFields => {
    'probeResult': _probeResult,
    'probeMs': _probeWatch.elapsedMilliseconds,
    'probeStatus': ?_probeStatus,
    'probeErrorType': ?_probeErrorType,
    'requests': _requestsSeen,
    'upstreamAttempts': _upstreamAttempts,
    'redirectRefreshes': _redirectRefreshes,
    'upstreamStatus': ?_lastUpstreamStatus,
    'completedSegments': _completedSegments,
    'segmentFailures': _segmentFailures,
    'servedBytes': _servedBytes,
    'receivedBytes': _receivedBytes,
    if (readCache != null) 'reusedDownloadBytes': _reusedBytes,
    'firstUpstreamByteMs': ?_firstUpstreamByteMs,
    'firstPlayerByteMs': ?_firstPlayerByteMs,
    'activeRequests': _active,
    'readers': _readers.length,
    'queuedSegments': _segments.values
        .where(
          (segment) =>
              !segment.started &&
              !segment.cancelled &&
              segment.owners.isNotEmpty,
        )
        .length,
    'paused': _paused,
    'seekPending': _seekPending,
    'bufferedBytes': bufferedBytes,
    'cacheLimitBytes': maxCacheBytes,
    'connectionLimit': connections,
    'fileBytes': _length,
    'interleavedReads': _interleavedReads,
  };
  Uri get uri => Uri.parse('http://127.0.0.1:${_server!.port}$_path');
  int get _budget => math.min(
    _deliveredBytes < warmupBytes
        ? math.min(
            connections,
            2 +
                _segments.values
                    .where(
                      (s) =>
                          s.bytes == null && s.demanders.any((r) => r.metadata),
                    )
                    .length
                    .clamp(0, 2),
          )
        : connections,
    math.max(1, maxCacheBytes ~/ chunkBytes),
  );

  static HttpClient _client(int connections) => HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 10)
    ..maxConnectionsPerHost = connections;

  /// A small Range probe proves byte addressing and file identity. Ignored
  /// ranges, encoded responses and HLS/DASH keep the original mpv path.
  Future<bool> start() async {
    if (_closed || _started) return supported;
    _started = true;
    final parsed = Uri.tryParse(source.url);
    if (parsed == null ||
        !{'http', 'https'}.contains(parsed.scheme) ||
        parsed.userInfo.isNotEmpty ||
        RegExp(r'\.(m3u8|mpd)$', caseSensitive: false).hasMatch(parsed.path)) {
      _probeResult = 'unsupported_source';
      return false;
    }
    _probeResult = 'probing';
    _probeWatch.start();
    _upstream = _sourceUri = parsed;
    _headers = Map.of(source.headers);
    _sourceHeaders = Map.of(_headers);
    final client = _probeClient = _client(1);
    try {
      final result = await _getRange(client, 0, 1023, conditional: false);
      final response = result.$1;
      _probeStatus = response.statusCode;
      final failure = PlaybackFailure.http(response.statusCode);
      if (failure != null) {
        await response.listen((_) {}).cancel();
        throw failure;
      }
      final range = _contentRange(response);
      if (response.statusCode != HttpStatus.partialContent ||
          range == null ||
          range.$1 != 0 ||
          range.$2 != math.min(1023, range.$3 - 1) ||
          !_identity(response)) {
        _probeResult = 'range_not_supported';
        await response.listen((_) {}).cancel();
        return false;
      }
      final prefix = await _readBody(response, range.$2 + 1);
      final text = String.fromCharCodes(prefix).trimLeft();
      final contentType = response.headers.contentType?.mimeType;
      if (text.startsWith('#EXTM3U') ||
          RegExp(r'<MPD[\s>]', caseSensitive: false).hasMatch(text) ||
          (contentType?.contains('mpegurl') ?? false) ||
          contentType == 'application/dash+xml') {
        _probeResult = 'playlist';
        return false;
      }
      if (_closed) {
        _probeResult = 'closed';
        return false;
      }
      _length = range.$3;
      if (readCache != null &&
          source.expectedSize > 0 &&
          source.expectedSize != _length) {
        throw const PlaybackFailure(
          '远端文件长度已变化，请重新添加下载',
          PlaybackFailureKind.changed,
        );
      }
      _contentType = contentType ?? _contentType;
      _upstream = result.$2;
      _headers = result.$3;
      _etag = response.headers.value(HttpHeaders.etagHeader);
      _modified = response.headers.value(HttpHeaders.lastModifiedHeader);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (_closed) {
        _probeResult = 'closed';
        await server.close(force: true);
        return false;
      }
      _server = server;
      _streamWatch.start();
      _fetchClient = _client(connections);
      server.listen((request) {
        final task = _serve(request);
        _handlers.add(task);
        unawaited(task.whenComplete(() => _handlers.remove(task)));
      }, onError: (Object _) {});
      _probeResult = 'ready';
      return true;
    } on PlaybackFailure {
      _probeResult = 'http_error';
      rethrow;
    } catch (error) {
      _probeResult = _closed ? 'closed' : 'probe_failed';
      _probeErrorType = '${error.runtimeType}';
      return false;
    } finally {
      _probeWatch.stop();
      client.close(force: true);
      _probeClient = null;
    }
  }

  Future<(HttpClientResponse, Uri, Map<String, String>)> _getRange(
    HttpClient client,
    int start,
    int end, {
    bool conditional = true,
    _Segment? segment,
    bool fromSource = false,
  }) async {
    var url = fromSource ? _sourceUri : _upstream;
    var headers = Map<String, String>.of(
      fromSource ? _sourceHeaders : _headers,
    );
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (_closed) throw _ReadCancelled();
      segment?.check();
      final request = await client.getUrl(url);
      if (segment != null) {
        segment.request = request;
        if (segment.cancelled) {
          request.abort(_ReadCancelled());
          throw _ReadCancelled();
        }
      }
      request.followRedirects = false;
      for (final entry in headers.entries) {
        if (!{
          'range',
          'if-range',
          'accept-encoding',
          'host',
          'connection',
          'content-length',
          'transfer-encoding',
        }.contains(entry.key.toLowerCase())) {
          request.headers.set(entry.key, entry.value);
        }
      }
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$end');
      if (conditional) {
        final validator = _etag?.startsWith('W/') == false ? _etag : _modified;
        if (validator != null) {
          request.headers.set(HttpHeaders.ifRangeHeader, validator);
        }
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          request.abort();
          throw TimeoutException('Video response timeout');
        },
      );
      if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return (response, url, headers);
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.listen((_) {}).cancel();
      if (location == null || redirects == 5) {
        throw const HttpException('Invalid video redirect');
      }
      final next = url.resolve(location);
      if (!{'http', 'https'}.contains(next.scheme) ||
          next.userInfo.isNotEmpty ||
          (url.scheme == 'https' && next.scheme != 'https')) {
        throw const HttpException('Invalid video redirect');
      }
      if (next.scheme != url.scheme ||
          next.host != url.host ||
          next.port != url.port) {
        headers = Map.of(headers)
          ..removeWhere(
            (key, _) => {
              'cookie',
              'authorization',
              'proxy-authorization',
            }.contains(key.toLowerCase()),
          );
      }
      url = next;
    }
    throw const HttpException('Video redirect limit');
  }

  bool _sameFileRange(HttpClientResponse response, int start, int end) =>
      response.statusCode == HttpStatus.partialContent &&
      _contentRange(response) == (start, end, _length) &&
      _identity(response) &&
      (_etag == null ||
          response.headers.value(HttpHeaders.etagHeader) == _etag) &&
      (_etag != null ||
          _modified == null ||
          response.headers.value(HttpHeaders.lastModifiedHeader) == _modified);

  Future<void> _refreshRedirect(int rejectedRevision) {
    if (_routeRevision != rejectedRevision) return Future.value();
    final pending = _redirectRefresh;
    if (pending != null) return pending;
    late final Future<void> refresh;
    refresh = _resolveRedirect().whenComplete(() {
      if (identical(_redirectRefresh, refresh)) _redirectRefresh = null;
    });
    _redirectRefresh = refresh;
    return refresh;
  }

  Future<void> _resolveRedirect() async {
    // CDN tickets can expire before their original signed dispatcher URL.
    // All ranges rejected on the same route share one small re-resolution.
    // Credentials are restored only at the original origin and stripped again
    // on redirects. Never replace cached media until file identity is proven.
    _redirectRefreshes++;
    _upstreamAttempts++;
    final end = math.min(1023, _length - 1);
    final result = await _getRange(_fetchClient!, 0, end, fromSource: true);
    final response = result.$1;
    _lastUpstreamStatus = response.statusCode;
    final failure = PlaybackFailure.http(response.statusCode);
    if (failure != null || !_sameFileRange(response, 0, end)) {
      await response.listen((_) {}).cancel();
      throw failure ??
          const PlaybackFailure(
            '视频源的内容或分段响应已变化，请从文件列表重新打开',
            PlaybackFailureKind.changed,
          );
    }
    await _readBody(response, end + 1);
    if (_closed) throw _ReadCancelled();
    _upstream = result.$2;
    _headers = result.$3;
    _routeRevision++;
  }

  static (int, int, int)? _contentRange(HttpClientResponse response) {
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
      caseSensitive: false,
    ).firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '');
    if (match == null) return null;
    final start = int.tryParse(match[1]!),
        end = int.tryParse(match[2]!),
        total = int.tryParse(match[3]!);
    if (start == null ||
        end == null ||
        total == null ||
        start < 0 ||
        end < start ||
        total <= end) {
      return null;
    }
    return (start, end, total);
  }

  static bool _identity(HttpClientResponse response) {
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    return encoding == null || encoding.toLowerCase() == 'identity';
  }

  static Future<Uint8List> _readBody(
    HttpClientResponse response,
    int expected, {
    _Segment? segment,
    void Function(int count)? onBytes,
  }) async {
    if (response.contentLength != -1 && response.contentLength != expected) {
      await response.listen((_) {}).cancel();
      throw const HttpException('Video range length changed');
    }
    final offset = segment?.received ?? 0;
    final bytes = segment == null
        ? Uint8List(expected)
        : segment.buffer ??= Uint8List(segment.size);
    final done = Completer<Uint8List>();
    var received = 0;
    late StreamSubscription<List<int>> subscription;
    void fail(Object error, [StackTrace? stack]) {
      if (!done.isCompleted) done.completeError(error, stack);
      unawaited(subscription.cancel());
    }

    subscription = response
        .timeout(const Duration(seconds: 20))
        .listen(
          (data) {
            if (done.isCompleted) return;
            if (received + data.length > expected) {
              fail(const HttpException('Video range exceeded'));
            } else {
              bytes.setRange(
                offset + received,
                offset + received + data.length,
                data,
              );
              received += data.length;
              onBytes?.call(data.length);
              segment?.advance(offset + received);
            }
          },
          onError: fail,
          onDone: () {
            if (done.isCompleted) return;
            if (received != expected) {
              done.completeError(const HttpException('Video range truncated'));
            } else {
              done.complete(bytes);
            }
          },
        );
    void cancel() => fail(_ReadCancelled());
    if (segment != null) {
      segment.cancelBody = cancel;
      if (segment.cancelled) cancel();
    }
    try {
      return await done.future;
    } finally {
      if (segment != null) segment.cancelBody = null;
      await subscription.cancel();
    }
  }

  (int, int)? _requestedRange(String? value) {
    if (value == null) return (0, _length - 1);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) return null;
    if (match[1]!.isEmpty) {
      final suffix = int.tryParse(match[2]!);
      return suffix == null || suffix <= 0
          ? null
          : (math.max(0, _length - suffix), _length - 1);
    }
    final start = int.tryParse(match[1]!);
    final end = match[2]!.isEmpty ? _length - 1 : int.tryParse(match[2]!);
    if (start == null || end == null || start >= _length || end < start) {
      return null;
    }
    return (start, math.min(end, _length - 1));
  }

  void setPaused(bool value) {
    if (_closed || _paused == value) return;
    _paused = value;
    _pausedAllowance = 0;
    if (!value) _pump();
  }

  /// mpv may satisfy a seek from its demuxer cache without a new HTTP request.
  /// Keep its current response alive until a replacement read actually arrives;
  /// cutting it here can leave the player buffering after that cache runs out.
  void prepareSeek() {
    if (_closed) return;
    _seekPending = true;
  }

  void _supersede() {
    _generation++;
    _deliveredBytes = 0;
    for (final reader in _readers.toList()) {
      _cancelReader(reader);
    }
    for (final segment in _segments.values.toList()) {
      if (segment.bytes == null) {
        segment.cancel();
        _segments.remove(segment.key);
      }
    }
  }

  // Completed future ranges must not occupy connection slots. Keep filling
  // the bounded cache while a slower leading range or the player is waiting.
  int _window(_Reader reader) {
    if (reader.metadata) return 1;
    // Non-interleaved MP4 stores audio far from video. A deep window for each
    // short-lived HTTP read repeatedly speculates into the wrong track.
    // Keep one nearby chunk ready per region within the same session budget.
    if (_interleavedReads) return math.min(2, _budget);
    // Download-backed playback leaves preloading to its download task.
    if (readCache != null || _deliveredBytes < warmupBytes) return _budget;
    return math.max(1, maxCacheBytes ~/ chunkBytes);
  }

  void _scheduleAhead(_Reader reader) {
    if (reader.stopped) return;
    for (
      var ahead = reader.cursor + 1;
      ahead <= math.min(reader.last, reader.cursor + _window(reader) - 1);
      ahead++
    ) {
      _requestSegment(reader, ahead, demand: false);
    }
  }

  void _trimWindow(_Reader reader) {
    final end = reader.cursor + _window(reader) - 1;
    for (final index in reader.pending.keys.toList()) {
      final segment = reader.pending[index]!;
      if (index < reader.cursor ||
          index > end && (!segment.started || segment.bytes != null)) {
        _releaseSegment(reader, index);
      }
    }
  }

  void _releaseSegment(_Reader reader, int index, {bool keepPartial = false}) {
    final segment = reader.pending.remove(index);
    if (segment == null) return;
    final useful =
        keepPartial &&
        segment.started &&
        (segment.demanders.contains(reader) && segment.received > 0 ||
            _interleavedReads && index == reader.cursor + 1);
    segment.owners.remove(reader);
    segment.demanders.remove(reader);
    if (segment.owners.isEmpty && segment.bytes == null && !useful) {
      segment.cancel();
      if (identical(_segments[segment.key], segment)) {
        _segments.remove(segment.key);
      }
    }
  }

  void _cancelReader(_Reader reader, {bool keepPartial = false}) {
    if (reader.stopped) return;
    reader.stop();
    _readers.remove(reader);
    for (final index in reader.pending.keys.toList()) {
      // A demuxer switches between audio/video by closing and reopening HTTP
      // ranges. Finish its partially consumed chunk within the existing byte
      // budget so the next nearby read can reuse it instead of starting over.
      _releaseSegment(reader, index, keepPartial: keepPartial);
    }
  }

  _Segment _requestSegment(_Reader reader, int index, {required bool demand}) {
    final segment = reader.pending.putIfAbsent(index, () {
      final aligned = index * chunkBytes;
      // A seek can start late within a large segment. Request its first byte
      // directly instead of downloading a discarded prefix on a slow source.
      final start = math.max(reader.byteStart, aligned);
      final end = reader.metadata
          ? math.min(
              reader.byteEnd,
              math.min(_length, aligned + chunkBytes) - 1,
            )
          : math.min(_length, aligned + chunkBytes) - 1;
      final key = (start, end - start + 1);
      // Media can rejoin an in-flight covering range when switching tracks.
      // Footer probes only share available bytes so they never wait behind a
      // large prefix that the player does not need.
      final covering = _segments.values
          .where(
            (candidate) =>
                !candidate.cancelled &&
                candidate.start <= start &&
                candidate.start + candidate.size > end &&
                (!reader.metadata ||
                    candidate.bytes != null ||
                    candidate.availableBytes > end - candidate.start),
          )
          .firstOrNull;
      if (covering != null) {
        covering.owners.add(reader);
        return covering;
      }
      final shared = _segments.putIfAbsent(
        key,
        () => _Segment(index, start, _generation, end - start + 1),
      );
      shared.owners.add(reader);
      return shared;
    });
    if (demand) segment.demanders.add(reader);
    segment.touched = ++_clock;
    return segment;
  }

  bool _makeRoom(int size, {int? limit, bool evictAhead = true}) {
    final ceiling = limit ?? maxCacheBytes;
    final needed = bufferedBytes + size - ceiling;
    if (needed <= 0) return true;
    final candidates = _segments.values
        .where(
          (s) =>
              s.bytes != null &&
              s.demanders.isEmpty &&
              (evictAhead || s.owners.isEmpty),
        )
        .toList();
    // A resize that cannot fit in-flight reads must leave the cache intact.
    // Otherwise each performance sample can throw away and re-fetch the same
    // useful data without ever giving more space to the native packet cache.
    if (candidates.fold(0, (sum, s) => sum + s.bytes!.length) < needed) {
      return false;
    }
    int edge(_Segment s) =>
        s.index == 0 || s.index >= (_length - 1) ~/ chunkBytes - 1 ? 1 : 0;
    candidates.sort((a, b) {
      final ownership = (a.owners.isEmpty ? 0 : 1).compareTo(
        b.owners.isEmpty ? 0 : 1,
      );
      if (ownership != 0) return ownership;
      if (a.owners.isNotEmpty) {
        // When repartitioning the two caches, retain the nearest ready ranges.
        return (b.index - _cursor).abs().compareTo((a.index - _cursor).abs());
      }
      // Unowned header/tail data still helps later container probes and seeks.
      final priority = edge(a).compareTo(edge(b));
      return priority != 0 ? priority : a.touched.compareTo(b.touched);
    });
    for (final victim in candidates) {
      for (final owner in victim.owners.toList()) {
        owner.pending.remove(victim.index);
      }
      victim.owners.clear();
      _segments.remove(victim.key);
      _cachedBytes -= victim.bytes!.length;
      if (bufferedBytes + size <= ceiling) break;
    }
    return true;
  }

  void _pump() {
    if (_closed || _fetchClient == null) return;
    while (!_paused || _pausedAllowance > 0) {
      final waiting = _segments.values
          .where((s) => !s.started && !s.cancelled && s.owners.isNotEmpty)
          .toList();
      if (waiting.isEmpty) return;
      waiting.sort((a, b) {
        final metadata = (a.demanders.any((r) => r.metadata) ? 0 : 1).compareTo(
          b.demanders.any((r) => r.metadata) ? 0 : 1,
        );
        if (metadata != 0) return metadata;
        final demand = (a.demanders.isEmpty ? 1 : 0).compareTo(
          b.demanders.isEmpty ? 1 : 0,
        );
        return demand != 0
            ? demand
            : (a.index - _cursor).abs().compareTo((b.index - _cursor).abs());
      });
      final segment = waiting.first;
      if (_active >= _budget ||
          !_makeRoom(segment.size, evictAhead: segment.demanders.isNotEmpty)) {
        if (_metadataPreemption == null &&
            segment.demanders.any((r) => r.metadata)) {
          final victim = _segments.values
              .where(
                (s) =>
                    s.started &&
                    !s.cancelled &&
                    s.bytes == null &&
                    s.demanders.isEmpty,
              )
              .firstOrNull;
          if (victim != null) {
            _metadataPreemption = victim;
            for (final owner in victim.owners.toList()) {
              if (identical(owner.pending[victim.index], victim)) {
                owner.pending.remove(victim.index);
              }
            }
            victim.owners.clear();
            _segments.remove(victim.key);
            victim.cancel();
          }
        }
        return;
      }
      segment.started = true;
      _reservedBytes += segment.size;
      _active++;
      if (_paused) _pausedAllowance--;
      final task = _fetch(segment);
      _fetches.add(task);
      unawaited(task.whenComplete(() => _fetches.remove(task)));
    }
  }

  Future<void> _fetch(_Segment segment) async {
    var reserved = true;
    var networkRetried = false, redirectRetried = false;
    final start = segment.start, end = start + segment.size - 1;
    try {
      Uint8List? cached;
      try {
        cached = await readCache?.call(
          start,
          end,
          RemoteIdentity(_length, _etag, _modified),
        );
      } on AppException catch (error) {
        // A user's paused/deleted download must not trigger automatic source
        // recovery, which would otherwise resume their explicitly stopped task.
        throw PlaybackFailure(error.message, PlaybackFailureKind.paused);
      }
      segment.check();
      if (cached != null) {
        if (cached.length != segment.size) {
          throw const PlaybackFailure(
            '下载缓存长度异常，请重试播放',
            PlaybackFailureKind.changed,
          );
        }
        _reservedBytes -= segment.size;
        reserved = false;
        _cachedBytes += cached.length;
        _reusedBytes += cached.length;
        _completedSegments++;
        segment.buffer = cached;
        segment.received = cached.length;
        segment.complete(cached);
        return;
      }
      while (true) {
        segment.check();
        try {
          final offset = segment.received;
          if (offset >= segment.size) {
            throw const PlaybackFailure(
              '视频分段读取中断，请刷新链接重试',
              PlaybackFailureKind.network,
            );
          }
          _upstreamAttempts++;
          final revision = _routeRevision, redirected = _upstream != _sourceUri;
          final response = (await _getRange(
            _fetchClient!,
            start + offset,
            end,
            segment: segment,
          )).$1;
          _lastUpstreamStatus = response.statusCode;
          final failure = PlaybackFailure.http(response.statusCode);
          if (failure != null) {
            await response.listen((_) {}).cancel();
            if (!redirectRetried &&
                redirected &&
                {401, 403, 404, 410}.contains(response.statusCode)) {
              redirectRetried = true;
              await _refreshRedirect(revision);
              continue;
            }
            if (failure.kind == PlaybackFailureKind.network &&
                !networkRetried) {
              networkRetried = true;
              continue;
            }
            throw failure;
          }
          if (!_sameFileRange(response, start + offset, end)) {
            await response.listen((_) {}).cancel();
            throw const PlaybackFailure(
              '视频源的内容或分段响应已变化，请从文件列表重新打开',
              PlaybackFailureKind.changed,
            );
          }
          final bytes = await _readBody(
            response,
            segment.size - offset,
            segment: segment,
            onBytes: (count) {
              _receivedBytes += count;
              _firstUpstreamByteMs ??= _streamWatch.elapsedMilliseconds;
            },
          );
          segment.check();
          if (_closed || segment.generation != _generation) {
            throw _ReadCancelled();
          }
          _reservedBytes -= segment.size;
          reserved = false;
          _cachedBytes += bytes.length;
          _completedSegments++;
          segment.complete(bytes);
          return;
        } on SocketException {
          if (networkRetried) {
            throw const PlaybackFailure(
              '视频连接中断，请刷新链接重试',
              PlaybackFailureKind.network,
            );
          }
          networkRetried = true;
        } on TimeoutException {
          if (networkRetried) {
            throw const PlaybackFailure(
              '视频读取超时，请刷新链接重试',
              PlaybackFailureKind.network,
            );
          }
          networkRetried = true;
        } on HttpException catch (error) {
          if (error.message.contains('length changed') ||
              error.message.contains('range exceeded')) {
            throw const PlaybackFailure(
              '视频分段长度不一致，请重新打开文件',
              PlaybackFailureKind.changed,
            );
          }
          if (networkRetried) {
            throw const PlaybackFailure(
              '视频分段读取中断，请刷新链接重试',
              PlaybackFailureKind.network,
            );
          }
          networkRetried = true;
        }
      }
    } catch (error, stack) {
      if (error is! _ReadCancelled) _segmentFailures++;
      if (identical(_segments[segment.key], segment)) {
        _segments.remove(segment.key);
      }
      segment.fail(
        error is AppException && error is! PlaybackFailure
            ? PlaybackFailure(error.message, PlaybackFailureKind.network)
            : error,
        stack,
      );
    } finally {
      if (reserved) _reservedBytes -= segment.size;
      segment.request = null;
      if (identical(_metadataPreemption, segment)) _metadataPreemption = null;
      _active--;
      _pump();
    }
  }

  Future<void> _serve(HttpRequest request) async {
    _requestsSeen++;
    _Reader? reader;
    Socket? socket;
    StreamSubscription<Uint8List>? disconnect;
    var sent = false, complete = false;
    try {
      if (_closed || request.uri.path != _path || request.uri.hasQuery) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.contentLength = 0;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        request.response.contentLength = 0;
        return;
      }
      final value = request.headers.value(HttpHeaders.rangeHeader);
      final range = _requestedRange(value);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.bufferOutput = false;
      if (range == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$_length',
        );
        request.response.contentLength = 0;
        return;
      }
      final (start, end) = range;
      request.response.statusCode = value == null
          ? HttpStatus.ok
          : HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.contentTypeHeader, _contentType);
      request.response.contentLength = end - start + 1;
      if (value != null) {
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$_length',
        );
      }
      if (request.method == 'HEAD') return;
      final first = start ~/ chunkBytes, last = end ~/ chunkBytes;
      final metadata =
          end - start + 1 <= 2 * chunkBytes &&
          (first == 0 || start >= _length - 2 * chunkBytes);
      final seeking = _seekPending;
      _seekPending = false;
      if (!metadata) {
        final previous = _lastMediaFirst, beforePrevious = _previousMediaFirst;
        if (!seeking &&
            previous != null &&
            beforePrevious != null &&
            (first - previous).abs() > 4 &&
            (first - beforePrevious).abs() <= 4) {
          _interleavedReads = true;
          for (final activeReader in _readers) {
            _trimWindow(activeReader);
          }
        }
        _previousMediaFirst = seeking ? null : previous;
        _lastMediaFirst = first;
      }
      // Containers may alternate distant audio/video ranges during ordinary
      // demuxing. Byte distance cannot distinguish that from a user seek:
      // cancelling the other reader forces an endless reopen/cancel loop.
      // Actual seeks are signalled by the backend via prepareSeek().
      if (!metadata && seeking) {
        _supersede();
      }
      // A paused seek gets one bounded preview window, only when the native
      // player needs new bytes. Cached seeks do not resume old prefetch work.
      if (seeking && _paused) {
        _pausedAllowance = math.min(connections, maxCacheBytes ~/ chunkBytes);
      }
      if (!metadata) _cursor = first;
      final current = reader = _Reader(
        first,
        last,
        metadata,
        _generation,
        start,
        end,
      );
      _readers.add(current);
      // HttpResponse.done only finishes when the outgoing body is closed.
      // A demuxer can abandon an open-ended range while we await upstream or
      // socket backpressure. Listen to the underlying peer close immediately
      // so abandoned reads release their ranges and connection/cache budget.
      request.response.persistentConnection = false;
      final output = socket = await request.response.detachSocket();
      void disconnected() {
        _cancelReader(current, keepPartial: true);
        _pump();
      }

      disconnect = output.listen(
        (_) {},
        onDone: disconnected,
        onError: (Object _) => disconnected(),
      );
      for (var index = first; index <= last; index++) {
        current.check();
        current.cursor = index;
        if (!metadata) _cursor = index;
        _trimWindow(current);
        final demanded = _requestSegment(current, index, demand: true);
        _scheduleAhead(current);
        _pump();
        final offset = demanded.start;
        final from = math.max(0, start - offset),
            to = math.min(demanded.size, end - offset + 1);
        var cursor = from;
        while (cursor < to) {
          final available = await current.wait(
            demanded.availableAfter(cursor, current),
          );
          current.check();
          final next = math.min(to, available);
          sent = true;
          output.add(Uint8List.sublistView(demanded.buffer!, cursor, next));
          await current.wait(output.flush());
          current.check();
          _firstPlayerByteMs ??= _streamWatch.elapsedMilliseconds;
          _servedBytes += next - cursor;
          final warming = _deliveredBytes < warmupBytes;
          if (!metadata) _deliveredBytes += next - cursor;
          cursor = next;
          if (warming && _deliveredBytes >= warmupBytes) {
            _scheduleAhead(current);
            _pump();
          }
        }
        _releaseSegment(current, index);
      }
      complete = true;
    } catch (error) {
      // Failed speculative reads or player-cancelled requests must not stop a
      // healthy video. Only an active reader awaiting upstream bytes reports.
      if (!_closed &&
          reader != null &&
          !reader.stopped &&
          error is PlaybackFailure) {
        onFailure?.call(error);
      }
      if (!sent && socket == null) {
        try {
          request.response.statusCode = HttpStatus.badGateway;
          request.response.contentLength = 0;
        } catch (_) {}
      }
    } finally {
      if (reader != null) _cancelReader(reader, keepPartial: true);
      _pump();
      if (socket != null) {
        if (complete) {
          try {
            await socket.close();
          } catch (_) {
            socket.destroy();
          }
        } else {
          // Cancellation must also break a blocked outgoing flush.
          socket.destroy();
        }
        await disconnect?.cancel();
      } else {
        try {
          await request.response.close();
        } catch (_) {}
      }
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _streamWatch.stop();
    _probeClient?.close(force: true);
    _supersede();
    _fetchClient?.close(force: true);
    await _server?.close(force: true);
    await Future.wait([..._handlers, ..._fetches]);
    _segments.clear();
    _cachedBytes = 0;
  }
}
