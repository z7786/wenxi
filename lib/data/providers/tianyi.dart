import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:pointycastle/export.dart' as pc;
import 'package:crypto/crypto.dart';
import '../../core/crypto_box.dart';
import '../../core/login_crypto.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/file_types.dart';
import '../../domain/models.dart';
import '../../domain/tianyi_web_login.dart';
import '../../domain/tianyi_share.dart';
import '../../domain/uploads.dart';
import '../../domain/rapid_transfer.dart';
import 'dart:io' show HttpDate;
import '../http.dart';
import '../http_retry.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';
import '../state_store.dart';

part 'uploads/tianyi_upload.dart';
part 'uploads/tianyi_rapid_transfer.dart';

/// Tianyi's official cloud protocol, shared by native and imported logins.
class TianyiConnector extends CloudConnector {
  @override
  bool get providesTransferMd5 => true;
  @override
  bool canRapidTransferTo(BrowseSession session) => session.canManageFiles;
  @override
  Future<RapidTransferResult> rapidTransfer(
    BrowseSession session,
    String parent,
    RapidTransferFile file,
    Credential credential,
  ) => _run(credential, () => _rapidTransfer(session, parent, file, credential));
  TianyiConnector(
    this.http, {
    this.store,
    this.passwordLogin,
    this.taskDelay = const Duration(milliseconds: 800),
    this.maxTaskPolls = 60,
  });

  final JsonHttp http;
  final CredentialStore? store;
  final Future<LoginResult> Function(String username, String password)?
  passwordLogin;
  final Duration taskDelay;
  final int maxTaskPolls;
  static const origin = 'https://cloud.189.cn';
  static const _openOrigin = 'https://api.cloud.189.cn';
  static const _h5Origin = 'https://h5.cloud.189.cn';
  static const _familyAppKey = '600100422';
  static const _familySessionPath = 'portal/v2/getUserBriefInfo';
  static const _familyTokenPath = 'open/oauth2/getAccessTokenBySsKey';
  static const root = '-11';
  static const webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const _mobileUa =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';
  static const _pageSize = 60;
  static const autoLoginFailureMessage = '天翼自动登录失败，请重新登录或切换网页登录';
  static const _autoFailed = AccountLoginRequired(autoLoginFailureMessage);
  static const _accountChanged = AccountLoginRequired('天翼账号已变化，请重新登录');
  final _refreshing = <int, (Credential, Future<Credential>)>{};
  ({String cookie, int? revision, String token})? _accessToken;
  final _zoneKey = Object();
  _TianyiSession get _session => Zone.current[_zoneKey] as _TianyiSession;
  @override
  CloudPlatform get platform => CloudPlatform.tianyi;

  Credential _required(Credential? value) {
    if (value == null || !LoginCredentials.plausible(platform, value.primary)) {
      throw const AccountLoginRequired('请先登录天翼云盘');
    }
    return value;
  }

  Future<T> _run<T>(
    Credential? credential,
    Future<T> Function() action, {
    bool candidate = false,
    bool fresh = false,
  }) async {
    // Password renewal validates a new candidate while a stored session is
    // awaiting it. Its cookies must never inherit or mutate the old session.
    if (!candidate && !fresh && Zone.current[_zoneKey] != null) {
      _checkpoint();
      return action();
    }
    Credential? owner;
    var cookie = '', browserId = '';
    if (credential != null) {
      _required(credential);
      if (store != null && !candidate) {
        owner = _owner(credential);
      }
      final source = owner ?? credential;
      final normalized = LoginCredentials.normalize(platform, source.primary);
      cookie = TianyiWebLogin.cookie(normalized);
      browserId = TianyiWebLogin.browserId(source.field('browserId')).ifEmpty(
        TianyiWebLogin.browserId(
          TianyiWebLogin.decode(normalized)['browserId'],
        ),
      );
    }
    return runZoned(() async {
      _checkpoint();
      final result = await action();
      _checkpoint();
      return result;
    }, zoneValues: {_zoneKey: _TianyiSession(cookie, owner, browserId)});
  }

  void _checkpoint() {
    RequestScope.checkpoint();
    final owner = _session.owner;
    if (owner == null) return;
    final current = _owner(owner);
    if (current.field('autoLoginBlocked') == '1') throw _autoFailed;
    if (!owner.sameAs(current)) {
      _session.owner = current;
      _session.cookie = current.primary;
      _session.browserId = TianyiWebLogin.browserId(current.field('browserId'));
    }
  }

  Credential _owner(Credential expected) {
    final current = store?.credential(platform);
    if (!LoginCredentials.sameTianyiSession(expected, current)) {
      throw _accountChanged;
    }
    return current!;
  }

  bool _hasPassword(Credential credential) =>
      credential.field('authType') == 'passwordCookie' &&
      credential.field('username').trim().isNotEmpty &&
      credential.field('password').isNotEmpty;

  static bool _okCode(Object? value) =>
      value == null || {'', '0', 'Success', 'success'}.contains('$value');

  Json _checked(
    HttpResult response, {
    bool downloading = false,
    bool optionalVideo = false,
  }) {
    if (response.status == 401 ||
        response.status >= 300 && response.status < 400) {
      throw const _TianyiSessionExpired();
    }
    if (optionalVideo &&
        ReadRetryScope.transientStatuses.contains(response.status)) {
      throw HttpRequestFailure(
        '天翼视频取链接口暂时不可用（HTTP ${response.status}）',
        kind: 'http',
        status: response.status,
        retryable: true,
      );
    }
    final data = response.json;
    final code =
        [
          'errorCode',
          'res_code',
          'code',
        ].map(data.str).where((value) => !_okCode(value)).firstOrNull ??
        '';
    if ({
      'InvalidSessionKey',
      'CommonInvalidSessionKey',
      'SafeAccessLoginTimeout',
      'InvalidAccessToken',
      'AccessTokenHasExpired',
      'AccessTokenHasExired',
      'FamilyAccessTokenInvalid',
      'UserNotLogin',
    }.contains(code)) {
      throw const _TianyiSessionExpired();
    }
    if (code == 'InvalidDeviceStatus') {
      throw const AccountLoginRequired('天翼要求设备安全验证，请在官方客户端完成验证后重新登录');
    }
    if (code == 'FileTooLarge' && (downloading || optionalVideo)) {
      throw const _TianyiFileTooLarge();
    }
    final message = switch (code) {
      'FileTooLarge' => '天翼当前操作触发文件大小限制（FileTooLarge）',
      'AccessCodeError' ||
      'ShareAccessCodeError' ||
      'ShareAccessCodeNotMatch' => '天翼访问码错误，请检查后重新解析',
      'ShareAccessCodeFaildCountOver' ||
      'InvalidVerifyCode' => '天翼要求验证码，请先在官方分享页面完成验证后重试',
      'ShareNotFound' ||
      'ShareInfoNotFound' ||
      'ShareExpired' ||
      'ShareExpiredError' ||
      'ShareCanceled' => '天翼分享已取消或过期，请确认链接',
      'ShareAuditWaiting' => '天翼分享正在审核，请稍后重试',
      'ShareAuditNo' ||
      'ShareAuditNotPass' ||
      'ShareNotReceiver' => '天翼分享暂不可访问，请在官网确认分享状态',
      'FileNotFound' || 'FileNotFoundError' => '天翼文件不存在，请刷新列表',
      'MemberInfoNotExist' ||
      'FamilyNotFound' ||
      'InvalidFamilyId' => '当前账号已无法访问该家庭云，请重新选择家庭',
      'InsufficientStorageSpace' ||
      'InsufficientSpace' ||
      'NotEnoughSpace' => '天翼网盘空间不足，无法转存，请清理空间后重试',
      _ =>
        '天翼请求失败${RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(code) ? '（$code）' : ''}',
    };
    require(
      response.successful &&
          _okCode(data['res_code']) &&
          _okCode(data['errorCode']) &&
          _okCode(data['code']) &&
          (!data.containsKey('success') ||
              data.boolean('success') ||
              optionalVideo),
      message,
    );
    return data;
  }

  Future<void> _acceptCookies(
    HttpResult response,
    Credential? sentOwner,
  ) async {
    _checkpoint();
    if (sentOwner != null && !sentOwner.sameAs(_session.owner)) return;
    final updates = <String, String>{};
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final header in entry.value) {
        final parts = header.split(';');
        final pair = parts.first.trim(), separator = pair.indexOf('=');
        if (separator <= 0) continue;
        final name = pair.substring(0, separator).trim();
        final value = pair.substring(separator + 1).trim();
        if (!{'COOKIE_LOGIN_USER', 'LOGIN_USER', 'JSESSIONID'}.contains(name) ||
            value.isEmpty ||
            RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(value)) {
          continue;
        }
        // Do not promote cookies scoped to SSO or an unrelated host into the API.
        final domain = parts
            .map((p) => p.trim())
            .where((p) => p.toLowerCase().startsWith('domain='))
            .firstOrNull;
        if (domain != null &&
            !{'cloud.189.cn', '189.cn'}.contains(
              domain
                  .substring(7)
                  .toLowerCase()
                  .replaceFirst(RegExp(r'^\.'), ''),
            )) {
          continue;
        }
        if (parts.any(
          (p) => RegExp(
            r'^max-age\s*=\s*0$',
            caseSensitive: false,
          ).hasMatch(p.trim()),
        )) {
          continue;
        }
        updates[name] = value;
      }
    }
    if (updates.isEmpty) return;
    final pairs = LoginCredentials.cookiePairs(_session.cookie)
      ..addAll(updates);
    final cookie = pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
    if (sentOwner != null) {
      final replacement = sentOwner.withFields({
        'primary': cookie,
      }, preserveRevision: true);
      final cancel = RequestScope.current;
      final committed = await store!.replaceCredential(
        platform,
        sentOwner,
        replacement,
        canCommit: () => cancel?.isCancelled != true,
      );
      _checkpoint();
      if (!committed || !replacement.sameAs(_session.owner)) return;
    }
    _session.cookie = cookie;
  }

  Future<Json> _api(
    String path, {
    Map<String, Object?> params = const {},
    String method = 'GET',
    bool jsonBody = false,
    bool public = false,
    String shareCookie = '',
    Map<String, String> extraHeaders = const {},
    bool renewSession = true,
  }) async {
    if (path.startsWith('open/family/')) {
      require(method == 'GET' && !public, '家庭云暂不支持此操作');
      return _tokenApi(path, params, family: true);
    }
    for (var attempt = 0; ; attempt++) {
      _checkpoint();
      final owner = _session.owner, sentCookie = _session.cookie;
      final pairs = LoginCredentials.cookiePairs(public ? '' : sentCookie)
        ..addAll(LoginCredentials.cookiePairs(shareCookie));
      final cookies = pairs.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
      final url = query('$origin/api/$path.action', {
        if (method == 'GET') ...params,
        'noCache': DateTime.now().microsecondsSinceEpoch,
      });
      final response =
          await (path == 'open/batch/checkBatchTask'
              ? http.readRequest
              : http.request)(
            method,
            url,
            body: method == 'GET'
                ? null
                : jsonBody
                ? encoded(params)
                : form(params),
            headers: {
              'Accept': 'application/json;charset=UTF-8',
              'Sign-Type': '1',
              'User-Agent': webUa,
              'Referer': '$origin/web/',
              'Origin': origin,
              if (!public && _session.browserId.isNotEmpty)
                'Browser-Id': _session.browserId,
              if (cookies.isNotEmpty) 'Cookie': cookies,
              ...extraHeaders,
            },
            followRedirects: false,
            contentType: method == 'GET'
                ? null
                : jsonBody
                ? 'application/json; charset=utf-8'
                : 'application/x-www-form-urlencoded; charset=utf-8',
          );
      final Json result;
      try {
        result = switch (path) {
          _familySessionPath => _familyChecked(response, 'session'),
          _familyTokenPath => _familyChecked(response, 'authorize'),
          _ => _checked(
            response,
            downloading: path == 'open/file/getFileDownloadUrl',
            optionalVideo: path == 'portal/getNewVlcVideoPlayUrl',
          ),
        };
      } on _TianyiSessionExpired catch (error, stack) {
        _checkpoint();
        if (path == 'open/user/getUserInfoForPortal') {
          Json data = {};
          try {
            data = response.json;
          } on AppException {
            // Redirects may return HTML; only typed status fields are logged.
          }
          final code = data.str('errorCode').ifEmpty(data.str('res_code'));
          DiagnosticLog.event(
            'tianyi.identity_rejected',
            fields: {
              'httpStatus': response.status,
              'hasBrowserBinding': _session.browserId.isNotEmpty,
              if (RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(code))
                'serverCode': code,
            },
          );
        }
        if (public) {
          throw const _TianyiPublicLoginRequired();
        }
        if (!renewSession ||
            owner == null ||
            passwordLogin == null ||
            !_hasPassword(owner)) {
          rethrow;
        }
        if (attempt > 0) {
          await _blockAutoLogin(owner, error, stack, stage: 'retry');
          _checkpoint();
          throw _autoFailed;
        }
        final renewed = await _renew(owner, sentCookie);
        _session.owner = renewed;
        _session.cookie = renewed.primary;
        _session.browserId = TianyiWebLogin.browserId(
          renewed.field('browserId'),
        );
        continue;
      }
      // Only an explicit expired session retries this one API request. A
      // successful transfer/mutation or a network error is never replayed.
      _checkpoint();
      if (!public) await _acceptCookies(response, owner);
      return result;
    }
  }

  static String _accessSignature(Map<String, Object?> values) {
    // The official web client sorts unescaped key=value pairs before MD5.
    final pairs =
        values.entries
            .map((entry) => '${entry.key}=${entry.value ?? ''}')
            .toList()
          ..sort();
    return md5.convert(utf8.encode(pairs.join('&'))).toString();
  }

  Json _familyChecked(HttpResult response, String stage) {
    try {
      return _checked(response, downloading: stage == 'getFileDownloadUrl');
    } catch (error, stack) {
      _checkpoint();
      var code = '';
      try {
        final data = response.json;
        code =
            ['errorCode', 'res_code', 'code']
                .map(data.str)
                .where((value) => value.isNotEmpty && !_okCode(value))
                .firstOrNull ??
            '';
      } catch (_) {
        // A malformed body is reported by _checked without exposing its text.
      }
      DiagnosticLog.active?.record(
        'cloud.family.request_failed',
        level: error is _TianyiSessionExpired ? 'warning' : 'error',
        error: error,
        stack: stack,
        fields: {
          'platform': platform.key,
          'stage': stage,
          'httpStatus': response.status,
          if (RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(code))
            'serverCode': code,
        },
      );
      rethrow;
    }
  }

  Future<String> _getAccessToken() async {
    _checkpoint();
    final cached = _accessToken;
    if (cached != null &&
        cached.cookie == _session.cookie &&
        cached.revision == _session.owner?.updatedAt) {
      return cached.token;
    }
    for (var attempt = 0; ; attempt++) {
      final info = await _api(_familySessionPath);
      final sessionKey = info.str('sessionKey');
      require(
        info['sessionKey'] is String &&
            sessionKey.isNotEmpty &&
            sessionKey.length <= 4096 &&
            !RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(sessionKey),
        '天翼未返回有效登录会话，请重新登录',
      );
      final timestamp = '${DateTime.now().millisecondsSinceEpoch}';
      final Json result;
      try {
        result = await _api(
          _familyTokenPath,
          params: {'sessionKey': sessionKey},
          extraHeaders: {
            'AppKey': _familyAppKey,
            'Timestamp': timestamp,
            'Signature': _accessSignature({
              'sessionKey': sessionKey,
              'AppKey': _familyAppKey,
              'Timestamp': timestamp,
            }),
          },
          // A renewed Cookie needs a fresh sessionKey before another exchange.
          renewSession: false,
        );
      } on _TianyiSessionExpired {
        _checkpoint();
        if (attempt > 0) rethrow;
        continue;
      }
      _checkpoint();
      final token = result.str('accessToken');
      require(
        result['accessToken'] is String &&
            token.isNotEmpty &&
            token.length <= 8192 &&
            !RegExp(r'[\x00-\x20\x7f-\x9f]').hasMatch(token),
        '天翼未返回有效访问授权，请重新登录后重试',
      );
      _accessToken = (
        cookie: _session.cookie,
        revision: _session.owner?.updatedAt,
        token: token,
      );
      return token;
    }
  }

  // Family cloud and the mobile website use the same signed token protocol.
  Future<Json> _tokenApi(
    String path,
    Map<String, Object?> params, {
    bool family = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final token = await _getAccessToken();
      _checkpoint();
      final timestamp = '${DateTime.now().millisecondsSinceEpoch}';
      final response = await http.request(
        'GET',
        query('$_openOrigin/$path.action', params),
        headers: {
          'Accept': 'application/json;charset=UTF-8',
          'AccessToken': token,
          'Timestamp': timestamp,
          'Signature': _accessSignature({
            ...params,
            'AccessToken': token,
            'Timestamp': timestamp,
          }),
          'Sign-Type': '1',
          'User-Agent': family ? webUa : _mobileUa,
          'Referer': family ? '$origin/web/' : '$_h5Origin/share.html',
          'Origin': family ? origin : _h5Origin,
          if (!family) 'X-Request-ID': newId().replaceAll('-', ''),
        },
        followRedirects: false,
      );
      _checkpoint();
      try {
        return family
            ? _familyChecked(response, path.split('/').last)
            : _checked(response, downloading: true);
      } on _TianyiSessionExpired {
        // A concurrent request may already have replaced this expired token.
        if (_accessToken?.token == token) _accessToken = null;
        if (attempt > 0) {
          throw AccountLoginRequired(
            family ? '天翼家庭云授权已失效，请重新登录' : '天翼下载授权已失效，请重新登录',
          );
        }
      }
    }
  }

  Future<Credential> _renew(Credential expected, String rejectedCookie) async {
    RequestScope.checkpoint();
    final current = _owner(expected);
    if (current.field('autoLoginBlocked') == '1') throw _autoFailed;
    if (!_hasPassword(current) || passwordLogin == null) {
      throw const _TianyiSessionExpired();
    }
    if (current.primary != rejectedCookie) return current;
    final pending = _refreshing[current.updatedAt];
    final Future<Credential> shared;
    if (pending != null &&
        LoginCredentials.sameTianyiSession(pending.$1, current)) {
      shared = pending.$2;
    } else {
      late final Future<Credential> renewal;
      // A canceled player/download stops waiting without canceling the login
      // shared with other requests. Logout/switching is checked before commit.
      renewal = RequestScope().run(() => _performRenewal(current)).whenComplete(
        () {
          if (identical(_refreshing[current.updatedAt]?.$2, renewal)) {
            _refreshing.remove(current.updatedAt);
          }
        },
      );
      _refreshing[current.updatedAt] = (current, renewal);
      shared = renewal;
    }
    final cancel = RequestScope.current;
    if (cancel == null) {
      await shared;
    } else {
      await Future.any<Credential>([
        shared,
        cancel.whenCancel.then<Credential>(
          (_) => throw const AppException('请求已取消'),
        ),
      ]);
    }
    RequestScope.checkpoint();
    final renewed = _owner(expected);
    if (renewed.field('autoLoginBlocked') == '1') throw _autoFailed;
    return renewed;
  }

  Future<Credential> _performRenewal(Credential owner) async {
    DiagnosticLog.event('login.auto.start', fields: {'platform': platform.key});
    try {
      _owner(owner);
      final login = await passwordLogin!(
        owner.field('username'),
        owner.field('password'),
      );
      final current = _owner(owner);
      if (current.field('autoLoginBlocked') == '1') throw _autoFailed;
      final previousId = owner.field('userId');
      require(
        previousId.isNotEmpty
            ? login.credential.field('userId') == previousId
            : owner.field('loginName').isNotEmpty &&
                  login.credential.field('loginName') ==
                      owner.field('loginName'),
        '天翼自动登录账号校验不一致，请重新登录',
      );
      // A newer response already rotated this session while login was pending.
      if (current.primary != owner.primary) return current;
      final replacement = current.withFields({
        'primary': LoginCredentials.normalize(
          platform,
          login.credential.primary,
        ),
        'userId': login.credential.field('userId'),
        'loginName': login.credential.field('loginName'),
        'browserId': TianyiWebLogin.browserId(
          login.credential.field('browserId'),
        ),
        'nickname': login.account.nickname,
      }, preserveRevision: true);
      if (!await store!.replaceCredential(platform, current, replacement)) {
        final latest = _owner(owner);
        if (latest.field('autoLoginBlocked') == '1') throw _autoFailed;
        if (latest.primary == owner.primary) throw _accountChanged;
        return latest;
      }
      DiagnosticLog.event(
        'login.auto.success',
        fields: {'platform': platform.key},
      );
      return replacement;
    } catch (error, stack) {
      final current = _owner(owner);
      if (current.primary != owner.primary &&
          current.field('autoLoginBlocked') != '1') {
        return current;
      }
      await _blockAutoLogin(current, error, stack, stage: 'password');
      _owner(owner);
      throw _autoFailed;
    }
  }

  Future<void> _blockAutoLogin(
    Credential owner,
    Object error,
    StackTrace stack, {
    required String stage,
  }) async {
    await store!.replaceCredential(
      platform,
      owner,
      owner.withFields({'autoLoginBlocked': '1'}, preserveRevision: true),
    );
    DiagnosticLog.error(
      'login.auto.failed',
      error,
      stack,
      fields: {'platform': platform.key, 'stage': stage},
    );
  }

  Future<Json> _identity() async {
    final info = await _api('open/user/getUserInfoForPortal');
    require(
      info.str('loginName').trim().isNotEmpty ||
          info.str('userId').trim().isNotEmpty,
      '天翼未返回有效账号信息，请重新登录',
    );
    return info;
  }

  String _nickname(Json info) => info
      .obj('userExtResp')
      .str('nickName')
      .trim()
      .ifEmpty(info.str('nickName').trim())
      .ifEmpty(info.str('loginName').trim())
      .ifEmpty('天翼用户');

  Future<CloudAccount> _quota(String nickname) async {
    final data = (await _api(
      'portal/getUserSizeInfo',
      params: {'needClassification': true},
    )).obj('cloudCapacityInfo');
    final total = int.tryParse(data.str('totalSize'));
    final used = int.tryParse(data.str('usedSize'));
    require(
      total != null && total > 0 && used != null && used >= 0,
      '天翼未返回有效个人网盘容量，请重试',
    );
    return CloudAccount(nickname, total: total!, used: used!);
  }

  Future<LoginResult> authenticate(Credential credential) => _run(
    credential,
    () async {
      final identity = await _identity(), nickname = _nickname(identity);
      CloudAccount account;
      try {
        account = await _quota(nickname);
      } on AccountLoginRequired {
        rethrow;
      } on AppException {
        _checkpoint();
        // Identity must succeed; a separate quota outage does not block login.
        account = CloudAccount(nickname);
      }
      return LoginResult(
        credential.withFields({
          'primary': _session.cookie,
          'browserId': _session.browserId,
          'userId': identity.str('userId').trim(),
          'loginName': identity.str('loginName').trim(),
        }),
        account,
      );
    },
    candidate: true,
  );

  @override
  Future<CloudAccount> account(Credential credential) =>
      _run(credential, () async => _quota(_nickname(await _identity())));

  @override
  Future<BrowseSession> openPersonal(Credential credential) =>
      _run(credential, () async {
        return BrowseSession(
          platform: platform,
          mode: BrowseMode.personal,
          title: '我的天翼云盘',
          rootId: root,
        );
      });

  @override
  Future<List<CloudSpace>> familySpaces(Credential credential) =>
      _run(_required(credential), () async {
        final data = await _api('open/family/manage/getFamilyList');
        final raw = data['familyInfoResp'];
        require(
          raw is List && raw.every((item) => item is Map),
          '天翼未返回有效家庭云列表，请重试',
        );
        final spaces = <CloudSpace>[], seen = <String>{};
        for (final item in data.list('familyInfoResp')) {
          final id = item.str('familyId');
          require(RegExp(r'^[1-9]\d*$').hasMatch(id), '天翼家庭云编号无效');
          if (seen.add(id)) {
            spaces.add(CloudSpace(id, item.str('remarkName').ifEmpty('家庭云')));
          }
        }
        return spaces;
      });

  @override
  Future<BrowseSession> openFamily(CloudSpace space, Credential credential) =>
      _run(_required(credential), () async {
        require(RegExp(r'^[1-9]\d*$').hasMatch(space.id), '天翼家庭云编号无效');
        return BrowseSession(
          platform: platform,
          mode: BrowseMode.personal,
          title: '天翼家庭云',
          // The web API selects the family's root when folderId is empty.
          rootId: '',
          metadata: {'familyId': space.id, 'familyName': space.name},
        );
      });

  void _family(BrowseSession session) => require(
    session.platform == platform &&
        session.isFamily &&
        RegExp(r'^[1-9]\d*$').hasMatch(session.familyId),
    '天翼家庭云信息已缺失，请重新选择家庭',
  );

  static bool? _flag(Object? value) => switch (value) {
    true || 'true' || 1 || '1' => true,
    false || 'false' || 0 || '0' => false,
    _ => null,
  };

  Future<Json> _shareRead(
    String path,
    Credential? credential, {
    Map<String, Object?> params = const {},
    String shareCookie = '',
  }) async {
    try {
      return await _api(
        path,
        public: true,
        params: params,
        shareCookie: shareCookie,
      );
    } on _TianyiPublicLoginRequired {
      if (credential == null) rethrow;
      // Only an explicit login requirement uses the app account. A cancelled
      // share, incorrect access code or network failure never retries with it.
      return _run(
        credential,
        () => _api(path, params: params, shareCookie: shareCookie),
        fresh: true,
      );
    }
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) => _run(null, () async {
    final code = link.shareId ?? '', accessCode = link.passcode?.trim() ?? '';
    require(RegExp(r'^[A-Za-z0-9]+$').hasMatch(code), '天翼分享链接缺少分享编号');
    require(
      accessCode.isEmpty || RegExp(r'^[A-Za-z0-9]{1,12}$').hasMatch(accessCode),
      '天翼访问码格式无效',
    );
    final info = await _shareRead(
      'open/share/getShareInfoByCodeV2',
      credential,
      params: {'shareCode': code},
    );
    final folder = _flag(info['isFolder']);
    require(info.str('fileId').isNotEmpty && folder != null, '天翼未返回有效分享文件信息');
    final needsCode = tianyiNeedsAccessCode(info);
    require(!needsCode || accessCode.isNotEmpty, '该天翼分享需要访问码，请补充后重新解析');
    var shareId = info.str('shareId');
    if (accessCode.isNotEmpty || shareId.isEmpty) {
      shareId = (await _shareRead(
        'open/share/checkAccessCode',
        credential,
        params: {'shareCode': code, 'accessCode': accessCode},
      )).str('shareId');
    }
    require(RegExp(r'^\d+$').hasMatch(shareId), '天翼没有返回有效分享凭证，请确认访问码');
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: info.str('fileName').ifEmpty('天翼分享'),
      rootId: info.str('fileId'),
      sourceLink: link,
      metadata: {
        'shareCode': code,
        'shareId': shareId,
        'shareMode': info.str('shareMode', '1'),
        'accessCode': accessCode,
        'isFolder': '$folder',
      },
    );
  }, fresh: true);

  void _share(BrowseSession session) {
    require(
      session.platform == platform && session.mode == BrowseMode.share,
      '请打开天翼分享链接',
    );
    require(
      RegExp(r'^\d+$').hasMatch(session.meta('shareId')) &&
          RegExp(r'^[A-Za-z0-9]*$').hasMatch(session.meta('accessCode')),
      '天翼分享凭证已缺失，请重新解析',
    );
  }

  String _shareCookie(BrowseSession session) =>
      session.meta('accessCode').isEmpty
      ? ''
      : 'share_${session.meta('shareId')}=${session.meta('accessCode')}';

  CloudFile _file(Json data, String parent, bool folder) {
    final id = data.str('id').ifEmpty(data.str('fileId'));
    final name = data.str('name').ifEmpty(data.str('fileName'));
    final size = folder
        ? 0
        : int.tryParse(data.str('size', data.str('fileSize')));
    require(
      id.isNotEmpty && name.isNotEmpty && size != null && size >= 0,
      '天翼返回的文件信息不完整，请刷新列表',
    );
    final md5 = data.str('md5').toLowerCase();
    return CloudFile(
      id: id,
      name: name,
      size: size!,
      isDirectory: folder,
      parentId: parent,
      modifiedAt: data.str('lastOpTime').ifEmpty(data.str('createDate')),
      hashType: RegExp(r'^[0-9a-f]{32}$').hasMatch(md5) ? 'md5' : null,
      hashValue: RegExp(r'^[0-9a-f]{32}$').hasMatch(md5) ? md5 : null,
      thumbnailUrl: data
          .obj('icon')
          .str('largeUrl')
          .ifEmpty(data.obj('icon').str('smallUrl')),
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) => _run(
    session.mode == BrowseMode.personal ? _required(credential) : null,
    () async {
      require(session.platform == platform, '网盘来源不一致');
      final sharing = session.mode == BrowseMode.share;
      if (sharing) _share(session);
      if (session.isFamily) _family(session);
      final parent = parentId.ifEmpty(session.rootId);
      final single = sharing && session.meta('isFolder') == 'false';
      require(!single || parent == session.rootId, '单文件分享没有子目录');
      final files = <CloudFile>[], seen = <String>{};
      for (var page = 1; page <= 200; page++) {
        final params = <String, Object?>{
          'pageNum': page,
          'pageSize': _pageSize,
          'iconOption': 5,
          'orderBy': 'lastOpTime',
          'descending': true,
          if (session.isFamily) 'familyId': session.familyId,
          if (sharing) ...{
            'fileId': parent,
            if (!single) 'shareDirFileId': parent,
            'isFolder': !single,
            'shareId': session.meta('shareId'),
            'shareMode': session.meta('shareMode').ifEmpty('1'),
            'accessCode': session.meta('accessCode'),
          } else ...{
            'folderId': parent,
            'mediaType': 0,
          },
        };
        final result = sharing
            ? await _shareRead(
                'open/share/listShareDir',
                credential,
                params: params,
                shareCookie: _shareCookie(session),
              )
            : await _api(
                session.isFamily
                    ? 'open/family/file/listFiles'
                    : 'open/file/listFiles',
                params: params,
              );
        require(result['fileListAO'] is Map, '天翼未返回文件列表，请重试');
        final data = result.obj('fileListAO');
        final total = data.containsKey('count')
            ? int.tryParse(data.str('count'))
            : null;
        require(
          !data.containsKey('count') || total != null && total >= 0,
          '天翼文件数量无效',
        );
        final pageFiles = <CloudFile>[];
        for (final (key, folder) in [
          ('folderList', true),
          ('fileList', false),
        ]) {
          final items = data[key];
          require(items == null || items is List, '天翼文件列表格式错误');
          if (items is List) {
            for (final item in items) {
              require(item is Map, '天翼文件列表包含无效记录');
              pageFiles.add(_file(asJson(item), parent, folder));
            }
          }
        }
        require(
          pageFiles.isNotEmpty || total == 0 || total == files.length,
          '天翼文件列表不完整，请刷新后重试',
        );
        for (final file in pageFiles) {
          require(seen.add(file.id), '天翼返回重复分页，请刷新列表后重试');
          files.add(file);
        }
        require(files.length <= 10000, '天翼目录文件过多，请进入子目录后重试');
        if (single) {
          require(
            files.length == 1 &&
                !files.single.isDirectory &&
                files.single.id == session.rootId,
            '天翼单文件分享内容已变化，请重新解析',
          );
          return files;
        }
        if (total != null && files.length >= total ||
            total == null && pageFiles.length < _pageSize) {
          return files;
        }
      }
      throw const AppException('天翼目录分页过多，请进入子目录后重试');
    },
    fresh: session.mode == BrowseMode.share,
  );

  void _personal(BrowseSession session) => require(
    session.platform == platform && session.canManageFiles,
    '请在个人天翼网盘中执行此操作',
  );

  void _name(String value) => require(
    value.trim().isNotEmpty && !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(value),
    '文件名不能为空或包含路径分隔符',
  );

  bool _modifiable(CloudFile file) =>
      file.id.isNotEmpty &&
      file.id != root &&
      !(file.isDirectory &&
          {'0', '-10', '-12', '-13', '-14', '-15', '-16'}.contains(file.id));

  Future<CloudFile> _createFolder(String parent, String name) async {
    _name(name);
    require(parent.isNotEmpty, '天翼目标目录无效');
    CloudFile read(Json data) {
      final folder = _file(data, parent, true);
      require(
        folder.id != parent && folder.id != root && folder.name == name,
        '天翼未返回正确的新建目录',
      );
      return folder;
    }

    final result = await _api(
      'open/file/createFolder',
      method: 'POST',
      params: {'parentFolderId': parent, 'folderName': name},
    );
    return read(result);
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _run(c, () => _upload(s, parent, source, c, onProgress));

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) => _run(c, () async {
    _personal(s);
    return _createFolder(parent, name);
  });

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) => _run(c, () async {
    _personal(s);
    _name(name);
    require(_modifiable(f), '天翼文件无效或是不可修改的系统目录');
    final data = await _api(
      f.isDirectory ? 'open/file/renameFolder' : 'open/file/renameFile',
      method: 'POST',
      params: {
        if (f.isDirectory) ...{
          'folderId': f.id,
          'destFolderName': name,
        } else ...{
          'fileId': f.id,
          'destFileName': name,
        },
      },
    );
    require(
      data.str('res_code') == '0' ||
          data.str('id') == f.id && data.str('name') == name,
      '天翼未确认重命名结果，请刷新列表',
    );
  });

  Future<Json> _batch(
    String type,
    List<CloudFile> files, {
    String? target,
    BrowseSession? share,
  }) async {
    require(files.isNotEmpty && files.every(_modifiable), '请选择有效的天翼文件');
    require(files.map((f) => f.id).toSet().length == files.length, '所选文件重复');
    require(target == null || target.isNotEmpty, '天翼目标目录无效');
    if (share != null) _share(share);
    final created = await _api(
      'open/batch/createBatchTask',
      method: 'POST',
      shareCookie: share == null ? '' : _shareCookie(share),
      params: {
        'type': type,
        'taskInfos': encoded(
          files
              .map(
                (f) => {
                  'fileId': f.id,
                  'fileName': f.name,
                  'isFolder': f.isDirectory ? 1 : 0,
                },
              )
              .toList(),
        ),
        'targetFolderId': ?target,
        if (share != null) ...{'shareId': share.meta('shareId'), 'copyType': 1},
      },
    );
    final id = created.str('taskId');
    require(id.isNotEmpty, '天翼未返回操作任务编号，请刷新确认');
    for (var attempt = 0; attempt < maxTaskPolls; attempt++) {
      final result = await _api(
        'open/batch/checkBatchTask',
        method: 'POST',
        params: {'taskId': id, 'type': type},
      );
      final status = int.tryParse(result.str('taskStatus'));
      require(status != 2, '天翼目标目录有同名文件，请更换目录或重命名后重试');
      require(status != -1 && status != 5, '天翼文件操作失败或已取消，请刷新确认');
      require({1, 3, 4}.contains(status), '天翼返回未知任务状态，请刷新确认');
      final failed = result.containsKey('failedCount')
          ? int.tryParse(result.str('failedCount'))
          : null;
      require(
        !result.containsKey('failedCount') || failed != null && failed >= 0,
        '天翼任务结果格式无效',
      );
      require(failed == null || failed == 0, '天翼部分文件操作失败，请刷新确认');
      if (status == 4) {
        final succeeded = int.tryParse(result.str('successedCount'));
        final count = int.tryParse(result.str('subTaskCount'));
        require(
          failed == 0 &&
              succeeded != null &&
              succeeded >= files.length &&
              (count == null || count > 0 && succeeded >= count),
          '天翼未确认所有文件操作完成，请刷新确认',
        );
        return result;
      }
      if (attempt + 1 < maxTaskPolls) await Future<void>.delayed(taskDelay);
    }
    throw const AppException('天翼操作仍在处理中，请稍后刷新确认，避免重复提交');
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _run(c, () async {
    _personal(s);
    require(!files.any((f) => f.id == target), '不能将文件夹移动到自身');
    await _batch('MOVE', files, target: target);
  });

  @override
  Future<void> delete(BrowseSession s, List<CloudFile> files, Credential c) =>
      _run(c, () async {
        _personal(s);
        await _batch('DELETE', files);
      });

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _run(c, () async {
    _share(s);
    await _batch('SHARE_SAVE', files, target: target, share: s);
  });

  Future<DownloadSpec> _fileDownload(
    CloudFile file, {
    String familyId = '',
    BrowseSession? share,
  }) async {
    final params = <String, Object?>{
      'fileId': file.id,
      // Both official share clients download the original shared file ID.
      if (share != null) ...{'dt': 1, 'shareId': share.meta('shareId')},
      if (familyId.isNotEmpty) ...{'familyId': familyId, 'type': 1},
    };
    final Json result;
    try {
      result = await _api(
        familyId.isEmpty
            ? 'open/file/getFileDownloadUrl'
            : 'open/family/file/getFileDownloadUrl',
        shareCookie: share == null ? '' : _shareCookie(share),
        params: params,
      );
    } on _TianyiFileTooLarge {
      _checkpoint();
      if (familyId.isNotEmpty) rethrow;
      try {
        final mobile = await _tokenApi('open/file/getFileDownloadUrl', params);
        final spec = _downloadSpec(
          file,
          mobile.str('fileDownloadUrl'),
          mobile: true,
        );
        DiagnosticLog.event(
          'tianyi.download_route',
          fields: {
            'route': share == null
                ? 'personal-mobile-direct'
                : 'share-mobile-direct',
          },
        );
        return spec;
      } on _TianyiFileTooLarge {
        _checkpoint();
        if (fileKind(file.name) == FileKind.video) {
          final original = await ReadRetryScope.withoutRetries(
            () => _originalVideoDownload(file, share: share),
          );
          if (original != null) return original;
        }
        rethrow;
      }
    }
    return _downloadSpec(file, result.str('fileDownloadUrl'));
  }

  Future<DownloadSpec?> _originalVideoDownload(
    CloudFile file, {
    BrowseSession? share,
  }) async {
    try {
      final result = await _api(
        'portal/getNewVlcVideoPlayUrl',
        shareCookie: share == null ? '' : _shareCookie(share),
        params: {
          'fileId': file.id,
          'type': share == null ? 2 : 4,
          if (share != null) ...{
            'shareId': share.meta('shareId'),
            if (share.meta('isFolder') == 'true') 'dt': 1,
          },
        },
      );
      // An unsupported preview is optional. Authentication, share permissions
      // and other API errors are still checked before reaching this point.
      if (result.containsKey('success') && !result.boolean('success')) {
        return null;
      }
      final url = result.obj('normal').str('url');
      if (url.isEmpty) return null;
      // Only the original rendition can satisfy the selected file's length
      // and checksum. A transcode URL must never replace an original download.
      final DownloadSpec spec;
      try {
        spec = _downloadSpec(file, url);
      } on AppException {
        // An invalid optional address cannot replace the selected file.
        return null;
      }
      final probe = await http.peek(spec.url, spec.headers, maxBytes: 512);
      _checkpoint();
      if (!{200, 206}.contains(probe.status)) return null;
      final contentType = probe.header('content-type').toLowerCase();
      if (contentType.contains('mpegurl') ||
          contentType.contains('text/html') ||
          contentType.contains('application/json') ||
          probe.body.trimLeft().startsWith('#EXTM3U')) {
        return null;
      }
      final range = RegExp(
        r'^bytes\s+0-\d+/(\d+)$',
        caseSensitive: false,
      ).firstMatch(probe.header('content-range').trim());
      final length = probe.status == 206
          ? int.tryParse(range?.group(1) ?? '')
          : int.tryParse(probe.header('content-length'));
      if (file.size <= 0 || length != file.size) return null;
      DiagnosticLog.event(
        'tianyi.download_route',
        fields: {
          'route': share == null
              ? 'personal-original-video'
              : 'share-original-video',
        },
      );
      return spec;
    } on _TianyiFileTooLarge {
      _checkpoint();
      return null;
    } on HttpRequestFailure {
      _checkpoint();
      // This optional read has one attempt before reporting the size error.
      return null;
    }
  }

  DownloadSpec _downloadSpec(
    CloudFile file,
    String address, {
    bool mobile = false,
  }) {
    // Family responses HTML-escape query separators even inside JSON. Keep the
    // signed query bytes intact: decoding/rebuilding URI parameters changes it.
    var url = address.replaceAll('&amp;', '&');
    final uri = Uri.tryParse(url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '天翼未返回有效下载地址',
    );
    // Uri normalizes an explicit :80 away. Inspect the original authority so
    // upgrading the scheme cannot accidentally leave HTTPS using port 80.
    if (RegExp(
      r'^http://download\.cloud\.189\.cn(?=[/?#]|$)',
      caseSensitive: false,
    ).hasMatch(url)) {
      url = 'https${url.substring(4)}';
    }
    return DownloadSpec(
      url: url,
      fileName: file.name,
      expectedSize: file.size,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
      profile: 'tianyi',
      // A signed CDN URL does not need the user's web login cookies.
      headers: {
        'User-Agent': mobile ? _mobileUa : webUa,
        'Referer': mobile ? '$_h5Origin/' : '$origin/',
      },
    );
  }

  @override
  Future<DownloadSpec> download(BrowseSession s, CloudFile f, Credential? c) =>
      _run(_required(c), () async {
        require(
          s.platform == platform && !f.isDirectory && f.id.isNotEmpty,
          '请选择有效的天翼文件',
        );
        if (s.isFamily) {
          _family(s);
          return OperationProgress.step(
            OperationStage.downloadLink,
            () => _fileDownload(f, familyId: s.familyId),
          );
        }
        if (s.mode == BrowseMode.personal) {
          return OperationProgress.step(
            OperationStage.downloadLink,
            () => _fileDownload(f),
          );
        }
        _share(s);
        return OperationProgress.step(
          OperationStage.downloadLink,
          () => _fileDownload(f, share: s),
        );
      });

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) => _run(c, () async {
    _personal(s);
    require(files.isNotEmpty && files.every(_modifiable), '请选择有效的天翼文件');
    require({null, 1, 7}.contains(options.expiryDays), '天翼分享有效期支持 1 天、7 天或永久');
    require(options.passcode?.isNotEmpty != true, '天翼分享的访问码由服务器自动生成');
    final data = await _api(
      files.length == 1
          ? 'open/share/createShareLink'
          : 'open/share/createBatchShare',
      method: files.length == 1 ? 'GET' : 'POST',
      jsonBody: files.length != 1,
      params: {
        if (files.length == 1)
          'fileId': files.single.id
        else
          'fileIdList': files.map((f) => f.id).toList(),
        'shareType': 3,
        'expireTime': options.expiryDays ?? 2099,
      },
    );
    final result = files.length == 1
        ? data.list('shareLinkList').firstOrNull ?? <String, dynamic>{}
        : data.obj('data');
    final url = result.str('url'), passcode = result.str('accessCode');
    final uri = Uri.tryParse(url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          CloudPlatform.fromHost(uri.host) == platform &&
          uri.userInfo.isEmpty &&
          RegExp(r'^[A-Za-z0-9]{1,12}$').hasMatch(passcode),
      '天翼未返回完整分享链接与访问码',
    );
    return ShareCreation(url, passcode, options.title);
  });
}

class _TianyiSession {
  _TianyiSession(this.cookie, this.owner, this.browserId);
  String cookie, browserId;
  Credential? owner;
}

class _TianyiSessionExpired extends AccountLoginRequired {
  const _TianyiSessionExpired() : super('天翼登录已失效，请重新登录');
}

class _TianyiPublicLoginRequired extends AccountLoginRequired {
  const _TianyiPublicLoginRequired() : super('天翼要求登录后访问此分享，请先登录天翼云盘');
}

class _TianyiFileTooLarge extends AppException {
  const _TianyiFileTooLarge() : super('天翼未返回可用下载链接（文件大小限制），请稍后重试或在网页版确认');
}
