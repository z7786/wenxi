import 'dart:convert';
import 'package:html/parser.dart' as html;
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/ctfile_captcha.dart';
import '../../domain/links.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../login_cookies.dart';
import '../uploads/upload_io.dart';
import 'token_session.dart' show checkedCloudUrl;
import 'ctfile_web.dart';

typedef CtfileCaptchaPrompt =
    Future<CtfileCaptchaProof?> Function(CtfileCaptchaChallenge);

/// Official REST API: https://openapi.ctfile.com/ . Public shares use the
/// website API, which also reports guest restrictions and download wait times.
class CtfileConnector extends CloudConnector {
  CtfileConnector(this.http) : _web = CtfileWeb(http);
  final JsonHttp http;
  final CtfileWeb _web;
  static const rest = 'https://rest.ctfile.com/v1';
  static const web = 'https://webapi.ctfile.com';
  static const headers = {
    'User-Agent': WebLoginTarget.desktopUserAgent,
    'Referer': 'https://www.ctfile.com/',
  };
  @override
  CloudPlatform get platform => CloudPlatform.ctfile;

  Json _checked(HttpResult response) {
    RequestScope.checkpoint();
    if (response.status == 401) {
      throw const AccountLoginRequired('城通登录已过期，请重新登录');
    }
    final data = response.json;
    final code = data.integer('code', -1);
    final message = data
        .str('message')
        .ifEmpty(data.obj('file').str('message'));
    if (code == 401) {
      throw AccountLoginRequired(message.ifEmpty('城通登录已过期，请重新登录'));
    }
    if (code == 423) throw AppException(message.ifEmpty('请输入正确的城通分享访问密码'));
    require(
      response.successful && code == 200,
      message.ifEmpty(code < 0 ? '城通响应缺少状态码，请稍后重试' : '城通请求失败（$code）'),
    );
    return data;
  }

  String _session(Credential? c) {
    if (c == null) throw const AccountLoginRequired('请先登录城通网盘');
    return LoginCredentials.normalize(platform, c.primary);
  }

  Future<Json> _api(String path, Json body, {bool read = true}) async {
    RequestScope.checkpoint();
    return _checked(
      await (read ? http.postJsonRead : http.postJson)(
        '$rest/$path',
        body,
        headers,
      ),
    );
  }

  Future<LoginResult> password(
    String email,
    String password, {
    CtfileCaptchaPrompt? verifyCaptcha,
    void Function(String)? onStatus,
  }) async {
    require(email.contains('@') && password.isNotEmpty, '请输入注册邮箱和密码');
    final uri = Uri.parse(
      '${CtfileCaptchaChallenge.restOrigin}/p8/public/login/login?lang=zh-hans',
    );
    final cookies = LoginCookieJar({'ctfile.com', 'rest.ctfile.com'});
    const loginHeaders = {...headers, 'Accept-Language': 'zh-CN'};
    CtfileCaptchaProof? proof;
    var captchaType = 'image';
    Future<void> captcha(String message) async {
      require(verifyCaptcha != null, message);
      onStatus?.call('请完成城通安全验证');
      final challenge = CtfileCaptchaChallenge(
        captchaType,
        message: message,
        imageHeaders: {...loginHeaders, 'Cookie': cookies.header(uri)},
      );
      proof = await RequestScope.cancellable(verifyCaptcha!(challenge));
      RequestScope.checkpoint();
      require(proof != null, '已取消登录');
      require(proof!.belongsTo(challenge), '城通验证码已变化，请重新验证');
    }

    try {
      if (verifyCaptcha != null) {
        Json config = {};
        try {
          final response = await http.get(
            '${CtfileCaptchaChallenge.restOrigin}/p8/public/captcha/type?lang=zh-hans',
            loginHeaders,
          );
          cookies.absorb(uri, response);
          config = _checked(response);
        } on AppException {
          // A preflight unavailable on older servers can defer to login's
          // explicit captcha response. Cancellation still stops the attempt.
          RequestScope.checkpoint();
        }
        captchaType = config.str('captcha_type').ifEmpty(captchaType);
        if (config.boolean('always_required')) {
          await captcha('请完成城通安全验证');
        }
      }
      for (var attempt = 0; attempt < 3; attempt++) {
        RequestScope.checkpoint();
        onStatus?.call('正在验证城通账号…');
        final response = await http.postJson(
          uri.toString(),
          {
            'email': email.trim(),
            'password': password,
            'ref': '/',
            'country': 'CN',
            if (proof != null) ...proof!.fields,
          },
          {...loginHeaders, 'Cookie': cookies.header(uri)},
        );
        RequestScope.checkpoint();
        cookies.absorb(uri, response);
        final data = response.json;
        if (!response.successful || data.integer('code') != 200) {
          final error = data.str('error_code');
          final needsCaptcha =
              const {
                'LOGIN_CAPTCHA_REQUIRED',
                'LOGIN_CAPTCHA_WRONG',
                'LOGIN_CAPTCHA_TIMEOUT',
              }.contains(error) ||
              (error.isEmpty || error == 'LOGIN_FAILED') &&
                  data.boolean('require_captcha');
          final message = _passwordError(data, response.status);
          if (needsCaptcha && attempt < 2) {
            captchaType = data.str('captcha_type').ifEmpty(captchaType);
            await captcha(message);
            continue;
          }
          throw AppException(message);
        }
        onStatus?.call('正在读取城通网盘账号…');
        final cookie = cookies.header(
          Uri.parse('${CtfileWeb.base}/user/auth/exchange-token'),
        );
        if (LoginCredentials.cookiePairs(
          cookie,
        ).containsKey('ctfile_session')) {
          return await authenticate(
            Credential(platform.label, {
              'primary': cookie,
              'authType': 'webCookie',
            }),
          );
        }
        // Optional tracking cookies do not turn an OpenAPI session into a
        // website login. Only ctfile_session selects the v4 exchange route.
        final tokenValue = data.str('token').trim();
        require(tokenValue.isNotEmpty, '城通登录服务未返回登录信息');
        final token = LoginCredentials.normalize(platform, tokenValue);
        return await authenticate(
          Credential(platform.label, {'primary': token}),
        );
      }
      throw const AppException('城通安全验证未完成，请重新登录');
    } finally {
      cookies.clear();
    }
  }

  String _passwordError(Json data, int status) =>
      switch (data.str('error_code')) {
        'LOGIN_CAPTCHA_REQUIRED' => '城通需要安全验证，请完成验证后继续登录',
        'LOGIN_CAPTCHA_WRONG' => '城通验证码错误，请重新验证',
        'LOGIN_CAPTCHA_TIMEOUT' => '城通验证码已过期，请重新验证',
        'LOGIN_PASSWORD_WRONG' => '城通邮箱或密码错误，请检查后重试',
        'LOGIN_ACCOUNT_NOT_EXIST' => '城通账号不存在或异常，请检查注册邮箱',
        'LOGIN_ACCOUNT_LOCKED' => '城通账号存在安全限制，请在官网确认账号状态',
        'LOGIN_ACCOUNT_CLOSED' => '城通账号已被关闭，请联系城通客服',
        'LOGIN_PASSWORD_LENGTH' => '城通密码长度应为 6 至 30 个字符',
        'LOGIN_REQUIRE_QRSCAN' => '城通要求使用官方客户端扫码登录，请登录官网后导入 Session Token',
        'LOGIN_NO_PASSWORD' ||
        'LOGIN_PASSWORD_NOT_SET' ||
        'LOGIN_PASSWORD_SETUP_REQUIRED' => '城通账号尚未设置登录密码，请先在官网设置密码',
        'RATE_LIMIT' => '城通登录请求过于频繁，请稍后重试',
        _ =>
          data.boolean('require_captcha')
              ? '城通需要安全验证，请完成验证后继续登录'
              : data.str('message').isNotEmpty &&
                    data.str('message') != 'Login failed'
              ? data.str('message')
              : '城通登录失败，请稍后重试（HTTP $status）',
      };

  Future<LoginResult> authenticate(Credential c) async {
    if (CtfileWeb.accepts(c)) return _web.authenticate(c);
    final profile = await _api('user/info/profile', {'session': _session(c)});
    require(profile.str('userid').isNotEmpty, '城通未返回账号标识，请重新登录');
    final quota = await _api('user/info/quota', {'session': _session(c)});
    final account = CloudAccount(
      profile.str('nick_name').ifEmpty(profile.str('username').ifEmpty('城通用户')),
      used: quota.integer('space_used'),
      total: quota.integer('max_storage'),
    );
    return LoginResult(
      c.withFields({
        'userId': profile.str('userid'),
        'nickname': account.nickname,
      }),
      account,
    );
  }

  @override
  Future<CloudAccount> account(Credential credential) async =>
      (await authenticate(credential)).account;

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    if (CtfileWeb.accepts(credential)) return _web.open(credential);
    _session(credential);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的城通网盘',
      rootId: 'd0',
    );
  }

  @override
  Future<List<CloudSpace>> personalSpaces(Credential credential) async =>
      CtfileWeb.accepts(credential)
      ? _web.spaces(credential)
      : [const CloudSpace('legacy', '公开空间')];

  @override
  Future<BrowseSession> openPersonalSpace(
    CloudSpace space,
    Credential credential,
  ) async {
    if (CtfileWeb.accepts(credential)) return _web.open(credential, space);
    require(space.id == 'legacy', '城通存储空间不可用，请重新选择');
    return openPersonal(credential);
  }

  @override
  String destinationId(BrowseSession session, String parentId) =>
      session.personalSpaceId.isEmpty
      ? parentId
      : 'ctfile:${session.personalSpaceId}:$parentId';

  String _number(String id, String prefix) {
    final value = id.startsWith(prefix) ? id.substring(1) : id;
    require(RegExp(r'^\d+$').hasMatch(value), '城通文件标识无效');
    return value;
  }

  CloudFile _file(Json row, String parent) {
    final id = row.str('key');
    require(RegExp(r'^[fd]\d+$').hasMatch(id), '城通文件列表缺少有效标识');
    require(row.str('name').isNotEmpty, '城通未返回文件名称');
    return CloudFile(
      id: id,
      name: row.str('name'),
      size: row.integer('size'),
      isDirectory: id.startsWith('d'),
      parentId: parent,
      modifiedAt: row.str('date'),
      thumbnailUrl: row.str('imgsrc'),
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async {
    if (s.mode == BrowseMode.share) return _shareList(s, parent);
    if (CtfileWeb.accepts(c)) return _web.list(s, parent, c!);
    final result = <CloudFile>[];
    final seen = <String>{};
    for (var page = 0; page < 1000; page++) {
      final data = await _api('public/file/list', {
        'session': _session(c),
        'folder_id': 'd${_number(parent, 'd')}',
        'start': result.length,
        'filter': 'all',
        'orderby': 'old',
      });
      require(data['results'] is List, '城通文件列表响应不完整');
      final batch = data.list('results');
      if (batch.isEmpty) return result;
      for (final row in batch) {
        final file = _file(row, parent);
        require(seen.add(file.id), '城通分页未前进，请刷新文件列表');
        result.add(file);
      }
    }
    throw const AppException('城通目录过大，请分目录浏览');
  }

  Future<Json> _shareInfo(ParsedLink link, {String? parent}) async {
    final id = LinkParser.shareId(platform, link.url);
    require(id != null, '无法识别城通分享链接');
    final parts = id!.split('/');
    final kind = parts.first;
    final category = kind[0];
    final queryParameters = Uri.parse(link.url).queryParameters;
    final subfolder = parent ?? queryParameters['d'];
    final params = <String, Object?>{
      'path': kind,
      category: parts.last,
      'passcode': link.passcode ?? '',
      'url': link.url,
      if (category != 'f' && subfolder != null)
        'folder_id': _number(subfolder, 'd'),
      if (category != 'f' && queryParameters.containsKey('fk'))
        'fk': queryParameters['fk'],
    };
    final endpoint = category == 'f'
        ? 'getfile.php'
        : category == 'd'
        ? 'getdir.php'
        : 'getshare.php';
    final data = _checked(
      await http.get(query('$web/$endpoint', params), headers),
    );
    require(data['file'] is Map, '城通分享响应不完整');
    return data.obj('file');
  }

  CloudFile _sharedFile(Json info, String parent, {String token = ''}) {
    final id = 'f${_number(info.str('file_id'), 'f')}';
    final name = info.str('file_name').ifEmpty(info.str('name'));
    require(name.isNotEmpty, '城通未返回文件名称');
    return CloudFile(
      id: id,
      name: name,
      size: info.integer('file_size', info.integer('size')),
      parentId: parent,
      token: token,
    );
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    final info = await _shareInfo(link);
    final single = LinkParser.shareId(platform, link.url)!.startsWith('f');
    final root = single ? 'd0' : 'd${_number(info.str('folder_id', '0'), 'd')}';
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: info
          .str('file_name')
          .ifEmpty(info.str('folder_name').ifEmpty('城通分享')),
      rootId: root,
      sourceLink: link,
      metadata: {'single': '$single', 'info': jsonEncode(info)},
    );
  }

  Future<List<CloudFile>> _shareList(BrowseSession s, String parent) async {
    final link = s.sourceLink;
    require(link != null, '原分享链接缺失，请重新解析');
    if (s.meta('single') == 'true') {
      require(parent == s.rootId, '文件不属于此分享目录');
      return [
        _sharedFile(
          asJson(jsonDecode(s.meta('info'))),
          parent,
          token: link!.url,
        ),
      ];
    }
    // Keep the original signed share scope when traversing descendants.
    final info = asJson(jsonDecode(s.meta('info')));
    final source = Uri.parse(web).resolve(info.str('url'));
    require(
      source.scheme == 'https' &&
          source.host == 'webapi.ctfile.com' &&
          source.path.isNotEmpty &&
          source.path != '/',
      '城通未返回有效目录地址',
    );
    final result = <CloudFile>[];
    final seen = <String>{};
    for (var page = 0; page < 1000; page++) {
      final response = await http.get(
        query(source.toString(), {
          'folder_id': _number(parent, 'd'),
          'iDisplayStart': result.length,
          'iDisplayLength': 100,
          'sEcho': page + 1,
        }),
        headers,
      );
      final data = response.json;
      require(
        response.successful &&
            (data['code'] == null || data.integer('code') == 200),
        data.str('message').ifEmpty('城通目录读取失败'),
      );
      final rows = data['aaData'] ?? data['data'];
      require(rows is List, '城通分享目录格式异常');
      if ((rows as List).isEmpty) return result;
      for (final raw in rows) {
        require(raw is List && raw.length >= 2, '城通目录条目不完整');
        final cells = raw as List;
        final doc = html.parseFragment(cells.map((e) => '$e').join(' '));
        var anchor = doc.querySelectorAll('a[href]').where((a) {
          final u = Uri.parse(link!.url).resolve(a.attributes['href']!);
          return {'http', 'https'}.contains(u.scheme) &&
              CloudPlatform.fromHost(u.host) == platform &&
              LinkParser.shareId(platform, u.toString()) != null;
        }).firstOrNull;
        final inputId =
            doc.querySelector('input[value]')?.attributes['value'] ?? '';
        late String url, id;
        late bool directory;
        if (anchor != null) {
          url = Uri.parse(
            link!.url,
          ).resolve(anchor.attributes['href']!).toString();
          final shareId = LinkParser.shareId(platform, url)!;
          directory = shareId.startsWith('d') || shareId.startsWith('s');
          final prefix = directory ? 'd' : 'f';
          final segments = shareId.split('/').last.split('-');
          id = RegExp('^$prefix[1-9]\\d*\$').hasMatch(inputId)
              ? inputId
              : '$prefix${_number(segments.length >= 2 ? segments[1] : segments[0], prefix)}';
        } else {
          // Parse only the known navigation call; never execute returned JS.
          final call = RegExp(
            r'''^\s*load_subdir\(\s*(\d+)\s*,\s*['"]([a-zA-Z0-9]+)['"]\s*\)\s*;?\s*$''',
          );
          anchor = doc
              .querySelectorAll('a[onclick]')
              .where((a) => call.hasMatch(a.attributes['onclick']!))
              .firstOrNull;
          require(anchor != null, '城通目录缺少文件链接');
          final match = call.firstMatch(anchor!.attributes['onclick']!)!;
          id = 'd${match[1]}';
          require(inputId.isEmpty || inputId == id, '城通子目录标识不一致');
          directory = true;
          final original = Uri.parse(link!.url);
          url = original
              .replace(
                queryParameters: {
                  ...original.queryParameters,
                  'd': match[1]!,
                  'fk': match[2]!,
                },
              )
              .toString();
        }
        require(seen.add(id), '城通分享分页未前进，请重新解析');
        final name = (anchor.attributes['title'] ?? '').ifEmpty(
          anchor.text.trim(),
        );
        require(name.isNotEmpty, '城通目录缺少文件名称');
        result.add(
          CloudFile(
            id: id,
            name: name,
            parentId: parent,
            isDirectory: directory,
            token: url,
          ),
        );
      }
      final total = data.integer(
        'iTotalDisplayRecords',
        data.integer('recordsFiltered', -1),
      );
      if (total >= 0 && result.length >= total) return result;
    }
    throw const AppException('城通分享目录过大，请分目录浏览');
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory, '文件夹不能直接下载');
    if (s.mode == BrowseMode.personal && CtfileWeb.accepts(c)) {
      return _web.download(s, f, c!);
    }
    Json data;
    var expectedSize = f.size;
    if (s.mode == BrowseMode.share) {
      require(s.sourceLink != null, '原分享链接缺失，请重新解析');
      final original = s.sourceLink!;
      final link = f.token.isEmpty
          ? original
          : ParsedLink(
              source: f.token,
              url: f.token,
              kind: LinkKind.cloudShare,
              platform: platform,
              passcode:
                  LinkParser.parse(f.token).firstOrNull?.passcode ??
                  original.passcode,
            );
      final info = await _shareInfo(link);
      final fresh = _sharedFile(info, f.parentId);
      require(
        fresh.id == f.id && (f.size <= 0 || fresh.size == f.size),
        '城通返回的文件与所选文件不一致，请重新解析',
      );
      expectedSize = fresh.size;
      final wait = info.integer('wait_seconds');
      require(wait >= 0 && wait <= 300, '城通要求等待较长时间，请稍后重试');
      if (wait > 0) await RequestScope.wait(Duration(seconds: wait));
      require(
        info.str('file_chk').isNotEmpty && info.str('userid').isNotEmpty,
        '城通未返回下载凭据',
      );
      data = _checked(
        await http.get(
          query('$web/get_down_url.php', {
            'uid': info.str('userid'),
            'fid': _number(f.id, 'f'),
            'file_chk': info.str('file_chk'),
            'start_time': info.integer('start_time'),
            'wait_seconds': wait,
          }),
          headers,
        ),
      );
      require(
        expectedSize <= 0 ||
            data.integer('file_size', expectedSize) == expectedSize,
        '城通下载响应的文件大小不一致',
      );
      expectedSize = data.integer('file_size', expectedSize);
      require(expectedSize > 0, '城通未返回原文件大小，请稍后重试');
    } else {
      data = await _api('public/file/fetch_url', {
        'session': _session(c),
        'file_id': _number(f.id, 'f'),
      });
    }
    final address = data.str('download_url').ifEmpty(data.str('downurl'));
    checkedCloudUrl(address, '城通未返回有效下载地址');
    return DownloadSpec(
      url: address,
      fileName: f.name,
      expectedSize: expectedSize,
      headers: headers,
      profile: 'ctfile',
    );
  }

  void _personal(BrowseSession s) =>
      require(s.mode == BrowseMode.personal, '请在个人网盘中管理文件');
  String _ids(List<CloudFile> files) {
    require(files.isNotEmpty, '请选择文件');
    for (final f in files) {
      require(RegExp(r'^[fd][1-9]\d*$').hasMatch(f.id), '城通文件标识无效');
    }
    return files.map((f) => f.id).toSet().join(',');
  }

  void _name(String name) => require(
    name.trim().isNotEmpty &&
        !RegExp(r'[/\\\x00-\x1f]').hasMatch(name) &&
        name != '.' &&
        name != '..',
    '文件名称无效',
  );

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    _personal(s);
    _name(name);
    if (CtfileWeb.accepts(c)) {
      final data = await _web.inSpace(s, c, 'file/manage/create-folder', {
        'folder_id': 'd${_number(parent, 'd')}',
        'name': name,
      }, read: false);
      return CloudFile(
        id: 'd${_number(data.str('folder_id'), 'd')}',
        name: name,
        isDirectory: true,
        parentId: parent,
      );
    }
    final data = await _api('public/folder/create', {
      'session': _session(c),
      'folder_id': _number(parent, 'd'),
      'name': name,
    }, read: false);
    return CloudFile(
      id: 'd${_number(data.str('folder_id'), 'd')}',
      name: name,
      isDirectory: true,
      parentId: parent,
    );
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    _personal(s);
    _name(name);
    _ids([f]);
    if (CtfileWeb.accepts(c)) {
      final data = await _web.inSpace(s, c, 'file/manage/rename', {
        'id': f.id,
        'name': name,
        'is_rename': 1,
      }, read: false);
      return _web.complete(c, data);
    }
    await _api('public/${f.isDirectory ? 'folder' : 'file'}/modify_meta', {
      'session': _session(c),
      (f.isDirectory ? 'folder_id' : 'file_id'): _number(
        f.id,
        f.isDirectory ? 'd' : 'f',
      ),
      'name': name,
      if (f.isDirectory) 'is_rename': true,
    }, read: false);
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    _personal(s);
    if (CtfileWeb.accepts(c)) {
      final parts = target.split(':');
      final folder = parts.length == 3 && parts.first == 'ctfile'
          ? parts[2]
          : target;
      final workspace = parts.length == 3 && parts.first == 'ctfile'
          ? parts[1]
          : s.personalSpaceId;
      require(
        workspace.isEmpty || RegExp(r'^[1-9]\d*$').hasMatch(workspace),
        '城通目标空间标识无效',
      );
      require(
        !(workspace == s.personalSpaceId && files.any((f) => f.id == folder)),
        '不能移动到文件夹自身',
      );
      final data = await _web.inSpace(s, c, 'file/manage/move', {
        'ids': _ids(files),
        'target_folder_id': 'd${_number(folder, 'd')}',
        if (workspace.isNotEmpty) 'target_workspace_id': workspace,
      }, read: false);
      return _web.complete(c, data);
    }
    require(!files.any((f) => f.id == target), '不能移动到文件夹自身');
    await _api('public/file/move', {
      'session': _session(c),
      'ids': _ids(files),
      'folder_id': _number(target, 'd'),
    }, read: false);
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    _personal(s);
    if (CtfileWeb.accepts(c)) {
      final data = await _web.inSpace(s, c, 'file/manage/delete', {
        'ids': _ids(files),
      }, read: false);
      return _web.complete(c, data);
    }
    await _api('public/file/delete', {
      'session': _session(c),
      'ids': _ids(files),
    }, read: false);
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    _personal(s);
    require(files.length == 1, '城通请逐个分享文件，或将多个文件放入文件夹后分享');
    require(
      options.expiryDays == null && (options.passcode ?? '').isEmpty,
      '城通分享使用账号默认提取码和有效期，请在城通官网设置',
    );
    if (CtfileWeb.accepts(c)) {
      _ids(files);
      return _web.share(s, files.single, c);
    }
    final data = await _api('public/file/share', {
      'session': _session(c),
      'ids': _ids(files),
    }, read: false);
    final rows = data.list('results');
    require(
      rows.length == 1 && rows.single.str('key') == files.single.id,
      '城通分享结果与所选文件不一致',
    );
    final links = LinkParser.parse(rows.single.str('weblink'));
    require(
      links.length == 1 &&
          links.single.platform == platform &&
          links.single.kind == LinkKind.cloudShare,
      '城通未返回有效分享链接',
    );
    return ShareCreation(
      links.single.url,
      links.single.passcode ?? '',
      files.single.name,
    );
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async => throw const AppException('城通暂不支持转存到指定目录，请下载或在官网转存');

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    _personal(s);
    _name(source.name);
    if (CtfileWeb.accepts(c)) {
      return _web.upload(s, parent, source, c, onProgress);
    }
    final io = UploadIO(http, source, onProgress);
    io.progress(UploadPhase.preparing);
    require(
      !(await list(s, parent, c)).any((f) => f.name == source.name),
      '城通目录已有同名文件，请重命名后上传',
    );
    final data = await _api('public/file/upload', {
      'session': _session(c),
      'folder_id': _number(parent, 'd'),
    }, read: false);
    final url = data.str('upload_url');
    final uri = Uri.tryParse(url);
    require(
      uri != null &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          (uri.host == 'ctfile.com' || uri.host.endsWith('.ctfile.com')),
      '城通上传地址无效',
    );
    final max = int.tryParse(uri!.queryParameters['maxsize'] ?? '');
    require(max == null || source.size <= max, '文件超过城通上传大小限制');
    final response = await io.send(
      url,
      method: 'POST',
      headers: headers,
      fields: const {},
      includeContentType: false,
      retry: false,
    );
    final result = response.json;
    if (result['code'] != null) _checked(response);
    require(result['error'] == null || result['error'] == '', '城通上传失败');
    final rawId = result.str('file_id');
    return io.confirm(
      () => list(s, parent, c),
      id: rawId.isEmpty ? '' : 'f${_number(rawId, 'f')}',
    );
  }
}
