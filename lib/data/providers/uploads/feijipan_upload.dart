part of '../feijipan.dart';

extension _FeijipanUpload on FeijipanConnector {
  Future<CloudFile> _upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c,
    UploadProgressCallback? onProgress,
  ) => _mutations.run(() async {
    personal(s);
    cloudFileName(source.name);
    require(source.size > 0, '小飞机不支持上传空文件');
    require(
      !(await list(s, parent, c)).any((f) => f.name == source.name),
      '目录中已有同名文件，请重命名后上传',
    );
    final session = await _session(c), io = UploadIO(http, source, onProgress);
    if (session.field('account').isEmpty) await _account(session);
    final account = session.field('account');
    require(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(account), '小飞机上传账号标识无效');
    final now = DateTime.fromMillisecondsSinceEpoch(sessions.now());
    String two(int v) => '$v'.padLeft(2, '0');
    final path =
        'storage/files/${now.year}/${two(now.month)}/${two(now.day)}/${account.substring(account.length - 1)}/$account/${now.millisecondsSinceEpoch}${newId().replaceAll('-', '')}.gz';
    final digest = await io.digest(crypto.md5);
    final kib = math.max(1, (source.size / 1024).round());
    final body = <String, Object?>{
      'fileName': source.name,
      'fileType': 1,
      'userId': session.field('userId'),
      'md5': digest,
      'pathKey': path,
      'fileSize': kib,
      'folderId': FeijipanConnector.id(parent),
      'fileId': '',
    };
    final pre = await _call(session, '/vod/getUpToken', body: body);
    if (pre.str('upToken') == '-1') {
      final fid = pre.obj('map').str('fileId');
      require(fid.isNotEmpty, '小飞机未确认秒传文件');
      return io.confirm(
        () => list(s, parent, c),
        id: 'f:$fid',
        exactSize: false,
      );
    }
    final credentials = pre.obj('upToken');
    require(
      [
        'accessKeyId',
        'secretAccessKey',
        'sessionToken',
      ].every((k) => credentials.str(k).isNotEmpty),
      '小飞机未返回完整上传授权',
    );
    final callback = base64Encode(
      utf8.encode(
        jsonEncode({
          'callbackMode': 'HTTP_ASYNC',
          'callbackBody': jsonEncode({...body, 'fileSize': kib * 1024}),
        }),
      ),
    );
    await _vodUpload(io, credentials, path, callback);
    io.progress(UploadPhase.finishing, source.size);
    for (var attempt = 0; attempt < 60; attempt++) {
      sessions.checkpoint(session);
      final result = _checked(
        await _request(
          'GET',
          _url(
            '/ws/vod/results',
            session.field('uuid'),
            session.access,
            extra: {'token': path},
          ),
        ),
      ).obj('map');
      if (result.integer('status') == 1) {
        final fid = result.str('fileId');
        require(fid.isNotEmpty, '小飞机上传结果缺少文件标识');
        return io.confirm(
          () => list(s, parent, c),
          id: 'f:$fid',
          exactSize: false,
        );
      }
      await RequestScope.wait(const Duration(seconds: 1));
    }
    throw const AppException('小飞机正在处理上传，请稍后刷新目录确认');
  });

  Future<void> _vodUpload(
    UploadIO io,
    Json credentials,
    String object,
    String callback,
  ) async {
    const host = '1500033322.vodpro-upload.com';
    final uri = Uri.https(host, '/9b5hmmeuqkg00qf/$object');
    String escape(String v) => Uri.encodeComponent(v)
        .replaceAll('!', '%21')
        .replaceAll("'", '%27')
        .replaceAll('(', '%28')
        .replaceAll(')', '%29')
        .replaceAll('*', '%2A');
    Future<HttpResult> request(
      String method,
      Map<String, String> params, {
      int? start,
      int? end,
      String body = '',
      bool meta = false,
    }) async {
      final seconds = sessions.now() ~/ 1000 - 1,
          keyTime =
              '${sessions.now() ~/ 1000 - 1};${sessions.now() ~/ 1000 + 600}';
      final expiration = DateTime.tryParse(credentials.str('expiration'));
      require(
        expiration == null ||
            expiration.millisecondsSinceEpoch ~/ 1000 > seconds + 10,
        '小飞机上传授权已过期，请重试',
      );
      final headers = <String, String>{
        'host': host,
        'x-cos-security-token': credentials.str('sessionToken'),
        if (meta) 'x-amz-meta-callback': callback,
      };
      final names = headers.keys.toList()..sort(),
          keys = params.keys.toList()..sort();
      final canonical =
          '${method.toLowerCase()}\n${uri.path}\n${keys.map((k) => '${escape(k.toLowerCase())}=${escape(params[k]!)}').join('&')}\n${names.map((k) => '${escape(k)}=${escape(headers[k]!)}').join('&')}\n';
      final signing = crypto.Hmac(
        crypto.sha1,
        utf8.encode(credentials.str('secretAccessKey')),
      ).convert(utf8.encode(keyTime)).toString();
      final text =
          'sha1\n$keyTime\n${crypto.sha1.convert(utf8.encode(canonical))}\n';
      final signature = crypto.Hmac(
        crypto.sha1,
        utf8.encode(signing),
      ).convert(utf8.encode(text));
      headers['Authorization'] =
          'q-sign-algorithm=sha1&q-ak=${credentials.str('accessKeyId')}&q-sign-time=$keyTime&q-key-time=$keyTime&q-header-list=${names.join(';')}&q-url-param-list=${keys.map((k) => k.toLowerCase()).join(';')}&q-signature=$signature';
      final url = uri
          .replace(queryParameters: params.isEmpty ? null : params)
          .toString();
      final result = start == null
          ? await http.request(
              method,
              url,
              headers: headers,
              body: body,
              followRedirects: false,
              contentType: 'application/xml',
            )
          : await io.send(
              url,
              method: method,
              headers: headers,
              start: start,
              end: end,
              commitsFile: !params.containsKey('uploadId'),
            );
      require(
        result.successful && !UploadIO.xmlError(result.body),
        '小飞机上传服务返回异常（HTTP ${result.status}）',
      );
      return result;
    }

    final size = math.max(4 * 1024 * 1024, (io.file.size / 9000).ceil());
    if (io.file.size <= size) {
      await request('PUT', {}, start: 0, end: io.file.size, meta: true);
      return;
    }
    final uploadId = UploadIO.xmlValue(
      (await io.temporary(
        () => request('POST', {'uploads': ''}, meta: true),
      )).body,
      'UploadId',
    );
    require(uploadId.isNotEmpty, '小飞机未创建分段上传');
    var completed = false;
    try {
      final etags = <String>[];
      for (var start = 0; start < io.file.size; start += size) {
        final r = await request(
          'PUT',
          {'partNumber': '${etags.length + 1}', 'uploadId': uploadId},
          start: start,
          end: math.min(io.file.size, start + size),
        );
        final etag = r.header('etag');
        require(etag.isNotEmpty, '小飞机未确认上传分段');
        etags.add(etag);
      }
      io.notSavedYet();
      io.progress(UploadPhase.finishing, io.file.size);
      await request('POST', {
        'uploadId': uploadId,
      }, body: UploadIO.completeXml(etags));
      completed = true;
    } finally {
      if (!completed && RequestScope.current?.isCancelled != true) {
        try {
          await io.temporary(() => request('DELETE', {'uploadId': uploadId}));
        } catch (_) {}
      }
    }
  }
}
