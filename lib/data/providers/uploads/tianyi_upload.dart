part of '../tianyi.dart';

extension _TianyiUpload on TianyiConnector {
  Future<CloudFile> _upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c,
    UploadProgressCallback? onProgress,
  ) async {
    _personal(s);
    _name(source.name);
    final io = UploadIO(http, source, onProgress);
    final sessionKey = (await _api(
      TianyiConnector._familySessionPath,
    )).str('sessionKey');
    require(sessionKey.isNotEmpty, '天翼未返回上传会话');
    final rsaInfo = await _api('security/generateRsaKey');
    final rsa = LoginRsa(rsaInfo.str('pubKey')), pkId = rsaInfo.str('pkId');
    require(pkId.isNotEmpty, '天翼未返回上传加密信息');
    Future<Json> call(String path, Map<String, String> params) async {
      _checkpoint();
      final date = '${DateTime.now().millisecondsSinceEpoch}';
      final secret = CryptoBox.random(
        12,
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final raw = params.entries.map((e) => '${e.key}=${e.value}').join('&');
      final cipher =
          pc.PaddedBlockCipherImpl(
            pc.PKCS7Padding(),
            pc.ECBBlockCipher(pc.AESEngine()),
          )..init(
            true,
            pc.PaddedBlockCipherParameters<pc.KeyParameter, Null>(
              pc.KeyParameter(
                Uint8List.fromList(utf8.encode(secret.substring(0, 16))),
              ),
              null,
            ),
          );
      final encrypted = cipher
          .process(Uint8List.fromList(utf8.encode(raw)))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final signature = Hmac(sha1, utf8.encode(secret))
          .convert(
            utf8.encode(
              'SessionKey=$sessionKey&Operate=GET&RequestURI=$path&Date=$date&params=$encrypted',
            ),
          )
          .toString();
      // These endpoints mutate upload state despite using the GET verb.
      final response = await http.mutationRequest(
        'GET',
        query('https://upload.cloud.189.cn$path', {'params': encrypted}),
        headers: {
          'Accept': 'application/json;charset=UTF-8',
          'SessionKey': sessionKey,
          'Signature': signature,
          'X-Request-Date': date,
          'X-Request-ID': newId(),
          'EncryptionText': rsa.encrypt(secret),
          'PkId': pkId,
          'User-Agent': TianyiConnector.webUa,
        },
        followRedirects: false,
      );
      _checkpoint();
      final result = response.json;
      require(
        response.successful && result.str('code') == 'SUCCESS',
        result.str('code') == 'InsufficientStorageSpace'
            ? '天翼云盘剩余空间不足，无法上传此文件'
            : '天翼上传请求失败（${result.str('code').ifEmpty('${response.status}')}）',
      );
      return result;
    }

    const partSize = 10 * 1024 * 1024;
    final digests = await io.hashes(
      whole: ['md5'],
      partAlgorithm: 'md5',
      partSize: partSize,
    );
    final fileHash = digests.whole['md5']!;
    final hashes = digests.parts.map((hash) => hash.toUpperCase()).toList();
    final count = math.max(1, (source.size / partSize).ceil());
    final sliceHash = source.size <= partSize
        ? fileHash
        : md5.convert(utf8.encode(hashes.join('\n'))).toString();
    final pre = (await io.temporary(
      () => call('/person/initMultiUpload', {
        'parentFolderId': parent,
        'fileName': Uri.encodeQueryComponent(source.name),
        'fileSize': '${source.size}',
        'sliceSize': '$partSize',
        'fileMd5': fileHash,
        'sliceMd5': sliceHash,
      }),
    )).obj('data');
    final uploadId = pre.str('uploadFileId');
    require(uploadId.isNotEmpty, '天翼未创建上传任务');
    if (pre.integer('fileDataExists') != 1) {
      io.notSavedYet();
      await io.parts(count, (i) async {
        final hashBytes = [
          for (var j = 0; j < 32; j += 2)
            int.parse(hashes[i].substring(j, j + 2), radix: 16),
        ];
        final data = await io.temporary(
          () => call('/person/getMultiUploadUrls', {
            'partInfo': '${i + 1}-${base64Encode(hashBytes)}',
            'uploadFileId': uploadId,
          }),
        );
        final part = data.obj('uploadUrls').obj('partNumber_${i + 1}');
        final headers = <String, String>{};
        for (final pair in Uri.decodeComponent(
          part.str('requestHeader'),
        ).split('&')) {
          final eq = pair.indexOf('=');
          if (eq > 0) headers[pair.substring(0, eq)] = pair.substring(eq + 1);
        }
        await io.send(
          part.str('requestURL'),
          start: i * partSize,
          end: math.min(source.size, (i + 1) * partSize),
          commitsFile: false,
          headers: headers,
        );
      });
    }
    io.notSavedYet();
    io.progress(UploadPhase.finishing, source.size);
    final completed = (await call('/person/commitMultiUploadFile', {
      'uploadFileId': uploadId,
      'fileMd5': fileHash,
      'sliceMd5': sliceHash,
      'lazyCheck': '1',
      'opertype': '3',
    })).obj('data');
    CloudFile? receipt;
    if (completed.str('fileId').isNotEmpty &&
        completed.str('fileName').isNotEmpty &&
        completed.containsKey('fileSize')) {
      final folder = completed.str('parentFolderId');
      require(folder.isEmpty || folder == parent, '天翼上传回执的目录不一致，请刷新后确认');
      receipt = _file(completed, parent, false);
    }
    return io.confirm(
      () => list(s, parent, c),
      id: completed.str('fileId'),
      receipt: receipt,
    );
  }
}
