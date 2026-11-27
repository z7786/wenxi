part of 'lan_service.dart';

const _browserCookie = 'wenxi_lan_browser';

extension _LanBrowser on LanService {
  void _browserHome(HttpResponse response) {
    response.headers.contentType = ContentType.html;
    response.headers.set(
      'Content-Security-Policy',
      "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
          "img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'; worker-src 'none'",
    );
    response.write(lanBrowserHtml);
  }

  _LanSession _browserAuthorize(HttpRequest request, String remote) {
    if (_forwardedSession(request) != null) {
      throw const _LanRequestError('网页连接请求无效', 403);
    }
    final cookies = request.cookies
        .where((cookie) => cookie.name == _browserCookie)
        .toList();
    final session = cookies.length == 1
        ? _browserSessions[cookies.single.value]
        : null;
    if (session == null ||
        session.address != remote ||
        !session.expires.isAfter(clock())) {
      throw const _LanRequestError('网页连接已失效，请重新输入连接码', 401);
    }
    return session;
  }

  void _pruneBrowserSessions() {
    for (final entry in _browserSessions.entries.toList()) {
      if (!entry.value.expires.isAfter(clock())) {
        _browserSessions.remove(entry.key);
        unawaited(browserReceiver?.cancelOwner(entry.value.id));
      }
    }
  }

  LanBrowserReceiver get _browserReceiver =>
      browserReceiver ??
      (throw const _LanRequestError('此版本尚未提供网页接收，请更新应用', 503));

  Future<void> _browserRoute(HttpRequest request, String remote) async {
    final response = request.response, path = request.uri.path;
    final read = request.method == 'GET' || request.method == 'HEAD';
    final parts = request.uri.pathSegments;
    require(_forwardedSession(request) == null, '网页连接请求无效');
    if (read && path == '/web/app.css') {
      await loadLanBrowserAssets();
      response.headers.contentType = ContentType(
        'text',
        'css',
        charset: 'utf-8',
      );
      response.write(lanBrowserCss);
      return;
    }
    if (read && (path == '/web/app.js' || path == '/web/sha256.js')) {
      await loadLanBrowserAssets();
      response.headers.contentType = ContentType(
        'application',
        'javascript',
        charset: 'utf-8',
      );
      response.write(path == '/web/app.js' ? lanBrowserJs : lanBrowserSha256Js);
      return;
    }
    if (request.method == 'POST' && path == '/web/pair') {
      final body = await _readBody(request);
      final attempts = _attempts.putIfAbsent(remote, () => []);
      attempts.removeWhere((time) => clock().difference(time).inMinutes >= 1);
      if (attempts.length >= 8) {
        response.headers.set(HttpHeaders.retryAfterHeader, '60');
        throw const _LanRequestError('连接码错误次数过多，请一分钟后再试', 429);
      }
      if (body.str('code') != connectionCode) {
        attempts.add(clock());
        throw const _LanRequestError('连接码不正确，请查看本机的 6 位连接码', 403);
      }
      final browserId = body.str('id'), browserName = body.str('name').trim();
      require(
        RegExp(r'^[a-f0-9]{32}$').hasMatch(browserId) &&
            browserName.isNotEmpty &&
            browserName.length <= 64 &&
            !RegExp(r'[\x00-\x1f\x7f]').hasMatch(browserName),
        '浏览器名称无效',
      );
      _pruneBrowserSessions();
      // Idempotent pairing only for the same already authenticated browser.
      // A self-reported ID cannot reclaim somebody else's pending uploads.
      _LanSession? existing;
      String? token;
      final cookie = request.cookies
          .where((c) => c.name == _browserCookie)
          .firstOrNull;
      final candidate = cookie == null ? null : _browserSessions[cookie.value];
      if (candidate != null && candidate.address == remote) {
        existing = candidate;
        token = cookie!.value;
      }
      if (existing == null) {
        require(
          _browserSessions.length + _sessions.length < 64,
          '连接设备过多，请稍后重试',
        );
        token = lanId();
        // An owner ID is server-generated and remains private to the receiver.
        existing = _LanSession(
          lanId(),
          remote,
          browserName,
          clock().add(const Duration(hours: 4)),
        );
        _browserSessions[token] = existing;
      }
      response.cookies.add(
        Cookie(_browserCookie, token!)
          ..path = '/web'
          ..httpOnly = true
          ..sameSite = SameSite.strict
          ..maxAge = 4 * 60 * 60,
      );
      _reply(response, {
        'connected': true,
        'name': name,
        'uploadEnabled': browserReceiver != null,
        'chunkSize': lanBrowserChunkSize,
      });
      _changed();
      return;
    }
    final session = _browserAuthorize(request, remote);
    if (request.method == 'POST' && path == '/web/logout') {
      _browserSessions.removeWhere((key, value) => identical(value, session));
      await browserReceiver?.cancelOwner(session.id);
      response.cookies.add(
        Cookie(_browserCookie, '')
          ..path = '/web'
          ..httpOnly = true
          ..sameSite = SameSite.strict
          ..maxAge = 0,
      );
      _reply(response, {'connected': false});
      _changed();
    } else if (request.method == 'GET' && path == '/web/session') {
      _reply(response, {
        'connected': true,
        'name': name,
        'uploadEnabled': browserReceiver != null,
        'chunkSize': lanBrowserChunkSize,
        'expiresAt': session.expires.millisecondsSinceEpoch,
        'shares': shares
            .where((s) => !s.draining)
            .map(
              (s) => {
                ...s.summary,
                'url': '/s/${s.manifest.token}',
                'downloadUrl': s.manifest.singleFile
                    ? '/v1/files/${s.manifest.token}/${s.manifest.files.single.id}'
                    : '/web/zip/${s.manifest.token}',
                'archive': !s.manifest.singleFile,
              },
            )
            .toList(),
        'uploads': browserReceiver?.status(session.id) ?? [],
      });
    } else if (request.method == 'POST' && path == '/web/uploads') {
      final value = await _browserReceiver.prepare(
        session.id,
        session.name,
        await _readBody(request),
      );
      _reply(response, value.toJson());
    } else if (parts.length == 3 &&
        parts[1] == 'uploads' &&
        request.method == 'GET') {
      _reply(response, _browserReceiver.upload(session.id, parts[2]).toJson());
    } else if (parts.length == 3 &&
        parts[1] == 'uploads' &&
        request.method == 'DELETE') {
      await _browserReceiver.cancel(session.id, parts[2]);
      _reply(response, _browserReceiver.upload(session.id, parts[2]).toJson());
    } else if (parts.length == 3 &&
        parts[1] == 'uploads' &&
        request.method == 'PUT') {
      require(
        request.headers.contentType?.mimeType == 'application/octet-stream',
        '上传请求格式无效',
      );
      final match = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(request.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      require(match != null, '上传范围无效');
      final start = int.tryParse(match!.group(1)!),
          end = int.tryParse(match.group(2)!);
      final total = int.tryParse(match.group(3)!);
      final value = _browserReceiver.upload(session.id, parts[2]);
      require(
        start != null &&
            end != null &&
            total == value.size &&
            end >= start &&
            request.contentLength == end - start + 1,
        '上传范围或内容长度无效',
      );
      final next = await _browserReceiver.append(
        session.id,
        value.id,
        start!,
        end! - start + 1,
        request,
      );
      _reply(response, next.toJson());
    } else if (parts.length == 4 &&
        parts[1] == 'uploads' &&
        parts[3] == 'complete' &&
        request.method == 'POST') {
      final value = _browserReceiver.complete(session.id, parts[2]);
      _reply(
        response,
        value.toJson(),
        status: value.state == LanBrowserUploadState.completed ? 200 : 202,
      );
    } else if (parts.length == 3 && parts[1] == 'zip' && read) {
      await _serveBrowserZip(request, _findShare(parts[2]), remote);
    } else {
      _reply(response, {'error': '网页请求地址不存在'}, status: 404);
    }
  }

  Future<void> _serveBrowserZip(
    HttpRequest request,
    LanShare share,
    String remote,
  ) async {
    final response = request.response;
    final transfer = request.uri.queryParameters['transfer'] ?? '';
    require(
      transfer.isEmpty || RegExp(r'^[a-f0-9]{32}$').hasMatch(transfer),
      '接收标识无效',
    );
    final client = '$remote/$transfer';
    require(!share.draining || share.clients.contains(client), '分享已停止接受新的下载');
    if (activeConnections >= 32) {
      throw const _LanRequestError('发送端忙，请稍后重试', 503);
    }
    share.responses.add(response);
    _changed();
    try {
      for (final source in share.sources.values) {
        try {
          await files.check(source);
        } on AppException catch (error) {
          throw _LanRequestError(error.message, 409);
        }
      }
      _findShare(share.manifest.token);
      final filename = '${safeFileName(share.manifest.name)}.zip';
      response.headers.contentType = ContentType('application', 'zip');
      response.headers.set(
        'Content-Disposition',
        "attachment; filename=\"files.zip\"; filename*=UTF-8''${Uri.encodeComponent(filename)}",
      );
      if (request.method == 'HEAD') return;
      // The archive is generated in a bounded stream, without copying the
      // source tree to a cache or holding complete files in the browser.
      share.clients.add(client);
      try {
        await response.addStream(
          lanBrowserZip(
            share.manifest,
            (entry) => files.read(share.sources[entry.id]!),
            () {
              if (!running || share.stopped || share.expired(clock())) {
                throw const HttpException('Share ended');
              }
            },
          ).map((chunk) {
            share.transferred += chunk.length;
            share.lastActivity = clock();
            _changed(progress: true);
            return chunk;
          }),
        );
      } catch (_) {
        throw const _LanStreamFailure();
      }
    } finally {
      share.responses.remove(response);
      share.lastActivity = clock();
      _changed();
    }
  }
}
