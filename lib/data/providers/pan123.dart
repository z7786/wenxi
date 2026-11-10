import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../../domain/rapid_transfer.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';
import '../state_store.dart';

class Pan123Connector extends CloudConnector {
  Pan123Connector(
    this.http,
    this.vault, {
    this.taskDelay = const Duration(seconds: 1),
    this.listDelay = const Duration(milliseconds: 600),
    this.listWait = RequestScope.wait,
    this.uploadWait = RequestScope.wait,
    this.stageCleanup,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final JsonHttp http;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  final CredentialStore vault;
  final Duration taskDelay;
  final Duration listDelay;
  final Future<void> Function(Duration) listWait;
  final Future<void> Function(Duration) uploadWait;
  final DateTime Function() now;
  final _uuids = <String, Future<String>>{};
  final _refreshing = <int, (Credential, Future<Credential>)>{};
  final _listingGate = AsyncGate();
  DateTime? _nextListingAt;
  late Duration _listingInterval = listDelay;
  static const _expired = AccountLoginRequired('123 登录已失效，请重新登录');
  // Personal file lists can return HTTP 200 with code 20101 for an expired login.
  static const _expiredCodes = {401, 20101};
  static const autoLoginFailureMessage = '123 自动登录失败，请重新登录或切换网页登录';
  static const _autoFailed = AccountLoginRequired(autoLoginFailureMessage);
  static const _accountChanged = AccountLoginRequired('123 账号已退出或发生变化，请重新登录');
  @override
  CloudPlatform get platform => CloudPlatform.pan123;
  static const webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36';
  static const dartUa = 'Dart/3.12 (dart:io)';
  Future<String> loginUuid() => _uuids.putIfAbsent(
    vault is Vault ? (vault as Vault).accountId(platform) ?? '' : '',
    () => (() async {
      final existing = vault.secret('pan123.login_uuid');
      if (existing?.isNotEmpty == true) return existing!;
      final uuid = newId().replaceAll('-', '');
      await vault.putSecret('pan123.login_uuid', uuid);
      return uuid;
    })(),
  );
  Json check(Json j) {
    if (_expiredCodes.contains(j.integer('code', -1))) throw _expired;
    if ({100011, 429}.contains(j.integer('code', -1))) {
      throw const HttpRequestFailure(
        '123 请求过于频繁，请稍后重试',
        kind: 'providerRateLimit',
        status: 429,
        retryable: true,
      );
    }
    require(
      j.integer('code', -1) == 0,
      j.str('message').ifEmpty('123 请求失败（code=${j.integer('code', -1)}）'),
    );
    return j;
  }

  Json response(HttpResult result) {
    RequestScope.checkpoint();
    if (result.status == 401) {
      throw const AccountLoginRequired('123 登录已失效，请重新登录');
    }
    if (result.status == 429) {
      throw HttpRequestFailure(
        '123 请求过于频繁，请稍后重试',
        kind: 'http',
        status: 429,
        retryAfter: result.header('retry-after'),
        retryable: true,
      );
    }
    if (result.status >= 500) {
      throw HttpRequestFailure(
        '123 服务暂时不可用（HTTP ${result.status}）',
        kind: 'http',
        status: result.status,
        retryable: true,
      );
    }
    final json = result.json;
    require(
      result.successful,
      json.str('message').ifEmpty('123 请求失败（HTTP ${result.status}）'),
    );
    return json;
  }

  static String crc32(String value) {
    var crc = 0xffffffff;
    for (final byte in utf8.encode(value)) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return ((crc ^ 0xffffffff) & 0xffffffff).toRadixString(16);
  }

  static (String, String) makeSign(
    String path, {
    int? epochSeconds,
    int? random,
  }) {
    final seconds =
        epochSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final stamp = DateTime.fromMillisecondsSinceEpoch(
      (seconds + 57600) * 1000,
      isUtc: true,
    );
    String two(int value) => '$value'.padLeft(2, '0');
    final minute =
        '${stamp.year.toString().padLeft(4, '0')}${two(stamp.month)}${two(stamp.day)}${two(stamp.hour)}${two(stamp.minute)}';
    const table = 'adefghlmyijnopkqrstubcvwsz';
    final authKey = crc32(
      minute.split('').map((d) => table[int.parse(d)]).join(),
    );
    final nonce = random ?? Random.secure().nextInt(10000000);
    return (
      authKey,
      '$seconds-$nonce-${crc32('$seconds|$nonce|$path|web|3|$authKey')}',
    );
  }

  Future<Map<String, String>> authHeaders(
    String token,
    String path, {
    String device = 'web',
    String version = '3',
  }) async {
    final sign = makeSign(path);
    return {
      'platform': device,
      'app-version': version,
      'authorization': 'Bearer $token',
      'loginuuid': await loginUuid(),
      'auth-key': sign.$1,
      'auth-value': sign.$2,
      'User-Agent': webUa,
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/json;charset=UTF-8',
    };
  }

  Future<Json> getAuth(String url, String path, Credential credential) =>
      _authorized(
        credential,
        (token) async => http.request(
          'GET',
          url,
          headers: await authHeaders(token, path),
          followRedirects: false,
        ),
      );
  Future<Json> postAuth(
    String url,
    String path,
    Json body,
    Credential credential, {
    String device = 'web',
    String version = '3',
    bool readOnly = false,
  }) => _authorized(
    credential,
    (token) async => (readOnly ? http.readRequest : http.request)(
      'POST',
      url,
      body: encoded(body),
      headers: await authHeaders(token, path, device: device, version: version),
      contentType: 'application/json; charset=utf-8',
      followRedirects: false,
    ),
  );

  bool _hasPassword(Credential c) =>
      !{'webToken', 'passwordToken'}.contains(c.field('authType')) &&
      c.primary.isNotEmpty &&
      c.field('secondary').isNotEmpty;

  String _tokenValue(Credential c) => c
      .field('accessToken')
      .ifEmpty(
        {'webToken', 'passwordToken'}.contains(c.field('authType'))
            ? c.primary
            : '',
      );

  String _storedToken(Credential c) => _tokenValue(c).ifEmpty(
    _hasPassword(c) &&
            LoginCredentials.samePan123Session(c, vault.credential(platform))
        ? vault.secret('pan123.access_token') ?? ''
        : '',
  );

  Credential _owner(Credential expected) {
    final current = vault.credential(platform);
    if (!LoginCredentials.samePan123Session(expected, current)) {
      throw _accountChanged;
    }
    return current!;
  }

  bool _expiresSoon(String token) {
    final parts = token.split('.');
    if (parts.length != 3 || token.length > 16384) return false;
    try {
      final payload = asJson(
        jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        ),
      );
      final expiry = int.tryParse(payload.str('exp'));
      // JWT metadata only schedules renewal; the server still validates tokens.
      return expiry != null &&
          expiry <=
              now().add(const Duration(seconds: 60)).millisecondsSinceEpoch ~/
                  1000;
    } on FormatException {
      return false;
    }
  }

  Future<Json> _authorized(
    Credential credential,
    Future<HttpResult> Function(String) send,
  ) async {
    RequestScope.checkpoint();
    final stored = LoginCredentials.samePan123Session(
      credential,
      vault.credential(platform),
    );
    // Candidate passwords are validated only by authenticate/password. In
    // particular, a request holding a logged-out account cannot log it back in.
    if (!stored && _hasPassword(credential)) throw _accountChanged;
    var owner = stored ? _owner(credential) : credential;
    if (owner.field('autoLoginBlocked') == '1') throw _autoFailed;
    var value = stored ? _storedToken(owner) : _tokenValue(owner);
    var renewed = false;
    if (_hasPassword(owner) && (value.isEmpty || _expiresSoon(value))) {
      owner = await _renew(owner, value);
      value = _tokenValue(owner);
      renewed = true;
    }
    if (value.isEmpty) throw _expired;

    void checkpoint() {
      RequestScope.checkpoint();
      if (stored && _owner(credential).field('autoLoginBlocked') == '1') {
        throw _autoFailed;
      }
    }

    Future<Json> attempt(String token) async {
      checkpoint();
      final result = await send(token);
      checkpoint();
      final json = response(result);
      if (_expiredCodes.contains(json.integer('code', -1))) throw _expired;
      return json;
    }

    try {
      return await attempt(value);
    } on AccountLoginRequired {
      checkpoint();
      if (!stored || !_hasPassword(owner)) rethrow;
      if (renewed) {
        await _blockAutoLogin(owner);
        checkpoint();
        throw _autoFailed;
      }
    }
    owner = await _renew(owner, value);
    checkpoint();
    try {
      // Only an explicit authentication rejection is retried. Network errors,
      // throttling and other failures must not replay file mutations.
      return await attempt(_tokenValue(owner));
    } on AccountLoginRequired {
      checkpoint();
      await _blockAutoLogin(owner);
      checkpoint();
      throw _autoFailed;
    }
  }

  Future<Credential> _renew(Credential expected, String rejectedToken) async {
    RequestScope.checkpoint();
    final current = _owner(expected);
    if (current.field('autoLoginBlocked') == '1') throw _autoFailed;
    if (!_hasPassword(current)) throw _expired;
    final value = _storedToken(current);
    if (value.isNotEmpty && value != rejectedToken) return current;
    final pending = _refreshing[current.updatedAt];
    final Future<Credential> shared;
    if (pending != null &&
        LoginCredentials.samePan123Session(pending.$1, current)) {
      shared = pending.$2;
    } else {
      late final Future<Credential> renewal;
      // A cancelled download stops waiting without cancelling the renewal that
      // other requests need. Logout/account changes are checked before commit.
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
    return _owner(expected);
  }

  Future<Credential> _performRenewal(Credential owner) async {
    DiagnosticLog.event('login.auto.start', fields: {'platform': platform.key});
    try {
      _owner(owner);
      // Preserve leading/trailing password characters, unlike secondary's
      // legacy convenience getter which trims them.
      final value = await _passwordToken(
        owner.primary,
        owner.field('secondary'),
      );
      _owner(owner);
      final data = await _userToken(value);
      _loginAccount(data);
      _owner(owner);
      final identity = _userId(data), previousId = owner.field('userId');
      require(previousId.isEmpty || identity == previousId, '123 登录账号校验不一致');
      final replacement = owner.withFields({
        'accessToken': value,
        if (identity.isNotEmpty) 'userId': identity,
      }, preserveRevision: true);
      if (!await vault.replaceCredential(platform, owner, replacement)) {
        final current = _owner(owner);
        if (current.field('autoLoginBlocked') == '1') throw _autoFailed;
        if (_tokenValue(current).isEmpty ||
            _tokenValue(current) == _tokenValue(owner)) {
          throw _accountChanged;
        }
        return current;
      }
      DiagnosticLog.event(
        'login.auto.success',
        fields: {'platform': platform.key},
      );
      return replacement;
    } catch (_) {
      _owner(owner);
      await _blockAutoLogin(owner);
      _owner(owner);
      throw _autoFailed;
    }
  }

  Future<void> _blockAutoLogin(Credential owner) async {
    await vault.replaceCredential(
      platform,
      owner,
      owner.withFields({'autoLoginBlocked': '1'}, preserveRevision: true),
    );
    DiagnosticLog.event(
      'login.auto.failed',
      fields: {'platform': platform.key},
    );
  }

  Future<String> _passwordToken(String username, String password) async {
    require(username.trim().isNotEmpty && password.isNotEmpty, '请输入 123 账号和密码');
    require(username.trim().length <= 254 && password.length <= 256, '账号或密码过长');
    RequestScope.checkpoint();
    final result = await http.request(
      'POST',
      'https://user.123pan.cn/api/user/sign_in',
      body: encoded({
        'passport': username.trim(),
        'password': password,
        'remember': false,
      }),
      headers: {
        'platform': 'web',
        'app-version': '132',
        'loginuuid': await loginUuid(),
        'Origin': 'https://user.123pan.cn',
        'Referer': 'https://user.123pan.cn/',
        'User-Agent': webUa,
      },
      contentType: 'application/json; charset=utf-8',
      followRedirects: false,
    );
    RequestScope.checkpoint();
    require(result.status < 300 || result.status >= 400, '123 登录接口发生变化，请稍后重试');
    require(result.status != 429, '123 登录请求过于频繁，请稍后重试');
    require(result.status < 500, '123 登录服务暂时不可用，请稍后重试');
    final j = result.json;
    if (!result.successful || j.integer('code', -1) != 200) {
      final code = j.integer('code', -1), msg = j.str('message');
      // Never surface a raw sign-in response: it can echo account/password data.
      throw AppException(
        code == 429 || RegExp('频繁|频率|次数|稍后').hasMatch(msg)
            ? '123 登录请求过于频繁，请稍后重试'
            : RegExp(
                '验证码|滑块|安全验证|验证失败|captcha|verify',
                caseSensitive: false,
              ).hasMatch(msg)
            ? '123 要求额外安全验证，请切换网页登录完成验证'
            : RegExp('冻结|封禁|封停|注销|禁用').hasMatch(msg)
            ? '123 账号暂时不可登录，请先在官方客户端检查账号状态'
            : '123 登录失败，请检查账号和密码后重试',
      );
    }
    final value = j.obj('data').str('token');
    require(
      value.isNotEmpty &&
          value.length <= 16384 &&
          !RegExp(r'[\x00-\x20\x7f]').hasMatch(value),
      '123 登录未返回有效令牌',
    );
    return value;
  }

  Future<LoginResult> password(String username, String password) async {
    final value = await _passwordToken(username, password);
    return authenticate(
      Credential(platform.label, {
        'primary': username.trim(),
        'secondary': password,
        'accessToken': value,
        'authType': 'password',
      }),
    );
  }

  @override
  Future<CloudAccount> account(Credential credential) async {
    final data = await _user(credential);
    return quota(data);
  }

  Future<Json> _user(Credential credential) async {
    final json = check(
      await getAuth(
        'https://yun.123pan.cn/b/api/user/info',
        '/b/api/user/info',
        credential,
      ),
    );
    return _userData(json);
  }

  Future<Json> _userToken(String value) async => _userData(
    check(
      response(
        await http.request(
          'GET',
          'https://yun.123pan.cn/b/api/user/info',
          headers: await authHeaders(value, '/b/api/user/info'),
          followRedirects: false,
        ),
      ),
    ),
  );

  Json _userData(Json json) {
    require(
      json['data'] is Map && json.obj('data').isNotEmpty,
      '123 用户信息响应不完整',
    );
    return json.obj('data');
  }

  String _userId(Json data) => data
      .str('UID')
      .ifEmpty(
        data
            .str('Uid')
            .ifEmpty(
              data
                  .str('uid')
                  .ifEmpty(data.str('UserId').ifEmpty(data.str('userId'))),
            ),
      );

  CloudAccount quota(Json data) {
    final used = int.tryParse(data.str('SpaceUsed')),
        permanent = int.tryParse(data.str('SpacePermanent')),
        temporary = int.tryParse(data.str('SpaceTemp', '0'));
    require(
      used != null &&
          used >= 0 &&
          permanent != null &&
          permanent >= 0 &&
          temporary != null &&
          temporary >= 0 &&
          permanent + temporary > 0,
      '123 未返回有效容量，请重试',
    );
    return CloudAccount(
      data.str('Nickname').ifEmpty('123 用户'),
      used: used!,
      total: permanent! + temporary!,
    );
  }

  Future<LoginResult> authenticate(Credential credential) async {
    // Explicit login candidates must never reuse a stored token or be repaired
    // with the previous account's password when their token is rejected.
    var value = _tokenValue(credential);
    if (value.isEmpty && _hasPassword(credential)) {
      value = await _passwordToken(
        credential.primary,
        credential.field('secondary'),
      );
      credential = credential.withFields({'accessToken': value});
    }
    if (value.isEmpty) throw _expired;
    final data = await _userToken(value);
    final account = _loginAccount(data), userId = _userId(data);
    return LoginResult(
      userId.isEmpty ? credential : credential.withFields({'userId': userId}),
      account,
    );
  }

  CloudAccount _loginAccount(Json data) {
    CloudAccount account;
    try {
      account = quota(data);
    } on AppException {
      require(data.str('Nickname').isNotEmpty, '123 未返回有效账号信息');
      account = CloudAccount(data.str('Nickname'));
    }
    return account;
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    require(LoginCredentials.stored(platform, credential), '请先登录 123 网盘');
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的123网盘',
      rootId: '0',
    );
  }

  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? c) async {
    require(link.shareId?.isNotEmpty == true, '123 分享链接缺少分享 Key');
    final data = await _shareFiles(link.shareId!, link.passcode ?? '', '0', 1);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: _files(data, '0').firstOrNull?.name ?? '123 分享',
      rootId: '0',
      metadata: {'shareKey': link.shareId!, 'passcode': link.passcode ?? ''},
      sourceLink: link,
    );
  }

  Future<Json> _shareFiles(
    String key,
    String password,
    String parent,
    int page,
  ) async {
    final data = (await _listPage(
      () async => response(
        await http.get(
          query('https://yun.123pan.cn/b/api/share/get', {
            'limit': 100,
            'next': 0,
            'orderBy': 'file_name',
            'orderDirection': 'asc',
            'shareKey': key,
            'ParentFileId': parent,
            'Page': page,
            if (password.isNotEmpty) 'SharePwd': password,
          }),
          {'User-Agent': dartUa},
        ),
      ),
    )).obj('data');
    require(!data.boolean('Expired'), '123 分享已失效');
    return data;
  }

  // Pace each listing page, including pages of the same folder. A shared gate
  // also prevents concurrent searches from amplifying an API cooldown.
  Future<Json> _listPage(Future<Json> Function() read) =>
      RequestScope.cancellable(
        _listingGate.run(() async {
          for (var attempt = 0; ; attempt++) {
            RequestScope.checkpoint();
            final remaining = _nextListingAt?.difference(now());
            if (remaining != null && remaining > Duration.zero) {
              await listWait(remaining);
            }
            RequestScope.checkpoint();
            _nextListingAt = now().add(_listingInterval);
            try {
              return check(await read());
            } on HttpRequestFailure catch (failure) {
              if (failure.status != 429) rethrow;
              if (_listingInterval < const Duration(seconds: 1)) {
                _listingInterval = const Duration(seconds: 1);
              }
              var delay = Duration(seconds: const [2, 5, 10][attempt]);
              final seconds = int.tryParse(failure.retryAfter.trim());
              Duration? serverDelay;
              if (seconds != null && seconds >= 0) {
                serverDelay = Duration(seconds: seconds);
              } else if (failure.retryAfter.isNotEmpty) {
                try {
                  serverDelay = HttpDate.parse(
                    failure.retryAfter,
                  ).difference(now().toUtc());
                } catch (_) {}
              }
              if (serverDelay != null && serverDelay > delay) {
                delay = serverDelay;
              }
              _nextListingAt = now().add(delay);
              // Only listing reads are replayed, at most twice. Mutations and
              // password login keep their existing retry rules.
              if (attempt >= 2) rethrow;
            }
          }
        }),
      );

  String _thumbnail(Json item) {
    final uri = Uri.tryParse(item.str('DownloadUrl'));
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return '';
    }
    // DownloadUrl can also be an original file URL. Only use an identified
    // thumbnail variant so browsing never downloads full-size media.
    if (uri.path.endsWith('_24_24')) {
      return uri
          .replace(
            path: uri.path.replaceFirst(RegExp(r'_24_24$'), '_70_70'),
            queryParameters: {
              ...uri.queryParameters,
              'w': '70',
              'h': '70',
              if (!uri.queryParameters.containsKey('trade_key'))
                'trade_key': '123pan-thumbnail',
            },
          )
          .toString();
    }
    return uri.queryParameters['trade_key'] == '123pan-thumbnail'
        ? uri.toString()
        : '';
  }

  List<CloudFile> _files(Json data, String parent) {
    final raw = data['InfoList'] is Map
        ? data.obj('InfoList')['list']
        : data['InfoList'] ?? data['infoList'];
    require(raw is List, '123 文件列表响应不完整，请刷新重试');
    return objects(raw).map((j) {
      require(j.str('FileId').isNotEmpty, '123 文件标识缺失，请刷新列表');
      final etag = j.str('Etag'),
          isMd5 = RegExp(r'^[A-Fa-f0-9]{32}$').hasMatch(j.str('Etag'));
      return CloudFile(
        id: j.str('FileId'),
        name: j.str('FileName'),
        size: j.integer('Size'),
        isDirectory: j.integer('Type') == 1,
        parentId: j.str('ParentFileId').ifEmpty(parent),
        token: encoded({
          's3': j.str('S3KeyFlag'),
          'etag': etag,
          'storage': j.str('StorageNode'),
        }),
        modifiedAt: j.str('UpdateAt'),
        thumbnailUrl: _thumbnail(j),
        hashType: isMd5 ? 'md5' : null,
        hashValue: isMd5 ? etag : null,
      );
    }).toList();
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    final share = s.mode == BrowseMode.share;
    require(share || c != null, '请先登录 123 网盘');
    final all = <CloudFile>[], seen = <String>{};
    var cursor = '0';
    for (var page = 1; page <= 100; page++) {
      final data = share
          ? await _shareFiles(
              s.meta('shareKey'),
              s.meta('passcode'),
              parent,
              page,
            )
          : (await _listPage(
              () => getAuth(
                query('https://yun.123pan.cn/b/api/file/list/new', {
                  'driveId': 0,
                  'limit': 100,
                  'next': cursor,
                  'orderBy': 'update_time',
                  'orderDirection': 'desc',
                  'parentFileId': parent,
                  'trashed': false,
                  'SearchData': '',
                  'Page': 1,
                  'OnlyLookAbnormalFile': 0,
                  'event': 'homeListFile',
                  'operateType': 1,
                  'inDirectSpace': false,
                }),
                '/b/api/file/list/new',
                c!,
              ),
            )).obj('data');
      final batch = _files(data, parent);
      final fresh = batch.where((f) => seen.add(f.id)).toList();
      all.addAll(fresh);
      if (batch.isEmpty || fresh.isEmpty || data.str('Next') == '-1') break;
      // Personal pages use the server cursor, including an explicit empty one.
      // Shared pages intentionally keep next=0 and increment Page (YunX).
      cursor = data.str('Next');
      require(page < 100, '目录文件过多，请缩小范围后重试');
    }
    return all;
  }

  Json parts(String value) {
    try {
      return asJson(jsonDecode(value));
    } catch (_) {
      return {};
    }
  }

  static String? decodeDownloadUrl(String value) {
    try {
      final input = value.trim();
      if (input.isEmpty) return null;
      final raw = input.contains('://')
          ? Uri.parse(input).queryParameters['params']
          : input;
      if (raw == null || raw.isEmpty) return null;
      final decoded = utf8.decode(base64.decode(base64.normalize(raw)));
      final uri = Uri.tryParse(decoded);
      return uri != null &&
              {'http', 'https'}.contains(uri.scheme) &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty
          ? decoded
          : null;
    } on FormatException {
      return null;
    }
  }

  Future<String> _follow(String initial) async {
    var current = initial;
    for (var i = 0; i < 5; i++) {
      final uri = Uri.tryParse(current);
      require(
        uri != null &&
            ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty,
        '123 返回的下载地址无效',
      );
      try {
        final r = await http.peek(current, {
          'Referer': 'https://yun.123pan.cn/',
          'User-Agent': dartUa,
        });
        if (!r.body.trimLeft().startsWith('{')) return current;
        final next = r.json.obj('data').str('redirect_url');
        if (next.isEmpty || next == current) return current;
        current = next;
      } on AppException {
        RequestScope.checkpoint();
        return current;
      }
    }
    throw const AppException('123 下载地址跳转过多，请重新获取');
  }

  Future<DownloadSpec> _transferDownload(
    BrowseSession share,
    CloudFile file,
    Credential account,
  ) async {
    final personal = await openPersonal(account);
    final name = 'AsterLink临时转存_${newId()}';
    final directory = await OperationProgress.step(
      OperationStage.createTemporary,
      () => _temporaryFolder(personal.rootId, name, account),
    );
    final cleanup = DownloadCleanup(
      url: '',
      action: {
        'kind': 'temporary-folder',
        'platform': platform.key,
        'folderId': directory,
        'name': name,
        'accountRevision': account.updatedAt,
      },
    );
    await stageCleanup?.call(cleanup);
    await OperationProgress.step(
      OperationStage.transfer,
      () => saveShare(share, [file], directory, account),
    );
    final transferred = await OperationProgress.step(
      OperationStage.waitTransfer,
      () async {
        for (var attempt = 0; attempt < 8; attempt++) {
          RequestScope.checkpoint();
          final matches = (await list(personal, directory, account))
              .where(
                (item) =>
                    !item.isDirectory &&
                    item.name == file.name &&
                    (file.size <= 0 || item.size == file.size),
              )
              .toList();
          if (matches.length == 1) {
            final transferred = matches.single;
            require(
              file.hashValue == null ||
                  transferred.hashValue == null ||
                  file.hashType != transferred.hashType ||
                  file.hashValue!.toLowerCase() ==
                      transferred.hashValue!.toLowerCase(),
              '转存后的文件校验标识不一致',
            );
            return transferred;
          }
          require(matches.length <= 1, '转存目录存在多个同名文件，无法确定下载目标');
          await Future<void>.delayed(taskDelay);
        }
        throw const AppException('转存已提交，但目标文件暂不可见，请稍后重试');
      },
    );
    return (await download(
      personal,
      transferred,
      account,
    )).copyWith(fileName: file.name, cleanup: cleanup);
  }

  Future<String> _temporaryFolder(
    String parent,
    String name,
    Credential account,
  ) async {
    const endpoint = 'https://yun.123pan.cn/b/api/file/upload_request';
    final data = check(
      await postAuth(endpoint, '/b/api/file/upload_request', {
        'driveId': 0,
        'parentFileId': int.tryParse(parent) ?? 0,
        'fileName': name,
        'size': 0,
        'type': 1,
        'etag': '',
        'duplicate': 1,
        'NotReuse': true,
        'RequestSource': null,
      }, account),
    ).obj('data');
    final id = data
        .obj('Info')
        .str('FileId')
        .ifEmpty(data.str('FileId'))
        .ifEmpty(data.str('fileId'));
    require(int.tryParse(id) != null && int.parse(id) > 0, '123 未返回临时目录 ID');
    return id;
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    require(s.canManageFiles, '请在个人网盘中新建文件夹');
    require(
      name.trim().isNotEmpty && !RegExp(r'[/\\\x00-\x1f]').hasMatch(name),
      '文件夹名称无效',
    );
    final id = await _temporaryFolder(parent, name, c);
    return CloudFile(id: id, name: name, isDirectory: true, parentId: parent);
  }

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
  ) async {
    final s = session, c = credential;
    require(canRapidTransferTo(s), '请在个人网盘中执行秒传');
    require(int.tryParse(parent) != null, '123 目标目录无效');
    const path = '/b/api/file/upload_request';
    final pre = check(
      await postAuth('https://yun.123pan.cn$path', path, {
        'driveId': 0,
        'duplicate': 1,
        'etag': file.md5,
        'fileName': file.name,
        'parentFileId': int.parse(parent),
        'size': file.size,
        'type': 0,
      }, c),
    ).obj('data');
    RequestScope.checkpoint();
    // A miss only initializes an upload; never request object URLs or send data.
    if (!pre.boolean('Reuse')) return const RapidTransferResult.missed();
    final info = pre.obj('Info');
    final id = info.str('FileId').ifEmpty(pre.str('FileId'));
    require((int.tryParse(id) ?? 0) > 0, '123 秒传回执无效，请刷新目标目录确认');
    require(
      !info.containsKey('Size') || info.integer('Size', -1) == file.size,
      '123 秒传文件大小不一致',
    );
    require(
      info.str('Etag').isEmpty || contentMd5(info.str('Etag')) == file.md5,
      '123 秒传文件校验值不一致',
    );
    require(
      info.str('ParentFileId').isEmpty || info.str('ParentFileId') == parent,
      '123 秒传目标目录不一致',
    );
    return RapidTransferResult.reused(id);
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    require(s.canManageFiles, '请在个人网盘中上传文件');
    final io = UploadIO(http, source, onProgress);
    Future<Json> post(String path, Json body) async => check(
      await postAuth(
        'https://yun.123pan.cn/b/api/file/$path',
        '/b/api/file/$path',
        body,
        c,
      ),
    ).obj('data');
    final etag = await io.digest(md5);
    final pre = await post('upload_request', {
      'driveId': 0,
      'duplicate': 1,
      'etag': etag,
      'fileName': source.name,
      'parentFileId': int.tryParse(parent) ?? 0,
      'size': source.size,
      'type': 0,
    });
    final reuse = pre.boolean('Reuse');
    final id = reuse
        ? pre.obj('Info').str('FileId').ifEmpty(pre.str('FileId'))
        : pre.str('FileId').ifEmpty(pre.obj('Info').str('FileId'));
    require((int.tryParse(id) ?? 0) > 0, '123 未返回上传文件标识');
    CloudFile completedFile(Json info) => _uploadedFile(
      info,
      pre: pre,
      id: id,
      parent: parent,
      source: source,
      etag: etag,
    );
    if (reuse) {
      io.progress(UploadPhase.finishing, source.size);
      return completedFile(pre.obj('Info'));
    }
    require(pre.str('Key').isNotEmpty, '123 未创建上传任务');
    final body = <String, dynamic>{
      'StorageNode': pre['StorageNode'],
      'bucket': pre['Bucket'],
      'key': pre['Key'],
      'uploadId': pre['UploadId'],
    };
    late final String completePath;
    late final Json completeBody;
    if (pre.str('AccessKeyId').isNotEmpty &&
        pre.str('SecretAccessKey').isNotEmpty) {
      await io.s3(
        endpoint: pre.str('EndPoint'),
        bucket: pre.str('Bucket'),
        object: pre.str('Key'),
        access: pre.str('AccessKeyId'),
        secret: pre.str('SecretAccessKey'),
        token: pre.str('SessionToken'),
        region: '123pan',
        pathStyle: true,
      );
      completePath = 'upload_complete';
      completeBody = {'fileId': id};
    } else {
      const chunkSize = 16 * 1024 * 1024;
      final count = max(1, (source.size / chunkSize).ceil());
      for (var i = 0; i < count; i++) {
        final urls = await post(
          count == 1 ? 's3_upload_object/auth' : 's3_repare_upload_parts_batch',
          {...body, 'partNumberStart': i + 1, 'partNumberEnd': i + 2},
        );
        await io.send(
          urls.obj('presignedUrls').str('${i + 1}'),
          start: i * chunkSize,
          end: min(source.size, (i + 1) * chunkSize),
        );
      }
      completePath = 'upload_complete/v2';
      completeBody = {
        ...body,
        'fileId': id,
        'fileSize': source.size,
        'isMultipart': count > 1,
      };
    }
    io.progress(UploadPhase.finishing, source.size);
    Json completed = {};
    try {
      completed = await post(completePath, completeBody);
    } on HttpRequestFailure catch (error) {
      RequestScope.checkpoint();
      if (!error.retryable) rethrow;
      // The server may have committed before the response was lost. Query
      // the same upload; never submit another upload or repeat the merge.
      DiagnosticLog.event(
        'upload.confirm.recover',
        fields: {'platform': platform.key, 'kind': error.kind},
      );
    }
    if (completed.obj('file_info').integer('FileId') > 0) {
      return completedFile(completed.obj('file_info'));
    }
    return _waitUploadedFile(s, parent, c, {
      ...body,
      'fileId': id,
      'fileSize': source.size,
      'isMultipart': completeBody['isMultipart'] ?? false,
    }, completedFile);
  }

  CloudFile _uploadedFile(
    Json info, {
    required Json pre,
    required String id,
    required String parent,
    required UploadFile source,
    required String etag,
  }) {
    RequestScope.checkpoint();
    final resultId = info.str('FileId').ifEmpty(id);
    require((int.tryParse(resultId) ?? 0) > 0, '123 上传回执的文件标识无效，请刷新目录确认');
    require(
      !info.containsKey('Size') || info.integer('Size', -1) == source.size,
      '上传后的文件大小不一致，请重新检查',
    );
    require(
      !info.containsKey('Type') || info.integer('Type', -1) == 0,
      '123 上传回执不是文件，请刷新目录确认',
    );
    require(
      info.str('ParentFileId').isEmpty || info.str('ParentFileId') == parent,
      '123 上传回执的目录不一致，请刷新目录确认',
    );
    final remoteHash = info.str('Etag');
    require(
      remoteHash.isEmpty || remoteHash.toLowerCase() == etag.toLowerCase(),
      '上传后的文件校验标识不一致，请重新检查',
    );
    return _files({
      'InfoList': [
        {
          'FileId': resultId,
          'FileName': source.name,
          'ParentFileId': parent,
          'Size': source.size,
          'Type': 0,
          'Etag': etag,
          'S3KeyFlag': pre.str('S3KeyFlag'),
          'StorageNode': pre.str('StorageNode'),
          ...info,
        },
      ],
    }, parent).single;
  }

  Future<CloudFile> _waitUploadedFile(
    BrowseSession s,
    String parent,
    Credential c,
    Json body,
    CloudFile Function(Json) completedFile,
  ) async {
    // Match the official web client's asynchronous merge protocol. A normal
    // directory refresh is not an upload acknowledgement and can lag behind.
    const path = '/b/api/file/upload_complete/result';
    final deadline = now().add(const Duration(minutes: 15));
    var failures = 0;
    for (
      var attempt = 0;
      attempt < 450 && now().isBefore(deadline);
      attempt++
    ) {
      RequestScope.checkpoint();
      var delay = const Duration(seconds: 2);
      try {
        final data = check(
          await getAuth(query('https://yun.123pan.cn$path', body), path, c),
        ).obj('data');
        failures = 0;
        final info = data.obj('file_info');
        if (info.integer('FileId') > 0) return completedFile(info);
        delay = Duration(seconds: data.integer('duration', 2).clamp(1, 10));
      } on HttpRequestFailure catch (error) {
        RequestScope.checkpoint();
        if (!error.retryable) rethrow;
        failures++;
        // A transient failure in the confirmation request must not trigger a
        // fresh upload. Back off, then verify the file once if it persists.
        if (failures >= 4) break;
        delay = Duration(seconds: min(10, failures * 2));
      }
      await uploadWait(delay);
    }
    // An ID lookup in the destination is the last recovery path if the merge
    // result stays unavailable. Only a matching ID, size and hash can succeed.
    try {
      final matches = (await list(
        s,
        parent,
        c,
      )).where((f) => f.id == body.str('fileId') && !f.isDirectory).toList();
      if (matches.length == 1) {
        final file = matches.single;
        completedFile({
          'FileId': file.id,
          'Size': file.size,
          'ParentFileId': file.parentId,
          'Etag': file.hashValue ?? '',
        });
        return file;
      }
    } on HttpRequestFailure catch (error) {
      RequestScope.checkpoint();
      if (!error.retryable) rethrow;
    }
    throw const AppException('123 上传已提交，但暂未确认完成，请先刷新目标目录，避免重复上传');
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory, '文件夹不能直接下载');
    if (s.mode == BrowseMode.share) {
      require(c != null, '分享下载需要先登录网盘账号');
      return _transferDownload(s, f, c!);
    }
    require(c != null, '123 下载需要登录账号');
    return OperationProgress.step(OperationStage.downloadLink, () async {
      final p = parts(f.token);
      const endpoint = 'https://yun.123pan.cn/api/file/download_info';
      final data = check(
        await postAuth(
          endpoint,
          Uri.parse(endpoint).path,
          {
            'driveId': 0,
            'type': 0,
            'etag': p.str('etag'),
            'fileId': int.tryParse(f.id) ?? 0,
            's3keyFlag': p.str('s3'),
            'fileName': f.name,
            'size': f.size,
          },
          c!,
          readOnly: true,
        ),
      ).obj('data');
      final wrapped = data.str('DownloadUrl');
      require(wrapped.isNotEmpty, '123 没有返回下载信息');
      final decoded = decodeDownloadUrl(wrapped);
      if (decoded == null) {
        final wrappedUri = Uri.tryParse(wrapped);
        require(wrappedUri != null, '123 返回的下载地址无效');
        require(
          !wrappedUri!.path.contains('download-v2'),
          '123 下载包装地址无法解码，请重新获取',
        );
      }
      final direct = await _follow(decoded ?? wrapped);
      final md5 = RegExp(r'^[A-Fa-f0-9]{32}$').hasMatch(p.str('etag'))
          ? p.str('etag')
          : null;
      return DownloadSpec(
        url: direct,
        fileName: f.name,
        expectedSize: f.size,
        headers: {'Referer': 'https://yun.123pan.cn/', 'User-Agent': webUa},
        checksumType: md5 == null ? null : 'md5',
        checksumValue: md5,
      );
    });
  }

  Future<void> _operation(String path, Json body, Credential c) async {
    check(await postAuth('https://yun.123pan.cn$path', path, body, c));
  }

  void personal(BrowseSession s) =>
      require(s.mode == BrowseMode.personal, '请在个人网盘中执行此操作');
  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    personal(s);
    await _operation('/b/api/file/rename', {
      'driveId': 0,
      'fileId': int.tryParse(f.id) ?? 0,
      'fileName': name,
      'duplicate': 1,
      'event': 'fileRename',
      'operatePlace': 'right',
      'RequestSource': null,
    }, c);
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    await _operation('/b/api/file/mod_pid', {
      'fileIdList': files
          .map((f) => {'FileId': int.tryParse(f.id) ?? 0})
          .toList(),
      'parentFileId': int.tryParse(target) ?? 0,
      'event': 'fileMove',
      'operatePlace': 1,
      'RequestSource': null,
    }, c);
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    await _operation('/b/api/file/trash', {
      'driveId': 0,
      'fileTrashInfoList': files
          .map(
            (f) => {
              'FileId': int.tryParse(f.id) ?? 0,
              'FileName': f.name,
              'Type': f.isDirectory ? 1 : 0,
              'Size': f.size,
              'S3KeyFlag': parts(f.token).str('s3'),
              'Etag': parts(f.token).str('etag'),
            },
          )
          .toList(),
      'operation': true,
      'event': 'intoRecycle',
      'operatePlace': 1,
      'safeBox': false,
    }, c);
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请打开分享链接');
    require(files.isNotEmpty, '请选择要转存的文件');
    for (final f in files) {
      final p = parts(f.token),
          node = parts(f.token).str('s3').split('-').first;
      require(RegExp(r'^[A-Za-z0-9]+$').hasMatch(node), '无法识别 123 分享节点');
      final j = await _authorized(
        c,
        (auth) async => http.request(
          'POST',
          'https://$node.mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save',
          body: encoded({
            'fileList': [
              {
                'fileID': int.tryParse(f.id) ?? 0,
                'fileId': int.tryParse(f.id) ?? 0,
                'size': f.size,
                'etag': p.str('etag'),
                'type': f.isDirectory ? 1 : 0,
                'parentFileID': int.tryParse(target) ?? 0,
                'parentFileId': int.tryParse(target) ?? 0,
                'fileName': f.name,
                'driveID': 0,
                'driveId': 0,
                's3keyFlag': p.str('s3'),
                'S3KeyFlag': p.str('s3'),
                'StorageNode': p.str('storage'),
              },
            ],
            'shareKey': s.meta('shareKey'),
            'sharePwd': s.meta('passcode'),
            'currentLevel': 1,
            'superAdmin': null,
          }),
          headers: {
            'Authorization': 'Bearer $auth',
            'LoginUuid': await loginUuid(),
            'platform': 'web',
            'Content-Type': 'application/json;charset=UTF-8',
            'User-Agent': dartUa,
          },
          contentType: 'application/json; charset=utf-8',
          followRedirects: false,
        ),
      );
      check(j);
      final taskId = j.obj('data').str('taskID');
      require(taskId.isNotEmpty && taskId != '0', '123 转存未返回任务 ID');
      await pollCopySave(node, taskId, c);
    }
  }

  Future<void> pollCopySave(
    String node,
    String taskId,
    Credential credential,
  ) async {
    for (var attempt = 0; attempt < 15; attempt++) {
      RequestScope.checkpoint();
      await Future<void>.delayed(taskDelay);
      RequestScope.checkpoint();
      final data = check(
        await _authorized(
          credential,
          (auth) async => http.request(
            'GET',
            query(
              'https://$node.mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save/get',
              {'taskID': taskId},
            ),
            headers: {
              'Authorization': 'Bearer $auth',
              'LoginUuid': await loginUuid(),
              'platform': 'web',
              'User-Agent': dartUa,
            },
            followRedirects: false,
          ),
        ),
      ).obj('data');
      final state = data.str('state').toLowerCase();
      require(
        !{'failed', 'error', 'cancelled'}.contains(state) &&
            !{4, 5, -1}.contains(data.integer('status')) &&
            data.integer('error_code') == 0,
        data.str('message').ifEmpty('123 转存任务失败'),
      );
      if (data.boolean('finished') ||
          {2, 3}.contains(data.integer('status')) ||
          {'success', 'done', '2'}.contains(state) ||
          [
            'newFileId',
            'FileId',
            'fileId',
          ].any((key) => data.str(key).isNotEmpty)) {
        return;
      }
    }
    throw const AppException('123 转存任务超时，请稍后刷新网盘确认');
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
    var expiration = '2099-12-12T08:00:00+08:00';
    if (options.expiryDays != null) {
      final date = DateTime.now().toUtc().add(
        Duration(days: options.expiryDays!, hours: 8),
      );
      expiration = '${date.toIso8601String().substring(0, 19)}+08:00';
    }
    final data = check(
      await postAuth(
        'https://yun.123pan.cn/b/api/share/create',
        '/b/api/share/create',
        {
          'driveId': 0,
          'fileIdList': files.length == 1
              ? int.tryParse(files.first.id) ?? 0
              : files.map((f) => int.tryParse(f.id) ?? 0).toList(),
          'expiration': expiration,
          'shareName': options.title,
          'event': 'shareCreate',
          'fileNum': files.length,
          'shareModality': 4,
          'trafficLimitSwitch': 1,
          'trafficLimit': 0,
          'trafficSwitch': 1,
          'fillPwdSwitch': 0,
          if (options.passcode?.isNotEmpty == true)
            'sharePwd': options.passcode,
        },
        c,
      ),
    ).obj('data');
    final linkList = data.obj('shareLinkList');
    final first =
        (linkList['list'] as List? ?? []).firstOrNull?.toString() ?? '';
    final url = first
        .ifEmpty(linkList.str('standBy'))
        .ifEmpty(
          data.str('ShareKey').isEmpty
              ? ''
              : 'https://www.123pan.com/s/${data.str('ShareKey')}',
        );
    require(url.isNotEmpty, '123 没有返回分享链接');
    return ShareCreation(url, options.passcode ?? '', options.title);
  }
}
