import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/downloads.dart';
import '../download/download_playback_cache.dart';
import 'playback_failure.dart';
import 'stream_proxy.dart';

/// Only control messages and periodic counters cross the UI isolate. HTTP,
/// Range validation, buffering and socket backpressure stay in the worker.
class IsolatedPlaybackStreamProxy extends PlaybackStreamProxy {
  IsolatedPlaybackStreamProxy(
    super.source, {
    super.connections,
    super.chunkBytes,
    super.maxCacheBytes,
    super.warmupBytes,
    super.onFailure,
    super.readCache,
    super.cacheSnapshot,
  });
  final _events = ReceivePort();
  final _ready = Completer<SendPort?>();
  final _pending = <int, Completer<Object?>>{};
  Isolate? _worker;
  SendPort? _commands;
  StreamSubscription<Object?>? _subscription;
  Map<String, Object?> _snapshot = {};
  Uri? _uri;
  int _serial = 0;
  bool _closed = false, _started = false, _available = false;
  bool _failed = false;
  bool _pausedIntent = false;
  Future<void>? _closeFuture;

  @override
  Future<bool> start() async {
    if (_started || _closed) return supported;
    _started = true;
    _subscription = _events.listen(_event);
    // A data-only entry point avoids copying the backend, player FFI pointers
    // or download-manager closures into the new isolate.
    _worker = await Isolate.spawn(
      _proxyWorker,
      <String, Object?>{
        'events': _events.sendPort,
        'source': source.toJson(),
        'connections': super.connections,
        'chunkBytes': chunkBytes,
        'maxCacheBytes': super.maxCacheBytes,
        'warmupBytes': warmupBytes,
        'readCache': readCache != null,
        'cacheSnapshot': cacheSnapshot != null,
      },
      onExit: _events.sendPort,
      onError: _events.sendPort,
      debugName: 'playback-range-proxy',
    );
    if (_closed) {
      _worker?.kill(priority: Isolate.immediate);
      return false;
    }
    _commands = await _ready.future.timeout(const Duration(seconds: 10));
    if (_closed || _commands == null) return false;
    _send('paused', _pausedIntent);
    final result = await _call('start');
    _available = !_closed && result == true;
    return _available;
  }

  void _event(Object? message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! Map) {
      if (!_closed && !_failed) {
        _failed = true;
        const failure = PlaybackFailure(
          '播放传输进程已停止，请重试',
          PlaybackFailureKind.network,
        );
        _available = false;
        if (!_ready.isCompleted) _ready.completeError(failure);
        for (final pending in _pending.values) {
          pending.completeError(failure);
        }
        _pending.clear();
        onFailure?.call(failure);
      }
      return;
    }
    switch (message['type']) {
      case 'snapshot':
        _snapshot = Map<String, Object?>.from(message['fields'] as Map);
        final url = message['uri'];
        if (url is String) _uri = Uri.parse(url);
      case 'reply':
        final pending = _pending.remove(message['id']);
        if (message['error'] case final PlaybackFailure failure) {
          pending?.completeError(failure);
        } else {
          pending?.complete(message['value']);
        }
      case 'failure':
        if (!_closed) onFailure?.call(message['failure'] as PlaybackFailure);
      case 'cache':
        unawaited(_cache(message));
    }
  }

  Future<void> _cache(Map message) async {
    final reply = message['reply'] as SendPort;
    Object? result, error;
    try {
      if (!_closed) {
        if (message['operation'] == 'snapshot') {
          result = await cacheSnapshot?.call();
        } else {
          final bytes = await readCache?.call(
            message['start'] as int,
            message['end'] as int,
            message['identity'] as RemoteIdentity,
          );
          if (bytes != null) result = TransferableTypedData.fromList([bytes]);
        }
      }
    } catch (e) {
      error = e is PlaybackFailure
          ? e
          : PlaybackFailure(
              e is AppException ? e.message : '下载缓存暂时无法读取',
              PlaybackFailureKind.network,
            );
    }
    reply.send({'value': result, 'error': error});
  }

  Future<Object?> _call(String method, [Object? value]) {
    if (_failed) return Future.value(null);
    final port = _commands;
    if (port == null) return Future.value(null);
    final id = ++_serial, pending = Completer<Object?>();
    _pending[id] = pending;
    port.send({'id': id, 'method': method, 'value': value});
    return pending.future;
  }

  void _send(String method, [Object? value]) {
    if (!_closed) _commands?.send({'method': method, 'value': value});
  }

  int _count(String name) => (_snapshot[name] as num?)?.toInt() ?? 0;
  @override
  bool get supported => !_closed && _available;
  @override
  Uri get uri => _uri!;
  @override
  int get length => _count('fileBytes');
  @override
  int get cachedBytes => _count('cachedBytes');
  @override
  int get bufferedBytes => _count('bufferedBytes');
  @override
  int get activeRequests => _count('activeRequests');
  @override
  int get receivedBytes => _count('receivedBytes');
  @override
  int get segmentFailures => _count('segmentFailures');
  @override
  int? get lastUpstreamStatus => _snapshot['upstreamStatus'] as int?;
  @override
  int get generation => _count('generation');
  @override
  int get maxCacheBytes =>
      (_snapshot['cacheLimitBytes'] as int?) ?? super.maxCacheBytes;
  @override
  String? get playlistMime => _snapshot['playlistMime'] as String?;
  @override
  Map<String, Object?> get diagnosticFields => {
    ..._snapshot,
    'proxyIsolate': true,
  };
  @override
  set connections(int value) {
    super.connections = value;
    _send('connections', super.connections);
  }

  @override
  bool resizeCache(int bytes) => false; // A remote resize needs acknowledgement.
  @override
  Future<bool> resizeCacheAsync(int bytes) async =>
      !_closed && await _call('resize', bytes) == true;
  @override
  void setPaused(bool value) {
    _pausedIntent = value;
    _send('paused', value);
  }

  @override
  void prepareSeek() => _send('seek');
  @override
  Future<void> prepareSeekAsync() async {
    if (!_closed) await _call('seek');
  }

  @override
  void interruptReadForSeek() => _send('interrupt');
  @override
  void observeThroughput({
    required double receivedBytesPerSecond,
    required double requiredBytesPerSecond,
    required bool buffering,
  }) => _send('throughput', (
    receivedBytesPerSecond,
    requiredBytesPerSecond,
    buffering,
  ));
  @override
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closed = true;
    _available = false;
    if (!_ready.isCompleted) _ready.complete(null);
    try {
      if (_commands != null) {
        await _call('close').timeout(const Duration(seconds: 5));
      }
    } catch (_) {
      // Force teardown if a download callback or upstream read is stuck.
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      for (final pending in _pending.values) {
        pending.complete(null);
      }
      _pending.clear();
      _events.close();
      await _subscription?.cancel();
    }
  }
}

Future<void> _proxyWorker(Map<String, Object?> config) async {
  final events = config['events'] as SendPort;
  final commands = ReceivePort();
  Future<Object?> cache(Map<String, Object?> request) async {
    final reply = ReceivePort();
    try {
      events.send({'type': 'cache', ...request, 'reply': reply.sendPort});
      final result =
          await reply.first.timeout(const Duration(seconds: 10)) as Map;
      if (result['error'] case final Object error) throw error;
      final value = result['value'];
      return value is TransferableTypedData
          ? value.materialize().asUint8List()
          : value;
    } finally {
      reply.close();
    }
  }

  final proxy = PlaybackStreamProxy(
    DownloadSpec.fromJson(asJson(config['source'])),
    connections: config['connections'] as int,
    chunkBytes: config['chunkBytes'] as int,
    maxCacheBytes: config['maxCacheBytes'] as int,
    warmupBytes: config['warmupBytes'] as int,
    onFailure: (failure) =>
        events.send({'type': 'failure', 'failure': failure}),
    readCache: config['readCache'] == true
        ? (start, end, identity) async =>
              await cache({
                    'operation': 'read',
                    'start': start,
                    'end': end,
                    'identity': identity,
                  })
                  as Uint8List?
        : null,
    cacheSnapshot: config['cacheSnapshot'] == true
        ? () async =>
              await cache({'operation': 'snapshot'}) as DownloadReadableState?
        : null,
  );
  void snapshot() => events.send({
    'type': 'snapshot',
    'uri': proxy.supported ? proxy.uri.toString() : null,
    'fields': {
      ...proxy.diagnosticFields,
      'cachedBytes': proxy.cachedBytes,
      'generation': proxy.generation,
      'playlistMime': proxy.playlistMime,
    },
  });
  final timer = Timer.periodic(
    const Duration(milliseconds: 500),
    (_) => snapshot(),
  );
  events.send(commands.sendPort);
  commands.listen((raw) async {
    final message = raw as Map;
    Object? result, error;
    try {
      switch (message['method']) {
        case 'start':
          result = await proxy.start();
        case 'connections':
          proxy.connections = message['value'] as int;
        case 'paused':
          proxy.setPaused(message['value'] as bool);
        case 'seek':
          proxy.prepareSeek();
        case 'interrupt':
          proxy.interruptReadForSeek();
        case 'resize':
          result = proxy.resizeCache(message['value'] as int);
        case 'throughput':
          final (received, required, buffering) =
              message['value'] as (double, double, bool);
          proxy.observeThroughput(
            receivedBytesPerSecond: received,
            requiredBytesPerSecond: required,
            buffering: buffering,
          );
        case 'close':
          timer.cancel();
          await proxy.close();
          commands.close();
      }
    } catch (e) {
      error = e is PlaybackFailure
          ? e
          : const PlaybackFailure('播放分段传输失败，请重试', PlaybackFailureKind.network);
    }
    snapshot();
    if (message['id'] != null) {
      events.send({
        'type': 'reply',
        'id': message['id'],
        'value': result,
        'error': error,
      });
    }
  });
}
