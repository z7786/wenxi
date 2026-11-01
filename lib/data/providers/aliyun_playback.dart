import 'dart:convert';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/web_tokens.dart';
import '../http.dart';
import '../http_retry.dart';
import 'token_session.dart';

class AliyunPlaybackApiException extends AppException {
  const AliyunPlaybackApiException(
    super.message,
    this.code, {
    required this.status,
  });

  final String code;
  final int status;
  bool get fileUnavailable => const {
    'NotFound.FileId',
    'NotFound.DriveId',
    'ForbiddenFileInTheRecycleBin',
  }.contains(code);
}

/// Ordinary login tokens authorize an OpenList OAuth application at Aliyun.
/// Only the authorization code goes to OpenList; media APIs use the resulting
/// open-platform token at Aliyun. Both credentials retain the same saved owner.
class AliyunPlaybackApi {
  AliyunPlaybackApi(
    this.http,
    this.sessions, {
    required this.renew,
    required this.userAgent,
    this.wait = RequestScope.wait,
  });

  final JsonHttp http;
  final TokenSessions sessions;
  final Future<void> Function(TokenSession) renew;
  final String userAgent;
  final Future<void> Function(Duration) wait;
  final _authorizationGate = AsyncGate();

  static const api = 'https://open.aliyundrive.com/adrive/v1.0';
  static const oauth = 'https://api.oplist.org/alicloud';
  static const callback = '$oauth/callback';
  static const scope = 'user:base,file:all:read,file:all:write';
  static const referer = 'https://www.aliyundrive.com/';

  bool _fresh(TokenSession session) =>
      WebTokens.validToken(session.field('openAccessToken')) &&
      (session.field('openUserId').isEmpty ||
          session.field('userId').isEmpty ||
          session.field('openUserId') == session.field('userId')) &&
      (int.tryParse(session.field('openExpiresAt')) ?? 0) >
          sessions.now() + 120000;

  Future<void> fresh(TokenSession session, {String? rejectedAccess}) async {
    bool usable() =>
        _fresh(session) &&
        (rejectedAccess == null ||
            session.field('openAccessToken') != rejectedAccess);
    sessions.checkpoint(session);
    if (usable()) return;
    await RequestScope.cancellable(
      _authorizationGate.run(() async {
        sessions.checkpoint(session);
        if (usable()) return;
        await _authorize(session);
        sessions.checkpoint(session);
      }),
    );
  }

  Json _json(HttpResult response, String service) {
    require(response.body.length <= 512 * 1024, '$service响应过大，请稍后重试');
    try {
      return response.json;
    } on AppException {
      if (response.status == 401) return {};
      throw AliyunPlaybackApiException(
        '$service返回异常（HTTP ${response.status}）',
        'InvalidResponse',
        status: response.status,
      );
    }
  }

  bool _authExpired(HttpResult response, Json data) =>
      response.status == 401 ||
      const {
        'AccessTokenInvalid',
        'AccessTokenExpired',
        'InvalidAccessToken',
        'InvalidParameter.AccessToken',
        'InvalidToken',
      }.contains(data.str('code'));

  Json _checked(HttpResult response, Json data, String service) {
    final code = data.str('code');
    if (response.successful &&
        (code.isEmpty || code == '0') &&
        data['success'] != false) {
      return data;
    }
    // Responses and callback URLs can contain credentials. Keep them out of
    // exception text, which can be displayed or included in diagnostic exports.
    final safeCode = RegExp(r'^[A-Za-z0-9._-]{1,80}$').hasMatch(code)
        ? code
        : '';
    final message = switch (safeCode) {
      'NotFound.FileId' => '阿里云盘文件已移动或删除',
      'NotFound.DriveId' => '当前阿里存储空间不可访问，请重新打开文件列表',
      'ForbiddenFileInTheRecycleBin' => '文件已在回收站中',
      'QuotaExhausted.Drive' => '阿里云盘空间不足',
      'TooManyRequests' => '$service请求过于频繁，请稍后重试',
      _ => '$service请求失败（HTTP ${response.status}）',
    };
    throw AliyunPlaybackApiException(
      message,
      safeCode,
      status: response.status,
    );
  }

  Uri? _callbackUri(String value) {
    if (value.length > 8192 || RegExp(r'[\x00-\x20\x7f]').hasMatch(value)) {
      return null;
    }
    final uri = Uri.tryParse(value);
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host == 'api.oplist.org' &&
            uri.port == 443 &&
            uri.userInfo.isEmpty &&
            uri.path == '/alicloud/callback' &&
            !uri.hasFragment
        ? uri
        : null;
  }

  Future<void> _authorize(TokenSession session) async {
    await sessions.fresh(session, renew);
    final bootstrap = await http.request(
      'GET',
      query('$oauth/requests', {
        'driver': 'alicloud',
        'driver_txt': 'alicloud_go',
        'server_use': 'true',
      }),
      headers: {'User-Agent': userAgent},
      followRedirects: false,
    );
    sessions.checkpoint(session);
    final configuration = _checked(
      bootstrap,
      _json(bootstrap, 'OpenList 授权服务'),
      'OpenList 授权服务',
    );
    final address = configuration.str('text');
    final authorization = Uri.tryParse(address);
    require(
      address.length <= 8192 &&
          !RegExp(r'[\x00-\x20\x7f]').hasMatch(address) &&
          authorization != null &&
          authorization.scheme == 'https' &&
          {
            'openapi.aliyundrive.com',
            'open.aliyundrive.com',
          }.contains(authorization.host) &&
          authorization.port == 443 &&
          authorization.userInfo.isEmpty &&
          authorization.path == '/oauth/authorize' &&
          !authorization.hasFragment,
      'OpenList 未返回有效的阿里授权地址，请稍后重试',
    );
    final parameters = authorization!.queryParameters;
    final client = parameters['client_id'] ?? '';
    final redirect = _callbackUri(parameters['redirect_uri'] ?? '');
    final state = parameters['state'] ?? '';
    require(
      RegExp(r'^[A-Za-z0-9._-]{1,256}$').hasMatch(client) &&
          redirect != null &&
          !redirect.hasQuery &&
          state.length <= 2048 &&
          !RegExp(r'[\x00-\x1f\x7f]').hasMatch(state),
      'OpenList 返回的阿里授权参数无效，请稍后重试',
    );

    String code = '';
    for (var attempt = 0; attempt < 2; attempt++) {
      sessions.checkpoint(session);
      final access = session.access;
      final response = await http.mutationRequest(
        'POST',
        query('https://open.aliyundrive.com/oauth/users/authorize', {
          'client_id': client,
          'redirect_uri': callback,
          'scope': scope,
          if (state.isNotEmpty) 'state': state,
          'response_type': 'code',
        }),
        body: encoded({'authorize': 1, 'scope': scope}),
        headers: {
          'Authorization': 'Bearer $access',
          'User-Agent': userAgent,
          'Referer': referer,
        },
        contentType: 'application/json; charset=utf-8',
        followRedirects: false,
      );
      sessions.checkpoint(session);
      final data = _json(response, '阿里开放授权');
      if (_authExpired(response, data)) {
        if (attempt == 0 && session.refresh.isNotEmpty) {
          await sessions.fresh(
            session,
            renew,
            force: true,
            rejectedAccess: access,
          );
          continue;
        }
        throw const AccountLoginRequired('阿里云盘登录已过期，请重新网页登录');
      }
      _checked(response, data, '阿里开放授权');
      final returned = _callbackUri(data.str('redirectUri'));
      require(
        returned != null &&
            (state.isEmpty || returned.queryParameters['state'] == state),
        '阿里未返回有效的开放授权结果，请稍后重试',
      );
      code = returned!.queryParameters['code'] ?? '';
      require(
        RegExp(r'^[A-Za-z0-9._~-]{1,512}$').hasMatch(code),
        '阿里未返回开放授权码，请稍后重试',
      );
      break;
    }

    // The code is single-use. A network retry must start a new authorization
    // rather than replaying this exchange or following its credential fragment.
    final exchange = await http.mutationRequest(
      'GET',
      query(callback, {'code': code}),
      headers: {
        'Cookie': 'server_use=true; driver_txt=alicloud_go',
        'User-Agent': userAgent,
      },
      followRedirects: false,
    );
    sessions.checkpoint(session);
    final location = exchange.header('location');
    require(
      {301, 302, 303, 307, 308}.contains(exchange.status) &&
          location.length <= 96 * 1024,
      'OpenList 授权换取失败，请稍后重试',
    );
    Json tokens;
    try {
      final fragment = Uri.parse(location).fragment;
      require(fragment.isNotEmpty && fragment.length <= 64 * 1024, '授权结果无效');
      final decoded = jsonDecode(utf8.decode(base64.decode(fragment)));
      require(decoded is Map, '授权结果无效');
      tokens = asJson(decoded);
    } catch (_) {
      throw const AppException('OpenList 未返回有效的阿里开放凭据，请稍后重试');
    }
    final access = tokens.str('access_token');
    final refresh = tokens.str('refresh_token');
    final type = tokens.str('token_type', 'Bearer');
    require(
      WebTokens.validToken(access) &&
          (refresh.isEmpty || WebTokens.validToken(refresh)) &&
          type.toLowerCase() == 'bearer',
      'OpenList 返回的阿里开放凭据无效，请稍后重试',
    );
    sessions.checkpoint(session);
    final userId = tokens.str('user_id');
    require(
      userId.isEmpty ||
          session.field('userId').isEmpty ||
          userId == session.field('userId'),
      '阿里开放授权账号不一致，请重新登录',
    );
    var expires = WebTokens.epochMilliseconds(tokens.str('expire_time'));
    if (expires == 0) {
      final seconds = tokens.integer('expires_in', 7200);
      expires = sessions.now() + seconds * 1000;
    }
    require(expires > sessions.now() + 120000, '阿里开放授权已过期，请重新播放');
    await sessions.update(session, {
      'openAccessToken': access,
      'openRefreshToken': refresh,
      'openTokenType': 'Bearer',
      'openExpiresAt': '$expires',
      'openUserId': userId,
    });
  }

  Future<Json> request(
    TokenSession session,
    String path,
    Json body, {
    bool read = true,
  }) async {
    await fresh(session);
    var renewed = false, throttled = 0;
    while (true) {
      sessions.checkpoint(session);
      final access = session.field('openAccessToken');
      final response = await (read ? http.readRequest : http.mutationRequest)(
        'POST',
        '$api/$path',
        body: encoded(body),
        headers: {
          'Authorization': 'Bearer $access',
          'User-Agent': userAgent,
          'Referer': referer,
        },
        contentType: 'application/json; charset=utf-8',
        followRedirects: false,
      );
      sessions.checkpoint(session);
      if (read &&
          response.status == 429 &&
          ReadRetryScope.current == null &&
          throttled < 3) {
        throttled++;
        await wait(const Duration(seconds: 1));
        continue;
      }
      final data = _json(response, '阿里开放接口');
      if (_authExpired(response, data)) {
        if (!renewed) {
          renewed = true;
          await fresh(session, rejectedAccess: access);
          continue;
        }
        throw const AppException('阿里开放授权暂不可用，请稍后重新播放');
      }
      return _checked(response, data, '阿里开放接口');
    }
  }
}
