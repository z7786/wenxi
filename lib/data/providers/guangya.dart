import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../core/operation_progress.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import '../state_store.dart';
import 'guangya_login.dart';
import 'personal_cloud.dart';
import 'token_session.dart';

part 'uploads/guangya_upload.dart';

class GuangyaApiException extends AppException {
  const GuangyaApiException(super.message, this.code);
  final String code;
}

class GuangyaConnector extends CloudConnector {
  GuangyaConnector(
    this.http,
    CredentialStore store, {
    this.stageCleanup,
    this.taskDelay = const Duration(milliseconds: 750),
    int Function()? now,
  }) : sessions = TokenSessions(CloudPlatform.guangya, store, now: now);
  final JsonHttp http;
  final TokenSessions sessions;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  final Duration taskDelay;
  final _publicDevice = newId().replaceAll('-', '');
  static const api = 'https://api.guangyapan.com';
  static const authApi = GuangyaLoginProtocol.origin;
  static const web = GuangyaLoginProtocol.web;
  // Public client identifier of the official web login (no client secret).
  static const clientId = GuangyaLoginProtocol.clientId;
  static const userAgent =
      '${WebLoginTarget.desktop}Chrome/131.0.0.0 Safari/537.36';
  @override
  CloudPlatform get platform => CloudPlatform.guangya;

  Map<String, String> _headers(TokenSession? session, {bool account = false}) {
    final device =
        session?.field('deviceId').ifEmpty(_publicDevice) ?? _publicDevice;
    final sign = session?.field('deviceSign') ?? '';
    return {
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      'User-Agent': userAgent,
      'Origin': web,
      'Referer': '$web/',
      if (session?.access.isNotEmpty == true)
        'Authorization': 'Bearer ${session!.access}',
      if (account) ...{
        ...GuangyaLoginProtocol.deviceHeaders(device, sign),
      } else ...{
        'did': device,
        'dt': '4',
        'traceparent':
            '00-${newId().replaceAll('-', '')}-${newId().replaceAll('-', '').substring(0, 16)}-01',
      },
    };
  }

  bool _unauthorized(HttpResult response, Json data) =>
      response.status == 401 ||
      data.integer('code') == 401 ||
      data.str('error') == 'unauthenticated' ||
      RegExp(
        r'access\s*token.*(?:invalid|expired)|accessToken.*(?:无效|过期)',
        caseSensitive: false,
      ).hasMatch(data.str('message').ifEmpty(data.str('msg')));

  Json _checked(HttpResult response, Json data) {
    if (_unauthorized(response, data)) {
      throw const AccountLoginRequired('光鸭登录已过期，请重新网页登录');
    }
    final code = data.str('code');
    final success =
        response.successful &&
        data['success'] != false &&
        data.str('error').isEmpty &&
        (code.isEmpty || code == '0');
    var message = data
        .str('msg')
        .ifEmpty(data.str('message'))
        .ifEmpty(data.str('error_description'));
    if (message.isEmpty) {
      message = switch (code) {
        '209' => '光鸭分享提取码错误或缺失',
        '200' || '201' || '202' => '光鸭分享已取消、过期或不可访问',
        '205' || '206' || '207' || '504' => '光鸭分享下载受限，请在官网确认该分享的下载权限',
        '157' => '光鸭网盘空间不足',
        _ => '光鸭请求失败（HTTP ${response.status}${code.isEmpty ? '' : '，$code'}）',
      };
    }
    if (!success) throw GuangyaApiException(message, code);
    return data['data'] is Map ? data.obj('data') : data;
  }

  Future<void> _renew(TokenSession session) async {
    if (session.field('autoLoginBlocked') == '1') {
      throw const AccountLoginRequired('光鸭自动登录需要验证，请重新登录');
    }
    try {
      await _refreshToken(session);
    } on AccountLoginRequired {
      if (session.field('authType') != 'passwordToken' ||
          session.field('username').isEmpty ||
          session.field('password').isEmpty) {
        rethrow;
      }
      try {
        final candidate = await GuangyaPasswordLogin(
          http,
        ).password(session.field('username'), session.field('password'));
        sessions.checkpoint(session);
        final verified = await authenticate(candidate);
        sessions.checkpoint(session);
        await sessions.update(session, {
          ...verified.credential.fields,
          'authType': 'passwordToken',
          'autoLoginBlocked': '0',
        });
      } on AppException {
        await sessions.update(session, {'autoLoginBlocked': '1'});
        throw const AccountLoginRequired('光鸭自动登录未完成，请重新登录并完成安全验证');
      }
    }
  }

  Future<void> _refreshToken(TokenSession session) async {
    final response = await http.postJson(
      '$authApi/v1/auth/token',
      {
        'client_id': clientId,
        'grant_type': 'refresh_token',
        'refresh_token': session.refresh,
      },
      {
        ..._headers(session, account: true)..remove('Authorization'),
        'X-Action': '401',
      },
    );
    sessions.checkpoint(session);
    if (response.status == 400 || response.status == 401) {
      throw const AccountLoginRequired('光鸭登录凭据已失效，请重新网页登录');
    }
    final data = response.json;
    if (data.str('error') == 'invalid_grant') {
      throw const AccountLoginRequired('光鸭登录凭据已失效，请重新网页登录');
    }
    await sessions.update(
      session,
      sessions.refreshedFields(session, _checked(response, data)),
    );
  }

  Future<Json> _post(
    String path,
    Json body, {
    TokenSession? session,
    bool read = false,
    bool account = false,
    bool get = false,
    Set<String> acceptedCodes = const {},
  }) async {
    if (session != null) await sessions.fresh(session, _renew);
    for (var attempt = 0; attempt < 2; attempt++) {
      if (session != null) sessions.checkpoint(session);
      final access = session?.access;
      final url = '${account ? authApi : api}$path';
      final response = get
          ? await http.readRequest(
              'GET',
              url,
              headers: _headers(session, account: account),
              followRedirects: false,
            )
          : await (read ? http.postJsonRead : http.postJson)(
              url,
              body,
              _headers(session, account: account),
            );
      if (session != null) sessions.checkpoint(session);
      Json data;
      try {
        data = response.json;
      } on AppException {
        if (response.status != 401) rethrow;
        data = {};
      }
      if (_unauthorized(response, data) && session != null && attempt == 0) {
        await sessions.fresh(
          session,
          _renew,
          force: true,
          rejectedAccess: access,
        );
        continue;
      }
      if (response.successful && acceptedCodes.contains(data.str('code'))) {
        return {...data.obj('data'), '_uploadCode': data.str('code')};
      }
      return _checked(response, data);
    }
    throw const AccountLoginRequired('光鸭登录已失效，请重新网页登录');
  }

  Future<TokenSession> _session(
    Credential credential, {
    bool candidate = false,
  }) async {
    final session = sessions.open(credential, candidate: candidate);
    if (session.field('deviceId').isEmpty ||
        session.field('deviceSign').isEmpty) {
      await RequestScope.cancellable(
        sessions.gate.run(() async {
          sessions.checkpoint(session);
          if (session.field('deviceId').isEmpty ||
              session.field('deviceSign').isEmpty) {
            await sessions.update(session, {
              if (session.field('deviceId').isEmpty)
                'deviceId': newId().replaceAll('-', ''),
              if (session.field('deviceSign').isEmpty)
                'deviceSign':
                    'wdi10.${newId().replaceAll('-', '')}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
            });
          }
        }),
      );
    }
    await sessions.fresh(session, _renew);
    return session;
  }

  Future<CloudAccount> _account(TokenSession session) async {
    final data = await _post(
      '/v1/user/me',
      {},
      session: session,
      account: true,
      read: true,
      get: true,
    );
    final user = data
        .str('sub')
        .ifEmpty(data.str('user_id'))
        .ifEmpty(data.str('userId'));
    require(user.isNotEmpty, '光鸭未返回有效账号信息，请重新登录');
    await sessions.update(session, {'userId': user});
    final assets = await _post(
      '/assets/v1/get_assets',
      {},
      session: session,
      read: true,
    );
    final total = int.tryParse(assets.str('totalSpaceSize'));
    // The API omits zero-valued protobuf fields for an empty account.
    final used = assets.containsKey('usedSpaceSize')
        ? int.tryParse(assets.str('usedSpaceSize'))
        : 0;
    require(
      total != null && total >= 0 && used != null && used >= 0,
      '光鸭未返回有效容量信息，请稍后刷新',
    );
    return CloudAccount(
      data
          .str('nickname')
          .ifEmpty(data.str('nick_name'))
          .ifEmpty(data.str('name'))
          .ifEmpty(data.str('username'))
          .ifEmpty(session.field('nickname'))
          .ifEmpty('光鸭用户'),
      total: total!,
      used: used!,
    );
  }

  Future<LoginResult> authenticate(Credential credential) async {
    final session = await _session(credential, candidate: true);
    final account = await _account(session);
    return LoginResult(session.credential, account);
  }

  Future<LoginResult> password(
    String username,
    String password, {
    GuangyaCaptchaPrompt? verifyCaptcha,
    void Function(String)? onStatus,
  }) async {
    final candidate = await GuangyaPasswordLogin(http).password(
      username,
      password,
      verifyCaptcha: verifyCaptcha,
      onStatus: onStatus,
    );
    RequestScope.checkpoint();
    onStatus?.call('正在读取光鸭账号…');
    return authenticate(
      candidate.withFields({
        'username': username.trim(),
        'password': password,
        'authType': 'passwordToken',
      }),
    );
  }

  @override
  Future<CloudAccount> account(Credential credential) async =>
      _account(await _session(credential));

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    await _session(credential);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的光鸭云盘',
      rootId: 'root',
    );
  }

  String _parent(String id) =>
      {'root', '0', '/', 'guangya_root'}.contains(id) ? '' : id;

  Future<String> _shareAccess(BrowseSession session) async {
    final id = session
        .meta('shareId')
        .ifEmpty(session.sourceLink?.shareId ?? '');
    require(id.isNotEmpty, '光鸭分享信息缺失，请重新解析');
    final data = await _post('/userres/v1/get_share_access_token', {
      'shareId': id,
      'code': session.sourceLink?.passcode ?? session.meta('passcode'),
    }, read: true);
    final token = data.str('accessToken').ifEmpty(data.str('access_token'));
    require(token.isNotEmpty, '光鸭未返回分享凭据，请检查提取码');
    return token;
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    require(link.shareId?.isNotEmpty == true, '光鸭分享链接无效');
    final data = await _post('/userres/v1/get_share_summary', {
      'shareId': link.shareId,
    }, read: true);
    final result = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: data.str('title').ifEmpty(data.str('shareName')).ifEmpty('光鸭分享'),
      rootId: 'root',
      sourceLink: link,
      metadata: {'shareId': link.shareId!, 'passcode': link.passcode ?? ''},
    );
    await _shareAccess(result);
    return result;
  }

  static CloudFile file(Json data, String parent, {bool share = false}) {
    String first(List<String> names) {
      for (final name in names) {
        if (data.str(name).isNotEmpty) return data.str(name);
      }
      return '';
    }

    final id = first(['fileId', 'file_id', 'id', 'resId', 'resourceId']);
    final name = first(['fileName', 'name', 'filename', 'dirName', 'title']);
    final type = first(['type', 'fileType']).toLowerCase();
    final resType = first(['resType', 'res_type']);
    final directory =
        resType == '2' ||
        resType != '1' &&
            ([
                  'isDir',
                  'isdir',
                  'dir',
                  'isFolder',
                  'folder',
                ].any(data.boolean) ||
                data.str('dirName').isNotEmpty ||
                {'folder', 'dir', 'directory', '0'}.contains(type) ||
                !RegExp(r'\.[a-zA-Z0-9]{1,16}$').hasMatch(name) &&
                    first(['dirType', 'dir_type']) == '1');
    var checksum = cloudChecksum(
      first(['contentHashAlgorithm', 'content_hash_name']),
      first(['contentHash', 'content_hash']),
    );
    for (final type in ['sha1', 'md5', 'sha256']) {
      if (checksum.$1 != null) break;
      checksum = cloudChecksum(type, data.str(type));
    }
    final modified = first([
      'updatedAt',
      'updateAt',
      'updated_at',
      'updateTime',
      'mtime',
      'utime',
      'createdAt',
      'createTime',
      'ctime',
    ]);
    require(id.isNotEmpty && name.isNotEmpty, '光鸭返回的文件信息不完整');
    return CloudFile(
      id: id,
      name: name,
      isDirectory: directory,
      size: data.integer(
        'fileSize',
        data.integer('size', data.integer('file_size')),
      ),
      // A share root can expose the owner's private parentId. Only the folder
      // used to list this share can be reopened when a queued download starts.
      parentId: share
          ? parent
          : first(['parentId', 'parentFileId', 'parent_id']).ifEmpty(parent),
      modifiedAt: personalCloudDate(modified),
      thumbnailUrl: first([
        'thumbnail',
        'thumbnailUrl',
        'thumbnailURL',
        'cover',
      ]),
      hashType: checksum.$1,
      hashValue: checksum.$2,
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    final share = s.mode == BrowseMode.share;
    if (!share && c == null) throw const AccountLoginRequired('请先登录光鸭云盘');
    final session = share ? null : await _session(c!);
    final token = share ? await _shareAccess(s) : '';
    final result = <CloudFile>[];
    final ids = <String>{}, cursors = <String>{};
    Object? cursor;
    for (var page = 0; page < 1000; page++) {
      final data = await _post(
        share
            ? '/userres/v1/get_share_page_files_list'
            : '/userres/v1/file/get_file_list',
        {
          'parentId': _parent(parentId),
          'pageSize': 100,
          'orderBy': 0,
          'sortType': 0,
          if (share) 'accessToken': token,
          if (share && cursor != null) 'cursor': cursor,
          if (!share) 'page': page,
        },
        session: session,
        read: true,
      );
      final raw =
          data['list'] ??
          data['items'] ??
          data['files'] ??
          data['records'] ??
          data['content'];
      if (raw == null && data.isEmpty && page == 0 && !share) return [];
      require(raw is List, '光鸭未返回有效文件列表，请重试');
      final entries = objects(raw);
      require(entries.length == (raw as List).length, '光鸭文件列表包含无效项目，请重试');
      var added = 0;
      for (final item in entries) {
        final value = file(item, parentId, share: share);
        if (ids.add(value.id)) {
          result.add(value);
          added++;
        }
      }
      if (share) {
        final next = data['cursor'], nextText = data.str('cursor');
        final nextOffset = int.tryParse(nextText);
        // The web API counts filtered entries in total and advances a numeric
        // cursor by page size. Comparing total to visible files never finishes
        // a directory containing hidden or rejected entries.
        final more = data.containsKey('hasMore')
            ? data.boolean('hasMore')
            : data.containsKey('total')
            ? (nextOffset ?? result.length) < data.integer('total')
            : entries.length >= 100 && nextText.isNotEmpty;
        if (!more) return result;
        require(
          nextText.isNotEmpty &&
              cursors.add(nextText) &&
              (nextOffset != null
                  ? nextOffset > (int.tryParse('$cursor') ?? 0)
                  : added > 0),
          '光鸭分享分页异常，请重试',
        );
        cursor = next;
      } else {
        final total = data.integer('total', data.integer('totalCount'));
        require(
          entries.isNotEmpty || total <= result.length,
          '光鸭文件列表分页不完整，请刷新重试',
        );
        if (total > 0 && result.length >= total ||
            total == 0 && entries.length < 100) {
          return result;
        }
        require(added > 0, '光鸭文件列表分页重复，请重试');
      }
    }
    throw const AppException('光鸭目录项目过多，请分目录打开');
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory && f.id.isNotEmpty, '请选择要下载的文件');
    final share = s.mode == BrowseMode.share;
    if (!share && c == null) throw const AccountLoginRequired('请先登录光鸭云盘');
    final session = c == null ? null : await _session(c);
    Json data;
    try {
      data = await _post(
        share
            ? '/userres/v1/get_share_download_url'
            : '/userres/v1/get_res_download_url',
        {'fileId': f.id, if (share) 'accessToken': await _shareAccess(s)},
        session: session,
        read: true,
      );
    } on GuangyaApiException catch (error) {
      if (share && error.code == '207') {
        if (session == null) {
          throw const AccountLoginRequired('该光鸭分享需登录并转存后下载，请先登录光鸭云盘');
        }
        return _shareDownload(s, f, session);
      }
      rethrow;
    }
    final url = data
        .str('signedURL')
        .ifEmpty(data.str('signedUrl'))
        .ifEmpty(data.str('downloadUrl'))
        .ifEmpty(data.str('download_url'))
        .ifEmpty(data.str('url'))
        .ifEmpty(data.str('cdnUrl'));
    return DownloadSpec(
      url: checkedCloudUrl(url, '光鸭未返回有效下载地址，请确认下载权限'),
      fileName: f.name,
      expectedSize: f.size > 0 ? f.size : data.integer('size'),
      checksumType: f.hashType,
      checksumValue: f.hashValue,
      headers: {'User-Agent': userAgent, 'Referer': '$web/'},
      profile: 'guangya',
    );
  }

  Future<DownloadSpec> _shareDownload(
    BrowseSession share,
    CloudFile source,
    TokenSession token,
  ) async {
    final personal = BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      rootId: 'root',
      title: '我的光鸭云盘',
    );
    final name = 'AsterLink临时转存_${newId()}';
    final folder = await OperationProgress.step(
      OperationStage.createTemporary,
      () => createFolder(personal, 'root', name, token.credential),
    );
    final cleanup = DownloadCleanup(
      url: '',
      action: {
        'kind': 'temporary-folder',
        'platform': platform.key,
        'accountRevision': token.credential.updatedAt,
        'folderId': folder.id,
        'name': name,
      },
    );
    var staged = false;
    try {
      await stageCleanup?.call(cleanup);
      staged = stageCleanup != null;
      await OperationProgress.step(
        OperationStage.transfer,
        () => saveShare(share, [source], folder.id, token.credential),
      );
      final copied = await OperationProgress.step(
        OperationStage.waitTransfer,
        () async {
          for (var attempt = 0; attempt < 30; attempt++) {
            final files = await list(personal, folder.id, token.credential);
            final matches = files
                .where((f) => !f.isDirectory && f.name == source.name)
                .toList();
            require(matches.length <= 1, '光鸭临时目录出现同名文件，无法确定下载目标');
            if (matches.isNotEmpty) {
              final file = matches.single;
              require(
                source.size <= 0 || file.size == source.size,
                '光鸭转存文件大小不一致',
              );
              require(
                source.hashValue == null ||
                    file.hashValue == null ||
                    source.hashType != file.hashType ||
                    source.hashValue == file.hashValue,
                '光鸭转存文件校验信息不一致',
              );
              return file;
            }
            await RequestScope.wait(taskDelay);
          }
          throw const AppException('光鸭转存已提交，目标文件暂不可见，请稍后重试');
        },
      );
      return (await download(
        personal,
        copied,
        token.credential,
      )).copyWith(fileName: source.name, cleanup: cleanup);
    } catch (_) {
      if (!staged) {
        try {
          await deleteTemporaryFolder(
            personal,
            folder.id,
            name,
            token.credential,
          );
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> deleteTemporaryFolder(
    BrowseSession session,
    String id,
    String name,
    Credential credential,
  ) async {
    require(
      _parent(id).isNotEmpty &&
          RegExp(r'^AsterLink临时转存_[0-9a-f-]{36}$').hasMatch(name),
      '临时目录标识无效',
    );
    final roots = await list(session, session.rootId, credential);
    final folder = roots.where((f) => f.id == id).firstOrNull;
    if (folder == null) return;
    require(
      folder.isDirectory && folder.name == name,
      '临时目录已被修改，已保留目录，请在网盘中确认',
    );
    await delete(session, [folder], credential);
  }

  void _personal(BrowseSession session) =>
      require(session.canManageFiles, '请在个人网盘中执行此操作');

  Future<void> _wait(Json result, TokenSession session) async {
    final id = result.str('taskId');
    if (id.isEmpty) return;
    for (var attempt = 0; attempt < 80; attempt++) {
      await RequestScope.wait(taskDelay);
      final data = await _post(
        '/userres/v1/get_task_status',
        {'taskId': id},
        session: session,
        read: true,
      );
      final status = data.integer('status', -1), detail = data.obj('detail');
      if (status == 2 || status == 3) {
        require(
          status == 2 && detail.integer('code') == 0,
          detail.str('msg').ifEmpty('光鸭文件操作失败，请刷新列表后重试'),
        );
        return;
      }
      require(status == 0 || status == 1, '光鸭返回的任务状态无效，请刷新列表确认');
    }
    throw const AppException('光鸭操作仍在处理中，请稍后刷新列表确认结果');
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    _personal(s);
    cloudFileName(name);
    final session = await _session(c);
    final data = await _post('/userres/v1/file/create_dir', {
      'parentId': _parent(parent),
      'dirName': name,
      'failIfNameExist': true,
    }, session: session);
    require(
      data.str('fileId').ifEmpty(data.str('id')).isNotEmpty &&
          data.str('resType') != '1',
      '光鸭未创建文件夹，请检查是否存在同名文件',
    );
    return file({
      ...data,
      'fileName': data.str('fileName').ifEmpty(name),
      'resType': 2,
    }, parent);
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _upload(s, parent, source, c, onProgress);

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    _personal(s);
    cloudFileName(name);
    final session = await _session(c);
    await _wait(
      await _post('/userres/v1/file/rename', {
        'fileId': f.id,
        'newName': name,
      }, session: session),
      session,
    );
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    _personal(s);
    if (files.isEmpty) return;
    require(!files.any((f) => f.isDirectory && f.id == target), '不能移动到文件夹自身');
    final session = await _session(c);
    await _wait(
      await _post('/userres/v1/file/move_file', {
        'fileIds': files.map((f) => f.id).toList(),
        'parentId': _parent(target),
      }, session: session),
      session,
    );
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    _personal(s);
    if (files.isEmpty) return;
    require(files.every((f) => _parent(f.id).isNotEmpty), '不能删除网盘根目录');
    final session = await _session(c);
    await _wait(
      await _post('/userres/v1/file/delete_file', {
        'fileIds': files.map((f) => f.id).toList(),
      }, session: session),
      session,
    );
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    _personal(s);
    require(files.isNotEmpty, '请先选择文件');
    final data = await _post('/userres/v1/share_file', {
      'fileIds': files.map((f) => f.id).toList(),
      'title': options.title,
      'validateDuration': options.expiryDays ?? 0,
      'shareType': options.passcode?.isNotEmpty == true ? 1 : 0,
      'code': options.passcode ?? '',
      'autoFillCode': false,
      'trafficLimit': '0',
      'maxRestoreCount': 0,
      'downloadType': 1,
    }, session: await _session(c));
    final id = data.str('shareId').ifEmpty(data.str('id'));
    final url = data.str('shareUrl').ifEmpty(id.isEmpty ? '' : '$web/s/$id');
    return ShareCreation(
      checkedCloudUrl(url, '光鸭未返回分享链接'),
      data.str('code').ifEmpty(options.passcode ?? ''),
      options.title,
    );
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请先打开分享链接');
    if (files.isEmpty) return;
    final token = await _shareAccess(s), session = await _session(c);
    await _wait(
      await _post('/userres/v1/restore_share', {
        'accessToken': token,
        'fileIds': files.map((f) => f.id).toList(),
        'parentId': _parent(target),
      }, session: session),
      session,
    );
  }
}
