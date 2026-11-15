part of '../quark_uc.dart';

extension _QuarkUpload on QuarkUcConnector {
  Future<CloudFile> _upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c,
    UploadProgressCallback? onProgress,
  ) async {
    personal(s);
    final io = UploadIO(http, source, onProgress);
    io.progress(UploadPhase.preparing);
    final response = await http.postJson(url('file/upload/pre'), {
      'ccp_hash_update': true,
      'dir_name': '',
      'file_name': source.name,
      'format_type': source.mimeType,
      'pdir_fid': parent,
      'size': source.size,
      'l_created_at': source.modifiedAt.millisecondsSinceEpoch,
      'l_updated_at': source.modifiedAt.millisecondsSinceEpoch,
      'same_path_reuse': false,
    }, headers(c.primary));
    final pre = success(response);
    final taskId = pre.str('task_id');
    require(taskId.isNotEmpty, '网盘未返回上传任务');
    final digests = await io.hashes(whole: ['md5', 'sha1']);
    final hashes = await post('file/update/hash', {
      'md5': digests.whole['md5'],
      'sha1': digests.whole['sha1'],
      'task_id': taskId,
    }, c.primary);
    if (!hashes.boolean('finish')) {
      io.notSavedYet();
      final bucket = pre.str('bucket'), object = pre.str('obj_key');
      final uploadId = pre.str('upload_id');
      final endpoint = Uri.tryParse(pre.str('upload_url'));
      require(endpoint != null && endpoint.host.isNotEmpty, '网盘未返回上传服务器');
      require(
        bucket.isNotEmpty && object.isNotEmpty && uploadId.isNotEmpty,
        '网盘未返回完整上传凭据',
      );
      final address = endpoint!
          .replace(
            scheme: 'https',
            host: endpoint.host.startsWith('$bucket.')
                ? endpoint.host
                : '$bucket.${endpoint.host}',
            pathSegments: object.split('/'),
            query: null,
          )
          .toString();
      Future<String> authorize(String meta) async {
        final result = await io.temporary(
          () => post('file/upload/auth', {
            'auth_info': pre['auth_info'],
            'auth_meta': meta,
            'task_id': taskId,
          }, c.primary),
        );
        final key = result.str('auth_key');
        require(key.isNotEmpty, '网盘未签发上传授权');
        return key;
      }

      const agent =
          'aliyun-sdk-js/6.6.1 Chrome 98.0.4758.80 on Windows 10 64-bit';
      final partSize = response.json
          .obj('metadata')
          .integer('part_size', 8 * 1024 * 1024);
      require(partSize > 0, '网盘上传分段大小无效');
      final count = math.max(1, (source.size / partSize).ceil());
      final etags = List.filled(count, '');
      await io.parts(count, (i) async {
        final date = HttpDate.format(DateTime.now().toUtc());
        final key = await authorize(
          'PUT\n\n${source.mimeType}\n$date\n'
          'x-oss-date:$date\nx-oss-user-agent:$agent\n'
          '/$bucket/$object?partNumber=${i + 1}&uploadId=$uploadId',
        );
        final result = await io.send(
          query(address, {'partNumber': i + 1, 'uploadId': uploadId}),
          start: i * partSize,
          end: math.min(source.size, (i + 1) * partSize),
          commitsFile: false,
          headers: {
            'Authorization': key,
            'Content-Type': source.mimeType,
            'Referer': '$origin/',
            'x-oss-date': date,
            'x-oss-user-agent': agent,
          },
        );
        final etag = result.header('etag');
        require(etag.isNotEmpty, '网盘未确认上传分段');
        etags[i] = etag;
      });
      io.notSavedYet();
      io.progress(UploadPhase.finishing, source.size);
      final xml = UploadIO.completeXml(etags),
          date = HttpDate.format(DateTime.now().toUtc());
      final hash = base64Encode(md5.convert(utf8.encode(xml)).bytes);
      final callback = base64Encode(utf8.encode(jsonEncode(pre['callback'])));
      final key = await authorize(
        'POST\n$hash\napplication/xml\n$date\n'
        'x-oss-callback:$callback\nx-oss-date:$date\nx-oss-user-agent:$agent\n'
        '/$bucket/$object?uploadId=$uploadId',
      );
      final result = await http.request(
        'POST',
        query(address, {'uploadId': uploadId}),
        body: xml,
        contentType: 'application/xml',
        followRedirects: false,
        headers: {
          'Authorization': key,
          'Content-MD5': hash,
          'Referer': '$origin/',
          'x-oss-callback': callback,
          'x-oss-date': date,
          'x-oss-user-agent': agent,
        },
      );
      require(
        result.successful && !result.body.contains('<Error>'),
        '网盘未完成上传分段合并',
      );
      await post('file/upload/finish', {
        'obj_key': object,
        'task_id': taskId,
      }, c.primary);
    }
    return io.confirm(() => list(s, parent, c));
  }
}
