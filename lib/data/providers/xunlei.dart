import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/xunlei_web_login.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../../diagnostics/app_log.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';
import '../state_store.dart';
import 'xunlei_protocol.dart';
import 'xunlei_login.dart';

class XunleiShareParentUnavailable extends AppException {
  const XunleiShareParentUnavailable(super.message);
}

class XunleiSession {
  XunleiSession(
    this.credential,
    this.access,
    this.refresh,
    this.device,
    this.captcha,
    this.clientId,
    this.clientSecret,
    this.version, {
    this.managed = false,
  });
  Credential credential;
  bool managed, passwordRenewed = false;
  String access, refresh, captcha, device, clientId, clientSecret, version;
}

class XunleiConnector extends CloudConnector {
  XunleiConnector(
    this.http,
    this.vault,
    this.devices, {
    this.stageCleanup,
    this.passwordLogin,
    this.mutationDelay = const Duration(milliseconds: 750),
  });
  final JsonHttp http;
  final CredentialStore vault;
  final XunleiDevices devices;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  final Future<LoginResult> Function(String username, String password)?
  passwordLogin;
  final Duration mutationDelay;
  final _refreshGate = AsyncGate();
  final _captchaGate = AsyncGate();
  @override
  CloudPlatform get platform => CloudPlatform.xunlei;
  static const base = 'https://api-pan.xunlei.com';
  static const autoLoginFailureMessage = '迅雷自动登录失败，请重新登录或完成安全验证';
  static const _autoFailed = AccountLoginRequired(autoLoginFailureMessage);
  static const _accountChanged = AppException('迅雷账号已变化，请重新打开文件列表');
  static const ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
  String value(Credential c, String one, String two) =>
      c.field(one).trim().ifEmpty(c.field(two).trim());
  bool webCredential(Credential c) =>
      value(c, 'clientId', 'client_id') == XunleiWebLogin.clientId &&
      c.field('authType') == 'webToken';
  String clientVersion(Credential c) => webCredential(c)
      ? XunleiProtocol.webVersion
      : value(
          c,
          'clientVersion',
          'client_version',
        ).ifEmpty(XunleiProtocol.version);
  Future<XunleiSession> auth(Credential c) async {
    RequestScope.checkpoint();
    final current = vault.credential(platform);
    final managed = LoginCredentials.sameXunleiSession(c, current);
    if (!managed && LoginCredentials.hasXunleiPassword(c)) {
      throw _accountChanged;
    }
    if (managed) c = current!;
    final a = XunleiSession(
      c,
      value(c, 'accessToken', 'access_token').ifEmpty(c.primary),
      value(c, 'refreshToken', 'refresh_token').ifEmpty(c.secondary),
      value(c, 'deviceId', 'device_id').ifEmpty((await devices.get()).id),
      value(c, 'captchaToken', 'captcha_token'),
      value(c, 'clientId', 'client_id'),
      value(c, 'clientSecret', 'client_secret'),
      clientVersion(c),
      managed: managed,
    );
    checkpoint(a);
    final expiry = XunleiProtocol.jwt(a.access).integer('exp');
    if (a.access.isEmpty ||
        expiry > 0 &&
            expiry - DateTime.now().millisecondsSinceEpoch ~/ 1000 <= 60) {
      if (!await refresh(a)) throw const AccountLoginRequired('迅雷登录已过期，请重新登录');
    }
    return a;
  }

  void checkpoint(XunleiSession a) {
    RequestScope.checkpoint();
    _checkOwner(a);
  }

  void _checkOwner(XunleiSession a) {
    if (a.managed) {
      final latest = vault.credential(platform);
      if (!LoginCredentials.sameXunleiSession(a.credential, latest)) {
        throw _accountChanged;
      }
      if (!a.credential.sameAs(latest)) _useCredential(a, latest!);
    }
    if (a.credential.field('autoLoginBlocked') == '1') throw _autoFailed;
  }

  void _useCredential(XunleiSession a, Credential credential) {
    a.credential = credential;
    a.access = value(
      credential,
      'accessToken',
      'access_token',
    ).ifEmpty(credential.primary);
    a.refresh = value(
      credential,
      'refreshToken',
      'refresh_token',
    ).ifEmpty(credential.secondary);
    a.captcha = value(credential, 'captchaToken', 'captcha_token');
    a.device = value(credential, 'deviceId', 'device_id').ifEmpty(a.device);
    a.clientId = value(credential, 'clientId', 'client_id');
    a.clientSecret = value(credential, 'clientSecret', 'client_secret');
    a.version = clientVersion(credential);
  }

  Map<String, String> headers(XunleiSession a) => {
    'User-Agent': webCredential(a.credential)
        ? WebLoginTarget.desktopUserAgent
        : ua,
    'Authorization': 'Bearer ${a.access}',
    'X-Device-Id': a.device,
    'X-Client-Version': a.version,
    'Content-Type': 'application/json',
    'Origin': 'https://pan.xunlei.com',
    'Referer': 'https://pan.xunlei.com/',
    if (a.captcha.isNotEmpty) 'X-Captcha-Token': a.captcha,
    if (a.clientId.isNotEmpty) 'X-Client-Id': a.clientId,
  };
  Future<Json> pan(
    String method,
    String path,
    XunleiSession a, {
    Json? body,
    Map<String, Object?> params = const {},
  }) async {
    final url = params.isEmpty ? '$base$path' : query('$base$path', params);
    final action = '$method:$path';
    var refreshed = false, captchaRefreshed = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      checkpoint(a);
      final sentAccess = a.access, sentCaptcha = a.captcha;
      final r = await http.request(
        method,
        url,
        body: body == null ? null : encoded(body),
        headers: headers(a),
        contentType: 'application/json',
      );
      checkpoint(a);
      Json j;
      try {
        j = r.json;
      } on AppException {
        if (r.status != 401) rethrow;
        j = {};
      }
      final error = j.str('error');
      final captchaRejected =
          error == 'captcha_invalid' || error == 'captcha_required';
      if ((r.status == 401 || error == 'unauthenticated') && attempt < 2) {
        final alreadyRefreshed = a.access != sentAccess;
        if (alreadyRefreshed || await refresh(a, passwordOnly: refreshed)) {
          refreshed = true;
          await refreshCaptcha(
            a,
            action,
            rejectedCaptcha: alreadyRefreshed ? sentCaptcha : null,
          );
          continue;
        }
      }
      if (captchaRejected &&
          !captchaRefreshed &&
          attempt < 2 &&
          (a.captcha != sentCaptcha ||
              await refreshCaptcha(a, action, rejectedCaptcha: sentCaptcha))) {
        captchaRefreshed = true;
        continue;
      }
      if (r.status == 401 || error == 'unauthenticated' || captchaRejected) {
        if (a.passwordRenewed) await _blockAutoLogin(a);
        throw const AccountLoginRequired('迅雷登录已失效，请重新登录并完成验证');
      }
      final message = j
          .str('error_description')
          .ifEmpty(j.str('message'))
          .ifEmpty(error)
          .ifEmpty('迅雷请求失败（HTTP ${r.status}）');
      if (path == '/drive/v1/share/detail' &&
          r.status == 403 &&
          error == 'permission_denied') {
        throw XunleiShareParentUnavailable(message);
      }
      require(
        r.successful && error.isEmpty && j.integer('error_code') == 0,
        error == 'captcha_invalid' ? '$message；请重新登录迅雷账号' : message,
      );
      return j['data'] is Map ? j.obj('data') : j;
    }
    throw const AccountLoginRequired('迅雷登录已过期，请重新登录');
  }

  Future<bool> refresh(XunleiSession a, {bool passwordOnly = false}) {
    final access = a.access;
    return RequestScope.cancellable(
      _refreshGate.run(() async {
        checkpoint(a);
        if (a.access != access) return true;
        if (!passwordOnly && await _refresh(a)) return true;
        return _passwordRefresh(a);
      }),
    );
  }

  Future<bool> _refresh(XunleiSession a) async {
    checkpoint(a);
    final sent = a.credential;
    final web =
        a.clientId == XunleiWebLogin.clientId &&
        a.credential.field('authType') == 'webToken';
    if (a.refresh.isEmpty ||
        a.clientId.isEmpty ||
        !web && a.clientSecret.isEmpty) {
      return false;
    }
    final body = {
      'grant_type': 'refresh_token',
      'client_id': a.clientId,
      if (a.clientSecret.isNotEmpty) 'client_secret': a.clientSecret,
      'refresh_token': a.refresh,
    };
    final url = '${XunleiProtocol.authBase}/v1/auth/token';
    final response = web
        ? await http.postJson(url, body, {
            'X-Device-Id': a.device,
            'X-Client-Id': a.clientId,
            'Origin': 'https://pan.xunlei.com',
            'Referer': 'https://pan.xunlei.com/',
            'User-Agent': WebLoginTarget.desktopUserAgent,
          })
        : await http.postForm(url, form(body), {'X-Device-Id': a.device});
    checkpoint(a);
    if (!sent.sameAs(a.credential)) return true;
    XunleiLoginService.checkAvailable(response);
    if (!response.successful) return false;
    final j = response.json,
        access = response.json
            .str('access_token')
            .ifEmpty(response.json.str('accessToken'));
    if (access.isEmpty || access == 'null') return false;
    a.access = access;
    a.refresh = j
        .str('refresh_token')
        .ifEmpty(j.str('refreshToken'))
        .ifEmpty(a.refresh);
    await persist(a);
    return true;
  }

  Future<bool> _passwordRefresh(XunleiSession a) async {
    checkpoint(a);
    if (!a.managed ||
        a.passwordRenewed ||
        !LoginCredentials.hasXunleiPassword(a.credential) ||
        passwordLogin == null) {
      return false;
    }
    final sent = a.credential, rejectedAccess = a.access;
    DiagnosticLog.event('login.auto.start', fields: {'platform': platform.key});
    try {
      final result = await RequestScope.guarded(
        () => passwordLogin!(sent.field('username'), sent.field('password')),
        () => _checkOwner(a),
      );
      checkpoint(a);
      if (a.access != rejectedAccess) return true;
      final previousId = sent
          .field('userId')
          .ifEmpty(XunleiProtocol.jwt(rejectedAccess).str('sub'));
      final currentId = result.credential
          .field('userId')
          .ifEmpty(XunleiProtocol.jwt(result.credential.primary).str('sub'));
      require(
        previousId.isNotEmpty && currentId == previousId,
        '迅雷自动登录账号校验不一致，请重新登录',
      );
      final replacement = a.credential.withFields({
        ...result.credential.fields,
        'username': sent.field('username'),
        'password': sent.field('password'),
        'authType': 'passwordToken',
        'autoLoginBlocked': '',
        'userId': currentId,
      }, preserveRevision: true);
      final cancel = RequestScope.current;
      if (await vault.replaceCredential(
        platform,
        a.credential,
        replacement,
        canCommit: () => cancel?.isCancelled != true,
      )) {
        _useCredential(a, replacement);
        a.passwordRenewed = true;
        DiagnosticLog.event(
          'login.auto.success',
          fields: {'platform': platform.key},
        );
        return true;
      }
      checkpoint(a);
      if (a.access != rejectedAccess) return true;
      throw _accountChanged;
    } catch (error) {
      checkpoint(a);
      if (a.access != rejectedAccess) return true;
      if (error is HttpRequestFailure ||
          error is! AppException && error is! XunleiVerificationRequired) {
        rethrow;
      }
      await _blockAutoLogin(a);
      checkpoint(a);
      if (a.access != rejectedAccess) return true;
      throw _autoFailed;
    }
  }

  Future<void> _blockAutoLogin(XunleiSession a) async {
    checkpoint(a);
    final owner = a.credential, cancel = RequestScope.current;
    if (await vault.replaceCredential(
      platform,
      owner,
      owner.withFields({'autoLoginBlocked': '1'}, preserveRevision: true),
      canCommit: () => cancel?.isCancelled != true,
    )) {
      DiagnosticLog.event(
        'login.auto.failed',
        fields: {'platform': platform.key},
      );
    }
    checkpoint(a);
  }

  Future<void> persist(XunleiSession a) async {
    RequestScope.checkpoint();
    final updated = a.credential.withFields({
      'primary': a.access,
      'secondary': a.refresh,
      'accessToken': a.access,
      'refreshToken': a.refresh,
      'deviceId': a.device,
      'captchaToken': a.captcha,
      'clientId': a.clientId,
      'clientSecret': a.clientSecret,
      'clientVersion': a.version,
    }, preserveRevision: true);
    final cancel = RequestScope.current;
    if (await vault.replaceCredential(
      platform,
      a.credential,
      updated,
      canCommit: () => cancel?.isCancelled != true,
    )) {
      a.credential = updated;
    } else if (!a.managed) {
      // Candidate validation carries refreshed tokens into the final login;
      // AccountLoginService owns the eventual replacement of the stored account.
      a.credential = updated;
    }
    checkpoint(a);
  }

  Future<bool> refreshCaptcha(
    XunleiSession a,
    String action, {
    String? rejectedCaptcha,
  }) {
    final sentCaptcha = rejectedCaptcha ?? a.captcha;
    return RequestScope.cancellable(
      _captchaGate.run(() async {
        checkpoint(a);
        if (a.captcha != sentCaptcha && a.captcha.isNotEmpty) return true;
        final sent = a.credential;
        final web = webCredential(sent);
        if (!web &&
            (a.clientId != XunleiProtocol.clientId ||
                a.version != XunleiProtocol.version)) {
          return false;
        }
        final timestamp = '${DateTime.now().millisecondsSinceEpoch}';
        try {
          final response = await http.postJson(
            '${XunleiProtocol.authBase}/v1/shield/captcha/init',
            {
              'client_id': a.clientId,
              'device_id': a.device,
              'action': action,
              'captcha_token': a.captcha,
              if (!web)
                'redirect_uri': 'xlaccsdk01://xunlei.com/callback?state=harbor',
              'meta': {
                'client_version': a.version,
                'package_name': web
                    ? XunleiProtocol.webPackageName
                    : XunleiProtocol.packageName,
                'timestamp': timestamp,
                'captcha_sign': web
                    ? XunleiProtocol.webCaptchaSign(a.device, timestamp)
                    : XunleiProtocol.captchaSign(a.device, timestamp),
                'user_id': XunleiProtocol.jwt(
                  a.access,
                ).str('sub').ifEmpty(a.credential.field('userId')),
              },
            },
            {
              'User-Agent': web
                  ? WebLoginTarget.desktopUserAgent
                  : XunleiProtocol.appUa,
              if (web) 'Origin': 'https://pan.xunlei.com',
              if (web) 'Referer': 'https://pan.xunlei.com/',
              'Accept': 'application/json;charset=UTF-8',
              'X-Client-Id': a.clientId,
              'X-Device-Id': a.device,
              'X-Client-Version': a.version,
            },
          );
          checkpoint(a);
          if (!sent.sameAs(a.credential)) return a.captcha.isNotEmpty;
          XunleiLoginService.checkAvailable(response);
          final token = response.json.str('captcha_token');
          if (!response.successful ||
              token.isEmpty ||
              token == 'null' ||
              response.json.str('url').isNotEmpty) {
            return false;
          }
          a.captcha = token;
          await persist(a);
          return true;
        } on AppException catch (error) {
          checkpoint(a);
          if (error is HttpRequestFailure) rethrow;
          return false;
        }
      }),
    );
  }

  @override
  Future<CloudAccount> account(Credential credential) async =>
      _account(await auth(credential));

  Future<LoginResult> authenticate(Credential credential) async {
    final a = await auth(credential);
    final account = await _account(a);
    return LoginResult(a.credential, account);
  }

  Future<CloudAccount> _account(XunleiSession a) async {
    final data = await pan('GET', '/drive/v1/about', a);
    final jwt = XunleiProtocol.jwt(a.access), quota = data.obj('quota');
    final used = int.tryParse(quota.str('usage')),
        total = int.tryParse(quota.str('limit'));
    require(
      used != null && used >= 0 && total != null && total > 0,
      '迅雷未返回有效容量，请重试',
    );
    return CloudAccount(
      a.credential
          .field('nickname')
          .ifEmpty(jwt.str('name'))
          .ifEmpty(jwt.str('nickname'))
          .ifEmpty(jwt.str('sub'))
          .ifEmpty('迅雷用户'),
      used: used!,
      total: total!,
    );
  }

  Future<Json> sharePage(
    String id,
    String passcode,
    String pageToken,
    XunleiSession a,
  ) async {
    final data = await pan(
      'GET',
      '/drive/v1/share',
      a,
      params: {
        'share_id': id,
        'pass_code': passcode,
        'limit': 100,
        'page_token': pageToken,
        'thumbnail_size': 'SIZE_LARGE',
      },
    );
    require(
      !{'PASS_CODE_EMPTY', 'PASS_CODE_NEED'}.contains(data.str('share_status')),
      '该迅雷分享需要提取码',
    );
    require(data.str('share_status') != 'PASS_CODE_ERROR', '迅雷分享提取码错误');
    return data;
  }

  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? c) async {
    require(c != null, '迅雷分享解析需要先登录');
    require(link.shareId?.isNotEmpty == true, '迅雷分享链接缺少分享 ID');
    final data = await sharePage(
      link.shareId!,
      link.passcode ?? '',
      '',
      await auth(c!),
    );
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: data.str('title').ifEmpty('迅雷分享'),
      rootId: '',
      metadata: {
        'shareId': link.shareId!,
        'passCode': link.passcode ?? '',
        'passCodeToken': data.str('pass_code_token'),
      },
      sourceLink: link,
    );
  }

  @override
  Future<BrowseSession> openPersonal(Credential c) async {
    await auth(c);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的迅雷云盘',
      rootId: '',
    );
  }

  List<CloudFile> files(Json data, String parent, {bool share = false}) {
    require(data['files'] is List, '迅雷文件列表响应不完整，请刷新重试');
    return data.list('files').map((j) {
      require(j.str('id').isNotEmpty, '迅雷文件标识缺失，请刷新列表');
      final hashes = j['hash'] is Map ? j.obj('hash') : j.obj('hashes');
      final hashType = hashes.str('md5').isNotEmpty
          ? 'md5'
          : hashes.str('sha1').isNotEmpty
          ? 'sha1'
          : null;
      return CloudFile(
        id: j.str('id'),
        name: j.str('name'),
        size: j.integer('size'),
        isDirectory: j.str('kind') == 'drive#folder',
        // Share responses can expose an owner-only parent outside this share.
        parentId: share ? parent : j.str('parent_id').ifEmpty(parent),
        modifiedAt: j.str('modified_time'),
        thumbnailUrl: j.str('thumbnail_link'),
        hashType: hashType,
        hashValue: hashType == null ? null : hashes.str(hashType),
      );
    }).toList();
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    require(c != null, '请先登录迅雷云盘');
    final a = await auth(c!),
        result = <CloudFile>[],
        seen = <String>{},
        pages = <String>{};
    var pageToken = '';
    for (var page = 0; page < 100; page++) {
      final data = s.mode == BrowseMode.share
          ? parent.isEmpty
                ? await sharePage(
                    s.meta('shareId'),
                    s.meta('passCode'),
                    pageToken,
                    a,
                  )
                : await pan(
                    'GET',
                    '/drive/v1/share/detail',
                    a,
                    params: {
                      'share_id': s.meta('shareId'),
                      'parent_id': parent,
                      'pass_code_token': s.meta('passCodeToken'),
                      'limit': 100,
                      'page_token': pageToken,
                      'thumbnail_size': 'SIZE_LARGE',
                    },
                  )
          : await pan(
              'GET',
              '/drive/v1/files',
              a,
              params: {
                'parent_id': parent,
                'page_token': pageToken,
                'limit': 100,
                'with_audit': true,
                'filters': '{"trashed":{"eq":false}}',
              },
            );
      result.addAll(
        files(
          data,
          parent,
          share: s.mode == BrowseMode.share,
        ).where((f) => seen.add(f.id)),
      );
      pageToken = data.str('next_page_token');
      if (pageToken.isEmpty || !pages.add(pageToken)) break;
      require(page < 99, '目录文件过多，请缩小范围后重试');
    }
    return result;
  }

  Future<List<String>> restore(
    BrowseSession s,
    List<CloudFile> selected,
    String target,
    XunleiSession a,
  ) async {
    final data = await pan(
      'POST',
      '/drive/v1/share/restore',
      a,
      body: {
        'share_id': s.meta('shareId'),
        'pass_code_token': s.meta('passCodeToken'),
        'parent_id': target,
        'ancestor_ids': [],
        'file_ids': selected.map((f) => f.id).toList(),
        'specify_parent_id': true,
      },
    );
    Json mapping = {};
    try {
      mapping = asJson(jsonDecode(data.obj('params').str('trace_file_ids')));
    } catch (_) {}
    final mapped = selected
        .map((f) => mapping.str(f.id))
        .where((id) => id.isNotEmpty)
        .toList();
    final restored = mapped.isNotEmpty
        ? mapped
        : [if (data.str('file_id').isNotEmpty) data.str('file_id')];
    require(restored.length == selected.length, '迅雷未确认全部文件的转存结果，请刷新目标目录确认');
    return restored;
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory, '文件夹不能直接下载');
    require(c != null, '请先登录迅雷云盘');
    final a = await auth(c!);
    var id = f.id;
    DownloadCleanup? cleanup;
    if (s.mode == BrowseMode.share) {
      final name = 'AsterLink临时转存_${newId()}';
      final directory = await OperationProgress.step(
        OperationStage.createTemporary,
        () => _createFolder(a, '', name),
      );
      require(directory.name == name, '迅雷返回的临时目录与请求不一致，请刷新网盘后重试');
      cleanup = DownloadCleanup(
        url: '',
        action: {
          'kind': 'temporary-folder',
          'platform': platform.key,
          'folderId': directory.id,
          'name': name,
          'accountRevision': a.credential.updatedAt,
        },
      );
      await stageCleanup?.call(cleanup);
      final ids = await OperationProgress.step(
        OperationStage.transfer,
        () => restore(s, [f], directory.id, a),
      );
      require(ids.isNotEmpty, '迅雷转存完成后未返回新文件 ID');
      id = ids.first;
    }
    return OperationProgress.step(OperationStage.downloadLink, () async {
      final path = '/drive/v1/files/${Uri.encodeComponent(id)}';
      final data = await pan(
        'GET',
        path,
        a,
        params: {
          '_magic': 2021,
          'usage': 'PLAY',
          'thumbnail_size': 'SIZE_LARGE',
          'with': ['hdr10', 'subtitle_files', 'task', 'public_share_tag'],
        },
      );
      final url = data
          .obj('links')
          .obj('application/octet-stream')
          .str('url')
          .ifEmpty(data.str('web_content_link'));
      require(url.isNotEmpty, '迅雷没有返回可用下载链接');
      final uri = Uri.tryParse(url);
      require(
        uri != null &&
            {'http', 'https'}.contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty,
        '迅雷返回的下载地址无效',
      );
      final size = data.integer('size', f.size);
      require(
        f.size <= 0 || size <= 0 || size == f.size,
        '迅雷返回的文件大小与所选文件不一致，请刷新列表',
      );
      return DownloadSpec(
        url: url,
        fileName: data.str('name').ifEmpty(f.name),
        expectedSize: size > 0 ? size : f.size,
        headers: {'User-Agent': XunleiProtocol.appUa},
        checksumType: f.hashType,
        checksumValue: f.hashValue,
        cleanup: cleanup,
      );
    });
  }

  void personal(BrowseSession s) =>
      require(s.mode == BrowseMode.personal, '请在个人网盘中执行此操作');
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    require(s.canManageFiles, '请在个人网盘中上传文件');
    final a = await auth(c), io = UploadIO(http, source, onProgress);
    var blockSize = 0x40000;
    while (source.size / blockSize > 0x200 && blockSize < 0x200000) {
      blockSize *= 2;
    }
    Stream<List<int>> hashes() async* {
      for (var start = 0; start < source.size; start += blockSize) {
        checkpoint(a);
        final end = math.min(source.size, start + blockSize);
        final digest = await sha1.bind(source.openRead(start, end)).first;
        io.progress(UploadPhase.preparing, end);
        yield digest.bytes;
      }
    }

    final gcid = (await sha1.bind(hashes()).first).toString().toUpperCase();
    final task = await pan(
      'POST',
      '/drive/v1/files',
      a,
      body: {
        'kind': 'drive#file',
        'parent_id': parent,
        'name': source.name,
        'size': source.size,
        'hash': gcid,
        'upload_type': 'UPLOAD_TYPE_RESUMABLE',
        'space': '',
      },
    );
    final params = task.obj('resumable').obj('params');
    final id = task.obj('file').str('id').ifEmpty(task.str('id'));
    if (task.str('upload_type') == 'UPLOAD_TYPE_RESUMABLE' ||
        params.isNotEmpty) {
      await io.s3(
        endpoint: params.str('endpoint'),
        bucket: params.str('bucket'),
        object: params.str('key'),
        access: params.str('access_key_id'),
        secret: params.str('access_key_secret'),
        token: params.str('security_token'),
        region: 'xunlei',
      );
    }
    return io.confirm(() => list(s, parent, c), id: id);
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    personal(s);
    return _createFolder(await auth(c), parent, name);
  }

  Future<CloudFile> _createFolder(
    XunleiSession a,
    String parent,
    String name,
  ) async {
    final data = await pan(
      'POST',
      '/drive/v1/files',
      a,
      body: {
        'kind': 'drive#folder',
        'name': name,
        'parent_id': parent,
        'space': '',
      },
    );
    // The official create-file response wraps the new directory in `file`.
    // Keep legacy flat responses, but never use an envelope/task ID as a file ID.
    final wrapped = data.containsKey('file');
    final file = wrapped ? data.obj('file') : data;
    final id = file['id'] is String ? file.str('id').trim() : '';
    require(
      id.isNotEmpty &&
          id != 'null' &&
          (file.str('kind').isEmpty || file.str('kind') == 'drive#folder') &&
          (wrapped ||
              data['task'] is! Map ||
              file.str('kind') == 'drive#folder'),
      '迅雷创建目录响应缺少有效文件夹 ID，请重试',
    );
    require(
      (file.str('phase').isEmpty ||
              file.str('phase') == 'PHASE_TYPE_COMPLETE') &&
          data.obj('task').str('phase') != 'PHASE_TYPE_ERROR',
      '迅雷文件夹尚未创建成功，请稍后重试',
    );
    require(
      !file.containsKey('parent_id') || file.str('parent_id') == parent,
      '迅雷返回的文件夹位置与请求不一致，请刷新网盘后重试',
    );
    return CloudFile(
      id: id,
      name: file.str('name').ifEmpty(name),
      isDirectory: true,
      parentId: parent,
    );
  }

  Future<void> deleteTemporaryFolder(String id, Credential c) async {
    require(id.isNotEmpty, '迅雷临时目录标识无效');
    await pan(
      'POST',
      '/drive/v1/files:batchDelete',
      await auth(c),
      body: {
        'ids': [id],
        'space': '',
      },
    );
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    personal(s);
    await pan(
      'PATCH',
      '/drive/v1/files/${Uri.encodeComponent(f.id)}',
      await auth(c),
      body: {'name': name},
    );
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    final a = await auth(c);
    await pan(
      'POST',
      '/drive/v1/files:batchMove',
      a,
      body: {
        'ids': files.map((f) => f.id).toList(),
        'to': {'parent_id': target, 'space': ''},
        'space': '',
      },
    );
    final ids = files.map((file) => file.id).toSet();
    for (var attempt = 0; attempt < 8; attempt++) {
      checkpoint(a);
      final current = await list(s, target, a.credential);
      checkpoint(a);
      if (current.map((file) => file.id).toSet().containsAll(ids)) return;
      if (attempt < 7) await Future<void>.delayed(mutationDelay);
    }
    throw const AppException('迅雷已受理移动，列表尚未更新，请稍后刷新确认');
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    await pan(
      'POST',
      '/drive/v1/files:batchTrash',
      await auth(c),
      body: {'ids': files.map((f) => f.id).toList(), 'space': ''},
    );
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请打开分享链接');
    await restore(s, files, target, await auth(c));
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    require(files.isNotEmpty, '请选择文件');
    final data = await pan(
      'POST',
      '/drive/v1/share',
      await auth(c),
      body: {
        'file_ids': files.map((f) => f.id).toList(),
        'share_to': 'copy',
        'params': {
          'subscribe_push': 'false',
          'WithPassCodeInLink': 'true',
          'with_pass_code_in_link': 'true',
          if (options.passcode?.isNotEmpty == true)
            'pass_code': options.passcode,
        },
        'title': options.title.ifEmpty(files.first.name),
        'restore_limit': '-1',
        'expiration_days': options.expiryDays?.toString() ?? '-1',
      },
    );
    final url = data
        .str('share_url')
        .ifEmpty(
          data.str('share_id').isEmpty
              ? ''
              : 'https://pan.xunlei.com/s/${data.str('share_id')}',
        );
    require(url.isNotEmpty, '分享已创建，但服务未返回分享链接');
    return ShareCreation(
      url,
      data.str('pass_code'),
      data.str('title').ifEmpty(options.title).ifEmpty(files.first.name),
    );
  }
}
