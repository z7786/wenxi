import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../../domain/web_tokens.dart';
import '../http.dart';
import '../login_cookies.dart';
import '../state_store.dart';
import '../uploads/upload_io.dart';
import 'personal_cloud.dart';
import 'token_session.dart';

part 'uploads/ilanzou_upload.dart';

class ILanzouConnector extends PersonalCloudConnector {
  ILanzouConnector(this.http, CredentialStore store, {int Function()? now})
    : sessions = TokenSessions(CloudPlatform.ilanzou, store, now: now);
  final JsonHttp http;
  final TokenSessions sessions;
  static const api = 'https://apis.ilanzou.com';
  static const web = 'https://www.ilanzou.com';
  @override
  CloudPlatform get platform => CloudPlatform.ilanzou;

  static String encrypt(String value) {
    final cipher =
        PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(AESEngine()))
          ..init(
            true,
            PaddedBlockCipherParameters<KeyParameter, Null>(
              KeyParameter(Uint8List.fromList(utf8.encode('lanZouY-disk-app'))),
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
      'devModel': 'chrome',
      'devVersion': '125',
      'appVersion': '',
      'timestamp': encrypt('${timestamp ?? sessions.now()}'),
      if (token.isNotEmpty) 'appToken': token,
      if (path != '/unproved/file/redirect') 'extra': 2,
      ...extra,
    };
    return '$api$path?${values.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${e.key == 'appToken' ? tokenQueryValue('${e.value}') : Uri.encodeQueryComponent('${e.value}')}').join('&')}';
  }

  Map<String, String> get _headers => {
    'User-Agent': WebLoginTarget.desktopUserAgent,
    'Origin': web,
    'Referer': '$web/',
    'Accept-Language': 'zh-CN',
  };

  final _wafJar = LoginCookieJar({
    'ilanzou.com',
    'www.ilanzou.com',
    'apis.ilanzou.com',
  });

  Future<HttpResult> _request(String method, String url, {Json? body}) async {
    final uri = Uri.parse(url);
    for (var attempt = 0; attempt < 2; attempt++) {
      RequestScope.checkpoint();
      final cookies = _wafJar.header(uri);
      final response = await http.request(
        method,
        url,
        headers: {..._headers, if (cookies.isNotEmpty) 'Cookie': cookies},
        body: body == null ? null : jsonEncode(body),
        contentType: body == null ? null : 'application/json; charset=utf-8',
        followRedirects: false,
      );
      RequestScope.checkpoint();
      if (response.status == 409 &&
          response.header('content-type').toLowerCase().contains('text/html')) {
        _wafJar
          ..clear()
          ..absorb(uri, response);
        if (attempt == 0) continue;
        throw const AppException('蓝奏优享的访问验证未通过，请稍后重试或使用网页登录');
      }
      return response;
    }
    throw const AppException('蓝奏优享请求失败，请稍后重试');
  }

  Json _checked(HttpResult response) {
    if (response.status == 401 || response.status == 403) {
      throw const AccountLoginRequired('蓝奏优享登录已过期，请重新登录');
    }
    final data = response.json;
    if ({-1, -2}.contains(data.integer('code')) || response.status == 401) {
      throw const AccountLoginRequired('蓝奏优享登录已过期，请重新登录');
    }
    require(
      response.successful && data.integer('code') == 200,
      '蓝奏优享请求失败（${data.str('code').ifEmpty('${response.status}')}），请检查登录信息或稍后重试',
    );
    return data;
  }

  Future<String> _uuid() async {
    final data = _checked(
      await _request('GET', _url('/unproved/getUuid', '', '')),
    );
    final value = data.str('uuid');
    require(RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(value), '蓝奏优享未返回有效设备标识');
    return value;
  }

  Future<String> _login(String username, String password, String uuid) async {
    final data = _checked(
      await _request(
        'POST',
        _url('/unproved/login', uuid, ''),
        body: {'loginName': username, 'loginPwd': password},
      ),
    );
    final token = data.obj('data').str('appToken');
    require(WebTokens.validILanzouToken(token), '蓝奏优享未返回登录凭据，请切换网页登录');
    return token;
  }

  Future<LoginResult> password(String username, String password) async {
    username = username.trim();
    require(username.isNotEmpty && password.isNotEmpty, '请输入蓝奏优享账号和密码');
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
            throw const AccountLoginRequired('蓝奏优享登录已过期，请重新登录');
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
        _url('/proved$path', session.field('uuid'), token, extra: extra),
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
    throw const AccountLoginRequired('蓝奏优享登录已过期，请重新登录');
  }

  Future<CloudAccount> _account(TokenSession session) async {
    final data = (await _call(session, '/user/account/map')).obj('map');
    final user = data.str('userId');
    require(user.isNotEmpty, '蓝奏优享未返回有效账号信息');
    await sessions.update(session, {
      'userId': user,
      'account': data.str('account'),
    });
    return CloudAccount(
      data
          .str('nickName')
          .ifEmpty(data.str('nickname'))
          .ifEmpty(data.str('account'))
          .ifEmpty('蓝奏优享用户'),
      used: data.integer('usedSize') * 1024,
      total:
          (data.integer('totalSize') +
              data.integer('vipSize') +
              data.integer('rewardSize')) *
          1024,
    );
  }

  Future<LoginResult> authenticate(Credential c) async {
    final session = await _session(c, candidate: true);
    final account = await _account(session);
    return LoginResult(session.credential, account);
  }

  @override
  Future<CloudAccount> account(Credential c) async =>
      _account(await _session(c));
  @override
  Future<BrowseSession> openPersonal(Credential c) async {
    await _session(c);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的蓝奏云优享版',
      rootId: '0',
    );
  }

  static String id(String value) {
    final raw = value.replaceFirst(RegExp(r'^[df]:'), '');
    require(RegExp(r'^\d+$').hasMatch(raw), '蓝奏优享文件标识无效，请刷新列表');
    return raw;
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    personal(s);
    if (c == null) throw const AccountLoginRequired('请先登录蓝奏云优享版');
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
      require(data['list'] is List, '蓝奏优享文件列表格式无效');
      final entries = data.list('list');
      require(
        entries.length == (data['list'] as List).length,
        '蓝奏优享文件列表包含无效项目',
      );
      var added = 0;
      for (final entry in entries) {
        final folder = entry.integer('fileType') == 2;
        final fileId =
            '${folder ? 'd' : 'f'}:${id(entry.str(folder ? 'folderId' : 'fileId'))}';
        final name = entry.str(folder ? 'folderName' : 'fileName');
        require(name.isNotEmpty, '蓝奏优享未返回有效文件名');
        if (!ids.add(fileId)) continue;
        added++;
        result.add(
          CloudFile(
            id: fileId,
            name: name,
            parentId: parentId,
            isDirectory: folder,
            size: folder ? 0 : entry.integer('fileSize') * 1024,
            modifiedAt: entry.str('updTime').ifEmpty(entry.str('addTime')),
          ),
        );
      }
      final pages = data.integer('totalPage');
      if (pages > 0 ? page >= pages : entries.length < 60) return result;
      require(added > 0, '蓝奏优享分页重复或不完整，请重新打开目录');
    }
    throw const AppException('蓝奏优享目录项目过多，请分目录打开');
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    personal(s);
    require(!f.isDirectory, '请选择要下载的文件');
    if (c == null) throw const AccountLoginRequired('请先登录蓝奏云优享版');
    final session = await _session(c);
    if (session.field('userId').isEmpty) await _account(session);
    for (var attempt = 0; attempt < 2; attempt++) {
      sessions.checkpoint(session);
      final ts = sessions.now(), token = session.access, fileId = id(f.id);
      final url = _url(
        '/unproved/file/redirect',
        session.field('uuid'),
        token,
        timestamp: ts,
        extra: {
          'enable': 1,
          'downloadId': encrypt('$fileId|${session.field('userId')}'),
          'auth': encrypt('$fileId|$ts'),
        },
      );
      final response = await _request('GET', url);
      sessions.checkpoint(session);
      if ({401, 403}.contains(response.status)) {
        if (attempt == 0) {
          await _renew(session, token);
          continue;
        }
        throw const AccountLoginRequired('蓝奏优享登录已过期，请重新登录');
      }
      var location = response.header('location');
      if (response.successful && location.isEmpty) {
        final data = response.json;
        if ({-1, -2}.contains(data.integer('code'))) {
          if (attempt == 0) {
            await _renew(session, token);
            continue;
          }
          throw const AccountLoginRequired('蓝奏优享登录已过期，请重新登录');
        }
        location = data.str('url').ifEmpty(data.obj('data').str('url'));
      }
      require(
        response.successful ||
            {301, 302, 303, 307, 308}.contains(response.status),
        '蓝奏优享未返回下载地址',
      );
      require(location.isNotEmpty, '蓝奏优享未返回下载地址，请检查文件权限');
      location = checkedCloudUrl(
        Uri.parse(api).resolve(location).toString(),
        '蓝奏优享下载地址无效',
      );
      // The list is rounded to KiB. The transfer engine probes the real length.
      return DownloadSpec(
        url: location,
        fileName: f.name,
        headers: _headers,
        profile: 'ilanzou',
      );
    }
    throw const AppException('蓝奏优享下载地址获取失败');
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _upload(s, parent, source, c, onProgress);

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
    require(entries.length == 1, '蓝奏优享未返回新文件夹信息，请刷新确认');
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
