import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/links.dart';
import '../../domain/uploads.dart';
import '../../domain/web_tokens.dart';
import '../http.dart';
import '../desktop_browser_ua.dart';
import '../login_cookies.dart';
import '../state_store.dart';
import '../uploads/upload_io.dart';
import 'personal_cloud.dart';
import 'token_session.dart';

part 'uploads/feijipan_upload.dart';

class FeijipanConnector extends PersonalCloudConnector {
  FeijipanConnector(
    this.http,
    CredentialStore store, {
    int Function()? now,
    math.Random? random,
  }) : sessions = TokenSessions(CloudPlatform.feijipan, store, now: now),
       _userAgents = DesktopBrowserUaPool(random: random);
  final JsonHttp http;
  final TokenSessions sessions;
  final DesktopBrowserUaPool _userAgents;
  final _identityKey = Object();
  final _browseIdentities = Expando<DesktopBrowserUaSession>();
  late final _defaultIdentity = _userAgents.start();
  DesktopBrowserUaSession get _identity =>
      Zone.current[_identityKey] as DesktopBrowserUaSession? ??
      _defaultIdentity;

  Future<T> _withIdentity<T>(
    Future<T> Function() action, {
    BrowseSession? browse,
  }) {
    if (Zone.current[_identityKey] != null) return action();
    final identity = browse == null
        ? _userAgents.start()
        : _browseIdentities[browse] ??= _userAgents.start();
    return runZoned(action, zoneValues: {_identityKey: identity});
  }

  final _mutations = AsyncGate();
  static const api = 'https://api.feijipan.com';
  static const web = 'https://www.feijipan.com';
  @override
  CloudPlatform get platform => CloudPlatform.feijipan;

  static String encrypt(String value) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
          ..init(
            true,
            PaddedBlockCipherParameters<KeyParameter, Null>(
              KeyParameter(Uint8List.fromList(utf8.encode('dingHao-disk-app'))),
              null,
            ),
          );
    return cipher
        .process(Uint8List.fromList(utf8.encode(value)))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static String tokenQueryValue(String value) =>
      Uri.encodeQueryComponent(value).replaceAll('%3A', ':');

  static String decryptDownloadUrl(String value) {
    require(
      value.length <= 16384 &&
          value.length % 32 == 0 &&
          RegExp(r'^[0-9a-fA-F]+$').hasMatch(value),
      '小飞机下载地址格式异常',
    );
    try {
      final cipher =
          PaddedBlockCipherImpl(
            PKCS7Padding(),
            ECBBlockCipher(AESEngine()),
          )..init(
            false,
            PaddedBlockCipherParameters<KeyParameter, Null>(
              KeyParameter(Uint8List.fromList(utf8.encode('dingHao-disk-app'))),
              null,
            ),
          );
      final bytes = Uint8List.fromList([
        for (var i = 0; i < value.length; i += 2)
          int.parse(value.substring(i, i + 2), radix: 16),
      ]);
      return checkedCloudUrl(utf8.decode(cipher.process(bytes)), '小飞机下载地址无效');
    } catch (_) {
      throw const AppException('小飞机下载地址无法解码，请重新获取');
    }
  }

  String _url(
    String path,
    String uuid,
    String token, {
    Json extra = const {},
    int? timestamp,
  }) {
    final values = <String, Object?>{
      'uuid': uuid,
      'devType': 6,
      'devCode': uuid,
      'devModel': _identity.current.model,
      'devVersion': _identity.current.version,
      'appVersion': '',
      'timestamp': encrypt('${timestamp ?? sessions.now()}'),
      if (token.isNotEmpty) 'appToken': token,
      if (path != '/ws/file/redirect') 'extra': 2,
      ...extra,
    };
    return '$api$path?${values.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${e.key == 'appToken' ? tokenQueryValue('${e.value}') : Uri.encodeQueryComponent('${e.value}')}').join('&')}';
  }

  Map<String, String> _headersFor(DesktopBrowserUa identity) => {
    'User-Agent': identity.value,
    'Origin': web,
    'Referer': '$web/',
    'Accept-Language': 'zh-CN',
  };

  Future<HttpResult> _request(String method, String url, {Json? body}) async =>
      (await _requestWithIdentity(method, url, body: body)).response;

  Future<({HttpResult response, DesktopBrowserUa identity})>
  _requestWithIdentity(String method, String url, {Json? body}) async {
    var uri = Uri.parse(url);
    LoginCookieJar freshCookies() => LoginCookieJar({
      'feijipan.com',
      'www.feijipan.com',
      'api.feijipan.com',
    });
    var jar = freshCookies(), verificationRetries = 0;
    while (true) {
      RequestScope.checkpoint();
      final cookies = jar.header(uri);
      final identity = _identity.current;
      final response = await http.request(
        method,
        url,
        headers: {
          ..._headersFor(identity),
          if (cookies.isNotEmpty) 'Cookie': cookies,
        },
        body: body == null ? null : jsonEncode(body),
        contentType: body == null ? null : 'application/json; charset=utf-8',
        followRedirects: false,
      );
      RequestScope.checkpoint();
      jar.absorb(uri, response);
      if (response.status == 403 &&
          _uaRetryPaths.contains(uri.path) &&
          _browserBlocked(response) &&
          _identity.rotate()) {
        DiagnosticLog.event(
          'feijipan.user_agent_retry',
          fields: {
            'status': response.status,
            'apiPath': uri.path,
            'userAgent': _identity.current.value,
          },
        );
        // Keep encrypted tokens and signatures byte-for-byte unchanged.
        url = url
            .replaceFirstMapped(
              RegExp(r'([?&]devModel=)[^&]*'),
              (match) => '${match[1]}${_identity.current.model}',
            )
            .replaceFirstMapped(
              RegExp(r'([?&]devVersion=)[^&]*'),
              (match) => '${match[1]}${_identity.current.version}',
            );
        uri = Uri.parse(url);
        jar = freshCookies();
        verificationRetries = 0;
        continue;
      }
      if (response.status == 409 &&
          response.header('content-type').contains('text/html')) {
        if (verificationRetries++ == 0) continue;
        throw const AppException('小飞机的访问验证未通过，请稍后重试或使用网页登录');
      }
      return (response: response, identity: identity);
    }
  }

  // Only reads may be replayed after a UA rejection, including POST share lists.
  static const _uaRetryPaths = {
    '/ws/getUuid',
    '/ws/recommend/list',
    '/ws/share/list',
    '/ws/file/download',
    '/ws/file/redirect',
    '/app/user/account/map',
    '/app/user/info/map',
    '/app/record/file/list',
    '/ws/vod/results',
  };

  static bool _browserBlocked(HttpResult response) {
    try {
      response.json;
      return false; // A JSON rejection belongs to auth/permissions handling.
    } on AppException {
      return true;
    }
  }

  Json _checked(HttpResult response) {
    if (response.status == 401) {
      throw const AccountLoginRequired('小飞机登录已过期，请重新登录');
    }
    final data = response.json;
    if (data.integer('code') == -2 || response.status == 401) {
      throw const AccountLoginRequired('小飞机登录已过期，请重新登录');
    }
    require(
      response.successful && data.integer('code') == 200,
      '小飞机请求失败（${data.str('code').ifEmpty('${response.status}')}），请检查登录信息或稍后重试',
    );
    return data;
  }

  Future<String> _uuid() async {
    final data = _checked(await _request('GET', _url('/ws/getUuid', '', '')));
    final value = data.str('uuid');
    require(RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(value), '小飞机未返回有效设备标识');
    return value;
  }

  Future<String> _login(String username, String password, String uuid) async {
    final data = _checked(
      await _request(
        'POST',
        _url('/ws/login', uuid, ''),
        body: {'loginName': username, 'loginPwd': password},
      ),
    );
    final token = data.obj('data').str('appToken');
    require(WebTokens.validILanzouToken(token), '小飞机未返回登录凭据，请切换网页登录');
    return token;
  }

  Future<LoginResult> password(String username, String password) =>
      _withIdentity(() => _password(username, password));

  Future<LoginResult> _password(String username, String password) async {
    username = username.trim();
    require(username.isNotEmpty && password.isNotEmpty, '请输入小飞机账号和密码');
    require(username.length <= 254 && password.length <= 256, '账号或密码过长');
    final uuid = await _uuid();
    final token = await _login(username, password, uuid);
    return authenticate(
      Credential(platform.label, {
        'primary': token,
        'accessToken': token,
        'uuid': uuid,
        'username': username,
        'password': password,
        'authType': 'passwordToken',
      }),
    );
  }

  Future<TokenSession> _session(
    Credential credential, {
    bool candidate = false,
  }) async {
    final session = sessions.open(credential, candidate: candidate);
    if (session.field('uuid').isEmpty) {
      await RequestScope.cancellable(
        sessions.gate.run(() async {
          sessions.checkpoint(session);
          if (session.field('uuid').isEmpty) {
            await sessions.update(session, {'uuid': await _uuid()});
          }
        }),
      );
    }
    return session;
  }

  Future<void> _renew(TokenSession session, String rejected) =>
      RequestScope.cancellable(
        sessions.gate.run(() async {
          sessions.checkpoint(session);
          if (session.access != rejected && session.access.isNotEmpty) return;
          if (session.field('username').isEmpty ||
              session.field('password').isEmpty) {
            throw const AccountLoginRequired('小飞机登录已过期，请重新登录');
          }
          final token = await _login(
            session.field('username'),
            session.field('password'),
            session.field('uuid'),
          );
          await sessions.update(session, {
            'primary': token,
            'accessToken': token,
          });
        }),
      );

  Future<Json> _call(
    TokenSession session,
    String path, {
    Json? body,
    Json extra = const {},
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      sessions.checkpoint(session);
      final token = session.access;
      final response = await _request(
        body == null ? 'GET' : 'POST',
        _url('/app$path', session.field('uuid'), token, extra: extra),
        body: body,
      );
      sessions.checkpoint(session);
      try {
        return _checked(response);
      } on AccountLoginRequired {
        if (attempt != 0) rethrow;
        await _renew(session, token);
      }
    }
    throw const AccountLoginRequired('小飞机登录已过期，请重新登录');
  }

  Future<CloudAccount> _account(TokenSession session) async {
    final data = (await _call(session, '/user/account/map')).obj('map');
    final userInfo = (await _call(session, '/user/info/map')).obj('map');
    final user = data.str('userId');
    require(
      RegExp(r'^\d+$').hasMatch(user) && userInfo.str('userId') == user,
      '小飞机未返回一致的账号身份，请重新登录',
    );
    await sessions.update(session, {
      'userId': user,
      'account': data.str('account'),
    });
    return CloudAccount(
      userInfo
          .str('userName')
          .ifEmpty(data.str('nickName'))
          .ifEmpty(data.str('nickname'))
          .ifEmpty(data.str('account'))
          .ifEmpty('小飞机用户'),
      used: data.integer('usedSize') * 1024,
      total:
          (data.integer('totalSize') +
              data.integer('vipSize') +
              data.integer('contractSize') +
              data.integer('rewardSize')) *
          1024,
    );
  }

  Future<LoginResult> authenticate(Credential c) =>
      _withIdentity(() => _authenticate(c));

  Future<LoginResult> _authenticate(Credential c) async {
    final session = await _session(c, candidate: true);
    final account = await _account(session);
    return LoginResult(session.credential, account);
  }

  @override
  Future<CloudAccount> account(Credential c) async =>
      _withIdentity(() async => _account(await _session(c)));
  @override
  Future<BrowseSession> openPersonal(Credential c) =>
      _withIdentity(() => _openPersonal(c));

  Future<BrowseSession> _openPersonal(Credential c) async {
    await _session(c);
    final browse = BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的小飞机网盘',
      rootId: '0',
    );
    _browseIdentities[browse] = _identity;
    return browse;
  }

  static String id(String value) {
    final raw = value.replaceFirst(RegExp(r'^[df]:'), '');
    require(RegExp(r'^\d+$').hasMatch(raw), '小飞机文件标识无效，请刷新列表');
    return raw;
  }

  Future<Json> _sharePage(BrowseSession s, String parent, int page) async {
    final root = parent == 'share-root';
    final response = await _request(
      'POST',
      _url(
        root ? '/ws/recommend/list' : '/ws/share/list',
        s.meta('uuid'),
        '',
        extra: {
          'shareId': s.meta('shareId'),
          'code': s.meta('code'),
          'offset': page,
          'limit': 60,
          if (root) 'type': 0,
          if (!root) 'folderId': id(parent),
        },
      ),
    );
    final data = _checked(response);
    if ({1, 2}.contains(data.integer('status', -9))) {
      throw const AppException('小飞机分享需要正确的提取码，请填写后重试');
    }
    require(data.integer('status', 0) != -1, '小飞机分享已失效或暂不可用');
    require(data['list'] is List, '小飞机分享列表格式异常');
    return data;
  }

  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? credential) =>
      _withIdentity(() => _openShare(link, credential));

  Future<BrowseSession> _openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    final share = LinkParser.shareId(platform, link.url);
    require(share != null, '无法识别小飞机分享链接');
    final s = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '小飞机分享',
      rootId: 'share-root',
      sourceLink: link,
      metadata: {
        'shareId': share!,
        'uuid': await _uuid(),
        'code': link.passcode ?? '',
      },
    );
    _browseIdentities[s] = _identity;
    await _sharePage(s, s.rootId, 1);
    return s;
  }

  CloudFile _file(Json row, String parent) {
    final type = row.integer('fileType');
    require(type == 1 || type == 2, '小飞机返回了不支持的文件类型');
    final directory = type == 2;
    final raw = id(row.str(directory ? 'folderId' : 'fileId'));
    final name = row.str(directory ? 'folderName' : 'fileName');
    require(name.trim().isNotEmpty, '小飞机未返回文件名');
    return CloudFile(
      id: '${directory ? 'd' : 'f'}:$raw',
      name: name,
      parentId: parent,
      isDirectory: directory,
      size: directory
          ? 0
          : ((num.tryParse(row.str('fileSize')) ?? 0) * 1024).round(),
      modifiedAt: row.str('updTime').ifEmpty(row.str('addTime')),
    );
  }

  Future<List<CloudFile>> _shareFiles(BrowseSession s, String parent) async {
    if (parent != s.rootId) await _sharePage(s, s.rootId, 1);
    final result = <CloudFile>[], seen = <String>{};
    for (var page = 1; page <= 1000; page++) {
      final data = await _sharePage(s, parent, page);
      final top = data.list('list');
      require(top.length == (data['list'] as List).length, '小飞机分享列表包含无效项目');
      final rows = top
          .expand(
            (row) => row['fileList'] is List ? row.list('fileList') : [row],
          )
          .toList();
      for (final row in rows) {
        final file = _file(row, parent);
        require(seen.add(file.id), '小飞机分享分页重复，请重新解析');
        result.add(file);
      }
      final pages = data.integer('totalPage');
      require(page == 1 || rows.isNotEmpty, '小飞机分享分页不完整，请重新解析');
      if (pages > 0 ? page >= pages : rows.length < 60) return result;
      require(rows.isNotEmpty, '小飞机分享分页不完整，请重新解析');
    }
    throw const AppException('小飞机分享目录过大，请分目录打开');
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) => _withIdentity(() => _list(s, parentId, c), browse: s);

  Future<List<CloudFile>> _list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    if (s.mode == BrowseMode.share) return _shareFiles(s, parentId);
    personal(s);
    if (c == null) throw const AccountLoginRequired('请先登录小飞机网盘');
    final session = await _session(c), result = <CloudFile>[], ids = <String>{};
    for (var page = 1; page <= 1000; page++) {
      final data = await _call(
        session,
        '/record/file/list',
        extra: {
          'offset': page,
          'limit': 60,
          'folderId': id(parentId),
          'type': 0,
        },
      );
      require(data['list'] is List, '小飞机文件列表格式无效');
      final entries = data.list('list');
      require(entries.length == (data['list'] as List).length, '小飞机文件列表包含无效项目');
      var added = 0;
      for (final entry in entries) {
        final file = _file(entry, parentId);
        if (!ids.add(file.id)) continue;
        added++;
        result.add(file);
      }
      final pages = data.integer('totalPage');
      require(page == 1 || added > 0, '小飞机分页重复或不完整，请重新打开目录');
      if (pages > 0 ? page >= pages : entries.length < 60) return result;
      require(added > 0, '小飞机分页重复或不完整，请重新打开目录');
    }
    throw const AppException('小飞机目录项目过多，请分目录打开');
  }

  @override
  Future<DownloadSpec> download(BrowseSession s, CloudFile f, Credential? c) =>
      _withIdentity(() => _download(s, f, c), browse: s);

  Future<DownloadSpec> _download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    if (s.mode == BrowseMode.share) return _shareDownload(s, f, c);
    personal(s);
    require(!f.isDirectory, '请选择要下载的文件');
    if (c == null) throw const AccountLoginRequired('请先登录小飞机网盘');
    final session = await _session(c);
    if (session.field('userId').isEmpty) await _account(session);
    for (var attempt = 0; attempt < 2; attempt++) {
      sessions.checkpoint(session);
      final ts = sessions.now(), token = session.access, fileId = id(f.id);
      final url = _url(
        '/ws/file/redirect',
        session.field('uuid'),
        token,
        timestamp: ts,
        extra: {
          'enable': 1,
          'downloadId': encrypt('$fileId|${session.field('userId')}'),
          'auth': encrypt('$fileId|$ts'),
        },
      );
      final received = await _requestWithIdentity('GET', url);
      final response = received.response;
      sessions.checkpoint(session);
      if (response.status == 403 && _browserBlocked(response)) {
        throw const AppException('小飞机下载请求被拦截（HTTP 403），请稍后重试');
      }
      if ({401, 403}.contains(response.status)) {
        if (attempt == 0) {
          await _renew(session, token);
          continue;
        }
        throw const AccountLoginRequired('小飞机登录已过期，请重新登录');
      }
      var location = response.header('location');
      if (response.successful && location.isEmpty) {
        final data = response.json;
        if (data.integer('code') == -2) {
          if (attempt == 0) {
            await _renew(session, token);
            continue;
          }
          throw const AccountLoginRequired('小飞机登录已过期，请重新登录');
        }
        location = data.str('url').ifEmpty(data.obj('data').str('url'));
      }
      require(
        response.successful ||
            {301, 302, 303, 307, 308}.contains(response.status),
        '小飞机未返回下载地址',
      );
      require(location.isNotEmpty, '小飞机未返回下载地址，请检查文件权限');
      location = checkedCloudUrl(
        Uri.parse(api).resolve(location).toString(),
        '小飞机下载地址无效',
      );
      // The list is rounded to KiB. The transfer engine probes the real length.
      return DownloadSpec(
        url: location,
        fileName: f.name,
        headers: _headersFor(received.identity),
        profile: 'feijipan',
      );
    }
    throw const AppException('小飞机下载地址获取失败');
  }

  Future<DownloadSpec> _shareDownload(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory, '请选择要下载的文件');
    // Refresh membership and access-code validation before requesting a file URL.
    final files = await _shareFiles(
      s,
      f.parentId.isEmpty ? s.rootId : f.parentId,
    );
    require(
      files.any((v) => v.id == f.id && !v.isDirectory),
      '小飞机文件已不在此分享中，请重新解析',
    );
    TokenSession? session;
    if (c != null) {
      session = await _session(c);
      if (session.field('userId').isEmpty) await _account(session);
    }
    for (var attempt = 0; attempt < 2; attempt++) {
      if (session != null) sessions.checkpoint(session);
      final token = session?.access ?? '';
      final stamp = sessions.now();
      // The sharing API returns an encrypted URL, unlike personal-file redirects.
      final received = await _requestWithIdentity(
        'GET',
        _url(
          '/ws/file/download',
          session?.field('uuid') ?? s.meta('uuid'),
          token,
          timestamp: stamp,
          extra: {
            'shareId': s.meta('shareId'),
            'code': s.meta('code'),
            'enable': 1,
            'downloadId': encrypt(
              '${id(f.id)}|${session?.field('userId') ?? ''}',
            ),
            'auth': encrypt('${id(f.id)}|$stamp'),
          },
        ),
      );
      final response = received.response;
      if (session != null) sessions.checkpoint(session);
      Json data;
      try {
        data = _checked(response);
      } on AccountLoginRequired {
        if (session == null || attempt != 0) rethrow;
        await _renew(session, token);
        continue;
      }
      final location = decryptDownloadUrl(data.str('downloadUrl'));
      return DownloadSpec(
        url: location,
        fileName: f.name,
        headers: _headersFor(received.identity),
        profile: 'feijipan',
      );
    }
    throw const AccountLoginRequired('小飞机登录已过期，请重新登录');
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    require(files.isNotEmpty && files.length <= 5, '小飞机一次最多分享 5 个文件或文件夹');
    final code = options.passcode?.trim() ?? '';
    require(
      code.isEmpty || RegExp(r'^[A-Za-z0-9]{4}$').hasMatch(code),
      '小飞机提取码应为 4 位字母或数字',
    );
    final days = options.expiryDays ?? 0;
    require(days >= 0 && days <= 365, '小飞机分享有效期无效');
    final data = await _call(
      await _session(c),
      '/share/url',
      body: {
        ..._ids(files),
        'code': code,
        'term': days,
        'amt': '',
        'freeDownload': 1,
        'showRecommend': 0,
        'showUpTime': 1,
        'showDownloads': 0,
        'showComments': 0,
        'showStars': 0,
        'showLikes': 0,
      },
    );
    final url = data.str('shareUrl');
    require(LinkParser.shareId(platform, url) != null, '小飞机未返回有效分享地址');
    return ShareCreation(url, code, options.title);
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请先打开小飞机分享');
    if (files.isEmpty) return;
    await _call(
      await _session(c),
      '/file/transfer',
      body: {
        'shareId': s.meta('shareId'),
        'code': s.meta('code'),
        'folderId': id(target),
        'targetFileId': files
            .where((f) => !f.isDirectory)
            .map((f) => id(f.id))
            .join(','),
        'targetFolderId': files
            .where((f) => f.isDirectory)
            .map((f) => id(f.id))
            .join(','),
      },
    );
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) =>
      _withIdentity(() => _upload(s, parent, source, c, onProgress), browse: s);

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    personal(s);
    cloudFileName(name);
    final data = await _call(
      await _session(c),
      '/file/folder/save',
      body: {'folderDesc': '', 'folderId': id(parent), 'folderName': name},
    );
    final entries = data.list('list');
    require(entries.length == 1, '小飞机未返回新文件夹信息，请刷新确认');
    return CloudFile(
      id: 'd:${id(entries.first.str('id'))}',
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
    personal(s);
    cloudFileName(name);
    require(id(f.id) != '0', '不能重命名网盘根目录');
    final type = f.isDirectory ? 'folder' : 'file';
    await _call(
      await _session(c),
      f.isDirectory ? '/file/folder/edit' : '/file/edit',
      body: {'${type}Desc': '', '${type}Id': id(f.id), '${type}Name': name},
    );
  }

  Json _ids(List<CloudFile> files) {
    require(files.every((f) => id(f.id) != '0'), '不能操作网盘根目录');
    return {
      'folderIds': files
          .where((f) => f.isDirectory)
          .map((f) => id(f.id))
          .join(','),
      'fileIds': files
          .where((f) => !f.isDirectory)
          .map((f) => id(f.id))
          .join(','),
    };
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    if (files.isEmpty) return;
    require(
      !files.any((f) => f.isDirectory && id(f.id) == id(target)),
      '不能移动到文件夹自身',
    );
    await _call(
      await _session(c),
      '/file/folder/move',
      body: {..._ids(files), 'targetId': id(target)},
    );
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    if (files.isEmpty) return;
    await _call(
      await _session(c),
      '/file/delete',
      body: {..._ids(files), 'status': 0},
    );
  }
}
