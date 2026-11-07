part of 'lan_service.dart';

const _reverseChunkBytes = 64 * 1024;
const _reverseMaxRequests = 16;
const _reverseHeaderBytes = 36;
const _reverseTimeout = Duration(seconds: 30);

class _LanForwardedFile {
  _LanForwardedFile(
    this.origin,
    this.entry,
    this.token,
    this.transfer,
    this.peerId,
  );
  final Uri origin;
  final LanFileEntry entry;
  final String token, transfer;
  String peerId;
  int active = 0;
}

class _LanReverseJob {
  _LanReverseJob(this.service, this.channel, this.id) {
    // A disconnect can arrive before the header waiter is installed.
    unawaited(
      header.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  final LanService service;
  final _LanReverseChannel channel;
  final String id;
  final header = Completer<Json>();
  late final data = StreamController<Uint8List>(onCancel: cancel);
  int sequence = 0;
  int received = 0;
  int expected = -1;
  int acknowledged = -1;
  bool finished = false;

  void metadata(Json message) {
    if (finished || header.isCompleted) return;
    final status = message.integer('status');
    expected = message.integer('length', -1);
    if (status < 200 ||
        status > 599 ||
        expected < -1 ||
        jsonEncode(message['headers']).length > 16384) {
      fail(const _LanConnectionError());
      return;
    }
    header.complete(message);
  }

  void chunk(Uint8List bytes, int seq) {
    if (finished) return;
    if (!header.isCompleted ||
        seq != sequence ||
        sequence - acknowledged > 1 ||
        bytes.length > _reverseChunkBytes ||
        expected >= 0 && received + bytes.length > expected) {
      channel.close();
      return;
    }
    sequence++;
    received += bytes.length;
    data.add(bytes);
  }

  void acknowledge(int seq) {
    if (!finished && seq == acknowledged + 1 && seq < sequence) {
      acknowledged = seq;
      channel.send({'kind': 'ack', 'id': id, 'seq': seq});
    }
  }

  void end() {
    if (finished) return;
    if (!header.isCompleted || expected >= 0 && received != expected) {
      fail(const _LanConnectionError());
      return;
    }
    finished = true;
    service._reversePending.remove(id);
    unawaited(data.close());
  }

  void fail(Object error) {
    if (finished) return;
    finished = true;
    service._reversePending.remove(id);
    channel.send({'kind': 'cancel', 'id': id});
    if (!header.isCompleted) {
      header.completeError(error);
    } else {
      data.addError(error);
    }
    unawaited(data.close());
  }

  void cancel() {
    if (finished) return;
    channel.send({'kind': 'cancel', 'id': id});
    finished = true;
    service._reversePending.remove(id);
    if (!header.isCompleted) header.completeError(const _LanConnectionError());
    unawaited(data.close());
  }
}

class _LanReverseChannel {
  _LanReverseChannel(
    this.service,
    this.session,
    this.socket,
    this.localAddress,
  ) {
    socket.pingInterval = const Duration(seconds: 15);
    socket.listen(receive, onDone: close, onError: (Object _) => close());
  }
  final LanService service;
  final _LanSession session;
  final WebSocket socket;
  final String localAddress;
  bool closed = false;

  void send(Json message) {
    if (closed) return;
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      close();
    }
  }

  void receive(dynamic message) {
    if (closed) return;
    if (!session.expires.isAfter(service.clock()) ||
        !service._sessions.values.contains(session)) {
      close();
      return;
    }
    try {
      if (message is String) {
        if (message.length > 32768) throw const _LanConnectionError();
        final data = asJson(jsonDecode(message));
        final job = service._reversePending[data.str('id')];
        if (job == null || job.channel != this) return;
        switch (data.str('kind')) {
          case 'header':
            job.metadata(data);
          case 'end':
            job.end();
          case 'error':
            job.fail(const _LanConnectionError());
        }
      } else if (message is List<int>) {
        if (message.length <= _reverseHeaderBytes ||
            message.length > _reverseHeaderBytes + _reverseChunkBytes) {
          throw const _LanConnectionError();
        }
        final bytes = message is Uint8List
            ? message
            : Uint8List.fromList(message);
        final id = ascii.decode(bytes.sublist(0, 32));
        final job = service._reversePending[id];
        if (job == null || job.channel != this) return;
        job.chunk(
          Uint8List.sublistView(bytes, _reverseHeaderBytes),
          ByteData.sublistView(bytes, 32, 36).getUint32(0),
        );
      } else {
        throw const _LanConnectionError();
      }
    } catch (_) {
      close();
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    if (service._reverseChannels[session.id] == this) {
      service._reverseChannels.remove(session.id);
    }
    for (final job in service._reversePending.values.toList()) {
      if (job.channel == this) job.fail(const _LanConnectionError());
    }
    unawaited(socket.close().then<void>((_) {}, onError: (Object _) {}));
  }
}

class _LanReverseOutgoing {
  _LanReverseOutgoing(this.id);
  final String id;
  final cancelled = Completer<void>();
  HttpClientRequest? request;
  Completer<void>? ack;
  int sequence = -1;
  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
    request?.abort();
    if (ack?.isCompleted == false) ack!.complete();
  }
}

class _LanReverseWorker {
  _LanReverseWorker(this.service, this.peer, this.token);
  final LanService service;
  final LanPeer peer;
  final String token;
  final jobs = <String, _LanReverseOutgoing>{};
  WebSocket? socket;
  HttpClient? client;
  String? sourceAddress;
  Timer? reconnect;
  bool stopped = false, connecting = false;
  int failures = 0;

  bool get valid =>
      !stopped &&
      service.running &&
      service._peerSessions[peer.id]?.token == token &&
      service._peerSessions[peer.id]!.expires.isAfter(service.clock());

  Future<void> connect() async {
    if (!valid || connecting || socket != null) return;
    connecting = true;
    HttpClient? http;
    var expired = false;
    try {
      sourceAddress = await service._outgoingAddress(peer);
      http = service._shareClient(sourceAddress!);
      if (!valid) return;
      client = http;
      final opening = WebSocket.connect(
        peer.base.replace(scheme: 'ws', path: '/v1/reverse').toString(),
        headers: {'Authorization': 'Bearer $token'},
        customClient: http,
        compression: CompressionOptions.compressionOff,
      );
      unawaited(
        opening.then<void>((lateSocket) {
          if (expired || !valid) {
            unawaited(
              lateSocket.close().then<void>(
                (_) {},
                onError: (Object _, StackTrace _) {},
              ),
            );
          }
        }, onError: (Object _, StackTrace _) {}),
      );
      final ws = await opening.timeout(const Duration(seconds: 5));
      if (!valid) {
        await ws.close();
        return;
      }
      socket = ws;
      failures = 0;
      ws.pingInterval = const Duration(seconds: 15);
      // The channel belongs to the service, not the pairing dialog's scope.
      service._serviceZone.run(
        () => ws.listen(
          (message) {
            if (socket == ws) receive(message);
          },
          onDone: () => disconnected(ws),
          onError: (Object _) => disconnected(ws),
        ),
      );
      DiagnosticLog.event(
        'lan.reverse_ready',
        fields: {'peer': DiagnosticLog.reference(peer.id)},
      );
    } catch (_) {
      failures++;
    } finally {
      expired = true;
      connecting = false;
      if (socket == null) {
        http?.close(force: true);
        if (client == http) client = null;
        scheduleReconnect();
      }
    }
  }

  void scheduleReconnect() {
    if (!valid || reconnect != null) return;
    reconnect = service._serviceZone.run(
      () => Timer(
        Duration(seconds: const [1, 2, 5, 10][(failures - 1).clamp(0, 3)]),
        () {
          reconnect = null;
          unawaited(connect());
        },
      ),
    );
  }

  void receive(dynamic message) {
    if (!valid || message is! String || message.length > 256 * 1024) {
      disconnected();
      return;
    }
    try {
      final data = asJson(jsonDecode(message)), id = data.str('id');
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) return;
      switch (data.str('kind')) {
        case 'request':
          if (jobs.containsKey(id)) return;
          if (jobs.length >= _reverseMaxRequests) {
            socket?.add(
              jsonEncode({
                'kind': 'header',
                'id': id,
                'status': 503,
                'length': 0,
                'headers': {'retry-after': '2'},
              }),
            );
            socket?.add(jsonEncode({'kind': 'end', 'id': id}));
            return;
          }
          final job = _LanReverseOutgoing(id);
          jobs[id] = job;
          unawaited(service._serviceZone.run(() => serve(job, data)));
        case 'ack':
          final job = jobs[id];
          if (job != null &&
              job.sequence == data.integer('seq', -1) &&
              job.ack?.isCompleted == false) {
            job.ack!.complete();
          }
        case 'cancel':
          jobs[id]?.cancel();
      }
    } catch (_) {
      disconnected();
    }
  }

  Future<void> serve(_LanReverseOutgoing job, Json data) async {
    final ws = socket;
    final permit = lanId();
    try {
      if (!valid || ws == null) throw const _LanConnectionError();
      final method = data.str('method'), path = data.str('path');
      final body = data['body'];
      final uri = Uri.tryParse(path);
      require(
        uri != null &&
            !uri.hasAuthority &&
            uri.scheme.isEmpty &&
            uri.fragment.isEmpty &&
            _reversePath(method, uri.path),
        '转发请求无效',
      );
      final expires = service._peerSessions[peer.id]!.expires;
      service._forwardedRequests[permit] = (
        session: _LanSession(peer.id, peer.address, peer.name, expires),
        token: token,
      );
      final opening = service._loopbackHttp.openUrl(
        method,
        service._localHttpBase.resolveUri(uri!),
      );
      unawaited(
        opening.then<void>((request) {
          if (job.cancelled.isCompleted || !valid || socket != ws) {
            request.abort();
          }
        }, onError: (Object _, StackTrace _) {}),
      );
      job.request = await opening.timeout(const Duration(seconds: 5));
      if (job.cancelled.isCompleted) throw const _LanConnectionError();
      final request = job.request!;
      request.followRedirects = false;
      request.headers.set('X-AsterLink-Forwarded-Session', permit);
      for (final entry in strings(data['headers']).entries) {
        if ({'range', 'if-range', 'accept'}.contains(entry.key.toLowerCase()) &&
            entry.value.length <= 1024) {
          request.headers.set(entry.key, entry.value);
        }
      }
      if (method == 'POST') {
        final encoded = utf8.encode(jsonEncode(body));
        require(encoded.length <= 256 * 1024, '转发请求过大');
        request.headers.contentType = ContentType.json;
        request.add(encoded);
      }
      final response = await request.close().timeout(_reverseTimeout);
      if (!valid || socket != ws || job.cancelled.isCompleted) return;
      final length = method == 'HEAD' ? 0 : response.contentLength;
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        if (_forwardHeaders.contains(name)) headers[name] = values.join(', ');
      });
      ws.add(
        jsonEncode({
          'kind': 'header',
          'id': job.id,
          'status': response.statusCode,
          'length': length,
          'headers': headers,
        }),
      );
      var seq = 0, sent = 0;
      await for (final chunk in response.timeout(_reverseTimeout)) {
        for (
          var offset = 0;
          offset < chunk.length;
          offset += _reverseChunkBytes
        ) {
          if (!valid || socket != ws || job.cancelled.isCompleted) return;
          final count = min(_reverseChunkBytes, chunk.length - offset);
          sent += count;
          if (length >= 0 && sent > length) throw const _LanConnectionError();
          final frame = Uint8List(_reverseHeaderBytes + count);
          frame.setRange(0, 32, ascii.encode(job.id));
          ByteData.sublistView(frame, 32, 36).setUint32(0, seq);
          frame.setRange(_reverseHeaderBytes, frame.length, chunk, offset);
          job.sequence = seq++;
          job.ack = Completer<void>();
          ws.add(frame);
          await Future.any([
            job.ack!.future,
            job.cancelled.future,
          ]).timeout(_reverseTimeout);
        }
      }
      if (length >= 0 && sent != length) throw const _LanConnectionError();
      if (valid && socket == ws && !job.cancelled.isCompleted) {
        ws.add(jsonEncode({'kind': 'end', 'id': job.id}));
      }
    } catch (_) {
      if (valid && socket == ws && !job.cancelled.isCompleted) {
        ws?.add(jsonEncode({'kind': 'error', 'id': job.id}));
      }
    } finally {
      service._forwardedRequests.remove(permit);
      jobs.remove(job.id);
      job.request?.abort();
      job.cancel();
    }
  }

  void disconnected([WebSocket? expected]) {
    if (expected != null && socket != expected) return;
    final ws = socket;
    socket = null;
    for (final job in jobs.values.toList()) {
      job.cancel();
    }
    client?.close(force: true);
    client = null;
    if (ws != null) {
      unawaited(ws.close().then<void>((_) {}, onError: (Object _) {}));
    }
    scheduleReconnect();
  }

  void stop() {
    stopped = true;
    reconnect?.cancel();
    reconnect = null;
    disconnected();
  }
}

const _forwardHeaders = {
  'content-length',
  'content-type',
  'content-range',
  'accept-ranges',
  'etag',
  'last-modified',
  'content-disposition',
  'retry-after',
};

bool _reversePath(String method, String path) =>
    method == 'POST' && path == '/v1/inbox' ||
    method == 'GET' && path == '/v1/shares' ||
    method == 'GET' && RegExp(r'^/v1/manifests/[a-f0-9]{32}$').hasMatch(path) ||
    {'GET', 'HEAD'}.contains(method) &&
        RegExp(r'^/v1/files/[a-f0-9]{32}/[a-f0-9]{32}$').hasMatch(path);

extension _LanReverse on LanService {
  Uri get _localHttpBase => Uri(
    scheme: 'http',
    host: bindAddress.isLoopback ? bindAddress.address : '127.0.0.1',
    port: port,
  );
  HttpClient get _loopbackHttp => _loopbackClient ??= HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 3)
    ..maxConnectionsPerHost = _reverseMaxRequests;

  Future<String> _outgoingAddress(LanPeer peer) async {
    final info = await _json(
      peer.base.replace(path: '/v1/shares'),
      session: _session(peer),
      retry: false,
      timeout: const Duration(seconds: 2),
    );
    final observed = info.str('senderAddress');
    require(addresses.contains(observed), '网络地址已变化，请重新配对');
    return observed;
  }

  void _startReverseWorker(LanPeer peer, String token) {
    _reverseWorkers.remove(peer.id)?.stop();
    final worker = _LanReverseWorker(this, peer, token);
    _reverseWorkers[peer.id] = worker;
    _serviceZone.run(
      () => unawaited(
        worker.connect().catchError((_) {
          worker.connecting = false;
          worker.scheduleReconnect();
        }),
      ),
    );
  }

  Future<void> _acceptReverse(HttpRequest request, String remote) async {
    final session = _authorize(request, remote);
    final paired = _peerSessions[session.id];
    require(paired != null && paired.expires.isAfter(clock()), '请先完成双向配对');
    final localAddress = Uri.parse(
      'http://${request.headers.value(HttpHeaders.hostHeader)}',
    ).host;
    final socket = await WebSocketTransformer.upgrade(
      request,
      compression: CompressionOptions.compressionOff,
    );
    if (!running ||
        !session.expires.isAfter(clock()) ||
        !_sessions.values.contains(session)) {
      await socket.close();
      return;
    }
    _reverseChannels.remove(session.id)?.close();
    _reverseChannels[session.id] = _serviceZone.run(
      () => _LanReverseChannel(this, session, socket, localAddress),
    );
  }

  LanPeer? _peerForOrigin(Uri origin) => _peers.values
      .where((peer) => peer.base.origin == origin.origin && connected(peer))
      .firstOrNull;

  Future<Json> _peerJson(
    LanPeer peer,
    String path, {
    String method = 'GET',
    Json? body,
    HttpClient? client,
    bool publicRead = false,
  }) async {
    final token = publicRead ? null : _session(peer);
    final capable = _reverseCapablePeers.contains(peer.id);
    for (var attempt = 0; ; attempt++) {
      try {
        final current = _reverseChannels[peer.id];
        if (current != null &&
            (_reversePreferred[peer.id]?.isAfter(clock()) ?? false)) {
          return await _reverseJson(current, path, method: method, body: body);
        }
        try {
          return await _json(
            peer.base.replace(path: path),
            method: method,
            session: token,
            body: body,
            client: client,
            retry: !capable,
            timeout: capable ? const Duration(seconds: 2) : null,
          );
        } on _LanConnectionError {
          RequestScope.checkpoint();
          final reverse = await _readyReverseChannel(peer.id);
          if (reverse == null || reverse.closed) rethrow;
          _reversePreferred[peer.id] = clock().add(const Duration(seconds: 30));
          return await _reverseJson(reverse, path, method: method, body: body);
        }
      } catch (error) {
        RequestScope.checkpoint();
        if (!capable || !_retryableLanRequest(error, path) || attempt >= 2) {
          rethrow;
        }
        await RequestScope.wait(
          Duration(milliseconds: attempt == 0 ? 200 : 700),
        );
      }
    }
  }

  Future<_LanReverseChannel?> _readyReverseChannel(String peerId) async {
    for (var attempt = 0; attempt < 20 && running; attempt++) {
      final channel = _reverseChannels[peerId];
      if (channel != null && !channel.closed) return channel;
      if (!_reverseCapablePeers.contains(peerId)) return null;
      if (_reverseWorkers[peerId]?.valid == true) return null;
      await RequestScope.wait(const Duration(milliseconds: 100));
    }
    return null;
  }

  Future<_LanReverseJob> _reverseRequest(
    _LanReverseChannel channel,
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String> headers = const {},
    void Function(_LanReverseJob)? onCreated,
  }) async {
    require(
      !channel.closed && channel.session.expires.isAfter(clock()),
      '连接已失效，请重新连接设备',
    );
    if (_reversePending.length >= _reverseMaxRequests) {
      throw const _LanRequestError('发送端忙，请稍后重试', 503);
    }
    final job = _LanReverseJob(this, channel, lanId());
    _reversePending[job.id] = job;
    try {
      onCreated?.call(job);
      if (!job.finished) {
        channel.send({
          'kind': 'request',
          'id': job.id,
          'path': path,
          'method': method,
          'headers': headers,
          'body': ?body,
        });
      }
      await RequestScope.cancellable(
        job.header.future.timeout(_reverseTimeout),
      );
      return job;
    } catch (error) {
      job.cancel();
      RequestScope.checkpoint();
      if (error is _LanRequestError || error is _LanConnectionError) rethrow;
      throw const _LanConnectionError();
    }
  }

  Future<Json> _reverseJson(
    _LanReverseChannel channel,
    String path, {
    String method = 'GET',
    Json? body,
  }) async {
    final job = await _reverseRequest(
      channel,
      path,
      method: method,
      body: body,
    );
    final cancelled = RequestScope.current?.whenCancel.asStream().listen(
      (_) => job.cancel(),
    );
    try {
      final header = await job.header.future;
      final bytes = BytesBuilder(copy: false);
      var seq = 0;
      await for (final chunk in job.data.stream.timeout(_reverseTimeout)) {
        RequestScope.checkpoint();
        require(bytes.length + chunk.length <= 8 * 1024 * 1024, '设备返回的数据过大');
        bytes.add(chunk);
        job.acknowledge(seq++);
      }
      final status = header.integer('status');
      final payload = bytes.takeBytes();
      Json result;
      try {
        result = payload.isEmpty
            ? <String, dynamic>{}
            : asJson(jsonDecode(utf8.decode(payload)));
      } on FormatException {
        if (status != 200) throw _LanRequestError('设备请求失败（$status）', status);
        throw const AppException('设备返回的信息格式无效，请检查对方版本');
      }
      if (status != 200) {
        throw _LanRequestError(
          result.str('error').ifEmpty('设备请求失败（$status）'),
          status,
        );
      }
      return result;
    } finally {
      job.cancel();
      await cancelled?.cancel();
    }
  }

  List<DownloadSpec> _prepareDownloads(LanManifest manifest, Uri origin) {
    origin = lanAddress(origin.toString());
    final peer = _peerForOrigin(origin);
    final transfer = lanId();
    return [
      for (final file in manifest.files)
        DownloadSpec(
          url: origin
              .replace(
                path: '/v1/files/${manifest.token}/${file.id}',
                queryParameters: {'transfer': transfer},
                fragment: '',
              )
              .toString(),
          fileName: file.name,
          relativePath: file.directory,
          expectedSize: file.size,
          checksumType: 'sha256',
          checksumValue: file.sha256,
          profile: 'lan',
          source: {
            ...LanDownloadRoute.source(
              origin,
              manifest,
              file,
              peerId: peer?.id ?? '',
            ),
            'transfer': transfer,
          },
        ),
    ];
  }

  Future<DownloadSpec> _resolveDownload(DownloadSpec spec) async {
    require(LanDownloadRoute.owns(spec), '设备互联任务来源无效');
    await start();
    final source = spec.source!;
    final origin = lanAddress(source.str('origin'));
    final entry = LanFileEntry.fromJson(source.obj('file'));
    final token = source.str('token'), transfer = source.str('transfer');
    require(
      RegExp(r'^[a-f0-9]{32}$').hasMatch(token) &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch(transfer) &&
          entry.size == spec.expectedSize &&
          entry.sha256 == spec.checksumValue &&
          spec.checksumType == 'sha256',
      '设备互联文件信息不匹配，请重新接收',
    );
    // Expiry is enforced by the sender. A phone's clock can differ from the PC.
    final peerId = source
        .str('peerId')
        .ifEmpty(_peerForOrigin(origin)?.id ?? '');
    require(
      peerId.isEmpty || RegExp(r'^[a-f0-9]{32}$').hasMatch(peerId),
      '设备来源信息无效',
    );
    final identity = '${origin.origin}/$token/${entry.id}/$transfer';
    final existing = _downloadRouteIds[identity];
    if (existing != null && _downloadRoutes.containsKey(existing)) {
      final route = _downloadRoutes.remove(existing)!;
      route.peerId = peerId;
      _downloadRoutes[existing] = route;
      return spec.copyWith(
        url: _localHttpBase.replace(path: '/v1/receive/$existing').toString(),
      );
    }
    if (_downloadRoutes.length >= lanMaxFiles) {
      final old = _downloadRoutes.entries
          .where((entry) => entry.value.active == 0)
          .firstOrNull;
      require(old != null, '设备互联正在处理的文件过多，请稍后重试');
      _removeDownloadRoute(old!.key);
    }
    final routeId = lanId();
    _downloadRoutes[routeId] = _LanForwardedFile(
      origin,
      entry,
      token,
      transfer,
      peerId,
    );
    _downloadRouteIds[identity] = routeId;
    return spec.copyWith(
      url: _localHttpBase.replace(path: '/v1/receive/$routeId').toString(),
    );
  }

  Future<void> _serveForwardedFile(HttpRequest request, String key) async {
    final route = _downloadRoutes[key];
    if (route == null) {
      throw const _LanRequestError('设备互联分享已结束或过期，请重新接收', 410);
    }
    final headers = <String, String>{'accept-encoding': 'identity'};
    for (final name in ['range', 'if-range']) {
      final value = request.headers.value(name);
      if (value != null) headers[name] = value;
    }
    final target = route.origin.replace(
      path: '/v1/files/${route.token}/${route.entry.id}',
      queryParameters: {'transfer': route.transfer},
    );
    final channel = _reverseChannels[route.peerId];
    final capable = _reverseCapablePeers.contains(route.peerId);
    route.active++;
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..autoUncompress = false
      ..connectionTimeout = Duration(seconds: capable ? 2 : 5);
    HttpClientRequest? upstream;
    _LanReverseJob? reverseJob;
    var completed = false;
    var abandoned = false;
    unawaited(
      request.response.done.then<void>(
        (_) {
          if (!completed) {
            abandoned = true;
            upstream?.abort();
            reverseJob?.cancel();
          }
        },
        onError: (Object _, StackTrace _) {
          if (!completed) {
            abandoned = true;
            upstream?.abort();
            reverseJob?.cancel();
          }
        },
      ),
    );
    try {
      HttpClientResponse? direct;
      if (channel == null ||
          !(_reversePreferred[route.peerId]?.isAfter(clock()) ?? false)) {
        try {
          final opening = client.openUrl(request.method, target);
          unawaited(
            opening.then<void>((lateRequest) {
              if (completed || abandoned) lateRequest.abort();
            }, onError: (Object _, StackTrace _) {}),
          );
          upstream = await opening.timeout(Duration(seconds: capable ? 2 : 6));
          upstream.followRedirects = false;
          headers.forEach(upstream.headers.set);
          direct = await upstream.close().timeout(
            Duration(seconds: capable ? 2 : 12),
          );
        } on SocketException {
          // No body has been sent yet, so the reverse channel can take over.
        } on TimeoutException {
          // Do not switch an already started binary response.
        } on HttpException catch (error) {
          if (!isInterruptedHttpConnection(error)) rethrow;
        }
      }
      if (direct != null) {
        request.response.statusCode = direct.statusCode;
        direct.headers.forEach((name, values) {
          if (_forwardHeaders.contains(name)) {
            request.response.headers.set(name, values);
          }
        });
        try {
          await request.response.addStream(direct.timeout(_reverseTimeout));
        } catch (_) {
          if (capable) {
            _reversePreferred[route.peerId] = clock().add(
              const Duration(seconds: 30),
            );
          }
          throw const _LanStreamFailure();
        }
        return;
      }
      final reverse = await _readyReverseChannel(route.peerId);
      if (abandoned) throw const _LanConnectionError();
      if (reverse == null || reverse.closed) throw const _LanConnectionError();
      _reversePreferred[route.peerId] = clock().add(
        const Duration(seconds: 30),
      );
      upstream?.abort();
      final job = await _reverseRequest(
        reverse,
        '${target.path}?${target.query}',
        method: request.method,
        headers: headers,
        onCreated: (job) {
          reverseJob = job;
          if (abandoned) job.cancel();
        },
      );
      reverseJob = job;
      try {
        final header = await job.header.future;
        request.response.statusCode = header.integer('status');
        for (final entry in strings(header['headers']).entries) {
          if (_forwardHeaders.contains(entry.key)) {
            request.response.headers.set(entry.key, entry.value);
          }
        }
        DiagnosticLog.event(
          'lan.reverse_transfer',
          fields: {
            'peer': DiagnosticLog.reference(route.peerId),
            'file': DiagnosticLog.reference(route.entry.id),
            'range': headers.containsKey('range'),
          },
        );
        try {
          var seq = 0;
          await for (final chunk in job.data.stream.timeout(_reverseTimeout)) {
            if (!running) throw const _LanConnectionError();
            request.response.add(chunk);
            await request.response.flush();
            job.acknowledge(seq++);
          }
        } catch (_) {
          throw const _LanStreamFailure();
        }
      } finally {
        job.cancel();
      }
    } finally {
      completed = true;
      route.active--;
      upstream?.abort();
      client.close(force: true);
    }
  }

  void _removeDownloadRoute(String key) {
    _downloadRoutes.remove(key);
    _downloadRouteIds.removeWhere((_, value) => value == key);
  }

  void _disconnectPeer(String peerId) {
    _peerSessions.remove(peerId);
    _sessions.removeWhere((_, session) => session.id == peerId);
    _reverseWorkers.remove(peerId)?.stop();
    _reverseChannels.remove(peerId)?.close();
    _reversePreferred.remove(peerId);
    _reverseCapablePeers.remove(peerId);
  }

  void _pruneReverseTransfers() {
    for (final worker in _reverseWorkers.values.toList()) {
      if (!worker.valid) {
        worker.stop();
        _reverseWorkers.remove(worker.peer.id);
      }
    }
    for (final channel in _reverseChannels.values.toList()) {
      if (!_sessions.values.contains(channel.session) ||
          !channel.session.expires.isAfter(clock()) ||
          _peerSessions[channel.session.id] == null) {
        channel.close();
      }
    }
    _reversePreferred.removeWhere((_, until) => !until.isAfter(clock()));
  }

  void _stopReverseTransfers() {
    for (final worker in _reverseWorkers.values) {
      worker.stop();
    }
    _reverseWorkers.clear();
    for (final channel in _reverseChannels.values.toList()) {
      channel.close();
    }
    _reverseChannels.clear();
    for (final job in _reversePending.values.toList()) {
      job.fail(const _LanConnectionError());
    }
    _reversePending.clear();
    _forwardedRequests.clear();
    _downloadRoutes.clear();
    _downloadRouteIds.clear();
    _reversePreferred.clear();
    _reverseCapablePeers.clear();
    _pairReplies.clear();
  }
}
