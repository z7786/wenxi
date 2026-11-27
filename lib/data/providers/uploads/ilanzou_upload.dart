part of '../ilanzou.dart';

extension _ILanzouUpload on ILanzouConnector {
  Future<CloudFile> _upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c,
    UploadProgressCallback? onProgress,
  ) async {
    personal(s);
    final session = await _session(c), io = UploadIO(http, source, onProgress);
    final pre = await _call(
      session,
      '/7n/getUpToken',
      body: {
        'fileId': '',
        'fileName': source.name,
        'fileSize': math.max(1, (source.size / 1024).ceil()),
        'folderId': ILanzouConnector.id(parent),
        'md5': await io.digest(crypto.md5),
        'type': 1,
      },
    );
    final upToken = pre.str('upToken');
    require(upToken.isNotEmpty, '蓝奏优享未返回上传授权');
    if (upToken == '-1') {
      final id = pre.obj('map').str('fileId');
      require(id.isNotEmpty, '蓝奏优享未确认秒传文件');
      return io.confirm(
        () => list(s, parent, c),
        id: 'f:$id',
        exactSize: false,
      );
    }
    if (session.field('account').isEmpty) await _account(session);
    final account = session.field('account');
    require(account.isNotEmpty, '蓝奏优享未返回上传账号信息');
    final now = DateTime.now();
    String two(int value) => '$value'.padLeft(2, '0');
    final key =
        'disk/${now.year}/${two(now.month)}/${two(now.day)}/$account/${now.millisecondsSinceEpoch}.rar';
    const partSize = 8 * 1024 * 1024;
    String token;
    if (source.size <= partSize) {
      final response = await io.send(
        'https://upload.qiniup.com/',
        method: 'POST',
        fields: {'token': upToken, 'key': key, 'fname': source.name},
        retry: false,
      );
      token = response.json.str('token');
    } else {
      final headers = {'Authorization': 'UpToken $upToken'};
      final object = base64Url.encode(utf8.encode(key));
      final base =
          'https://upload.qiniup.com/buckets/wpanstore-lanzou/objects/$object/uploads';
      final init = await io.temporary(
        () => http.request(
          'POST',
          base,
          headers: headers,
          followRedirects: false,
        ),
      );
      require(init.successful, '蓝奏优享无法创建分段上传');
      final uploadId = init.json.str('uploadId');
      require(uploadId.isNotEmpty, '蓝奏优享未返回分段上传标识');
      final parts = <Json>[];
      for (var start = 0; start < source.size; start += partSize) {
        sessions.checkpoint(session);
        final number = parts.length + 1;
        final response = await io.send(
          '$base/$uploadId/$number',
          headers: headers,
          start: start,
          end: math.min(source.size, start + partSize),
          commitsFile: false,
        );
        final etag = response.json.str('etag');
        require(etag.isNotEmpty, '蓝奏优享未确认上传分段');
        parts.add({'partNumber': number, 'etag': etag});
      }
      io.notSavedYet();
      io.progress(UploadPhase.finishing, source.size);
      final commit = await http.postJson('$base/$uploadId', {
        'fname': source.name,
        'parts': parts,
      }, headers);
      require(commit.successful, '蓝奏优享无法合并上传分段');
      token = commit.json.str('token');
    }
    require(token.isNotEmpty, '蓝奏优享未返回上传结果');
    io.progress(UploadPhase.finishing, source.size);
    for (var attempt = 0; attempt < 30; attempt++) {
      sessions.checkpoint(session);
      final response = _checked(
        await _request(
          'POST',
          _url(
            '/unproved/7n/results',
            session.field('uuid'),
            '',
            extra: {
              'tokenList': token,
              'tokenTime': DateTime.now().toIso8601String(),
            },
          ),
        ),
      );
      final result = response.list('list').firstOrNull;
      if (result?.integer('status') == 1) {
        final id = result!.str('fileId');
        require(id.isNotEmpty, '蓝奏优享未确认上传文件标识');
        return io.confirm(
          () => list(s, parent, c),
          id: 'f:$id',
          exactSize: false,
        );
      }
      await RequestScope.wait(const Duration(seconds: 1));
    }
    throw const AppException('蓝奏优享仍在处理上传，请稍后刷新列表');
  }
}
