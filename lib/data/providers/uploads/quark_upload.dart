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
    // Hashing a large local/SAF file can be slow. Start the remote session only
    // after that read, so its task and credentials do not age during hashing.
    final digests = await io.hashes(whole: ['md5', 'sha1']);
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
    final serverClock = _QuarkUploadClock()..update(response);
    final taskId = pre.str('task_id');
    require(taskId.isNotEmpty, '网盘未返回上传任务');
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
      final mime = pre.str('format_type').trim().ifEmpty(source.mimeType);
      final metadata = response.json.obj('metadata');
      final partSize = response.json
          .obj('metadata')
          .integer('part_size', 8 * 1024 * 1024);
      require(partSize > 0, '网盘上传分段大小无效');
      final count = math.max(1, (source.size / partSize).ceil());
      require(count <= 10000, '网盘返回的上传分段过小，请重新添加上传任务');
      final concurrency = metadata.integer('part_thread', 3).clamp(1, 3);
      final etags = List.filled(count, '');
      await io.parts(count, (i) async {
        final start = i * partSize;
        final end = math.min(source.size, (i + 1) * partSize);
        for (var attempt = 0; ; attempt++) {
          RequestScope.checkpoint();
          // A retry opens the same range under the same upload ID. Renew both
          // the date and authorization instead of replaying an expired pair.
          try {
            final date = serverClock.date;
            final key = await authorize(
              'PUT\n\n$mime\n$date\n'
              'x-oss-date:$date\nx-oss-user-agent:$agent\n'
              '/$bucket/$object?partNumber=${i + 1}&uploadId=$uploadId',
            );
            final result = await io.send(
              query(address, {'partNumber': i + 1, 'uploadId': uploadId}),
              start: start,
              end: end,
              commitsFile: false,
              retry: false,
              contentType: mime,
              headers: {
                'Authorization': key,
                'Content-Type': mime,
                'Referer': '$origin/',
                'x-oss-date': date,
                'x-oss-user-agent': agent,
              },
            );
            if (UploadIO.xmlError(result.body)) {
              throw UploadResponseFailure(result);
            }
            final etag = result.header('etag');
            require(etag.isNotEmpty, '网盘未确认上传分段');
            etags[i] = etag;
            break;
          } on UploadResponseFailure catch (error) {
            RequestScope.checkpoint();
            final result = error.response;
            serverClock.update(result);
            DiagnosticLog.event(
              'upload.storage_rejected',
              fields: {
                'platform': platform.key,
                'stage': 'part',
                'httpStatus': result.status,
                if (error.code.isNotEmpty) 'storageCode': error.code,
                'partNumber': i + 1,
                'partCount': count,
                'partBytes': end - start,
                'attempt': attempt + 1,
              },
            );
            // Some storage gateways reject an idempotent resend after the
            // previous response was lost. Accept only a verified receipt for
            // the identical bytes; otherwise leave the task failed.
            if (error.code == 'PartAlreadyExist') {
              final etag = UploadIO.xmlValue(result.body, 'PartEtag').trim();
              final digest = etag.replaceAll('"', '').toLowerCase();
              if (RegExp(r'^[0-9a-f]{32}$').hasMatch(digest) &&
                  digest == await io.digest(md5, start: start, end: end)) {
                etags[i] = etag;
                break;
              }
            }
            final renew = const {
              'RequestTimeTooSkewed',
              'RequestExpired',
              'SignatureDoesNotMatch',
            }.contains(error.code);
            final transient = const {
              408,
              429,
              500,
              502,
              503,
              504,
            }.contains(result.status);
            if (attempt >= 2 || (!renew && !transient)) rethrow;
          } on HttpRequestFailure catch (error) {
            RequestScope.checkpoint();
            if (attempt >= 2 || !error.retryable) rethrow;
          }
          await RequestScope.wait(Duration(seconds: attempt + 1));
        }
      }, concurrent: concurrency);
      io.notSavedYet();
      io.progress(UploadPhase.finishing, source.size);
      final xml = UploadIO.completeXml(etags), date = serverClock.date;
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
      if (!result.successful || UploadIO.xmlError(result.body)) {
        final error = UploadResponseFailure(result);
        DiagnosticLog.event(
          'upload.storage_rejected',
          fields: {
            'platform': platform.key,
            'stage': 'merge',
            'httpStatus': result.status,
            if (error.code.isNotEmpty) 'storageCode': error.code,
            'partCount': count,
          },
        );
        throw error;
      }
      await post('file/upload/finish', {
        'obj_key': object,
        'task_id': taskId,
      }, c.primary);
    }
    return io.confirm(() => list(s, parent, c));
  }
}

class _QuarkUploadClock {
  DateTime? _server;
  final _elapsed = Stopwatch();
  String get date => HttpDate.format(
    _server == null ? DateTime.now().toUtc() : _server!.add(_elapsed.elapsed),
  );

  void update(HttpResult response) {
    var date = response.header('date');
    if (date.isEmpty && UploadIO.xmlError(response.body)) {
      date = UploadIO.xmlValue(response.body, 'ServerTime');
    }
    if (date.isEmpty) return;
    try {
      _server = (DateTime.tryParse(date) ?? HttpDate.parse(date)).toUtc();
      _elapsed
        ..reset()
        ..start();
    } on FormatException {
      // An invalid Date header must not prevent a normal upload.
    } on HttpException {
      // Keep the previous server sample if a gateway sent an invalid header.
    }
  }
}
