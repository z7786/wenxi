part of '../tianyi.dart';

extension _TianyiRapidTransfer on TianyiConnector {
  Future<RapidTransferResult> _rapidTransfer(
    BrowseSession s,
    String parent,
    RapidTransferFile file,
    Credential credential,
  ) async {
    _personal(s);
    _name(file.name);
    require(RegExp(r'^-?\d+$').hasMatch(parent), '天翼目标目录无效');
    // Exchange this account's web authorization for a signed upload session.
    // Session keys stay in this operation; no credentials are added to tasks.
    final webSession = (await _api(
      TianyiConnector._familySessionPath,
    )).str('sessionKey');
    if (webSession.isEmpty) {
      throw const AccountLoginRequired('天翼登录会话不可用，请重新登录后再使用秒传');
    }
    final timestamp = '${DateTime.now().millisecondsSinceEpoch}';
    const appKey = '8025431004';
    final token = (await _api(
      TianyiConnector._familyTokenPath,
      params: {'sessionKey': webSession},
      extraHeaders: {
        'AppKey': appKey,
        'Timestamp': timestamp,
        'Signature': TianyiConnector._accessSignature({
          'sessionKey': webSession,
          'AppKey': appKey,
          'Timestamp': timestamp,
        }),
      },
    )).str('accessToken');
    if (token.isEmpty) {
      throw const AccountLoginRequired('当前天翼登录未获得秒传授权，请重新登录');
    }
    final session = _familyChecked(
      await http.readRequest(
        'GET',
        query('${TianyiConnector._openOrigin}/getSessionForPC.action', {
          'appId': appKey,
          'accessToken': token,
          'clientType': 'TELEPC',
          'version': '6.2',
          'channelId': 'web_cloud.189.cn',
        }),
        headers: {
          'Accept': 'application/json;charset=UTF-8',
          'User-Agent': TianyiConnector.webUa,
          'X-Request-ID': newId(),
        },
        followRedirects: false,
      ),
      'uploadSession',
    );
    _checkpoint();
    final key = session.str('sessionKey'),
        secret = session.str('sessionSecret');
    if (!(key.isNotEmpty &&
        secret.isNotEmpty &&
        !RegExp(r'[\x00-\x20\x7f]').hasMatch(key))) {
      throw const AccountLoginRequired('当前天翼登录未获得秒传授权，请重新登录后重试');
    }

    Future<HttpResult> post(String url, Map<String, Object?> fields) async {
      _checkpoint();
      final uri = Uri.parse(url);
      require(
        uri.scheme == 'https' &&
            uri.userInfo.isEmpty &&
            (uri.host == 'cloud.189.cn' || uri.host.endsWith('.cloud.189.cn')),
        '天翼秒传提交地址无效',
      );
      final date = HttpDate.format(DateTime.now());
      final signature = Hmac(sha1, utf8.encode(secret))
          .convert(
            utf8.encode(
              'SessionKey=$key&Operate=POST&RequestURI=${uri.path}&Date=$date',
            ),
          )
          .toString()
          .toUpperCase();
      return http.mutationRequest(
        'POST',
        query(url, {
          'clientType': 'TELEPC',
          'version': '6.2',
          'channelId': 'web_cloud.189.cn',
        }),
        body: form(fields),
        headers: {
          'SessionKey': key,
          'Signature': signature,
          'Date': date,
          'X-Request-ID': newId(),
          'Accept': 'application/json;charset=UTF-8',
          'User-Agent': TianyiConnector.webUa,
        },
        contentType: 'application/x-www-form-urlencoded; charset=utf-8',
        followRedirects: false,
      );
    }

    final response =
        await post('${TianyiConnector._openOrigin}/createUploadFile.action', {
          'parentFolderId': parent,
          'fileName': file.name,
          'size': file.size,
          'md5': file.md5,
          'opertype': '3',
          'flag': '1',
          'resumePolicy': '1',
          'isLog': '0',
        });
    if (response.status == 429) {
      throw const RapidTransferUnavailable('天翼请求过于频繁，请稍后继续任务');
    }
    final state = response.json;
    final code = state
        .str('errorCode')
        .ifEmpty(state.str('res_code'))
        .ifEmpty(state.str('code'));
    if ({
      'InsufficientStorageSpace',
      'InsufficientSpace',
      'NotEnoughSpace',
      'UserDayFlowOverLimited',
    }.contains(code)) {
      throw RapidTransferUnavailable(
        code == 'UserDayFlowOverLimited'
            ? '天翼今日流量额度已用尽，请晚些时候继续任务'
            : '天翼剩余空间不足，请清理后继续任务',
      );
    }
    final created = _checked(response);
    _checkpoint();
    if (created.integer('fileDataExists') != 1) {
      return const RapidTransferResult.missed();
    }
    final uploadId = created.str('uploadFileId'),
        commitUrl = created.str('fileCommitUrl');
    require(uploadId.isNotEmpty && commitUrl.isNotEmpty, '天翼秒传回执缺少提交信息');
    final committed = await post(commitUrl, {
      'uploadFileId': uploadId,
      'opertype': '1',
      'resumePolicy': '1',
      'isLog': '0',
    });
    _checkpoint();
    require(committed.successful, '天翼秒传提交失败，请刷新目标目录确认');
    // Legacy commits can return XML. A successful HTTP response alone is not
    // evidence of a saved file; verify the listing, size and content digest.
    final files = await list(s, parent, _session.owner ?? credential);
    final verified = files.where(
      (entry) =>
          !entry.isDirectory &&
          entry.name == file.name &&
          entry.size == file.size &&
          contentMd5(entry.hashValue) == file.md5,
    );
    require(verified.length == 1, '天翼尚未确认秒传文件，请稍后刷新目标目录');
    return RapidTransferResult.reused(verified.single.id);
  }
}
