import 'dart:convert';
import '../core/json.dart';
import 'auth.dart';
import 'models.dart';
import 'web_tokens.dart';
import 'weiyun_web_login.dart';

class AccountLoginField {
  const AccountLoginField(this.key, this.label, this.value);
  final String key, label, value;
}

/// A view of saved authentication material, independent of the active account.
/// Login passwords and application secrets are never part of this export.
class AccountLoginInfo {
  AccountLoginInfo._(this.fields, this.preferredKey);
  final List<AccountLoginField> fields;
  final String? preferredKey;
  AccountLoginField? field(String key) =>
      fields.where((field) => field.key == key).firstOrNull;
  AccountLoginField? get preferred =>
      preferredKey == null ? null : field(preferredKey!);
  bool get hasCookie => field('cookie') != null;
  String get copyLabel => preferredKey == null
      ? '复制登录信息'
      : preferredKey == 'webdavUrl'
      ? '复制连接地址'
      : preferredKey == 'cookie'
      ? '复制 Cookie'
      : preferredKey == 'authorization'
      ? '复制授权信息'
      : preferredKey == 'tokenInfo'
      ? '复制登录信息'
      : '复制 Token';
  String get method => field('webdavUrl') != null
      ? 'WebDAV 连接'
      : hasCookie
      ? preferredKey == 'cookie' &&
                !fields.any((f) => f.key.toLowerCase().contains('token'))
            ? 'Cookie 登录'
            : 'Cookie / Token 登录'
      : preferred != null
      ? 'Token 登录'
      : '暂无登录凭据';
  String get json => const JsonEncoder.withIndent(
    '  ',
  ).convert({for (final field in fields) field.key: field.value});

  factory AccountLoginInfo.from(
    CloudPlatform platform,
    Credential? credential, {
    String legacyAccessToken = '',
  }) {
    if (credential == null) return AccountLoginInfo._(const [], null);
    if (platform == CloudPlatform.webdav) {
      return AccountLoginInfo._([
        AccountLoginField('webdavUrl', 'WebDAV 目录地址', credential.primary),
        if (credential.field('username').isNotEmpty)
          AccountLoginField('username', '用户名', credential.field('username')),
      ], 'webdavUrl');
    }
    var data = WebTokens.decode(credential.primary);
    if ((platform == CloudPlatform.feijipan ||
            platform == CloudPlatform.ilanzou) &&
        data.obj('common').isNotEmpty) {
      data = data.obj('common');
    }
    String read(List<String> keys) {
      for (final source in [credential.fields, data]) {
        for (final key in keys) {
          final value = source[key];
          if (value is String && _plain(value)) return value.trim();
        }
      }
      return '';
    }

    final fields = <AccountLoginField>[];
    void add(String key, String label, String value) {
      if (value.isEmpty) return;
      // Aliyun device sessions are generated locally. Export only the saved
      // account credentials, without device parameters or client defaults.
      if (platform == CloudPlatform.aliyun &&
          !const {
            'cookie',
            'accessToken',
            'refreshToken',
            'userId',
          }.contains(key)) {
        return;
      }
      fields.add(AccountLoginField(key, label, value));
    }

    final cookie = LoginCredentials.savedCookie(platform, credential) ?? '';
    add('cookie', 'Cookie', cookie);
    var access = read(['accessToken', 'access_token', 'authorToken']);
    if (platform == CloudPlatform.pan123 &&
        access.isEmpty &&
        _plain(legacyAccessToken)) {
      access = legacyAccessToken;
    }
    var refresh = read(['refreshToken', 'refresh_token']);
    final primary = credential.primary;
    final plainPrimary =
        _plain(primary) &&
        !primary.startsWith('{') &&
        !primary.startsWith('[') &&
        !primary.startsWith('"');
    if (WebTokens.supports(platform) && plainPrimary) {
      if (platform == CloudPlatform.aliyun || platform == CloudPlatform.wopan) {
        if (refresh.isEmpty) refresh = primary;
      } else if (access.isEmpty) {
        access = primary;
      }
    }
    if (platform == CloudPlatform.pan123 &&
        access.isEmpty &&
        plainPrimary &&
        ({'webToken', 'passwordToken'}.contains(credential.field('authType')) ||
            credential.secondary.isEmpty && WebTokens.validToken(primary))) {
      access = primary;
    }
    if (platform == CloudPlatform.xunlei &&
        refresh.isEmpty &&
        WebTokens.validToken(credential.secondary)) {
      refresh = credential.secondary;
    }
    if (platform == CloudPlatform.feijipan ||
        platform == CloudPlatform.ilanzou) {
      add('appToken', '应用令牌（appToken）', read(['appToken']).ifEmpty(access));
    } else {
      add('accessToken', '访问令牌（Access Token）', access);
    }
    add('refreshToken', '刷新令牌（Refresh Token）', refresh);
    if (platform == CloudPlatform.github && plainPrimary) {
      add('token', '个人访问令牌（Token）', primary);
    }
    if (platform == CloudPlatform.ctfile &&
        cookie.isEmpty &&
        plainPrimary &&
        WebTokens.validToken(primary)) {
      add('sessionToken', '会话令牌（Session Token）', primary);
    }
    add(
      'authorization',
      '授权信息（Authorization）',
      read(['authorization', 'Authorization']),
    );
    if (platform == CloudPlatform.weiyun) {
      final tokens = WeiyunWebLogin.tokenInfo(
        credential.field('weiyunTokenInfo').isNotEmpty
            ? credential.field('weiyunTokenInfo')
            : data['tokenInfo'],
      );
      if (tokens.isNotEmpty) {
        add('tokenInfo', '登录令牌信息（JSON）', jsonEncode(tokens));
      }
      final header = WeiyunWebLogin.requestHeader(
        credential.field('weiyunRequestHeader').isNotEmpty
            ? credential.field('weiyunRequestHeader')
            : data['requestHeader'],
      );
      if (header.isNotEmpty) {
        add('requestHeader', '会话请求信息（JSON）', jsonEncode(header));
      }
      add('csrf', '会话校验值（CSRF）', read(['weiyunCsrf', 'csrf']));
    }

    final preferredKeys = [
      'cookie',
      if (platform == CloudPlatform.aliyun || platform == CloudPlatform.wopan)
        'refreshToken',
      'accessToken',
      'appToken',
      'token',
      'sessionToken',
      'refreshToken',
      'authorization',
      'tokenInfo',
    ];
    final preferred = preferredKeys
        .where((key) => fields.any((field) => field.key == key))
        .firstOrNull;
    if (preferred != null) {
      for (final (key, label, aliases) in const [
        ('userId', '用户标识', ['userId', 'user_id']),
        ('deviceId', '设备标识', ['deviceId', 'device_id']),
        ('uuid', '设备编号（UUID）', ['uuid']),
        (
          'captchaToken',
          '验证令牌（Captcha Token）',
          ['captchaToken', 'captcha_token'],
        ),
      ]) {
        add(key, label, read(aliases));
      }
    }
    return AccountLoginInfo._(List.unmodifiable(fields), preferred);
  }

  static bool _plain(String value) =>
      value.trim().isNotEmpty &&
      !{'null', 'undefined'}.contains(value.trim()) &&
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);
}
