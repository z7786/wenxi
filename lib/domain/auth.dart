import 'dart:convert';
import '../core/json.dart';
import '../data/state_store.dart';
import '../data/http.dart';
import 'models.dart';
import 'pikpak_web_login.dart';
import 'tianyi_web_login.dart';
import 'web_tokens.dart';
import 'weiyun_web_login.dart';
import 'xunlei_web_login.dart';

class AccountLoginRequired extends AppException {
  const AccountLoginRequired(super.message);
}

class UcTvAuthorizationRequired extends AppException {
  const UcTvAuthorizationRequired([
    super.message = '请先扫码授权 UC TV 播放，并使用与网页登录相同的 UC 账号',
  ]);
}

class LoginCredentials {
  static bool sameCookieSession(Credential? expected, Credential? current) {
    if (expected == null || current == null) return expected == current;
    final before = {...expected.fields}..remove('nickname');
    final after = {...current.fields}..remove('nickname');
    return expected.updatedAt == current.updatedAt &&
        expected.label == current.label &&
        before.length == after.length &&
        before.entries.every((e) => after[e.key] == e.value);
  }

  static bool sameWebTokenSession(Credential? expected, Credential? current) =>
      expected == null || current == null
      ? expected == current
      : expected.updatedAt == current.updatedAt &&
            expected.label == current.label &&
            (expected.field('userId').isEmpty ||
                current.field('userId').isEmpty ||
                expected.field('userId') == current.field('userId'));
  static bool sameUcSession(Credential? expected, Credential? current) {
    if (expected == null || current == null) return expected == current;
    return expected.updatedAt == current.updatedAt &&
        expected.label == current.label;
  }

  // Renewing a 123 token must not change the owner of queued downloads or
  // invalidate an explicit login that is currently replacing this session.
  static bool samePan123Session(Credential? expected, Credential? current) {
    if (expected == null || current == null) return expected == current;
    return expected.updatedAt == current.updatedAt &&
        expected.label == current.label &&
        expected.primary == current.primary &&
        expected.field('secondary') == current.field('secondary') &&
        expected.field('authType') == current.field('authType');
  }

  // Tianyi rotates its primary Cookie during normal requests and password
  // renewal. The explicit login revision and saved account remain the owner.
  static bool sameTianyiSession(Credential? expected, Credential? current) {
    if (expected == null || current == null) return expected == current;
    return expected.updatedAt == current.updatedAt &&
        expected.label == current.label &&
        expected.field('username') == current.field('username') &&
        expected.field('password') == current.field('password') &&
        expected.field('authType') == current.field('authType');
  }

  static bool hasXunleiPassword(Credential? credential) =>
      credential?.field('authType') == 'passwordToken' &&
      credential!.field('username').trim().isNotEmpty &&
      credential.field('password').isNotEmpty;

  static bool sameXunleiSession(Credential? expected, Credential? current) {
    if (expected == null || current == null) return expected == current;
    return expected.updatedAt == current.updatedAt &&
        expected.label == current.label &&
        expected.field('username') == current.field('username') &&
        expected.field('password') == current.field('password') &&
        expected.field('authType') == current.field('authType') &&
        (expected.field('userId').isEmpty ||
            current.field('userId').isEmpty ||
            expected.field('userId') == current.field('userId'));
  }

  static String c139Cookie(String raw, String key) {
    var value =
        cookiePairs(raw).entries
            .where((entry) => entry.key.toLowerCase() == key.toLowerCase())
            .firstOrNull
            ?.value ??
        '';
    try {
      value = Uri.decodeComponent(value);
    } on FormatException {
      return '';
    } on ArgumentError {
      return '';
    }
    return RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value) ? '' : value.trim();
  }

  static String c139Authorization(String cookie) {
    final explicit = c139Cookie(cookie, 'authorization');
    if (explicit.isNotEmpty) return explicit;
    final token = c139Cookie(cookie, 'auth_token');
    var account = '';
    try {
      account = utf8.decode(
        base64.decode(
          base64.normalize(c139Cookie(cookie, 'ORCHES-I-ACCOUNT-ENCRYPT')),
        ),
      );
    } catch (_) {
      /* an incomplete login must keep waiting */
    }
    if (token.isEmpty || !RegExp(r'^\+?\d{6,20}$').hasMatch(account)) return '';
    return 'Basic ${base64Encode(utf8.encode('pc:$account:$token'))}';
  }

  static bool c139CloudReady(String cookie) =>
      c139Authorization(cookie).isNotEmpty &&
      c139Cookie(cookie, 'skey').isNotEmpty &&
      c139Cookie(cookie, 'ud_id').isNotEmpty;

  /// `skey` is optional for current cloud API requests.  The web client may
  /// finish login with only the authorization token and user-domain cookie.
  /// Keep the strict legacy predicate above for callers that explicitly need
  /// a complete cookie, but use this predicate while polling web login.
  static bool c139WebReady(String cookie) =>
      c139Authorization(cookie).isNotEmpty &&
      c139Cookie(cookie, 'ud_id').isNotEmpty;

  static bool stored(CloudPlatform p, Credential? c) {
    if (c == null || !p.requiresAccount) return false;
    return switch (p) {
      CloudPlatform.lanzou => plausible(p, c.primary),
      CloudPlatform.aliyun ||
      CloudPlatform.pikpak ||
      CloudPlatform.feijipan ||
      CloudPlatform.guangya ||
      CloudPlatform.ilanzou ||
      CloudPlatform.wopan =>
        c.field('accessToken').isNotEmpty ||
            c.field('refreshToken').isNotEmpty ||
            c.primary.isNotEmpty,
      CloudPlatform.pan123 =>
        c.field('accessToken').isNotEmpty ||
            c.primary.isNotEmpty &&
                (c.field('authType') == 'webToken' || c.secondary.isNotEmpty),
      CloudPlatform.xunlei =>
        c.field('accessToken').isNotEmpty ||
            c.primary.isNotEmpty ||
            c.field('refreshToken').isNotEmpty ||
            hasXunleiPassword(c),
      CloudPlatform.c139 =>
        c.primary.isNotEmpty ||
            c.field('authorization').isNotEmpty ||
            c.secondary.isNotEmpty,
      _ => c.primary.isNotEmpty,
    };
  }

  static Map<String, String> cookiePairs(String raw) {
    final result = <String, String>{};
    for (final part
        in raw
            .trim()
            .replaceFirst(RegExp(r'^cookie:', caseSensitive: false), '')
            .split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim(),
          value = part.substring(separator + 1).trim();
      if (name.isNotEmpty && value.isNotEmpty) {
        result.putIfAbsent(name, () => value);
      }
    }
    return result;
  }

  /// Return the saved Cookie header without exporting passwords, token JSON,
  /// browser metadata, or a token-only primary field.
  static String? savedCookie(CloudPlatform platform, Credential? credential) {
    if (credential == null || platform == CloudPlatform.github) return null;
    final primary =
        WebTokens.supports(platform) || platform == CloudPlatform.pan123
        ? credential.field('cookie')
        : switch (platform) {
            CloudPlatform.tianyi => TianyiWebLogin.cookie(credential.primary),
            CloudPlatform.weiyun => WeiyunWebLogin.cookie(credential.primary),
            _ => credential.primary,
          };
    for (final raw in [
      primary,
      credential.field('cookie'),
      WebTokens.decode(credential.primary).str('cookie'),
    ]) {
      final value = _savedCookieHeader(platform, raw);
      if (value != null) return value;
    }
    return null;
  }

  static String? _savedCookieHeader(CloudPlatform platform, String raw) {
    final value = raw
        .trim()
        .replaceFirst(RegExp(r'^Cookie:\s*', caseSensitive: false), '')
        .trim();
    if (value.isEmpty || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
      return null;
    }
    final namePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
    var hasCookie = false;
    for (final part in value.split(';')) {
      if (part.trim().isEmpty) continue;
      final separator = part.indexOf('=');
      if (separator <= 0 ||
          !namePattern.hasMatch(part.substring(0, separator).trim())) {
        return null;
      }
      hasCookie = true;
    }
    if (platform == CloudPlatform.ctfile &&
        !cookiePairs(value).containsKey('ctfile_session')) {
      return null;
    }
    // Keep encoded values, empty cookies, duplicates, and '=' padding intact.
    return hasCookie ? value : null;
  }

  static String mergeCookies(List<String> values) {
    final pairs = <String, String>{};
    for (final raw in values) {
      for (final e in cookiePairs(raw).entries) {
        pairs.putIfAbsent(e.key, () => e.value);
      }
    }
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  static String fromBrowser(
    CloudPlatform platform, {
    Object? storage,
    List<String> cookies = const [],
  }) {
    if (platform == CloudPlatform.tianyi) {
      final captured = TianyiWebLogin.decode(storage);
      final raw = TianyiWebLogin.encode(
        mergeCookies(cookies),
        captured['browserId'],
      );
      return plausible(platform, raw) ? raw : '';
    }
    if (platform == CloudPlatform.weiyun) {
      final captured = WeiyunWebLogin.decode(storage);
      final raw = WeiyunWebLogin.encode(
        mergeCookies([...cookies, captured.str('cookie')]),
        captured,
      );
      return plausible(platform, raw) ? raw : '';
    }
    var raw = storage is String
        ? storage
        : storage is Map
        ? jsonEncode(storage)
        : '';
    if ((WebTokens.supports(platform) || platform == CloudPlatform.pan123) &&
        plausible(platform, raw)) {
      return raw;
    }
    final cookie = mergeCookies(cookies);
    final pairs = cookiePairs(cookie);
    String token(List<String> names) {
      for (final name in names) {
        var value = pairs[name] ?? '';
        try {
          value = Uri.decodeComponent(value);
          if (value.startsWith('"') && jsonDecode(value) is String) {
            value = jsonDecode(value) as String;
          }
        } catch (_) {
          continue;
        }
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    if (platform == CloudPlatform.ilanzou ||
        platform == CloudPlatform.feijipan) {
      final data = WebTokens.decode(raw);
      raw = jsonEncode({
        'appToken': token(['appToken']),
        'uuid': data.str('uuid'),
      });
    } else if (platform == CloudPlatform.wopan) {
      final refresh = token(['refreshToken', 'refresh_token']);
      raw = refresh.isEmpty
          ? ''
          : jsonEncode({
              'access_token': token(['accessToken', 'access_token', 'token']),
              'refresh_token': refresh,
            });
    } else if (!WebTokens.supports(platform)) {
      raw = cookie;
    }
    return plausible(platform, raw) ? raw : '';
  }

  static bool plausible(CloudPlatform platform, String raw) {
    if (platform == CloudPlatform.github) {
      return RegExp(r'^[A-Za-z0-9_]{20,255}$').hasMatch(raw.trim());
    }
    if (WebTokens.supports(platform)) {
      return WebTokens.fields(platform, raw).isNotEmpty;
    }
    if (raw.trim().isEmpty || RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(raw)) {
      return false;
    }
    if (platform == CloudPlatform.pan123) {
      return !{'null', 'undefined', '""', 'Bearer'}.contains(raw.trim());
    }
    final cookie = switch (platform) {
      CloudPlatform.weiyun => WeiyunWebLogin.cookie(raw),
      CloudPlatform.tianyi => TianyiWebLogin.cookie(raw),
      _ => raw,
    };
    if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(cookie)) return false;
    final p = cookiePairs(cookie);
    return switch (platform) {
      CloudPlatform.ctfile =>
        RegExp(r'^[A-Za-z0-9_-]{16,256}$').hasMatch(raw.trim()) ||
            cookiePairs(raw).containsKey('ctfile_session'),
      CloudPlatform.pan115 => ['UID', 'CID', 'SEID'].every(p.containsKey),
      CloudPlatform.baidu => p.containsKey('BDUSS'),
      CloudPlatform.lanzou =>
        p.containsKey('ylogin') && p.containsKey('phpdisk_info'),
      CloudPlatform.quark ||
      CloudPlatform.uc => p.containsKey('__pus') && p.containsKey('__puus'),
      CloudPlatform.tianyi =>
        p.containsKey('COOKIE_LOGIN_USER') || p.containsKey('LOGIN_USER'),
      CloudPlatform.c139 =>
        c139Authorization(raw).isNotEmpty ||
            c139Cookie(raw, 'Os_SSo_Sid').isNotEmpty &&
                c139Cookie(raw, 'RMKEY').isNotEmpty,
      CloudPlatform.weiyun =>
        p.containsKey('openid') &&
                p.containsKey('access_token') &&
                p.containsKey('wy_appid') ||
            p.containsKey('weiyun_qq_openid') ||
            p.containsKey('weiyun_wx_openid') ||
            p.containsKey('p_skey') &&
                (p.containsKey('uin') || p.containsKey('p_uin')) ||
            p.isNotEmpty && _weiyunRequestReady(raw),
      _ => false,
    };
  }

  static bool _weiyunRequestReady(String raw) {
    final captured = WeiyunWebLogin.decode(raw);
    final info = WeiyunWebLogin.tokenInfo(captured['tokenInfo']);
    return info.containsKey('token_type') &&
        info.containsKey('login_key_type') &&
        (WeiyunWebLogin.csrf(captured['csrf']).isNotEmpty ||
            cookiePairs(captured.str('cookie')).containsKey('wyctoken'));
  }

  static String normalize(CloudPlatform p, String raw) {
    var value = raw.trim();
    if (p == CloudPlatform.github) {
      value = value.replaceFirst(
        RegExp(r'^(?:Bearer|token)\s+', caseSensitive: false),
        '',
      );
      require(plausible(p, value), hint(p));
      return value;
    }
    if (p == CloudPlatform.tianyi) {
      value = TianyiWebLogin.encode(
        mergeCookies([TianyiWebLogin.cookie(value)]),
        TianyiWebLogin.decode(value)['browserId'],
      );
      require(plausible(p, value), hint(p));
      return value;
    }
    if (p == CloudPlatform.weiyun) {
      value = WeiyunWebLogin.encode(
        mergeCookies([WeiyunWebLogin.cookie(value)]),
        WeiyunWebLogin.decode(value),
      );
      require(plausible(p, value), hint(p));
      return value;
    }
    if (WebTokens.supports(p)) {
      require(plausible(p, value), hint(p));
      return value;
    }
    if (p == CloudPlatform.pan123) {
      if (value.startsWith('"')) {
        try {
          value = (jsonDecode(value) as String).trim();
        } catch (_) {
          value = '';
        }
      }
      value = value
          .replaceFirst(RegExp(r'^Bearer\s*', caseSensitive: false), '')
          .trim();
    } else {
      value = value
          .replaceFirst(RegExp(r'^Cookie:', caseSensitive: false), '')
          .trim();
    }
    require(plausible(p, value), hint(p));
    return value;
  }

  static Credential candidate(
    CloudPlatform p,
    String raw,
    Credential? existing,
  ) {
    final value = normalize(p, raw);
    final fields = switch (p) {
      CloudPlatform.github => {'primary': value, 'authType': 'githubToken'},
      CloudPlatform.feijipan => WebTokens.fields(p, value),
      CloudPlatform.pikpak => WebTokens.fields(p, value),
      CloudPlatform.aliyun ||
      CloudPlatform.guangya ||
      CloudPlatform.ilanzou ||
      CloudPlatform.wopan ||
      CloudPlatform.xunlei => WebTokens.fields(p, value),
      CloudPlatform.weiyun => WeiyunWebLogin.fields(value),
      CloudPlatform.tianyi => TianyiWebLogin.fields(value),
      CloudPlatform.pan123 => {
        'primary': value,
        'accessToken': value,
        'authType': 'webToken',
      },
      CloudPlatform.c139 => {
        'primary': value,
        'authorization': c139Authorization(value),
        'userDomainId': c139Cookie(value, 'ud_id'),
      },
      CloudPlatform.baidu => {
        'primary': value,
        'appId': (existing?.field('appId') ?? '').ifEmpty(
          existing?.secondary ?? '',
        ),
      },
      _ => {'primary': value},
    };
    return Credential(
      p.label,
      Map.fromEntries(fields.entries.where((e) => e.value.isNotEmpty)),
    );
  }

  static String hint(CloudPlatform p) => switch (p) {
    CloudPlatform.github => '请粘贴 GitHub 个人访问令牌；管理文件需要所选仓库的 Contents 读写权限',
    CloudPlatform.pikpak =>
      '请粘贴 PikPak 的登录令牌 JSON（access_token、refresh_token）；也可切换账号密码登录',
    CloudPlatform.feijipan => '请粘贴小飞机网页登录的 appToken，或包含 appToken 和 uuid 的 JSON',
    CloudPlatform.ctfile =>
      '请粘贴城通网盘的 Session Token 或含 ctfile_session 的 Cookie；也可使用邮箱密码或网页登录',
    CloudPlatform.pan115 => '请粘贴 115 登录后的完整 Cookie，需包含 UID、CID 和 SEID',
    CloudPlatform.baidu => 'Cookie 需包含非空的 BDUSS',
    CloudPlatform.quark || CloudPlatform.uc => 'Cookie 需同时包含非空的 __pus 和 __puus',
    CloudPlatform.c139 =>
      '请在移动云盘首页复制完整 Cookie，需包含云盘 authorization 或 auth_token 与账号信息',
    CloudPlatform.pan123 => '请粘贴网页登录后的 authorToken',
    CloudPlatform.tianyi =>
      '请粘贴天翼官网登录后的完整 Cookie，需包含 COOKIE_LOGIN_USER 或 LOGIN_USER',
    CloudPlatform.xunlei => '请在迅雷网页完成登录，或使用账号密码、短信登录',
    CloudPlatform.aliyun => '请粘贴阿里云盘网页登录的 token JSON 或 refresh_token',
    CloudPlatform.guangya =>
      '请粘贴光鸭网页登录的 credentials JSON；仅填写 Access Token 时，过期后需重新登录',
    CloudPlatform.lanzou => '请粘贴蓝奏官网登录后的 Cookie，需包含 ylogin 和 phpdisk_info',
    CloudPlatform.ilanzou => '请粘贴蓝奏云优享版的 appToken，或包含 appToken 和 uuid 的 JSON',
    CloudPlatform.weiyun => '请粘贴微云登录后的完整 Cookie，支持 QQ 或微信登录',
    CloudPlatform.wopan =>
      '请粘贴联通云盘的 refresh_token，或包含 access_token、refresh_token 的 JSON',
  };
  static CloudAccount c139Account(String cookie) {
    String decode(String? raw) {
      try {
        return utf8.decode(base64.decode(base64.normalize(raw ?? '')));
      } catch (_) {
        return '';
      }
    }

    final nickname = c139Cookie(cookie, 'ORCHES-I-ACCOUNT-SIMPLIFY')
        .ifEmpty(decode(c139Cookie(cookie, 'ORCHES-I-ACCOUNT-ENCRYPT')))
        .ifEmpty(c139Cookie(cookie, 'Login_UserNumber'))
        .ifEmpty(
          decode(
                c139Authorization(cookie).replaceFirst('Basic', '').trim(),
              ).split(':').elementAtOrNull(1) ??
              '',
        );
    return CloudAccount(nickname.ifEmpty('139 用户'));
  }
}

class LoginResult {
  const LoginResult(this.credential, this.account);
  final Credential credential;
  final CloudAccount account;
}

class AccountLoginService {
  AccountLoginService(
    this.store,
    this.validate, {
    this.webAuthenticators = const {},
    this.checkAccess,
  });
  final CredentialStore store;
  final Future<CloudAccount> Function(CloudPlatform, Credential) validate;
  final void Function(CloudPlatform)? checkAccess;
  final Map<CloudPlatform, Future<LoginResult> Function(Credential)>
  webAuthenticators;
  final _busy = <CloudPlatform>{};
  final _revision = <CloudPlatform, int>{};
  final _requests = <CloudPlatform, RequestScope>{};
  void invalidate(CloudPlatform p) {
    _revision[p] = (_revision[p] ?? 0) + 1;
    _requests.remove(p)?.cancel();
    _busy.remove(p);
  }

  Future<void> remove(CloudPlatform p) async {
    invalidate(p);
    await store.removeCredential(p);
  }

  Future<LoginResult> submitWeb(
    CloudPlatform p,
    String raw, {
    String? appId,
    String? accountId,
    Map<String, String> rememberedLogin = const {},
  }) => submit(p, (existing) async {
    var candidate = LoginCredentials.candidate(p, raw, existing);
    if (p == CloudPlatform.aliyun &&
        rememberedLogin['loginUsername']?.isNotEmpty == true &&
        rememberedLogin['loginPassword']?.isNotEmpty == true) {
      candidate = candidate.withFields({
        'loginUsername': rememberedLogin['loginUsername']!,
        'loginPassword': rememberedLogin['loginPassword']!,
      });
    }
    if (p == CloudPlatform.baidu && appId != null) {
      final value = appId.trim();
      require(
        value.isEmpty || RegExp(r'^\d+$').hasMatch(value),
        '百度应用 ID 格式无效，可清空后使用默认值',
      );
      candidate = candidate.withFields({'appId': value});
    }
    final authenticate = webAuthenticators[p];
    if (authenticate != null) return authenticate(candidate);
    CloudAccount account;
    if (p == CloudPlatform.c139) {
      if (candidate.field('authorization').isEmpty) {
        throw const AccountLoginRequired('移动云盘登录尚未完成，请在网页进入网盘首页后重新保存');
      }
      try {
        account = await validate(p, candidate);
      } on AccountLoginRequired {
        rethrow;
      } on AppException {
        account = LoginCredentials.c139Account(candidate.primary);
      }
    } else if (p == CloudPlatform.pan123) {
      account = await validate(p, candidate);
    } else {
      try {
        account = await validate(p, candidate);
      } on AccountLoginRequired {
        rethrow;
      } on AppException {
        account = CloudAccount('${p.shortName}用户');
      }
    }
    return LoginResult(candidate, account);
  }, accountId: accountId);
  Future<LoginResult> submit(
    CloudPlatform p,
    Future<LoginResult> Function(Credential?) authenticate, {
    String? accountId,
  }) async {
    final vault = store;
    if (vault is! Vault) return _submit(p, authenticate);
    final revision = _revision[p] ?? 0;
    final selection = vault.activeAccountId(p);
    bool stillSelected() => vault.activeAccountId(p) == selection;
    final created = accountId == null && vault.activeAccountId(p) == null;
    final id =
        accountId ?? vault.activeAccountId(p) ?? await vault.createAccount(p);
    var committedId = id;
    try {
      require((_revision[p] ?? 0) == revision, '登录已取消或账号发生变化');
      final result = await vault.withAccount(
        p,
        id,
        () => _submit(
          p,
          authenticate,
          canCommit: stillSelected,
          commit: (expected, replacement, canCommit) async {
            final saved = await vault.commitLogin(
              p,
              id,
              expected,
              replacement,
              canCommit: canCommit,
            );
            if (saved == null) return false;
            committedId = saved;
            return true;
          },
        ),
      );
      await vault.activate(
        p,
        committedId,
        canCommit: () => (_revision[p] ?? 0) == revision && stillSelected(),
      );
      return result;
    } finally {
      if (created) await vault.removeAccount(p, id, onlyIfEmpty: true);
    }
  }

  Future<LoginResult> _submit(
    CloudPlatform p,
    Future<LoginResult> Function(Credential?) authenticate, {
    bool Function()? canCommit,
    Future<bool> Function(Credential?, Credential, bool Function())? commit,
  }) async {
    checkAccess?.call(p);
    require(_busy.add(p), '正在提交登录信息，请稍候');
    final requestScope = RequestScope();
    _requests[p] = requestScope;
    try {
      final revision = _revision[p] ?? 0, previous = store.credential(p);
      final result = await requestScope.run(() => authenticate(previous));
      checkAccess?.call(p);
      require((_revision[p] ?? 0) == revision, '登录已取消或账号发生变化');
      var timestamp = DateTime.now().millisecondsSinceEpoch;
      if (store case final Vault vault) {
        for (final profile in vault.profiles(p)) {
          final revision = vault.credentialFor(p, profile.id)!.updatedAt;
          if (timestamp <= revision) timestamp = revision + 1;
        }
      }
      final credential = Credential(
        result.credential.label,
        {...result.credential.fields, 'nickname': result.account.nickname},
        updatedAt: timestamp > (previous?.updatedAt ?? 0)
            ? timestamp
            : previous!.updatedAt + 1,
      );
      var committed = false;
      final sameSession = switch (p) {
        CloudPlatform.pikpak ||
        CloudPlatform.aliyun ||
        CloudPlatform.guangya ||
        CloudPlatform.feijipan ||
        CloudPlatform.ilanzou ||
        CloudPlatform.weiyun ||
        CloudPlatform.wopan => LoginCredentials.sameWebTokenSession,
        CloudPlatform.pan123 => LoginCredentials.samePan123Session,
        CloudPlatform.tianyi => LoginCredentials.sameTianyiSession,
        CloudPlatform.xunlei => LoginCredentials.sameXunleiSession,
        CloudPlatform.uc => LoginCredentials.sameUcSession,
        _ => LoginCredentials.sameCookieSession,
      };
      for (var attempt = 0; attempt < 2; attempt++) {
        final current = store.credential(p);
        if (!sameSession(previous, current)) {
          break;
        }
        bool allowed() {
          checkAccess?.call(p);
          return (_revision[p] ?? 0) == revision && (canCommit?.call() ?? true);
        }

        committed = commit != null
            ? await commit(current, credential, allowed)
            : await store.replaceCredential(
                p,
                current,
                credential,
                canCommit: allowed,
              );
        if (committed) break;
      }
      require(committed, '账号已发生变化，请重新登录');
      return LoginResult(credential, result.account);
    } finally {
      if (identical(_requests[p], requestScope)) {
        _busy.remove(p);
        _requests.remove(p);
      }
    }
  }
}

class WebLoginTarget {
  const WebLoginTarget(
    this.platform,
    this.url,
    this.cookieDomains, {
    this.userAgent = desktopUserAgent,
    this.desktopMode = true,
    this.localStorageKey,
    this.clearCookieDomains = const [],
    this.storageOrigins = const [],
  });
  final CloudPlatform platform;
  final String url;
  final List<String> cookieDomains;
  final List<String> clearCookieDomains;
  final List<String> storageOrigins;
  final String userAgent;
  final bool desktopMode;
  final String? localStorageKey;
  static const desktop =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ';
  static const desktopUserAgent = '${desktop}Chrome/131.0.0.0 Safari/537.36';
  static const mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';
  static const targets = {
    CloudPlatform.ctfile:
        WebLoginTarget(CloudPlatform.ctfile, 'https://my.ctfile.com/login', [
          'https://my.ctfile.com',
          'https://www.ctfile.com',
          'https://rest.ctfile.com',
          'https://api.ctfile.com',
        ]),
    CloudPlatform.pan115: WebLoginTarget(
      CloudPlatform.pan115,
      'https://115.com/?cid=0&offset=0&tab=&mode=wangpan',
      ['https://115.com', 'https://webapi.115.com', 'https://passport.115.com'],
      clearCookieDomains: [
        'https://passportapi.115.com',
        'https://qrcodeapi.115.com',
        'https://my.115.com',
      ],
    ),
    CloudPlatform.xunlei: WebLoginTarget(
      CloudPlatform.xunlei,
      XunleiWebLogin.loginUrl,
      [XunleiWebLogin.storageOrigin],
      localStorageKey: XunleiWebLogin.storageKey,
      storageOrigins: [XunleiWebLogin.storageOrigin],
      clearCookieDomains: [
        XunleiWebLogin.accountOrigin,
        'https://xluser-ssl.xunlei.com',
      ],
    ),
    CloudPlatform.lanzou: WebLoginTarget(
      CloudPlatform.lanzou,
      'https://pc.woozooo.com/account.php?action=login',
      [
        'https://pc.woozooo.com',
        'https://up.woozooo.com',
        'https://woozooo.com',
        'https://accounts.woozooo.com',
      ],
    ),
    CloudPlatform.baidu: WebLoginTarget(
      CloudPlatform.baidu,
      'https://pan.baidu.com/',
      ['https://pan.baidu.com'],
      userAgent: '${desktop}Chrome/124.0.0.0 Safari/537.36',
    ),
    CloudPlatform.quark: WebLoginTarget(
      CloudPlatform.quark,
      'https://pan.quark.cn/?fr=pc&platform=pc',
      ['https://pan.quark.cn'],
      userAgent: '${desktop}Chrome/130.0.0.0 Safari/537.36 QuarkPC/6.0.8.649',
    ),
    CloudPlatform.uc: WebLoginTarget(
      CloudPlatform.uc,
      'https://drive.uc.cn/',
      ['https://drive.uc.cn'],
      userAgent: '${desktop}Chrome/120.0.0.0 Safari/537.36',
    ),
    CloudPlatform.c139:
        WebLoginTarget(CloudPlatform.c139, 'https://yun.139.com/w/', [
          'https://yun.139.com/w/',
          'https://yun.139.com/m/',
          'https://yun.139.com',
          'https://user-njs.yun.139.com/',
          'https://personal-kd-njs.yun.139.com/',
          'https://share-kd-njs.yun.139.com/',
          'https://caiyun.139.com/',
          'https://mail.10086.cn',
        ]),
    CloudPlatform.pan123: WebLoginTarget(
      CloudPlatform.pan123,
      'https://yun.123pan.cn/',
      ['https://yun.123pan.cn'],
      userAgent: '${desktop}Chrome/127.0.0.0 Safari/537.36',
      localStorageKey: 'authorToken',
    ),
    CloudPlatform.aliyun: WebLoginTarget(
      CloudPlatform.aliyun,
      'https://www.alipan.com/drive',
      ['https://www.alipan.com', 'https://auth.aliyundrive.com'],
      userAgent: '${desktop}Chrome/131.0.0.0 Safari/537.36',
      localStorageKey: 'token',
    ),
    CloudPlatform.guangya: WebLoginTarget(
      CloudPlatform.guangya,
      'https://www.guangyapan.com/#/oauth/login',
      ['https://www.guangyapan.com', 'https://account.guangyapan.com'],
      userAgent: '${desktop}Chrome/131.0.0.0 Safari/537.36',
      localStorageKey: 'credentials_aMe-8VSlkrbQXpUR',
    ),
    CloudPlatform.tianyi: WebLoginTarget(
      CloudPlatform.tianyi,
      TianyiWebLogin.loginUrl,
      [
        'https://cloud.189.cn/api/',
        'https://cloud.189.cn/web/',
        'https://cloud.189.cn/',
        'https://m.cloud.189.cn/',
        'https://h5.cloud.189.cn/',
        'https://api.cloud.189.cn/',
      ],
      userAgent: mobileUserAgent,
      desktopMode: false,
      clearCookieDomains: ['https://open.e.189.cn/'],
    ),
    CloudPlatform.ilanzou: WebLoginTarget(
      CloudPlatform.ilanzou,
      'https://www.ilanzou.com/#/login',
      ['https://www.ilanzou.com', 'https://apis.ilanzou.com'],
      localStorageKey: 'disk-pc-vuex',
      storageOrigins: ['https://ilanzou.com'],
    ),
    CloudPlatform.feijipan: WebLoginTarget(
      CloudPlatform.feijipan,
      'https://www.feijipan.com/console/files/0',
      [
        'https://www.feijipan.com',
        'https://api.feijipan.com',
        'https://share.feijipan.com',
      ],
      localStorageKey: 'vuex',
      storageOrigins: ['https://feijipan.com', 'https://share.feijipan.com'],
    ),
    CloudPlatform.pikpak: WebLoginTarget(
      CloudPlatform.pikpak,
      'https://mypikpak.com/drive/all',
      [
        'https://mypikpak.com',
        'https://user.mypikpak.com',
        'https://api-drive.mypikpak.com',
      ],
      localStorageKey: PikPakWebLogin.storageKey,
      storageOrigins: ['https://www.mypikpak.com'],
    ),
    CloudPlatform.weiyun: WebLoginTarget(
      CloudPlatform.weiyun,
      'https://www.weiyun.com/disk',
      [
        'https://www.weiyun.com/disk',
        'https://www.weiyun.com/webapp/',
        'https://www.weiyun.com/qq_connect',
        'https://www.weiyun.com/web/callback/common_qq_login_ok.html',
        'https://www.weiyun.com/',
        'https://user.weiyun.com/login/verify_code',
        'https://user.weiyun.com/newcgi/',
        'https://user.weiyun.com/',
      ],
      clearCookieDomains: [
        'https://ssl.ptlogin2.weiyun.com',
        'https://open.weixin.qq.com',
      ],
    ),
    CloudPlatform.wopan: WebLoginTarget(
      CloudPlatform.wopan,
      'https://panservice.mail.wo.cn/h5/wocloud_ai/login',
      ['https://panservice.mail.wo.cn', 'https://pan.wo.cn'],
      localStorageKey: 'token',
      storageOrigins: ['https://pan.wo.cn'],
    ),
  };
  String get readStorageScript {
    if (platform == CloudPlatform.pikpak) {
      return PikPakWebLogin.readScript;
    }
    if (platform == CloudPlatform.xunlei) return XunleiWebLogin.readScript;
    final key = jsonEncode(localStorageKey);
    if (platform == CloudPlatform.ilanzou ||
        platform == CloudPlatform.feijipan) {
      return r'''(() => {
        let common = {};
        for (const key of ['disk-pc-vuex', 'vuex', 'disk-vuex']) {
          try {
            const stored = JSON.parse(localStorage.getItem(key) || '{}').common || {};
            if (stored.appToken) { common = stored; break; }
            if (stored.uuid) common = stored;
          } catch (_) {}
        }
        try {
          const raw = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('appToken='));
          const appToken = common.appToken || (raw && decodeURIComponent(raw.slice(9))) || '';
          return appToken || common.uuid ? JSON.stringify({appToken, uuid: common.uuid || ''}) : '';
        } catch (_) { return common.appToken || common.uuid ? JSON.stringify({appToken: common.appToken || '', uuid: common.uuid || ''}) : ''; }
      })()''';
    }
    if (platform == CloudPlatform.wopan) {
      return r'''(() => {
        for (const name of ['sessionStorage', 'localStorage']) {
          try {
            const store = window[name];
            const read = key => {
              const raw = store.getItem(key) || '';
              try { return JSON.parse(raw); } catch (_) { return raw; }
            };
            const token = read('token');
            const object = token && typeof token === 'object' ? (token.data || token) : {};
            const access_token = object.access_token || object.accessToken ||
              read('access_token') || read('accessToken') || (typeof token === 'string' ? token : '');
            const refresh_token = object.refresh_token || object.refreshToken ||
              read('refreshToken') || read('refresh_token');
            if (typeof refresh_token === 'string' && refresh_token) {
              return JSON.stringify({access_token, refresh_token});
            }
          } catch (_) {}
        }
        return '';
      })()''';
    }
    if (platform != CloudPlatform.guangya) {
      return 'window.localStorage.getItem($key)';
    }
    return '''(() => {
      const prefix = $key;
      const sub = localStorage.getItem('current_sub');
      const raw = (sub && localStorage.getItem(prefix + '@' + sub)) || localStorage.getItem(prefix);
      if (!raw) return '';
      try {
        const data = JSON.parse(raw);
        data.device_id = localStorage.getItem('swangpan_web_device_id') || data.device_id;
        const sign = localStorage.getItem('deviceid');
        if (sign) data.device_sign = sign.replace(/['"]/g, '');
        return JSON.stringify(data);
      } catch (_) { return ''; }
    })()''';
  }

  String get clearStorageScript {
    if (platform == CloudPlatform.pikpak) {
      return PikPakWebLogin.clearScript;
    }
    if (platform == CloudPlatform.xunlei) return XunleiWebLogin.clearScript;
    final key = jsonEncode(localStorageKey);
    if (platform == CloudPlatform.ilanzou ||
        platform == CloudPlatform.feijipan) {
      return "localStorage.removeItem('disk-pc-vuex');localStorage.removeItem('vuex');localStorage.removeItem('disk-vuex');";
    }
    if (platform == CloudPlatform.wopan) {
      return r'''(() => {
        for (const name of ['sessionStorage', 'localStorage']) {
          try {
            const store = window[name];
            for (const key of ['token', 'refreshToken', 'accessToken', 'access_token', 'refresh_token']) store.removeItem(key);
          } catch (_) {}
        }
      })()''';
    }
    if (platform != CloudPlatform.guangya) {
      return 'window.localStorage.removeItem($key)';
    }
    return '''(() => {
      const prefix = $key;
      for (const key of Object.keys(localStorage)) {
        if (key === prefix || key.startsWith(prefix + '@') || key === 'current_sub') localStorage.removeItem(key);
      }
    })()''';
  }

  Set<String> get storageOriginRules => {
    Uri.parse(url).origin,
    ...storageOrigins,
  };

  String prepareStorageScript(String session) =>
      '''(() => {
    if (window.top !== window || !${jsonEncode(storageOriginRules.toList())}.includes(location.origin)) return 'untrusted';
    const marker = ${jsonEncode('__asterlink_login_${platform.key}')};
    const session = ${jsonEncode(session)};
    try {
      if (sessionStorage.getItem(marker) === session) return 'ready';
      $clearStorageScript;
      sessionStorage.setItem(marker, session);
      return 'cleared';
    } catch (_) { return 'unavailable'; }
  })()''';

  bool canPrepareLocalStorage(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        storageOriginRules.contains(uri.origin) &&
        uri.userInfo.isEmpty &&
        uri.port == 443;
  }

  bool canReadLocalStorage(String? value) =>
      canPrepareLocalStorage(value) &&
      // The account center needs its previous login cleared, but only the
      // cloud's token can authenticate cloud APIs.
      (platform != CloudPlatform.xunlei ||
          Uri.parse(value!).origin == XunleiWebLogin.storageOrigin);

  List<String> cookieUrls(String? page) {
    final uri = Uri.tryParse(page ?? '');
    return {
      if (platform == CloudPlatform.lanzou) ...[
        'https://pc.woozooo.com/mydisk.php',
        'https://pc.woozooo.com/doupload.php',
        'https://up.woozooo.com/mydisk.php',
      ],
      if (platform == CloudPlatform.tianyi)
        'https://cloud.189.cn/api/open/user/getUserInfoForPortal.action',
      if (platform == CloudPlatform.ctfile)
        'https://api.ctfile.com/v4/user/auth/exchange-token',
      // Prefer the cookies the account API receives, including HttpOnly cookies
      // scoped below /webapp/json/, over a same-name cookie on the disk page.
      if (platform == CloudPlatform.weiyun)
        'https://www.weiyun.com/webapp/json/weiyunQdiskClient/DiskUserInfoGet',
      if (uri != null &&
          uri.scheme == 'https' &&
          uri.port == 443 &&
          uri.userInfo.isEmpty &&
          cookieDomains.any((domain) => Uri.parse(domain).host == uri.host))
        Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
        ).toString(),
      ...cookieDomains,
    }.toList();
  }
}

class LoginPollingPolicy {
  int? _last, _failedAt;
  String? _failedValue;
  bool canAttempt(String value, int monotonicMs) =>
      (_last == null || monotonicMs - _last! >= 5000) &&
      (value != _failedValue ||
          _failedAt == null ||
          monotonicMs - _failedAt! >= 10000);
  void started(int now) => _last = now;
  void failed(String value, int now) {
    _failedValue = value;
    _failedAt = now;
  }
}
