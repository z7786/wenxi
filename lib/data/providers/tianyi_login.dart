import 'dart:async';
import '../../core/json.dart';
import '../../core/login_crypto.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../http.dart';
import '../login_cookies.dart';
import 'tianyi.dart';
import 'tianyi_captcha.dart';

typedef TianyiCaptchaPrompt =
    Future<TianyiCaptchaProof?> Function(TianyiCaptchaClient);
typedef TianyiSmsPrompt = Future<String?> Function(TianyiSmsChallenge);

/// Uses the official account API without creating a WebView. A successful
/// password login returns credentials for local storage and later renewal.
class TianyiLoginService {
  TianyiLoginService(this.http, this.connector);
  final JsonHttp http;
  final TianyiConnector connector;

  Future<LoginResult> password(
    String username,
    String password, {
    TianyiCaptchaPrompt? verifyCaptcha,
    TianyiSmsPrompt? verifySms,
    void Function(String)? onStatus,
  }) async {
    final account = username.trim();
    require(account.isNotEmpty && password.isNotEmpty, '请输入天翼账号和密码');
    require(account.length <= 254 && password.length <= 256, '账号或密码过长');
    final session = _TianyiLoginSession(http);
    try {
      return await session.run(() async {
        onStatus?.call('正在连接天翼账号…');
        await session.prepare();
        final encryptedUser = session.encrypt(account),
            encryptedPassword = session.encrypt(password);
        TianyiCaptchaProof? proof;
        Future<void> captcha() async {
          require(verifyCaptcha != null, '天翼需要安全验证，请使用账号密码登录页面完成验证');
          onStatus?.call('请完成安全验证');
          proof = await verifyCaptcha!(
            TianyiCaptchaClient(
              request: (uri) => session.request('GET', uri),
              referer: session.page.toString(),
              appId: session.config.str('appKey'),
              checkpoint: session.checkpoint,
              cancel: session.cancel,
            ),
          );
          session.checkpoint();
          require(proof != null, '已取消登录');
        }

        final need = await session.post('oauth2/needcaptcha.do', {
          'accountType': session.config.str('accountType'),
          'userName': session.encrypt(
            session.config.str('accountType') == '01'
                ? account
                : '$account${session.config.str('mailSuffix')}',
          ),
          'appKey': session.config.str('appKey'),
        });
        require(
          need.successful && {'0', '1'}.contains(need.body.trim()),
          '天翼验证码状态读取失败，请稍后重试',
        );
        if (need.body.trim() == '1') await captcha();
        for (var attempt = 0; attempt < 3; attempt++) {
          session.checkpoint();
          onStatus?.call('正在验证账号…');
          final result = session.json(
            await session.post('oauth2/loginSubmit.do', {
              ...session.loginFields,
              'version': 'v2.0',
              'apToken': '',
              'userName': encryptedUser,
              'epd': encryptedPassword,
              'dynamicCheck': 'FALSE',
              if (proof != null) ...{
                'captchaType': proof!.type,
                'captchaToken': proof!.token,
                'validateCode': proof!.validate,
                'smsValidateCode': proof!.validate,
              },
            }),
          );
          session.checkpoint();
          final code = result.integer('result', -99999);
          String target;
          if (code == 0) {
            target = result.str('toUrl');
          } else if ({-2, -1101}.contains(code) && attempt < 2) {
            await captcha();
            continue;
          } else if (code == -133) {
            require(verifySms != null, '天翼要求短信验证，请在账号密码登录页面继续验证');
            onStatus?.call('请完成短信验证');
            target =
                await verifySms!(
                  TianyiSmsChallenge._(session, account, result),
                ) ??
                '';
            session.checkpoint();
            require(target.isNotEmpty, '已取消登录');
          } else {
            throw AppException(_loginError(code));
          }
          onStatus?.call('正在读取网盘账号…');
          await session.follow(Uri.parse(target));
          session.checkpoint();
          final cookie = session.cookies.header(
            Uri.parse(
              '${TianyiConnector.origin}/api/open/user/getUserInfoForPortal.action',
            ),
          );
          require(
            LoginCredentials.plausible(CloudPlatform.tianyi, cookie),
            '天翼尚未返回有效云盘登录状态，请重新登录',
          );
          final login = await connector.authenticate(
            Credential(CloudPlatform.tianyi.label, {
              'primary': cookie,
              'authType': 'passwordCookie',
              'username': account,
              'password': password,
            }),
          );
          session.checkpoint();
          return login;
        }
        throw const AppException('天翼安全验证未完成，请重新登录');
      });
    } finally {
      session.close();
    }
  }
}

String _loginError(int code) => switch (code) {
  -2 || -1101 => '天翼安全验证未通过，请重新登录',
  -135 || -136 || -20099 => '天翼登录验证已过期，请重新登录',
  -134 => '天翼要求进一步验证账号身份，请切换网页登录完成验证',
  68 || -3 || -70 => '天翼暂时限制了当前网络的登录，请稍后重试',
  -66 || 51323 => '天翼登录错误次数已达上限，请稍后重试或在官方客户端找回密码',
  51014 || -30199 || -51317 || -4 || 51317 => '天翼要求先更新账号密码，请在官方客户端修改后重试',
  51179 || 51325 || -151 => '天翼账号已被冻结或限制，请在官方客户端检查账号状态',
  51175 || 51176 => '短信验证码已失效，请重新获取',
  51177 => '短信验证码错误，请重新输入',
  -51009 ||
  -1000 ||
  -5 ||
  500 ||
  51003 ||
  51004 ||
  51009 ||
  -64 => '天翼登录服务暂时不可用，请稍后重试',
  51002 ||
  -51002 ||
  -16 ||
  -150 ||
  -149 ||
  -17 ||
  -15 ||
  -10 ||
  -9 ||
  -1 ||
  51001 ||
  51005 ||
  51101 ||
  -69 => '天翼账号或密码错误，请检查后重试',
  _ => '天翼登录未完成，请稍后重试（$code）',
};

class TianyiSmsChallenge {
  TianyiSmsChallenge._(this._session, this._username, this._result);
  final _TianyiLoginSession _session;
  final String _username;
  final Json _result;
  DateTime? _lastSent;
  bool _finished = false;
  String get phoneHint {
    final value = _result.str('showName');
    return RegExp(r'^[+0-9*•· -]{3,40}$').hasMatch(value)
        ? value
        : '当前账号绑定的手机号';
  }

  int get resendSeconds {
    final sent = _lastSent;
    return sent == null
        ? 0
        : (60 - DateTime.now().difference(sent).inSeconds).clamp(0, 60);
  }

  void cancel() => _session.cancel();

  Future<void> sendCode() async {
    _session.checkpoint();
    require(!_finished, '短信验证已完成');
    require(resendSeconds == 0, '请稍后再获取验证码');
    final mobile = _result.str('mobile');
    require(mobile.isNotEmpty && mobile.length <= 8192, '天翼未返回有效短信验证信息，请重新登录');
    // Reserve the cooldown before sending: a network timeout may still send SMS.
    _lastSent = DateTime.now();
    final result = _session.json(
      await _session.post('oauth2/sendSmsCodeForSecondAuth.do', {
        'mobile': mobile,
        'appKey': _session.config.str('appKey'),
      }),
    );
    final code = result.integer('result', -99999);
    require(code == 0, switch (code) {
      20104 || 51129 => '验证码发送次数过多，请稍后再试',
      20107 => '天翼账号绑定的手机号无效，请先在官方客户端检查',
      -10320 => '天翼暂不支持此账号的短信验证，请在官方客户端检查账号',
      _ => _loginError(code),
    });
  }

  /// Returns the official completion URL only after the server verifies SMS.
  Future<String> verify(String code) async {
    _session.checkpoint();
    require(!_finished, '短信验证已完成');
    require(RegExp(r'^\d{4,8}$').hasMatch(code.trim()), '请输入有效的短信验证码');
    final result = _session.json(
      await _session.post('oauth2/submitForSecondAuth.do', {
        ..._session.loginFields,
        'mobile': _result.str('mobile'),
        'userName': _result.str('romaSecondAuth') == 'true'
            ? _username
            : _session.encrypt(_username),
        'epd': _session.encrypt(code.trim()),
      }),
    );
    final resultCode = result.integer('result', -99999);
    require(resultCode == 0, _loginError(resultCode));
    final target = result.str('toUrl');
    require(_TianyiLoginSession.trusted(Uri.tryParse(target)), '天翼登录回调地址无效');
    _finished = true;
    return target;
  }
}

class _TianyiLoginSession {
  _TianyiLoginSession(this.http) {
    final parent = RequestScope.current;
    if (parent?.isCancelled == true) cancel();
    unawaited(
      parent?.whenCancel.then((_) {
        if (!_closed) cancel();
      }),
    );
  }
  final JsonHttp http;
  final cookies = LoginCookieJar({
    'cloud.189.cn',
    'open.e.189.cn',
    'e.189.cn',
    '189.cn',
  });
  final _scope = RequestScope();
  bool _closed = false;
  late Uri page;
  Json config = {};
  late LoginRsa _rsa;
  String _prefix = '';
  Map<String, String> _headers = {};

  Future<T> run<T>(Future<T> Function() action) => _scope.run(action);
  void checkpoint() {
    require(!_closed && !_scope.token.isCancelled, '已取消登录');
    RequestScope.checkpoint();
  }

  void cancel() => _scope.cancel();
  void close() {
    _closed = true;
    cancel();
    cookies.clear();
    config.clear();
    _headers.clear();
  }

  static bool trusted(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      {'cloud.189.cn', 'open.e.189.cn'}.contains(uri.host);

  Future<HttpResult> request(String method, Uri uri, {String? body}) =>
      run(() async {
        checkpoint();
        require(trusted(uri), '天翼返回了无效的登录地址，请稍后重试');
        final cookie = cookies.header(uri);
        final response = await http.request(
          method,
          uri.toString(),
          body: body,
          headers: {
            'User-Agent': TianyiConnector.webUa,
            'Accept': 'application/json, text/plain, */*',
            if (uri.host == 'open.e.189.cn') ...{
              'Origin': 'https://open.e.189.cn',
              ..._headers,
            },
            if (cookie.isNotEmpty) 'Cookie': cookie,
          },
          contentType: body == null
              ? null
              : 'application/x-www-form-urlencoded; charset=utf-8',
          followRedirects: false,
        );
        checkpoint();
        cookies.absorb(uri, response);
        return response;
      });

  Future<Uri> follow(Uri first) async {
    var uri = first;
    final visited = <String>{};
    for (var redirects = 0; redirects < 8; redirects++) {
      require(trusted(uri) && visited.add(uri.toString()), '天翼登录跳转无效，请重试');
      final response = await request('GET', uri);
      if ({301, 302, 303, 307, 308}.contains(response.status)) {
        final location = response.header('location');
        require(location.isNotEmpty, '天翼登录跳转信息不完整，请重试');
        uri = uri.resolve(location);
      } else {
        require(response.successful, '天翼登录服务连接失败，请稍后重试');
        return uri;
      }
    }
    throw const AppException('天翼登录跳转次数过多，请重试');
  }

  Future<HttpResult> post(String path, Json fields) => request(
    'POST',
    Uri.parse('https://open.e.189.cn/api/logbox/$path'),
    body: form(fields),
  );

  Json json(HttpResult response) {
    checkpoint();
    require(
      response.successful && response.body.length <= 65536,
      '天翼登录服务响应异常，请稍后重试',
    );
    return response.json;
  }

  Future<void> prepare() async {
    page = await follow(
      Uri.parse(
        query('${TianyiConnector.origin}/api/portal/loginUrl.action', {
          'redirectURL': '${TianyiConnector.origin}/web/redirect.html',
          'defaultSaveName': '3',
          'defaultSaveNameCheck': 'uncheck',
        }),
      ),
    );
    final parameters = page.queryParameters;
    require(
      page.host == 'open.e.189.cn' && parameters['appId'] == 'cloud',
      '天翼登录入口响应异常，请重试',
    );
    for (final name in ['lt', 'reqId']) {
      final value = parameters[name] ?? '';
      require(
        value.isNotEmpty &&
            value.length <= 4096 &&
            !RegExp(r'[\x00-\x20\x7f]').hasMatch(value),
        '天翼登录参数不完整，请重试',
      );
    }
    _headers = {
      'lt': parameters['lt']!,
      'reqId': parameters['reqId']!,
      'Referer': page.toString(),
    };
    final app = json(
      await post('oauth2/appConf.do', {'version': '2.0', 'appKey': 'cloud'}),
    );
    require(app.str('result') == '0', '天翼登录配置已失效，请重试');
    config = app.obj('data');
    require(
      config.str('appKey') == 'cloud' &&
          config.str('accountType').isNotEmpty &&
          config.str('paramId').isNotEmpty &&
          trusted(Uri.tryParse(config.str('returnUrl'))) &&
          Uri.parse(config.str('returnUrl')).host == 'cloud.189.cn',
      '天翼登录配置不完整，请重试',
    );
    final encryption = json(
      await post('config/encryptConf.do', {'appId': 'cloud'}),
    );
    require(encryption.str('result') == '0', '天翼登录加密参数获取失败，请重试');
    _prefix = encryption.obj('data').str('pre');
    require(
      RegExp(r'^\{[A-Za-z0-9_-]{1,16}\}$').hasMatch(_prefix),
      '天翼登录加密格式已变化，请稍后重试',
    );
    _rsa = LoginRsa(encryption.obj('data').str('pubKey'));
  }

  String encrypt(String value) => '$_prefix${_rsa.encryptTianyi(value)}';
  Json get loginFields => {
    'appKey': config.str('appKey'),
    'pageKey': config.str('pageKey'),
    'accountType': config.str('accountType'),
    'mailSuffix': config.str('mailSuffix'),
    'clientType': config['clientType'],
    'isOauth2': config['isOauth2'],
    'returnUrl': Uri.encodeComponent(config.str('returnUrl')),
    'cb_SaveName': '0',
    'state': config.str('state'),
    'paramId': config.str('paramId'),
  };
}
