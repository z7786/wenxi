import 'dart:convert';
import '../../core/json.dart';
import '../../domain/auth.dart' show WebLoginTarget;
import '../../domain/models.dart';
import '../../domain/web_tokens.dart';
import '../http.dart';

typedef GuangyaCaptchaPrompt =
    Future<String?> Function(GuangyaCaptchaChallenge);

class GuangyaLoginProtocol {
  static const clientId = 'aMe-8VSlkrbQXpUR';
  static const origin = 'https://account.guangyapan.com';
  static const web = 'https://www.guangyapan.com';

  static String accountDevice(String device, String sign) {
    final separator = sign.indexOf('.');
    return separator >= 0 && sign.length >= separator + 33
        ? sign.substring(separator + 1, separator + 33)
        : device;
  }

  static Map<String, String> deviceHeaders(String device, String sign) => {
    'X-Client-Id': clientId,
    'X-Client-Version': '0.0.1',
    'X-Device-Id': Uri.encodeComponent(accountDevice(device, sign)),
    'X-Device-Model': 'chrome%2F131.0.0.0',
    'X-Device-Name': 'PC-Chrome',
    if (sign.isNotEmpty) 'X-Device-Sign': Uri.encodeComponent(sign),
    'X-Os-Version': 'Win32',
    'X-Platform-Version': '1',
    'X-Protocol-Version': '301',
    'X-Sdk-Version': '9.1.3',
  };

  static String username(String value) {
    final text = value.trim();
    if (RegExp(r'^1[0-9]{10}$').hasMatch(text)) return '+86 $text';
    if (RegExp(r'^\+861[0-9]{10}$').hasMatch(text)) {
      return '+86 ${text.substring(3)}';
    }
    return text;
  }
}

class GuangyaCaptchaChallenge {
  GuangyaCaptchaChallenge(String page)
    : state = newId(),
      _page = Uri.tryParse(page) {
    require(trustedPage(page), '光鸭验证页面不可用，请切换网页登录');
  }

  final String state;
  final Uri? _page;
  static const callback = '${GuangyaLoginProtocol.web}/?asterlink_captcha=1';

  Uri get url => _page!.replace(
    queryParameters: {
      ..._page.queryParameters,
      'redirect_uri': callback,
      'state': state,
    },
  );

  static bool trustedPage(String? value) {
    final uri = Uri.tryParse(value ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    return [
      'guangyapan.com',
      'xunlei.com',
    ].any((domain) => uri.host == domain || uri.host.endsWith('.$domain'));
  }

  String? tokenFromCallback(String? value) {
    final uri = Uri.tryParse(value ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'www.guangyapan.com' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.path != '/' ||
        uri.queryParameters['asterlink_captcha'] != '1' ||
        uri.queryParameters['state'] != state) {
      return null;
    }
    final token = uri.queryParameters['captcha_token'] ?? '';
    return WebTokens.validToken(token) ? token : null;
  }
}

class GuangyaSmsChallenge {
  const GuangyaSmsChallenge({
    required this.mobile,
    required this.verificationId,
    required this.isUser,
    required this.device,
    required this.sign,
    required this.expiresAt,
  });
  final String mobile, verificationId, device, sign;
  final bool? isUser;
  final int expiresAt;
}

class GuangyaSmsLogin {
  GuangyaSmsLogin(this.http, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final JsonHttp http;
  final int Function() now;

  static bool validMobile(String value) =>
      RegExp(r'^1[0-9]{10}$').hasMatch(value.trim());

  Future<GuangyaSmsChallenge> sendSms(
    String mobile, {
    GuangyaCaptchaPrompt? verifyCaptcha,
    void Function(String)? onStatus,
  }) async {
    mobile = mobile.trim();
    require(validMobile(mobile), '请输入正确的手机号');
    final attempt = _GuangyaSmsAttempt(http);
    final data = await attempt.post(
      '/v1/auth/verification',
      {'phone_number': '+86 $mobile', 'target': 'ANY'},
      mobile: mobile,
      verifyCaptcha: verifyCaptcha,
      onStatus: onStatus,
    );
    require(
      WebTokens.validToken(data.str('verification_id')),
      '光鸭未返回短信验证信息，请稍后重试',
    );
    final seconds = data.integer('expires_in', 600).clamp(1, 1800);
    return GuangyaSmsChallenge(
      mobile: mobile,
      verificationId: data.str('verification_id'),
      isUser: switch (data['is_user']) {
        true || 'true' || 1 => true,
        false || 'false' || 0 => false,
        _ => null,
      },
      device: attempt.device,
      sign: attempt.sign,
      expiresAt: now() + seconds * 1000,
    );
  }

  Future<Credential> sms(
    GuangyaSmsChallenge challenge,
    String code, {
    GuangyaCaptchaPrompt? verifyCaptcha,
    void Function(String)? onStatus,
  }) async {
    require(now() < challenge.expiresAt, '短信验证码已过期，请重新获取');
    require(RegExp(r'^[0-9]{4,8}$').hasMatch(code.trim()), '请输入正确的短信验证码');
    final attempt = _GuangyaSmsAttempt(
      http,
      device: challenge.device,
      sign: challenge.sign,
    );
    onStatus?.call('正在校验短信验证码…');
    final verification = await attempt.post('/v1/auth/verification/verify', {
      'verification_id': challenge.verificationId,
      'verification_code': code.trim(),
    });
    final token = verification.str('verification_token');
    require(WebTokens.validToken(token), '光鸭未返回有效验证凭据，请重新获取验证码');
    onStatus?.call('正在登录光鸭云盘…');
    Future<Json> authenticate({required bool register}) => attempt.post(
      register ? '/v1/auth/signup' : '/v1/auth/signin',
      {
        if (!register) 'username': '+86 ${challenge.mobile}',
        if (register) ...{
          'phone_number': '+86 ${challenge.mobile}',
          'name':
              '${challenge.mobile.substring(0, 3)}****${challenge.mobile.substring(7)}',
        },
        'verification_code': code.trim(),
        'verification_token': token,
      },
      mobile: register ? null : challenge.mobile,
      verifyCaptcha: verifyCaptcha,
      onStatus: onStatus,
    );
    Future<Json> signInOrRegister() async {
      try {
        return await authenticate(register: challenge.isUser == false);
      } on _GuangyaSmsError catch (error) {
        // New verification responses omit is_user. Only an explicit signin
        // account error may register; captcha, code and transport errors cannot.
        if (challenge.isUser != null || !error.unregistered) rethrow;
        RequestScope.checkpoint();
        require(now() < challenge.expiresAt, '短信验证码已过期，请重新获取');
        return authenticate(register: true);
      }
    }

    final data = await signInOrRegister();
    final seconds = data.integer('expires_in');
    final fields = WebTokens.fields(
      CloudPlatform.guangya,
      jsonEncode({
        ...data,
        'device_id': challenge.device,
        'device_sign': challenge.sign,
        if (seconds > 0 && seconds <= 31536000)
          'expires_at': now() + seconds * 1000,
      }),
    );
    require(
      fields['accessToken']?.isNotEmpty == true &&
          fields['refreshToken']?.isNotEmpty == true,
      '光鸭未返回完整登录凭据，请切换网页登录',
    );
    return Credential(CloudPlatform.guangya.label, {
      ...fields,
      'username': challenge.mobile,
    });
  }
}

class _GuangyaSmsError extends AppException {
  const _GuangyaSmsError(super.message, this.path, this.status, this.error);
  final String path, error;
  final int status;

  bool get unregistered =>
      path == '/v1/auth/signin' &&
      status >= 400 &&
      status < 500 &&
      status != 429 &&
      error == 'user_not_found';
}

class _GuangyaSmsAttempt {
  _GuangyaSmsAttempt(this.http, {String? device, String? sign})
    : device = device ?? newId().replaceAll('-', ''),
      sign =
          sign ??
          'wdi10.${newId().replaceAll('-', '')}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
  final JsonHttp http;
  final String device, sign;

  Future<Json> _request(String path, Json body, [String captcha = '']) async {
    RequestScope.checkpoint();
    final response = await http.request(
      'POST',
      '${GuangyaLoginProtocol.origin}$path',
      headers: {
        'User-Agent': WebLoginTarget.desktopUserAgent,
        'Origin': GuangyaLoginProtocol.web,
        'Referer': '${GuangyaLoginProtocol.web}/',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN',
        ...GuangyaLoginProtocol.deviceHeaders(device, sign),
        if (captcha.isNotEmpty) 'X-Captcha-Token': captcha,
      },
      body: jsonEncode({'client_id': GuangyaLoginProtocol.clientId, ...body}),
      contentType: 'application/json; charset=utf-8',
      followRedirects: false,
    );
    RequestScope.checkpoint();
    final data = response.json;
    if (!response.successful || data.str('error').isNotEmpty) {
      throw _GuangyaSmsError(
        response.status == 429 || data.str('error') == 'too_many_requests'
            ? '验证码请求过于频繁，请稍后重试'
            : switch (data.str('error')) {
                'captcha_required' ||
                'captcha_invalid' => '光鸭安全验证未通过，请重试或切换网页登录',
                'invalid_verification_code' ||
                'verification_code_invalid' ||
                'verification_expired' ||
                'invalid_verification_token' => '短信验证码错误或已过期，请重新获取',
                _ =>
                  path.endsWith('/verification')
                      ? '短信发送失败，请稍后重试或切换网页登录'
                      : '光鸭短信验证失败，请检查验证码或切换网页登录',
              },
        path,
        response.status,
        data.str('error'),
      );
    }
    return data;
  }

  Future<Json> post(
    String path,
    Json body, {
    String? mobile,
    GuangyaCaptchaPrompt? verifyCaptcha,
    void Function(String)? onStatus,
  }) async {
    var captcha = '';
    if (mobile != null) {
      final shield = await _request('/v1/shield/captcha/init', {
        'action': 'POST:$path',
        'device_id': GuangyaLoginProtocol.accountDevice(device, sign),
        'captcha_token': '',
        'meta': {'phone_number': '+86 $mobile'},
      });
      captcha = shield.str('captcha_token');
      if (shield.str('url').isNotEmpty) {
        require(verifyCaptcha != null, '光鸭需要安全验证，请在登录页面继续');
        onStatus?.call('请完成光鸭安全验证');
        captcha =
            await RequestScope.cancellable(
              verifyCaptcha!(GuangyaCaptchaChallenge(shield.str('url'))),
            ) ??
            '';
        require(captcha.isNotEmpty, '已取消安全验证');
      }
      require(WebTokens.validToken(captcha), '光鸭安全验证凭据无效，请重试');
    }
    return _request(path, body, captcha);
  }
}

/// Uses the official web client's account and captcha endpoints. A fresh device
/// and token candidate are used for every attempt, never the saved account.
class GuangyaPasswordLogin {
  GuangyaPasswordLogin(this.http, {int Function()? now})
    : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final JsonHttp http;
  final int Function() now;

  static String _error(HttpResult response, Json data) {
    if (response.status == 429 || data.str('error') == 'too_many_requests') {
      return '光鸭登录尝试过于频繁，请稍后重试';
    }
    return switch (data.str('error')) {
      'invalid_password' ||
      'invalid_account_or_password' ||
      'invalid_credentials' ||
      'unauthenticated' ||
      'user_not_found' => '光鸭账号或密码不正确，请检查后重试',
      'password_required' || 'password_not_set' => '该光鸭账号尚未设置密码，请切换网页登录',
      'verification_required' ||
      'verification_code_required' => '光鸭需要短信验证，请切换网页登录继续',
      'captcha_required' || 'captcha_invalid' => '光鸭安全验证未通过，请重试或切换网页登录',
      _ => '光鸭登录失败，请检查账号密码，或切换网页登录',
    };
  }

  Future<Credential> password(
    String username,
    String password, {
    GuangyaCaptchaPrompt? verifyCaptcha,
    void Function(String)? onStatus,
  }) async {
    final account = GuangyaLoginProtocol.username(username);
    require(account.isNotEmpty && password.isNotEmpty, '请输入光鸭账号和密码');
    require(account.length <= 254 && password.length <= 256, '账号或密码过长');
    final device = newId().replaceAll('-', '');
    final sign =
        'wdi10.${newId().replaceAll('-', '')}xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
    final headers = {
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN',
      'User-Agent': WebLoginTarget.desktopUserAgent,
      'Origin': GuangyaLoginProtocol.web,
      'Referer': '${GuangyaLoginProtocol.web}/',
      ...GuangyaLoginProtocol.deviceHeaders(device, sign),
    };
    Future<(HttpResult, Json)> post(
      String path,
      Json body, [
      String captcha = '',
    ]) async {
      RequestScope.checkpoint();
      final response = await http.request(
        'POST',
        '${GuangyaLoginProtocol.origin}$path',
        body: jsonEncode(body),
        headers: {
          ...headers,
          if (captcha.isNotEmpty) 'X-Captcha-Token': captcha,
        },
        contentType: 'application/json; charset=utf-8',
        followRedirects: false,
      );
      RequestScope.checkpoint();
      return (response, response.json);
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      onStatus?.call('正在连接光鸭账号…');
      final (shieldResponse, shield) = await post('/v1/shield/captcha/init', {
        'client_id': GuangyaLoginProtocol.clientId,
        'action': 'POST:/v1/auth/signin',
        'device_id': GuangyaLoginProtocol.accountDevice(device, sign),
        'captcha_token': '',
        'meta': {
          account.startsWith('+')
                  ? 'phone_number'
                  : account.contains('@')
                  ? 'email'
                  : 'username':
              account,
        },
      });
      require(
        shieldResponse.successful && shield.str('error').isEmpty,
        _error(shieldResponse, shield),
      );
      var captcha = shield.str('captcha_token');
      if (shield.str('url').isNotEmpty) {
        require(verifyCaptcha != null, '光鸭需要安全验证，请在登录页面继续');
        onStatus?.call('请完成光鸭安全验证');
        captcha =
            await RequestScope.cancellable(
              verifyCaptcha!(GuangyaCaptchaChallenge(shield.str('url'))),
            ) ??
            '';
        require(captcha.isNotEmpty, '已取消安全验证');
      }
      require(WebTokens.validToken(captcha), '光鸭安全验证凭据无效，请重试');
      RequestScope.checkpoint();
      onStatus?.call('正在验证账号…');
      final (response, data) = await post('/v1/auth/signin', {
        'client_id': GuangyaLoginProtocol.clientId,
        'username': account,
        'password': password,
      }, captcha);
      if (attempt == 0 &&
          {'captcha_required', 'captcha_invalid'}.contains(data.str('error'))) {
        continue;
      }
      require(
        response.successful && data.str('error').isEmpty,
        _error(response, data),
      );
      final expiry = data.integer('expires_in');
      final fields = WebTokens.fields(
        CloudPlatform.guangya,
        jsonEncode({
          ...data,
          'device_id': device,
          'device_sign': sign,
          if (expiry > 0 && expiry <= 31536000)
            'expires_at': now() + expiry * 1000,
        }),
      );
      require(
        fields['accessToken']?.isNotEmpty == true &&
            fields['refreshToken']?.isNotEmpty == true,
        '光鸭未返回完整登录凭据，请切换网页登录',
      );
      return Credential(CloudPlatform.guangya.label, {
        ...fields,
        'username': username.trim(),
      });
    }
    throw const AppException('光鸭安全验证失败，请切换网页登录');
  }
}
