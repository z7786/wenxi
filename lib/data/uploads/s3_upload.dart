part of 'upload_io.dart';

extension S3Upload on UploadIO {
  Future<void> s3({
    required String endpoint,
    required String bucket,
    required String object,
    required String access,
    required String secret,
    required String region,
    String token = '',
    bool pathStyle = false,
  }) async {
    require(
      [endpoint, bucket, object, access, secret].every((v) => v.isNotEmpty),
      '网盘未返回完整上传凭据',
    );
    var base = Uri.parse(
      endpoint.contains('://') ? endpoint : 'https://$endpoint',
    );
    if (!pathStyle && !base.host.startsWith('$bucket.')) {
      base = base.replace(host: '$bucket.${base.host}');
    }
    String escape(String value) => utf8
        .encode(value)
        .map(
          (v) =>
              v >= 65 && v <= 90 ||
                  v >= 97 && v <= 122 ||
                  v >= 48 && v <= 57 ||
                  const [45, 46, 95, 126].contains(v)
              ? String.fromCharCode(v)
              : '%${v.toRadixString(16).toUpperCase().padLeft(2, '0')}',
        )
        .join();
    final path =
        '/${[if (pathStyle) bucket, ...object.split('/')].map(escape).join('/')}';
    checkedCloudUrl('${base.origin}$path', '网盘返回的上传地址无效');
    Future<HttpResult> request(
      String method,
      Map<String, String> parameters, {
      String body = '',
      int? start,
      int? end,
    }) async {
      final contentHash = start == null
          ? sha256.convert(utf8.encode(body)).toString()
          : await digest(sha256, start: start, end: end);
      final stamp =
          '${clock().toUtc().toIso8601String().replaceAll(RegExp(r'[:-]'), '').split('.').first}Z';
      final date = stamp.substring(0, 8);
      final headers = <String, String>{
        'host': base.authority,
        'x-amz-content-sha256': contentHash,
        'x-amz-date': stamp,
        if (token.isNotEmpty) 'x-amz-security-token': token,
      };
      final names = headers.keys.toList()..sort();
      final signedHeaders = names.join(';');
      final canonicalQuery = (parameters.keys.toList()..sort())
          .map((key) => '${escape(key)}=${escape(parameters[key]!)}')
          .join('&');
      final canonical =
          '$method\n$path\n$canonicalQuery\n'
          '${names.map((key) => '$key:${headers[key]}\n').join()}\n$signedHeaders\n$contentHash';
      final scope = '$date/$region/s3/aws4_request';
      List<int> sign(List<int> key, String value) =>
          Hmac(sha256, key).convert(utf8.encode(value)).bytes;
      final signingKey = sign(
        sign(sign(sign(utf8.encode('AWS4$secret'), date), region), 's3'),
        'aws4_request',
      );
      final signature = Hmac(sha256, signingKey).convert(
        utf8.encode(
          'AWS4-HMAC-SHA256\n$stamp\n$scope\n${sha256.convert(utf8.encode(canonical))}',
        ),
      );
      headers['Authorization'] =
          'AWS4-HMAC-SHA256 Credential=$access/$scope, SignedHeaders=$signedHeaders, Signature=$signature';
      final url =
          '${base.origin}$path${canonicalQuery.isEmpty ? '' : '?$canonicalQuery'}';
      if (start != null) {
        return send(
          url,
          start: start,
          end: end,
          headers: headers,
          commitsFile: !parameters.containsKey('uploadId'),
          retry: !parameters.containsKey('uploadId'),
        );
      }
      final result = await http.request(
        method,
        url,
        body: body,
        headers: headers,
        contentType: 'application/xml',
        followRedirects: false,
      );
      require(
        result.successful && !UploadIO.xmlError(result.body),
        '网盘上传服务返回错误（HTTP ${result.status}）',
      );
      return result;
    }

    final chunkSize = math.max(8 * 1024 * 1024, (file.size / 9000).ceil());
    if (file.size <= chunkSize) {
      await request('PUT', {}, start: 0, end: file.size);
      return;
    }
    final uploadId = UploadIO.xmlValue(
      (await temporary(() => request('POST', {'uploads': ''}))).body,
      'UploadId',
    );
    require(uploadId.isNotEmpty, '网盘未创建分段上传任务');
    var complete = false;
    try {
      notSavedYet();
      final count = (file.size / chunkSize).ceil();
      final etags = List.filled(count, '');
      await parts(count, (index) async {
        final start = index * chunkSize;
        final result = await retryPart(
          () => request(
            'PUT',
            {'uploadId': uploadId, 'partNumber': '${index + 1}'},
            start: start,
            end: math.min(file.size, start + chunkSize),
          ),
        );
        final etag = result.header('etag');
        require(etag.isNotEmpty, '网盘未确认上传分段');
        etags[index] = etag;
      });
      notSavedYet();
      progress(UploadPhase.finishing, file.size);
      await request('POST', {
        'uploadId': uploadId,
      }, body: UploadIO.completeXml(etags));
      complete = true;
    } finally {
      if (!complete && RequestScope.current?.isCancelled != true) {
        try {
          await temporary(() => request('DELETE', {'uploadId': uploadId}));
        } catch (_) {}
      }
    }
  }
}
