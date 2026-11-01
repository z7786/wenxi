part of 'lan_service.dart';

extension _LanServer on LanService {
  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final browserRead = request.method == 'GET' || request.method == 'HEAD';
    final browserPath =
        request.uri.path == '/' ||
        request.uri.path.isEmpty ||
        request.uri.path.startsWith('/s/');
    if (++_activeRequests > 64) {
      _activeRequests--;
      response.persistentConnection = false;
      response.statusCode = HttpStatus.serviceUnavailable;
      try {
        await response.close();
      } catch (_) {}
      return;
    }
    try {
      final remote = request.connectionInfo?.remoteAddress.address ?? '';
      require(running && isLanAddress(remote), '仅允许局域网连接');
      final host = request.headers.value(HttpHeaders.hostHeader);
      require(
        host != null && isLanAddress(Uri.parse('http://$host').host),
        '无效的设备地址',
      );
      final origin = request.headers.value('origin');
      require(origin == null || origin == 'http://$host', '不允许跨站请求');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('Referrer-Policy', 'no-referrer');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      final parts = request.uri.pathSegments.toList();
      if (parts.isNotEmpty && parts.last.isEmpty) parts.removeLast();
      if (browserRead &&
          (request.uri.path == '/' || request.uri.path.isEmpty)) {
        // The device address is public pairing information, not a share token.
        // Guide browsers without exposing active shares or the connection code.
        _browserPage(
          response,
          title: '设备互联已开启',
          content:
              '<p>这是设备连接地址，用于在文析助手中手动连接设备。</p>'
              '<p>要下载文件，请在发送端打开“我的分享”，复制完整分享链接，'
              '或扫描文件的分享二维码。</p>'
              '<p>完整文件链接会包含 <code>/s/…</code>。'
              '连接二维码请使用文析助手内的“扫码连接”打开。</p>',
        );
      } else if (browserRead && request.uri.path == '/favicon.ico') {
        response.statusCode = HttpStatus.noContent;
      } else if (request.method == 'GET' && request.uri.path == '/v1/info') {
        _reply(response, {
          'protocol': lanProtocol,
          'id': id,
          'name': name,
          'port': port,
        });
      } else if (request.method == 'POST' && request.uri.path == '/v1/pair') {
        final body = await _readBody(request);
        final attempts = _attempts.putIfAbsent(remote, () => []);
        attempts.removeWhere((time) => clock().difference(time).inMinutes >= 1);
        if (attempts.length >= 8) {
          _reply(response, {'error': '连接码错误次数过多，请一分钟后再试'}, status: 429);
          return;
        }
        if (body.str('code') != connectionCode) {
          attempts.add(clock());
          _reply(response, {'error': '连接码不正确，请查看对方设备的 6 位连接码'}, status: 403);
          return;
        }
        final peerId = body.str('id'), peerName = body.str('name');
        require(
          RegExp(r'^[a-f0-9]{32}$').hasMatch(peerId) &&
              peerName.isNotEmpty &&
              peerName.length <= 64 &&
              !RegExp(r'[\x00-\x1f]').hasMatch(peerName),
          '设备名称无效',
        );
        final replySession = body.str('replySession');
        final peerPort = body.integer('port');
        final bidirectional = replySession.isNotEmpty;
        if (bidirectional) {
          require(
            RegExp(r'^[a-f0-9]{32}$').hasMatch(replySession) &&
                peerPort > 0 &&
                peerPort <= 65535,
            '设备回连信息无效',
          );
        }
        final expires = clock().add(const Duration(hours: 4));
        _sessions.removeWhere(
          (key, value) =>
              !value.expires.isAfter(clock()) ||
              value.address == remote && value.id == peerId,
        );
        require(_sessions.length < 64, '连接设备过多，请稍后重试');
        final token = lanId();
        _sessions[token] = _LanSession(peerId, remote, peerName, expires);
        if (bidirectional) {
          final peer = LanPeer(
            id: peerId,
            name: peerName,
            address: remote,
            port: peerPort,
            lastSeen: clock(),
          );
          _peers[peerId] = peer;
          _peerSessions[peerId] = (
            token: replySession,
            base: peer.base,
            expires: expires,
          );
        }
        _reply(response, {
          'session': token,
          'id': id,
          'bidirectional': bidirectional,
        });
        _changed();
      } else if (request.method == 'GET' && request.uri.path == '/v1/shares') {
        _authorize(request, remote);
        _reply(response, {
          // Echo only on an authenticated request; callers use this source IP
          // for file invitations instead of guessing from Socket.address.
          'senderAddress': remote,
          'shares': shares
              .where((s) => !s.draining)
              .map((s) => s.summary)
              .toList(),
        });
      } else if (request.method == 'POST' && request.uri.path == '/v1/inbox') {
        final session = _authorize(request, remote);
        final body = await _readBody(request);
        final messageId = body.str('id'),
            kind = body.str('kind'),
            value = body.str('value').trim();
        require(
          RegExp(r'^[a-f0-9]{32}$').hasMatch(messageId) &&
              {'text', 'link', 'share'}.contains(kind) &&
              value.isNotEmpty &&
              value.length <= lanMaxMessageLength,
          '消息格式无效',
        );
        if (kind == 'share') {
          final uri = lanAddress(value);
          require(
            uri.host == remote &&
                RegExp(r'^/s/[a-f0-9]{32}$').hasMatch(uri.path),
            '分享来源与发送设备不一致',
          );
        } else if (kind == 'link') {
          require(LinkParser.parse(value).isNotEmpty, '消息中没有可识别的链接');
        }
        await _inboxGate.run(() async {
          if (_inbox.any((message) => message.id == messageId)) return;
          require(
            _inbox.where((m) => !m.read).length < 100,
            '对方收件箱已满，请先处理已有消息',
          );
          final item = LanInboxItem(
            id: messageId,
            sender: session.name,
            senderId: session.id,
            kind: kind,
            value: value,
            createdAt: clock().millisecondsSinceEpoch,
          );
          final next = [item, ..._inbox];
          while (next.length > 100) {
            // Keep pending messages when rotating the bounded history.
            final readIndex = next.lastIndexWhere((message) => message.read);
            require(readIndex >= 0, '对方收件箱已满，请先处理已有消息');
            next.removeAt(readIndex);
          }
          await store.put('lanInbox', next.map((m) => m.toJson()).toList());
          _inbox
            ..clear()
            ..addAll(next);
        });
        _changed();
        _reply(response, {'delivered': true});
      } else if (parts.length == 3 &&
          parts[0] == 'v1' &&
          parts[1] == 'manifests' &&
          request.method == 'GET') {
        final share = _findShare(parts[2]);
        require(!share.draining, '此分享已停止接受新接收');
        _reply(response, share.manifest.toJson());
      } else if (parts.length == 2 && parts[0] == 's' && browserRead) {
        final share = _findShare(parts[1]);
        require(
          share.manifest.singleFile && !share.draining,
          '请用文析助手连接码接收多文件或文件夹',
        );
        final file = share.manifest.files.single;
        final url =
            '/v1/files/${share.manifest.token}/${file.id}?transfer=${lanId()}';
        final expiry = share.manifest.expiresAt;
        final validity = expiry == null
            ? '有效期：直到发送方关闭分享或退出应用'
            : '有效期至 ${expiry.toLocal().toString().split('.').first}（发送端时间）';
        _browserPage(
          response,
          title: file.name,
          content:
              '<p>${_browserSize(file.size)}</p>'
              '<a href="$url" download>下载文件</a>'
              '<p>$validity</p>'
              '<p>请保持两台设备在同一局域网，并让发送端保持分享开启。</p>',
        );
      } else if (parts.length == 4 &&
          parts[0] == 'v1' &&
          parts[1] == 'files' &&
          {'GET', 'HEAD'}.contains(request.method)) {
        await _serveFile(request, _findShare(parts[2]), parts[3], remote);
      } else {
        if (browserRead && browserPath) {
          _browserPage(
            response,
            title: '分享链接不完整',
            content: '<p>请在发送端“我的分享”中重新复制完整分享链接，或扫描文件二维码。</p>',
            status: 404,
          );
        } else {
          _reply(response, {'error': '此地址不存在，请检查完整设备地址或分享链接'}, status: 404);
        }
      }
    } catch (error) {
      try {
        // Rejected requests can still have an unread body. Never advertise a
        // reusable connection that the server is about to discard.
        response.persistentConnection = false;
        final message = error is AppException ? error.message : '设备请求失败，请重新连接';
        final status = error is _LanRequestError ? error.status : 400;
        if (browserRead && browserPath) {
          _browserPage(
            response,
            title: '暂时无法打开分享',
            content: '<p>${const HtmlEscape().convert(message)}</p>',
            status: status,
          );
        } else {
          _reply(response, {'error': message}, status: status);
        }
      } catch (_) {}
    } finally {
      try {
        await response.close();
      } catch (_) {}
      _activeRequests--;
    }
  }

  void _browserPage(
    HttpResponse response, {
    required String title,
    required String content,
    int status = 200,
  }) {
    response.statusCode = status;
    response.headers.contentType = ContentType.html;
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
    );
    final escapedTitle = const HtmlEscape().convert(title);
    response.write(
      '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>文析助手 · $escapedTitle</title>
<style>body{margin:0;padding:24px;font-family:system-ui,sans-serif;background:#f2f2f7;color:#1c1c1e}main{max-width:480px;margin:12vh auto;padding:30px;background:white;border-radius:24px}small,p{color:#73737b;line-height:1.8}h1{font-size:22px;overflow-wrap:anywhere}a{display:block;text-align:center;background:#007aff;color:white;text-decoration:none;padding:15px;border-radius:14px;margin-top:24px}code{overflow-wrap:anywhere}</style>
<main><small>文析助手 · 局域网分享</small><h1>$escapedTitle</h1>$content</main></html>''',
    );
  }

  String _browserSize(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
      : bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB'
      : bytes >= 1024
      ? '${(bytes / 1024).toStringAsFixed(2)} KB'
      : '$bytes B';

  void _reply(HttpResponse response, Json value, {int status = 200}) {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(value));
  }

  Future<Json> _readBody(HttpRequest request) async {
    require(
      request.headers.contentType?.mimeType == 'application/json',
      '请求格式无效',
    );
    require(request.contentLength <= 256 * 1024, '请求内容过大');
    final data = BytesBuilder(copy: false);
    await for (final chunk in request.timeout(const Duration(seconds: 8))) {
      require(data.length + chunk.length <= 256 * 1024, '请求内容过大');
      data.add(chunk);
    }
    return asJson(jsonDecode(utf8.decode(data.takeBytes())));
  }

  _LanSession _authorize(HttpRequest request, String remote) {
    final value = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final session = value.startsWith('Bearer ')
        ? _sessions[value.substring(7)]
        : null;
    if (session == null ||
        session.address != remote ||
        !session.expires.isAfter(clock())) {
      throw const _LanRequestError('连接已失效，请重新输入对方的连接码', 401);
    }
    return session;
  }

  LanShare _findShare(String token) {
    final share = _shares[token];
    if (share == null || share.stopped) {
      throw const _LanRequestError('此分享不存在或已结束，请在发送端重新获取完整分享链接', 410);
    }
    if (share.expired(clock())) {
      throw const _LanRequestError('分享有效期已结束，请让发送方重新分享', 410);
    }
    return share;
  }

  Future<void> _serveFile(
    HttpRequest request,
    LanShare share,
    String fileId,
    String remote,
  ) async {
    final response = request.response;
    final entry = share.manifest.files
        .where((file) => file.id == fileId)
        .firstOrNull;
    final source = share.sources[fileId];
    require(entry != null && source != null, '分享文件不存在');
    final transfer = request.uri.queryParameters['transfer'] ?? '';
    require(
      transfer.isEmpty || RegExp(r'^[a-f0-9]{32}$').hasMatch(transfer),
      '接收标识无效',
    );
    final client = '$remote/$transfer';
    require(!share.draining || share.clients.contains(client), '分享已停止接受新的下载');
    if (activeConnections >= 32) {
      response.headers.set(HttpHeaders.retryAfterHeader, '2');
      throw const _LanRequestError('发送端忙，请稍后重试', 503);
    }
    share.responses.add(response);
    _changed();
    try {
      try {
        await files.check(source!);
      } on AppException catch (error) {
        throw _LanRequestError(error.message, 409);
      }
      _findShare(share.manifest.token);
      final etag = '"${entry!.sha256}"';
      final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
      final rangeHeader = ifRange == null || ifRange == etag
          ? request.headers.value(HttpHeaders.rangeHeader)
          : null;
      (int, int)? range;
      try {
        range = lanByteRange(rangeHeader, entry.size);
      } on HttpException {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${entry.size}',
        );
        response.contentLength = 0;
        return;
      }
      final start = range?.$1 ?? 0, end = range?.$2 ?? entry.size;
      response.statusCode = range == null ? 200 : 206;
      response.contentLength = end - start;
      response.headers.contentType = ContentType.binary;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.etagHeader, etag);
      final fallbackName = entry.name.replaceAll(RegExp(r'[^\x20-\x7e]'), '_');
      response.headers.set(
        'Content-Disposition',
        "attachment; filename=\"$fallbackName\"; filename*=UTF-8''${Uri.encodeComponent(entry.name)}",
      );
      if (range != null) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${end - 1}/${entry.size}',
        );
      }
      share.clients.add(client);
      share.clientRequests[client] = (share.clientRequests[client] ?? 0) + 1;
      if (request.method == 'HEAD') return;
      share.lastActivity = clock();
      await response.addStream(
        files.read(source, start, end).map((chunk) {
          if (!running || share.stopped || share.expired(clock())) {
            throw const HttpException('Share ended');
          }
          share.transferred += chunk.length;
          share.lastActivity = clock();
          _changed(progress: true);
          return chunk;
        }),
      );
    } finally {
      share.responses.remove(response);
      final requests = (share.clientRequests[client] ?? 1) - 1;
      if (requests <= 0) {
        share.clientRequests.remove(client);
      } else {
        share.clientRequests[client] = requests;
      }
      share.lastActivity = clock();
      _changed();
    }
  }
}
