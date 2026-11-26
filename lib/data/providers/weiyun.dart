import 'dart:convert';
import 'dart:io';
import '../../core/json.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../../domain/weiyun_web_login.dart';
import '../http.dart';
import '../state_store.dart';
import '../uploads/upload_io.dart';
import '../uploads/weiyun_hash.dart';
import 'personal_cloud.dart';
import 'token_session.dart';

part 'uploads/weiyun_upload.dart';

class WeiyunConnector extends PersonalCloudConnector {
  WeiyunConnector(this.http, CredentialStore store, {int Function()? now})
    : sessions = TokenSessions(CloudPlatform.weiyun, store, now: now);
  final JsonHttp http;
  final TokenSessions sessions;
  static const web = 'https://www.weiyun.com';
  @override
  CloudPlatform get platform => CloudPlatform.weiyun;

  Map<String, String> _cookies(TokenSession s) =>
      LoginCredentials.cookiePairs(s.credential.primary);
  Map<String, String> _headers(TokenSession s) => {
    'User-Agent': WebLoginTarget.desktopUserAgent,
    'Referer': '$web/disk',
    'Origin': web,
    'Cookie': s.credential.primary,
  };

  static Json tokenInfo(Map<String, String> cookies) =>
      switch (cookies.containsKey('weiyun_qq_openid') ||
          cookies.containsKey('weiyun_wx_openid')
      ? '2'
      : cookies.containsKey('openid') && cookies.containsKey('access_token')
      ? '1'
      : cookies['wy_uf']) {
        '1' => {
          'token_type': 1,
          'openid': cookies['openid'] ?? '',
          'open_appid': cookies['wy_appid'] ?? '',
          'access_token': cookies['access_token'] ?? '',
          'login_key_type': 192,
          'login_key_value': cookies['access_token'] ?? '',
        },
        '2' => {
          'token_type': 3,
          'login_key_type': 1540,
          if (cookies['weiyun_qq_openid']?.isNotEmpty == true)
            'qq_openid': cookies['weiyun_qq_openid'],
          if (cookies['weiyun_wx_openid']?.isNotEmpty == true)
            'openid': cookies['weiyun_wx_openid'],
        },
        _ => {
          'token_type': 0,
          'login_key_type': 27,
          'login_key_value': cookies['p_skey'] ?? '',
          'openid': '',
        },
      };

  Future<void> _absorb(TokenSession session, HttpResult response) async {
    sessions.checkpoint(session);
    final values = _cookies(session), before = session.credential.primary;
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final raw in entry.value) {
        if (RegExp(r'[\r\n\x00]').hasMatch(raw)) continue;
        try {
          final cookie = Cookie.fromSetCookieValue(raw);
          final domain = (cookie.domain ?? 'www.weiyun.com')
              .replaceFirst(RegExp(r'^\.'), '')
              .toLowerCase();
          if (!{'weiyun.com', 'www.weiyun.com'}.contains(domain)) continue;
          if (cookie.value.isEmpty ||
              cookie.maxAge != null && cookie.maxAge! <= 0 ||
              cookie.expires != null &&
                  cookie.expires!.millisecondsSinceEpoch <= sessions.now()) {
            values.remove(cookie.name);
          } else {
            values[cookie.name] = cookie.value;
          }
        } on FormatException {
          continue;
        }
      }
    }
    final current = values.entries.map((e) => '${e.key}=${e.value}').join('; ');
    if (current != before) await sessions.update(session, {'primary': current});
  }

  Future<bool> _touch(TokenSession session) async {
    final response = await http.request(
      'GET',
      '$web/disk',
      headers: _headers(session),
      followRedirects: false,
    );
    sessions.checkpoint(session);
    await _absorb(session, response);
    return response.successful &&
        (_cookies(session)['wyctoken'] ?? '').isNotEmpty;
  }

  Future<void> _refresh(
    TokenSession session, {
    String? rejected,
  }) => RequestScope.cancellable(
    sessions.gate.run(() async {
      sessions.checkpoint(session);
      if (rejected != null && session.credential.primary != rejected) return;
      if (rejected == null) {
        final checked = int.tryParse(session.field('csrfCheckedAt'));
        if ((_cookies(session)['wyctoken'] ?? '').isNotEmpty &&
            checked != null &&
            sessions.now() - checked < 300000) {
          return;
        }
      }
      if (!await _touch(session)) {
        final cookies = _cookies(session);
        if (tokenInfo(cookies).integer('token_type') != 1 ||
            (cookies['refresh_token'] ?? '').isEmpty ||
            (cookies['wy_appid'] ?? '').isEmpty) {
          throw const AccountLoginRequired('微云登录已失效，请重新网页登录');
        }
        final response = await http.request(
          'GET',
          query('https://api.weixin.qq.com/sns/oauth2/refresh_token', {
            'grant_type': 'refresh_token',
            'appid': cookies['wy_appid'],
            'refresh_token': cookies['refresh_token'],
          }),
          headers: {'User-Agent': WebLoginTarget.desktopUserAgent},
          followRedirects: false,
        );
        sessions.checkpoint(session);
        final data = response.json;
        if (!response.successful ||
            data.integer('errcode') != 0 ||
            data.str('access_token').isEmpty ||
            data.str('refresh_token').isEmpty ||
            data.str('openid') != cookies['openid']) {
          throw const AccountLoginRequired('微云微信登录已失效，请重新网页登录');
        }
        for (final key in ['access_token', 'refresh_token', 'openid']) {
          require(
            !RegExp(r'[;\s\x00-\x1f]').hasMatch(data.str(key)),
            '微云返回的登录凭据无效',
          );
          cookies[key] = data.str(key);
        }
        await sessions.update(session, {
          'primary': cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
          'weiyunTokenInfo': '',
          'weiyunCsrf': '',
        });
        if (!await _touch(session)) {
          throw const AccountLoginRequired('微云登录已失效，请重新网页登录');
        }
      }
      await sessions.update(session, {'csrfCheckedAt': '${sessions.now()}'});
    }),
  );

  Future<TokenSession> _session(Credential c, {bool candidate = false}) async {
    final session = sessions.open(c, candidate: candidate);
    final captured = {
      'tokenInfo': WeiyunWebLogin.tokenInfo(session.field('weiyunTokenInfo')),
      'requestHeader': WeiyunWebLogin.requestHeader(
        session.field('weiyunRequestHeader'),
      ),
      'csrf': session.field('weiyunCsrf'),
    };
    if (!LoginCredentials.plausible(
      platform,
      WeiyunWebLogin.encode(session.credential.primary, captured),
    )) {
      throw const AccountLoginRequired('微云登录信息不完整，请重新网页登录');
    }
    final last = int.tryParse(session.field('csrfCheckedAt')) ?? 0;
    final observed =
        (captured['tokenInfo'] as Json).containsKey('token_type') &&
        (captured['tokenInfo'] as Json).containsKey('login_key_type') &&
        (WeiyunWebLogin.csrf(captured['csrf']).isNotEmpty ||
            (_cookies(session)['wyctoken'] ?? '').isNotEmpty);
    if (!observed &&
        ((_cookies(session)['wyctoken'] ?? '').isEmpty ||
            sessions.now() - last >= 300000)) {
      await _refresh(session);
    }
    return session;
  }

  Future<Json> _call(
    TokenSession session,
    String name,
    int cmd,
    Json body, {
    String protocol = 'weiyunQdiskClient',
    bool read = false,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      sessions.checkpoint(session);
      final cookies = _cookies(session);
      final observed = WeiyunWebLogin.tokenInfo(
        session.field('weiyunTokenInfo'),
      );
      final info =
          observed.containsKey('token_type') &&
              observed.containsKey('login_key_type')
          ? observed
          : tokenInfo(cookies);
      // Refreshable cookie values can change after a webpage capture.
      if (info.integer('token_type', -1) == 0 &&
          cookies.containsKey('p_skey')) {
        info['login_key_value'] = cookies['p_skey'];
      } else if (info.integer('token_type', -1) == 1 &&
          cookies.containsKey('access_token')) {
        info['access_token'] = cookies['access_token'];
        info['login_key_value'] = cookies['access_token'];
      }
      final rejected = session.credential.primary;
      final url = query('$web/webapp/json/$protocol/$name', {
        'g_tk': (cookies['wyctoken'] ?? '').ifEmpty(
          session.field('weiyunCsrf'),
        ),
        'cmd': cmd,
      });
      final payload = {
        'req_header': jsonEncode({
          'seq': sessions.now() ~/ 1000,
          'cmd': cmd,
          'wx_openid': info['openid'] ?? '',
          'qq_openid': info['qq_openid'],
          'user_flag': info['token_type'],
          'env_id': info['env_id'],
          'type': 1,
          'appid': 30013,
          'version': 3,
          'major_version': 3,
          'minor_version': 3,
          'fix_version': 3,
          ...WeiyunWebLogin.requestHeader(session.field('weiyunRequestHeader')),
        }),
        'req_body': jsonEncode({
          'ReqMsg_body': {
            'ext_req_head': {
              'token_info': info,
              'language_info': {'language_type': 2052},
            },
            '.weiyun.${name}MsgReq_body': body,
          },
        }),
      };
      final response = await (read ? http.readRequest : http.request)(
        'POST',
        url,
        body: jsonEncode(payload),
        headers: _headers(session),
        contentType: 'application/json; charset=utf-8',
        followRedirects: false,
      );
      sessions.checkpoint(session);
      if ({401, 403}.contains(response.status)) {
        if (attempt == 0) {
          await _refresh(session, rejected: rejected);
          continue;
        }
        throw const AccountLoginRequired('微云登录已失效，请重新网页登录');
      }
      await _absorb(session, response);
      return _response(response, name);
    }
    throw const AccountLoginRequired('微云登录已失效，请重新网页登录');
  }

  Json _response(HttpResult response, String name) {
    Json? object(Object? value) {
      if (value is String) {
        try {
          value = jsonDecode(value);
        } on FormatException {
          return null;
        }
      }
      return value is Map ? asJson(value) : null;
    }

    final data = response.json;
    final envelope = object(data['data']) ?? object(data['result']);
    final header = object(envelope?['rsp_header']);
    final body = object(envelope?['rsp_body']);
    final result = object(body?['RspMsg_body']);
    // Successful replies may omit either status field when its value is 0.
    // Explicit invalid statuses still fail; the complete payload is required.
    int status(Json value, String key) =>
        value.containsKey(key) ? int.tryParse(value.str(key)) ?? -1 : 0;
    final outerCode = status(data, 'ret');
    final innerCode = header == null ? null : status(header, 'retcode');
    if (!response.successful ||
        outerCode != 0 ||
        header == null ||
        innerCode != 0 ||
        result == null) {
      DiagnosticLog.event(
        'weiyun.response_invalid',
        fields: {
          'operation': name,
          'httpStatus': response.status,
          'outerCode': outerCode,
          'innerCode': innerCode,
          'hasOuterStatus': data.containsKey('ret'),
          'hasEnvelope': envelope != null,
          'hasHeader': header != null,
          'hasResponseData': result != null,
          'explicitStatus': header?.containsKey('retcode') ?? false,
        },
      );
      if (!response.successful ||
          outerCode != 0 ||
          innerCode != null && innerCode != 0) {
        final code = outerCode != 0 ? outerCode : innerCode ?? response.status;
        throw AppException('微云请求失败（$code），请稍后重试或重新登录');
      }
      throw const AppException('微云响应缺少有效数据，请刷新重试');
    }
    return object(result['.weiyun.${name}MsgRsp_body']) ??
        object(result['weiyun.${name}MsgRsp_body']) ??
        result;
  }

  Future<CloudAccount> _account(TokenSession session) async {
    final data = await _call(session, 'DiskUserInfoGet', 2201, {
      'is_get_upload_flow_flag': false,
      'is_get_high_speed_flow_info': false,
      'is_get_weiyun_flag': false,
      'is_get_space_clean_info': false,
      'is_get_user_reward_info': false,
    }, read: true);
    require(
      data.integer('uin') > 0 && data.str('main_dir_key').isNotEmpty,
      '微云未返回有效账号和根目录',
    );
    await sessions.update(session, {
      'userId': data.str('uin'),
      'rootId': data.str('main_dir_key'),
    });
    return CloudAccount(
      data.str('nick_name').ifEmpty('微云用户'),
      used: data.integer('used_space'),
      total: data.integer('total_space'),
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
    final session = sessions.open(c);
    if (session.field('rootId').isEmpty) await _account(await _session(c));
    sessions.checkpoint(session);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的微云',
      rootId: session.field('rootId'),
    );
  }

  Future<TokenSession> _owner(BrowseSession s, Credential? c) async {
    personal(s);
    if (c == null) throw const AccountLoginRequired('请先登录微云');
    return _session(c);
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    final session = await _owner(s, c),
        result = <CloudFile>[],
        ids = <String>{};
    for (var page = 0; page < 1000; page++) {
      final data = await _call(
        session,
        'DiskDirList',
        2208,
        {
          'dir_key': parentId,
          'start': result.length,
          'count': 500,
          'sort_field': 1,
          'reverse_order': false,
          'get_type': 0,
          'get_abstract_url': false,
          'get_dir_detail_info': false,
        },
        protocol: 'weiyunQdisk',
        read: true,
      );
      require(
        data['dir_list'] is List ||
            data['file_list'] is List ||
            data.boolean('finish_flag'),
        '微云文件列表格式无效',
      );
      var added = 0;
      for (final folder in [true, false]) {
        final raw = data[folder ? 'dir_list' : 'file_list'];
        require(raw == null || raw is List, '微云文件列表格式无效');
        final entries = objects(raw);
        require(
          raw == null || entries.length == (raw as List).length,
          '微云文件列表包含无效项目',
        );
        for (final entry in entries) {
          final id = entry.str(folder ? 'dir_key' : 'file_id'),
              name = entry.str(folder ? 'dir_name' : 'filename');
          require(id.isNotEmpty && name.isNotEmpty, '微云文件信息不完整');
          if (!ids.add(id)) continue;
          added++;
          final hash = cloudChecksum('sha1', entry.str('file_sha'));
          result.add(
            CloudFile(
              id: id,
              name: name,
              isDirectory: folder,
              parentId: parentId,
              size: folder ? 0 : entry.integer('file_size'),
              modifiedAt: personalCloudDate(
                entry.str(folder ? 'dir_mtime' : 'file_mtime'),
              ),
              token: jsonEncode({'ppdir_key': data.str('pdir_key')}),
              thumbnailUrl: entry.obj('ext_info').str('thumb_url'),
              hashType: hash.$1,
              hashValue: hash.$2,
            ),
          );
        }
      }
      if (data.boolean('finish_flag')) {
        var visibleTotal = 0;
        for (final kind in ['dir', 'file']) {
          final total = data.integer('total_${kind}_count'),
              hidden = data.integer('hide_${kind}_count');
          require(
            total >= 0 && hidden >= 0 && hidden <= total,
            '微云文件列表计数无效，请刷新重试',
          );
          // The server includes hidden entries in its totals but omits them
          // from dir_list/file_list, including after an upload.
          visibleTotal += total - hidden;
        }
        require(result.length >= visibleTotal, '微云文件列表不完整，请刷新重试');
        return result;
      }
      require(added > 0, '微云文件分页重复或不完整，请刷新重试');
    }
    throw const AppException('微云目录项目过多，请分目录打开');
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!f.isDirectory && f.parentId.isNotEmpty, '微云文件信息不完整，请刷新列表');
    final data = await _call(
      await _owner(s, c),
      'DiskFileBatchDownload',
      2402,
      {
        'file_list': [
          {'pdir_key': f.parentId, 'file_id': f.id},
        ],
        'download_type': 0,
      },
      read: true,
    );
    final files = data.list('file_list');
    require(
      files.length == 1 && files.first.integer('retcode') == 0,
      '微云未返回有效下载信息，请检查文件权限',
    );
    final file = files.first,
        name = file.str('cookie_name'),
        value = file.str('cookie_value');
    require(
      name.isEmpty && value.isEmpty ||
          RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name) &&
              value.isNotEmpty &&
              !RegExp(r'[;\r\n\x00]').hasMatch(value),
      '微云下载授权信息无效',
    );
    return DownloadSpec(
      url: checkedCloudUrl(file.str('download_url'), '微云下载地址无效'),
      fileName: f.name,
      expectedSize: f.size,
      checksumType: f.hashType,
      checksumValue: f.hashValue,
      headers: {
        'User-Agent': WebLoginTarget.desktopUserAgent,
        'Referer': '$web/',
        if (name.isNotEmpty) 'Cookie': '$name=$value',
      },
      profile: 'weiyun',
    );
  }

  Future<List<Json>> _path(TokenSession session, String id) async {
    final data = await _call(
      session,
      'LibDirPathGet',
      26150,
      {'dir_key': id},
      protocol: 'weiyunFileLibClient',
      read: true,
    );
    final entries = data.list('items');
    require(entries.any((entry) => entry.str('dir_key') == id), '微云未返回有效目录路径');
    return entries;
  }

  Future<Json> _directory(TokenSession session, String id) async =>
      (await _path(
        session,
        id,
      )).firstWhere((entry) => entry.str('dir_key') == id);

  Future<Json> _fileParam(TokenSession session, CloudFile f) async {
    require(f.id.isNotEmpty && f.parentId.isNotEmpty, '微云文件信息不完整，请刷新列表');
    final parent = await _directory(session, f.parentId);
    return {
      'ppdir_key': parent.str('pdir_key'),
      'pdir_key': f.parentId,
      f.isDirectory ? 'dir_key' : 'file_id': f.id,
      f.isDirectory ? 'dir_name' : 'filename': f.name,
    };
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
    cloudFileName(name);
    final session = await _owner(s, c),
        directory = await _directory(session, parent);
    final data = await _call(session, 'DiskDirCreate', 2614, {
      'ppdir_key': directory.str('pdir_key'),
      'pdir_key': parent,
      'dir_name': name,
      'file_exist_option': 2,
      'create_type': 1,
    });
    require(data.str('dir_key').isNotEmpty, '微云未返回新文件夹信息，请刷新确认');
    return CloudFile(
      id: data.str('dir_key'),
      name: data.str('dir_name').ifEmpty(name),
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
    cloudFileName(name);
    require(f.id != s.rootId, '不能重命名网盘根目录');
    final session = await _owner(s, c), param = await _fileParam(session, f);
    await _call(
      session,
      f.isDirectory ? 'DiskDirAttrModify' : 'DiskFileRename',
      f.isDirectory ? 2615 : 2605,
      {
        'ppdir_key': param['ppdir_key'],
        'pdir_key': f.parentId,
        f.isDirectory ? 'dir_key' : 'file_id': f.id,
        f.isDirectory ? 'src_dir_name' : 'src_filename': f.name,
        f.isDirectory ? 'dst_dir_name' : 'filename': name,
      },
    );
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    final session = await _owner(s, c);
    if (files.isEmpty) return;
    final path = await _path(session, target),
        destination = path.firstWhere(
          (entry) => entry.str('dir_key') == target,
        );
    require(
      !files.any(
        (f) =>
            f.id == s.rootId ||
            f.isDirectory && path.any((entry) => entry.str('dir_key') == f.id),
      ),
      '不能移动根目录或移动到文件夹自身及子目录',
    );
    for (final file in files) {
      final param = await _fileParam(session, file);
      await _call(session, 'DiskDirFileBatchMove', 2618, {
        'src_ppdir_key': param['ppdir_key'],
        'src_pdir_key': file.parentId,
        file.isDirectory ? 'dir_list' : 'file_list': [param],
        'dst_ppdir_key': destination.str('pdir_key'),
        'dst_pdir_key': target,
      });
    }
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    final session = await _owner(s, c);
    if (files.isEmpty) return;
    require(files.every((f) => f.id != s.rootId), '不能删除网盘根目录');
    final dirs = <Json>[], values = <Json>[];
    for (final file in files) {
      (file.isDirectory ? dirs : values).add(await _fileParam(session, file));
    }
    await _call(session, 'DiskDirFileBatchDeleteEx', 2509, {
      if (dirs.isNotEmpty) 'dir_list': dirs,
      if (values.isNotEmpty) 'file_list': values,
    });
  }
}
