import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/download_network_policy.dart';
import '../lan/lan_files.dart';
import '../diagnostics/app_log.dart';
import 'cast/dlna.dart' show castMimeType;
import 'playback_failure.dart';
import 'isolated_stream_proxy.dart';

/// A separate, session-owned transport: pausing the internal decoder must not
/// pause the player the user has just opened. Credentials stay on this side of
/// the local server, including requests for HLS playlists, keys and segments.
/// Third-party players use loopback; TV sessions bind a selected LAN interface.
class ExternalPlaybackStream {
  ExternalPlaybackStream(this.source, {this.onFailure})
    : lanAddress = null,
      _files = null,
      _client = _newClient(source);
  ExternalPlaybackStream.lan(
    this.source, {
    required InternetAddress this.lanAddress,
    LanFiles? files,
    this.onFailure,
  }) : _files = files ?? LanFiles(),
       _client = _newClient(source);

  final DownloadSpec source;
  void Function(PlaybackFailure)? onFailure;
  final InternetAddress? lanAddress;
  final LanFiles? _files;
  LanLocalFile? _localFile;
  String get _host => lanAddress?.address ?? '127.0.0.1';
  String? _detectedMime;
  IsolatedPlaybackStreamProxy? _rangeProxy;
  int get mediaSize =>
      _localFile?.size ?? _rangeProxy?.length ?? source.expectedSize;
  String get mimeType =>
      _detectedMime ??
      castMimeType(
        Uri.tryParse(source.url)?.path.toLowerCase().endsWith('.m3u8') == true
            ? source.url
            : source.fileName,
      );
  int requestsServed = 0;
  String _lastError = '';
  DateTime? _errorTime;
  String get lastError =>
      _errorTime != null &&
          DateTime.now().difference(_errorTime!) > const Duration(seconds: 20)
      ? ''
      : _lastError;
  set lastError(String value) {
    _lastError = value;
    _errorTime = DateTime.now();
  }

  PlaybackFailure? failure;
  final _token = newId();
  final _resources = <String, Uri>{};
  final _paths = <Uri, String>{};
  final _handlers = <Future<void>>{};
  final _requests = <HttpClientRequest>{};
  final _peers = <_RelayPeer>{};
  final _bodies = <StreamIterator<List<int>>>{};
  final HttpClient _client;
  final HttpClient _proxyClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  static HttpClient _newClient(DownloadSpec source) {
    final limit = source.maxPlaybackConnections;
    return (source.networkPolicy?.client() ?? HttpClient())
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 20)
      ..maxConnectionsPerHost = limit != null && limit > 0
          ? limit.clamp(1, 8)
          : 8;
  }

  HttpServer? _server;
  bool _closed = false;
  Future<void>? _closing;
  String _url = '';
  String get url => _url;

  /// Probe before publishing DIDL. Reuse the existing isolated range scheduler
  /// for ordinary seekable media; unsupported ranges and HLS keep the relay.
  Future<void> prepareMedia({int connections = 8}) async {
    if (lanAddress == null || _localFile != null || _rangeProxy != null) return;
    final proxy = _rangeProxy = IsolatedPlaybackStreamProxy(
      source,
      connections: connections,
      chunkBytes: 1024 * 1024,
      maxCacheBytes: 32 * 1024 * 1024,
      onFailure: (value) {
        failure = value;
        lastError = value.message;
        onFailure?.call(value);
      },
    );
    try {
      final available = await proxy.start();
      require(!_closed, '投屏已取消');
      final detected = proxy.playlistMime;
      _detectedMime = detected?.toLowerCase().contains('mpegurl') == true
          ? 'application/vnd.apple.mpegurl'
          : detected;
      require(_detectedMime != 'application/dash+xml', '此 DASH 视频暂不支持电视投屏');
      if (available) {
        _resources[Uri.parse(_url).path] = proxy.uri;
      } else {
        await proxy.close();
        _rangeProxy = null;
      }
      DiagnosticLog.event(
        'cast.source_prepared',
        fields: {
          'relay': DiagnosticLog.reference(_token),
          'parallel': available,
          'connections': proxy.connections,
          'file_bytes': proxy.length,
          'mime': mimeType,
        },
      );
    } catch (_) {
      await proxy.close();
      _rangeProxy = null;
      rethrow;
    }
  }

  Future<void> start() async {
    require(!_closed, '第三方播放已取消');
    final uri = Uri.tryParse(source.url);
    require(source.url.isNotEmpty && uri != null, '视频地址无效，请重新打开视频');
    source.networkPolicy?.checkedUrl(source.url);
    if (!{'http', 'https'}.contains(uri!.scheme)) {
      if (lanAddress == null) {
        _url = source.url;
        return;
      }
      require(
        !{
          '.m3u8',
          '.mpd',
        }.any((extension) => source.fileName.toLowerCase().endsWith(extension)),
        '本地播放列表暂不支持投屏，请选择 MP4 等单个视频文件',
      );
      final location = uri.scheme == 'file'
          ? File.fromUri(uri).path
          : source.url;
      final selection = await _files!.scan([location]);
      require(selection.files.length == 1, '请选择单个视频文件投屏');
      _localFile = selection.files.single;
    }
    require(
      _localFile != null || uri.host.isNotEmpty && uri.userInfo.isEmpty,
      '视频地址无效',
    );
    // DASH templates cannot be rewritten as an HLS resource list. Public or
    // signed MPD URLs can be opened directly without leaking account headers.
    if (uri.path.toLowerCase().endsWith('.mpd')) {
      if (source.networkPolicy != null) {
        throw const PlaybackFailure(
          '此来源的 DASH 视频请下载完成后播放',
          PlaybackFailureKind.restricted,
        );
      }
      require(lanAddress == null, '此 DASH 视频暂不支持电视投屏，请更换 MP4 或 HLS 资源');
      require(source.headers.isEmpty, '此 DASH 视频需要专用授权，请使用内置播放器');
      _url = source.url;
      return;
    }
    final server = await HttpServer.bind(
      lanAddress ?? InternetAddress.loopbackIPv4,
      0,
    );
    if (_closed) {
      await server.close(force: true);
      throw const AppException('第三方播放已取消');
    }
    _server = server;
    _url = _localFile == null
        ? _register(uri).toString()
        : Uri(
            scheme: 'http',
            host: _host,
            port: server.port,
            path: '/$_token/local/video',
          ).toString();
    server.listen((request) {
      final task = _serve(request);
      _handlers.add(task);
      unawaited(task.whenComplete(() => _handlers.remove(task)));
    }, onError: (Object _) {});
  }

  Uri _register(Uri upstream) {
    source.networkPolicy?.checkedUrl(upstream.toString());
    require(
      {'http', 'https'}.contains(upstream.scheme) &&
          upstream.host.isNotEmpty &&
          upstream.userInfo.isEmpty,
      '播放列表含无效地址',
    );
    final path = _paths[upstream] ??= () {
      require(_resources.length < 65536, '播放列表过大，请重新打开视频');
      final suffix = upstream.path.toLowerCase().endsWith('.m3u8')
          ? 'index.m3u8'
          : 'video';
      final path = '/$_token/${_resources.length}/$suffix';
      _resources[path] = upstream;
      return path;
    }();
    return Uri(scheme: 'http', host: _host, port: _server!.port, path: path);
  }

  static bool _sameOrigin(Uri a, Uri b) =>
      a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  Map<String, String> _headers(Uri url) {
    final headers = source.networkPolicy == null
        ? source.headers
        : DownloadNetworkPolicy.redirectedHeaders(
            Uri.parse(source.url),
            url,
            source.headers,
          );
    return {
      for (final entry in headers.entries)
        if (!_hopHeaders.contains(entry.key.toLowerCase()) &&
            !{
              'range',
              'if-range',
              'accept-encoding',
            }.contains(entry.key.toLowerCase()) &&
            (_sameOrigin(Uri.parse(source.url), url) ||
                !_originHeaders.contains(entry.key.toLowerCase())))
          entry.key: entry.value,
    };
  }

  static const _credentials = {
    'cookie',
    'authorization',
    'proxy-authorization',
  };
  // Source Host overrides can select a delivery route. A different origin
  // needs its own URL-derived Host, just as it must not receive account headers.
  static const _originHeaders = {'host', ..._credentials};
  static const _hopHeaders = {
    'connection',
    'keep-alive',
    'transfer-encoding',
    'content-length',
    'te',
    'trailer',
    'upgrade',
    'proxy-connection',
  };

  bool _playlist(Uri uri, HttpClientResponse response) =>
      uri.path.toLowerCase().endsWith('.m3u8') ||
      (response.headers.contentType?.mimeType.contains('mpegurl') ?? false);

  // Null means a fragmented prefix could still become an HLS signature.
  // Only inspect a bounded prefix so ordinary video bytes stream immediately.
  static bool? _playlistPrefix(List<int> bytes) {
    final prefix = bytes.take(128).toList(growable: false);
    var index = 0;
    if (prefix.isNotEmpty && prefix.first == 0xef) {
      for (final byte in const [0xef, 0xbb, 0xbf]) {
        if (index >= prefix.length) return null;
        if (prefix[index++] != byte) return false;
      }
    }
    while (index < prefix.length &&
        const {9, 10, 11, 12, 13, 32}.contains(prefix[index])) {
      index++;
    }
    for (final byte in '#EXTM3U'.codeUnits) {
      if (index >= prefix.length) return null;
      if (prefix[index++] != byte) return false;
    }
    return true;
  }

  Future<(HttpClientResponse, Uri, HttpClientRequest)> _fetch(
    HttpRequest downstream,
    _RelayPeer peer,
    Uri initial, {
    bool omitRange = false,
  }) async {
    var url = initial;
    final viaProxy =
        _rangeProxy?.supported == true && initial == _rangeProxy!.uri;
    var credentialsAllowed = true;
    var policyHeaders = viaProxy ? <String, String>{} : _headers(initial);
    for (var redirects = 0; redirects <= 5; redirects++) {
      require(!_closed, '第三方播放已结束');
      if (!viaProxy) source.networkPolicy?.checkedUrl(url.toString());
      // Signed URLs can authorize GET without authorizing HEAD. Read only the
      // GET headers for a TV probe, then cancel its body below.
      final opening = (viaProxy ? _proxyClient : _client).openUrl(
        lanAddress != null && downstream.method == 'HEAD'
            ? 'GET'
            : downstream.method,
        url,
      );
      unawaited(
        opening.then<void>((request) {
          if (peer.cancelled || peer.finished || _closed) request.abort();
        }, onError: (Object _) {}),
      );
      final outgoing = await peer.wait(
        opening.timeout(const Duration(seconds: 35)),
      );
      _requests.add(outgoing);
      peer.upstream = outgoing;
      outgoing.followRedirects = false;
      final headers = viaProxy
          ? <String, String>{}
          : source.networkPolicy == null
          ? _headers(url)
          : Map<String, String>.of(policyHeaders);
      if (!credentialsAllowed) {
        headers.removeWhere(
          (name, _) => _credentials.contains(name.toLowerCase()),
        );
      }
      headers.forEach(outgoing.headers.set);
      outgoing.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (!omitRange && !url.path.toLowerCase().endsWith('.m3u8')) {
        for (final name in [
          HttpHeaders.rangeHeader,
          HttpHeaders.ifRangeHeader,
        ]) {
          final value = downstream.headers.value(name);
          if (value != null) outgoing.headers.set(name, value);
        }
      }
      final HttpClientResponse response;
      try {
        final receiving = outgoing.close();
        unawaited(
          receiving.then<void>((response) async {
            if (peer.cancelled || peer.finished || _closed) {
              await response.listen((_) {}).cancel();
            }
          }, onError: (Object _) {}),
        );
        response = await peer.wait(
          receiving.timeout(
            const Duration(seconds: 20),
            onTimeout: () {
              throw TimeoutException('External video response timeout');
            },
          ),
        );
      } catch (_) {
        outgoing.abort();
        _requests.remove(outgoing);
        rethrow;
      }
      if (!{301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return (response, url, outgoing);
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.listen((_) {}).cancel();
      _requests.remove(outgoing);
      require(location != null && redirects < 5, '视频地址重定向失败');
      final next = url.resolve(location!);
      require(!viaProxy, '内部投屏传输不应发生重定向');
      source.networkPolicy?.checkedUrl(next.toString());
      require(
        {'http', 'https'}.contains(next.scheme) &&
            next.userInfo.isEmpty &&
            !(url.scheme == 'https' && next.scheme != 'https'),
        '视频地址重定向无效',
      );
      if (!_sameOrigin(url, next)) credentialsAllowed = false;
      if (source.networkPolicy != null) {
        policyHeaders = DownloadNetworkPolicy.redirectedHeaders(
          url,
          next,
          headers,
        );
      }
      url = next;
    }
    throw const AppException('视频地址重定向过多');
  }

  String _rewrite(String text, Uri base) => text
      .split('\n')
      .map((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return line;
        String local(String value) {
          final uri = base.resolve(value);
          // Inline encryption keys do not require an HTTP fetch.
          if (uri.scheme == 'data') return value;
          return _register(uri).toString();
        }

        if (!trimmed.startsWith('#')) return local(trimmed);
        return line.replaceAllMapped(
          RegExp(r'\bURI="([^"]+)"'),
          (match) => 'URI="${local(match[1]!)}"',
        );
      })
      .join('\n');

  Future<void> _serve(HttpRequest request) async {
    _RelayPeer? peer;
    HttpClientRequest? outgoing;
    StreamIterator<List<int>>? body;
    final watch = Stopwatch()..start();
    try {
      // Detach before contacting the source: HttpResponse.done does not report
      // abandoned streaming responses. Own HTTP framing and socket backpressure
      // so even a TV disconnect while waiting for a source slot cancels work.
      peer = await _RelayPeer.open(request);
      _peers.add(peer);
      if (_closed) peer.cancel();
      final upstream = _resources[request.uri.path];
      final local =
          _localFile != null && request.uri.path == '/$_token/local/video';
      if (_closed ||
          upstream == null && !local ||
          lanAddress == null && request.uri.hasQuery) {
        peer.statusCode = HttpStatus.notFound;
        return;
      }
      if (!{'GET', 'HEAD'}.contains(request.method)) {
        peer.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      requestsServed++;
      if (_handlers.length >= 24) {
        peer.statusCode = HttpStatus.serviceUnavailable;
        peer.headers.set(HttpHeaders.retryAfterHeader, '1');
        return;
      }
      if (lanAddress != null) {
        peer.headers.set('transferMode.dlna.org', 'Streaming');
        peer.headers.set(
          'contentFeatures.dlna.org',
          'DLNA.ORG_OP=01;DLNA.ORG_CI=0',
        );
      }
      if (local) {
        await _serveLocal(request, peer, _localFile!);
        return;
      }
      var fetched = await _fetch(request, peer, upstream!);
      outgoing = fetched.$3;
      if (fetched.$1.statusCode == HttpStatus.partialContent &&
          _playlist(fetched.$2, fetched.$1)) {
        await fetched.$1.listen((_) {}).cancel();
        _requests.remove(outgoing);
        fetched = await _fetch(request, peer, upstream, omitRange: true);
        outgoing = fetched.$3;
      }
      final (response, resolved, _) = fetched;
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      final httpFailure = PlaybackFailure.http(response.statusCode);
      if (httpFailure != null) {
        // The worker may report a precise expired/restricted failure and then
        // close its local response with 502. Preserve the source diagnosis.
        final typedProxyFailure =
            _rangeProxy?.supported == true &&
            {
              PlaybackFailureKind.expired,
              PlaybackFailureKind.restricted,
            }.contains(failure?.kind);
        if (!typedProxyFailure) {
          failure = httpFailure;
          onFailure?.call(httpFailure);
        }
      } else if (ok && _rangeProxy == null) {
        failure = null;
      }
      if (lanAddress != null) {
        if ({401, 403}.contains(response.statusCode)) {
          lastError = '视频链接已失效或网盘拒绝访问，请刷新链接后重试投屏';
        } else if (response.statusCode == 404) {
          lastError = '视频资源不存在，请刷新链接或更换资源';
        } else if (response.statusCode >= 500) {
          lastError = '视频源暂时无法访问，请稍后重试';
        } else if (ok) {
          lastError = '';
        }
      }
      var playlist = ok && _playlist(resolved, response);
      peer.statusCode = response.statusCode;
      for (final name in [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentEncodingHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = response.headers.value(name);
        if (value != null) peer.headers.set(name, value);
      }
      peer.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      if (lanAddress != null &&
          request.uri.path == Uri.parse(_url).path &&
          !playlist &&
          (response.headers.contentType == null ||
              response.headers.contentType?.mimeType ==
                  'application/octet-stream')) {
        peer.headers.set(HttpHeaders.contentTypeHeader, mimeType);
      }
      if (request.method == 'HEAD') {
        if (!playlist) peer.contentLength = response.contentLength;
        await response.listen((_) {}).cancel();
        return;
      }
      final encoding = response.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      final payload = playlist && encoding == 'gzip'
          ? gzip.decoder.bind(response)
          : response;
      body = StreamIterator(payload.timeout(const Duration(seconds: 60)));
      peer.body = body;
      _bodies.add(body);
      final hasFirst = await peer.wait(body.moveNext());
      var first = hasFirst ? body.current : const <int>[];
      if (ok && !playlist && (encoding == null || encoding == 'identity')) {
        var detected = _playlistPrefix(first);
        if (detected == null && hasFirst) {
          final prefix = BytesBuilder(copy: false)..add(first);
          while (detected == null &&
              prefix.length < 128 &&
              await peer.wait(body.moveNext())) {
            prefix.add(body.current);
            detected = _playlistPrefix(prefix.toBytes());
          }
          first = prefix.takeBytes();
        }
        playlist = detected == true;
      }
      if (playlist) {
        peer.headers.set(
          'contentFeatures.dlna.org',
          'DLNA.ORG_OP=00;DLNA.ORG_CI=0',
        );
        final bytes = BytesBuilder(copy: false)..add(first);
        require(bytes.length <= 4 * 1024 * 1024, '播放列表过大');
        while (await peer.wait(body.moveNext())) {
          bytes.add(body.current);
          require(bytes.length <= 4 * 1024 * 1024, '播放列表过大');
        }
        final data = bytes.takeBytes();
        final rewritten = utf8.encode(
          _rewrite(utf8.decode(data).trimLeft(), resolved),
        );
        peer.headers.removeAll(HttpHeaders.contentEncodingHeader);
        peer.headers.removeAll(HttpHeaders.contentRangeHeader);
        peer.headers.removeAll(HttpHeaders.acceptRangesHeader);
        peer.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        peer.contentLength = rewritten.length;
        peer.add(rewritten);
      } else {
        peer.contentLength = response.contentLength;
        if (hasFirst) peer.add(first);
        await peer.flush();
        while (!_closed && await peer.wait(body.moveNext())) {
          peer.add(body.current);
          await peer.flush();
        }
      }
    } catch (error) {
      if (peer?.cancelled == true || _closed) return;
      if (!_closed && error is DownloadNetworkPolicyException) {
        failure = PlaybackFailure(
          error.message,
          PlaybackFailureKind.restricted,
        );
        onFailure?.call(failure!);
      }
      if (lanAddress != null) {
        lastError = error is DownloadNetworkPolicyException
            ? error.message
            : '视频中转连接失败，请检查网络或刷新视频链接';
      }
      try {
        if (peer?.headersSent == true) {
          peer!.cancel();
        } else {
          peer?.statusCode = HttpStatus.badGateway;
        }
      } catch (_) {}
    } finally {
      outgoing?.abort();
      _requests.remove(outgoing);
      try {
        await body?.cancel();
      } catch (_) {}
      _bodies.remove(body);
      try {
        if (peer != null) {
          await peer.close();
        } else {
          await request.response.close();
        }
      } catch (_) {}
      _peers.remove(peer);
      if (lanAddress != null) {
        DiagnosticLog.event(
          'cast.relay_request',
          fields: {
            'relay': DiagnosticLog.reference(_token),
            'method': request.method,
            'status': peer?.statusCode,
            'cancelled': peer?.cancelled,
            'bytes': peer?.bytesSent,
            'elapsed_ms': watch.elapsedMilliseconds,
            'active': _handlers.length,
          },
        );
      }
    }
  }

  Future<void> _serveLocal(
    HttpRequest request,
    _RelayPeer peer,
    LanLocalFile file,
  ) async {
    await _files!.check(file);
    var start = 0, end = file.size;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
      bool valid =
          match != null && (match[1]!.isNotEmpty || match[2]!.isNotEmpty);
      if (valid) {
        if (match[1]!.isEmpty) {
          final suffix = int.tryParse(match[2]!);
          valid = suffix != null && suffix > 0;
          if (valid) start = (file.size - suffix).clamp(0, file.size);
        } else {
          final parsedStart = int.tryParse(match[1]!);
          final parsedEnd = match[2]!.isEmpty
              ? file.size - 1
              : int.tryParse(match[2]!);
          valid =
              parsedStart != null &&
              parsedEnd != null &&
              parsedEnd >= parsedStart;
          if (valid) {
            start = parsedStart;
            end = (parsedEnd + 1).clamp(0, file.size);
          }
        }
      }
      if (!valid || start >= file.size || start >= end) {
        peer.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        peer.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${file.size}',
        );
        return;
      }
      peer.statusCode = HttpStatus.partialContent;
      peer.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/${file.size}',
      );
    }
    peer.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    peer.headers.set(HttpHeaders.contentTypeHeader, mimeType);
    peer.contentLength = end - start;
    if (request.method != 'HEAD') {
      final body = StreamIterator(
        _files.read(file, start, end).timeout(const Duration(seconds: 60)),
      );
      peer.body = body;
      try {
        while (await peer.wait(body.moveNext())) {
          peer.add(body.current);
          await peer.flush();
        }
      } finally {
        await body.cancel();
      }
    }
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    for (final request in _requests.toList()) {
      request.abort();
    }
    for (final peer in _peers.toList()) {
      peer.cancel();
    }
    final cancels = _bodies.toList().map((body) async {
      try {
        await body.cancel();
      } catch (_) {}
    }).toList();
    _client.close(force: true);
    _proxyClient.close(force: true);
    await _rangeProxy?.close();
    await _server?.close(force: true);
    await Future.wait(cancels);
    await Future.wait(_handlers.toList());
    _resources.clear();
    _paths.clear();
  }();
}

class _RelayCancelled implements Exception {}

class _RelayHeaders {
  final values = <String, String>{};
  void set(String name, Object value) => values[name.toLowerCase()] = '$value';
  void removeAll(String name) => values.remove(name.toLowerCase());
  set contentType(ContentType value) =>
      set(HttpHeaders.contentTypeHeader, value);
}

/// Close-delimited HTTP avoids chunk framing and lets us observe peer FIN/RST
/// even before upstream headers arrive. No TV-provided query is forwarded.
class _RelayPeer {
  _RelayPeer(this.socket, this.head) {
    subscription = socket.listen(
      (_) {},
      onDone: cancel,
      onError: (Object _) => cancel(),
    );
  }
  static Future<_RelayPeer> open(HttpRequest request) async => _RelayPeer(
    await request.response.detachSocket(writeHeaders: false),
    request.method == 'HEAD',
  );
  final Socket socket;
  final bool head;
  late final StreamSubscription<List<int>> subscription;
  final headers = _RelayHeaders();
  final _cancelled = Completer<void>();
  HttpClientRequest? upstream;
  StreamIterator<List<int>>? body;
  bool cancelled = false, finished = false, headersSent = false;
  int statusCode = HttpStatus.ok, contentLength = -1, bytesSent = 0;
  Future<T> wait<T>(Future<T> operation) {
    if (cancelled) {
      operation.ignore();
      return Future.error(_RelayCancelled());
    }
    return Future.any([
      operation,
      _cancelled.future.then<T>((_) => throw _RelayCancelled()),
    ]);
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _cancelled.complete();
    upstream?.abort();
    unawaited(body?.cancel().catchError((Object _) {}) ?? Future<void>.value());
    socket.destroy();
  }

  void _sendHeaders() {
    if (cancelled) throw _RelayCancelled();
    if (headersSent) return;
    headersSent = true;
    final reason = switch (statusCode) {
      200 => 'OK',
      206 => 'Partial Content',
      404 => 'Not Found',
      405 => 'Method Not Allowed',
      416 => 'Range Not Satisfiable',
      502 => 'Bad Gateway',
      503 => 'Service Unavailable',
      _ => 'Response',
    };
    final text = StringBuffer(
      'HTTP/1.1 $statusCode $reason\r\nConnection: close\r\n',
    );
    if (contentLength >= 0) text.write('Content-Length: $contentLength\r\n');
    for (final entry in headers.values.entries) {
      text.write('${entry.key}: ${entry.value}\r\n');
    }
    text.write('\r\n');
    socket.add(latin1.encode(text.toString()));
  }

  void add(List<int> bytes) {
    _sendHeaders();
    if (!head) {
      socket.add(bytes);
      bytesSent += bytes.length;
    }
  }

  Future<void> flush() {
    _sendHeaders();
    return wait(socket.flush().timeout(const Duration(seconds: 20)));
  }

  Future<void> close() async {
    try {
      if (!cancelled) {
        await flush();
        await socket.close();
      }
    } catch (_) {
      cancel();
    } finally {
      finished = true;
      await subscription.cancel();
      socket.destroy();
    }
  }
}
