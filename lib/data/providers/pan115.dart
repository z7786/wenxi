import 'dart:io';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/links.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../uploads/upload_io.dart';
import 'pan115_crypto.dart';
import 'personal_cloud.dart';
import 'token_session.dart';

class Pan115Connector extends PersonalCloudConnector {
  Pan115Connector(this.http, {Pan115Cipher Function()? cipherFactory})
    : _cipherFactory = cipherFactory ?? Pan115Cipher.new;
  final JsonHttp http;
  final Pan115Cipher Function() _cipherFactory;
  final _mutations = AsyncGate();
  static const api = 'https://webapi.115.com';
  static const ua = WebLoginTarget.desktopUserAgent;
  static const shareUa = '$ua 115Browser/27.0.5.7';
  @override
  CloudPlatform get platform => CloudPlatform.pan115;

  Map<String, String> _headers(Credential? c) {
    if (c == null || !LoginCredentials.plausible(platform, c.primary)) {
      throw const AccountLoginRequired('请先登录 115 网盘');
    }
    return {
      'User-Agent': ua,
      'Referer': 'https://115.com/',
      'Cookie': c.primary,
    };
  }

  Json _checked(HttpResult response) {
    if (response.status == 401) {
      throw const AccountLoginRequired('115 登录已失效，请重新网页登录');
    }
    require(response.successful, '115 请求失败（HTTP ${response.status}），请稍后重试');
    Json data;
    try {
      data = response.json;
    } on AppException {
      throw const AppException('115 返回了验证页面，请在网页登录中完成验证后重试');
    }
    final code = data.integer(
      'errno',
      data.integer('errNo', data.integer('code')),
    );
    final message = data
        .str('error')
        .ifEmpty(data.str('errmsg'))
        .ifEmpty(data.str('message'));
    if ({99, 401, 990001}.contains(code) ||
        !data.boolean('state') &&
            RegExp(r'未登录|请.*登录|登录.*失效').hasMatch(message)) {
      throw const AccountLoginRequired('115 登录已失效，请重新网页登录');
    }
    if (!data.boolean('state')) {
      if (code == 4100001 || message.contains('同意分享协议')) {
        throw const AppException('请先在 115 官网同意分享协议，再返回创建分享');
      }
      if (RegExp(r'提取码|访问码|密码|口令').hasMatch(message)) {
        throw const AppException('115 提取码错误或缺失，请检查后重试');
      }
      if (RegExp(r'取消|过期|不存在').hasMatch(message)) {
        throw const AppException('115 文件或分享已失效，请刷新或重新获取分享链接');
      }
      if (RegExp(r'频繁|验证|风控').hasMatch(message)) {
        throw const AppException('115 请求受限，请稍后重试或在官方网页完成验证');
      }
    }
    require(data.boolean('state'), '115 请求未成功（$code），请检查登录状态、提取码或官方网页中的限制提示');
    return data;
  }

  Future<HttpResult> _request(
    String url,
    Credential? c, {
    Json? body,
    Json params = const {},
    String? userAgent,
  }) async {
    RequestScope.checkpoint();
    final response = await http.request(
      body == null ? 'GET' : 'POST',
      params.isEmpty ? url : query(url, params),
      headers: {..._headers(c), 'User-Agent': userAgent ?? ua},
      body: body == null ? null : form(body),
      contentType: body == null ? null : 'application/x-www-form-urlencoded',
      followRedirects: false,
    );
    RequestScope.checkpoint();
    return response;
  }

  Future<Json> _call(
    String path,
    Credential? c, {
    Json? body,
    Json params = const {},
  }) async => _checked(
    await _request(
      path == '/share/snap' ? 'https://115cdn.com/webapi$path' : '$api$path',
      c,
      body: body,
      params: params,
    ),
  );

  Future<(String, CloudAccount)> _account(Credential c) async {
    final user = _checked(
      await _request('https://my.115.com/?ct=ajax&ac=nav', c),
    ).obj('data');
    final uid = user.str('user_id');
    require(RegExp(r'^\d+$').hasMatch(uid), '115 未返回账号身份，请重新登录');
    final cookieUid = LoginCredentials.cookiePairs(
      c.primary,
    )['UID']!.split('_').first;
    require(uid == cookieUid, '115 返回的账号与当前登录不一致，请重新登录');
    final info = (await _call(
      '/files/index_info',
      c,
    )).obj('data').obj('space_info');
    int bytes(String key) {
      final raw = info.obj(key)['size'];
      final value = num.tryParse('$raw');
      require(
        value != null &&
            value.isFinite &&
            value >= 0 &&
            value <= 9223372036854775807,
        '115 容量信息无效',
      );
      return value!.toInt();
    }

    return (
      uid,
      CloudAccount(
        user
            .str('user_name')
            .ifEmpty(user.str('nick_name'))
            .ifEmpty('115 用户 $uid'),
        used: bytes('all_use'),
        total: bytes('all_total'),
      ),
    );
  }

  Future<LoginResult> authenticate(Credential c) async {
    final (uid, info) = await _account(c);
    return LoginResult(
      c.withFields({'userId': uid, 'nickname': info.nickname}),
      info,
    );
  }

  @override
  Future<CloudAccount> account(Credential credential) async =>
      (await _account(credential)).$2;
  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    _headers(credential);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: platform.label,
      rootId: '0',
    );
  }

  void _session(BrowseSession s) =>
      require(s.platform == platform, '115 文件来源不匹配');
  static void _id(String value) =>
      require(RegExp(r'^\d+$').hasMatch(value), '115 文件或目录标识无效');
  Json _share(BrowseSession s) {
    _session(s);
    require(
      s.mode == BrowseMode.share &&
          RegExp(r'^[A-Za-z0-9]+$').hasMatch(s.meta('shareCode')),
      '115 分享信息已失效，请重新解析',
    );
    return {
      'share_code': s.meta('shareCode'),
      'receive_code': s.meta('receiveCode'),
    };
  }

  CloudFile _file(Json j, String parent) {
    final folder = j.str('fid').isEmpty && j.str('file_id').isEmpty;
    final id = folder
        ? j.str('cid').ifEmpty(j.str('category_id'))
        : j.str('fid').ifEmpty(j.str('file_id'));
    _id(id);
    final name = j
        .str('n')
        .ifEmpty(j.str('file_name'))
        .ifEmpty(j.str('category_name'));
    require(name.isNotEmpty, '115 文件信息不完整');
    final (type, hash) = cloudChecksum(
      'sha1',
      j.str('sha').ifEmpty(j.str('sha1')),
    );
    return CloudFile(
      id: id,
      name: name,
      isDirectory: folder,
      parentId: parent,
      size: j.integer('s', j.integer('file_size')),
      token: j.str('pc').ifEmpty(j.str('pick_code')),
      hashType: type,
      hashValue: hash,
      modifiedAt: j.str('t').ifEmpty(j.str('user_ptime')),
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    _session(s);
    _id(parentId);
    final share = s.mode == BrowseMode.share;
    final files = <CloudFile>[];
    final seen = <String>{};
    var offset = 0;
    for (var page = 0; page < 10000; page++) {
      final response = await _call(
        share ? '/share/snap' : '/files',
        c,
        params: {
          if (share) ..._share(s),
          'cid': parentId,
          'offset': offset,
          'limit': 500,
          'asc': 1,
          'o': 'file_name',
          if (!share) ...{
            'aid': 1,
            'show_dir': 1,
            'count_folders': 1,
            'cur': 1,
            'custom_order': 1,
          },
        },
      );
      final data = share ? response.obj('data') : response;
      if (!share && data.containsKey('cid')) {
        require(data.str('cid') == parentId, '115 返回了其他目录，请刷新后重试');
      }
      final listKey = share ? 'list' : 'data';
      require(data[listKey] is List, '115 文件列表格式异常，请稍后重试');
      final rows = data.list(listKey);
      final total = data.integer('count', -1);
      require(
        rows.isNotEmpty || total < 0 || offset >= total,
        '115 文件列表不完整，请稍后重试',
      );
      if (rows.isEmpty) return files;
      for (final row in rows) {
        final file = _file(row, parentId);
        require(
          seen.add('${file.isDirectory}:${file.id}'),
          '115 目录内容发生变化，请重新刷新',
        );
        files.add(file);
      }
      offset += rows.length;
      if (total >= 0 ? offset >= total : rows.length < 500) return files;
    }
    throw const AppException('115 目录内容过多，请进入子目录查看');
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    require(
      link.platform == platform &&
          link.shareId != null &&
          LinkParser.shareId(platform, link.url) == link.shareId,
      '115 分享链接无效',
    );
    final s = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '115 分享',
      rootId: '0',
      sourceLink: link,
      metadata: {
        'shareCode': link.shareId!,
        'receiveCode': link.passcode ?? '',
      },
    );
    await _call(
      '/share/snap',
      credential,
      params: {..._share(s), 'cid': 0, 'offset': 0, 'limit': 1},
    );
    return s;
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile file,
    Credential? c,
  ) async {
    _session(s);
    _id(file.id);
    require(!file.isDirectory, '请选择文件下载');
    final share = s.mode == BrowseMode.share;
    require(
      share || RegExp(r'^[A-Za-z0-9]+$').hasMatch(file.token),
      '115 下载标识缺失，请刷新文件列表',
    );
    final cipher = _cipherFactory();
    final payload = share
        ? {..._share(s), 'file_id': file.id}
        : {'pickcode': file.token};
    final response = await _request(
      'https://proapi.115.com/app/${share ? 'share' : 'chrome'}/downurl',
      c,
      params: {'t': DateTime.now().millisecondsSinceEpoch ~/ 1000},
      body: {'data': cipher.encode(payload)},
      userAgent: share ? shareUa : ua,
    );
    final decoded = cipher.decode(_checked(response).str('data'));
    final Json info;
    if (share) {
      info = decoded;
      require(
        info.str('fid').ifEmpty(info.str('file_id')) == file.id,
        '115 返回了其他文件的下载信息',
      );
    } else {
      info = decoded.obj(file.id);
      require(
        info.isNotEmpty &&
            (info.str('pick_code').isEmpty ||
                info.str('pick_code') == file.token),
        '115 返回的下载信息与所选文件不一致',
      );
    }
    require(
      info.integer('file_size', info.integer('fs', -1)) == file.size,
      '115 返回的文件大小不一致，请刷新后重试',
    );
    final url = checkedCloudUrl(
      info.obj('url').str('url'),
      '115 未返回可用下载地址，请检查官方网页中的下载权限',
    );
    // Signed 115 URLs use c for simultaneous connections (0 = unrestricted).
    // Exceeding it returns 403 even while the ticket remains valid.
    final connectionLimit = int.tryParse(
      Uri.parse(url).queryParameters['c'] ?? '',
    );
    final cookies = <String, String>{};
    // Download authorization cookies are separate from the account Cookie.
    // Never forward UID/CID/SEID to a storage CDN.
    for (final e in response.headers.entries) {
      if (e.key.toLowerCase() != 'set-cookie') continue;
      for (final raw in e.value) {
        try {
          final cookie = Cookie.fromSetCookieValue(raw);
          if (cookie.name.startsWith('acw_tc') &&
              !RegExp(r'[\r\n]').hasMatch(cookie.value)) {
            cookies[cookie.name] = cookie.value;
          }
        } on FormatException {
          /* Ignore malformed optional download cookies. */
        }
      }
    }
    return DownloadSpec(
      url: url,
      fileName: file.name,
      expectedSize: file.size,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
      maxPlaybackConnections: connectionLimit != null && connectionLimit > 0
          ? connectionLimit
          : null,
      headers: {
        'User-Agent': share ? shareUa : ua,
        'Referer': 'https://115.com/',
        if (cookies.isNotEmpty)
          'Cookie': cookies.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
      },
    );
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    personal(s);
    _id(parent);
    cloudFileName(name);
    final result = await _mutations.run(
      () => _call('/files/add', c, body: {'pid': parent, 'cname': name}),
    );
    final id = result.str('cid').ifEmpty(result.obj('data').str('cid'));
    _id(id);
    return CloudFile(id: id, name: name, parentId: parent, isDirectory: true);
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    personal(s);
    _id(f.id);
    cloudFileName(name);
    await _mutations.run(
      () => _call(
        '/files/batch_rename',
        c,
        body: {'files_new_name[${f.id}]': name},
      ),
    );
  }

  Json _ids(List<CloudFile> files) {
    require(files.isNotEmpty, '请先选择文件');
    for (final f in files) {
      _id(f.id);
    }
    return {for (var i = 0; i < files.length; i++) 'fid[$i]': files[i].id};
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    _id(target);
    // A missing directory can otherwise silently produce orphaned files.
    await list(s, target, c);
    await _mutations.run(
      () => _call('/files/move', c, body: {'pid': target, ..._ids(files)}),
    );
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    await _mutations.run(() => _call('/rb/delete', c, body: _ids(files)));
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    personal(s);
    _id(parent);
    cloudFileName(source.name);
    require(
      source.size <= 5 * 1024 * 1024 * 1024,
      '115 网页上传单文件最大 5 GB，更大的文件请使用官方客户端上传',
    );
    final io = UploadIO(http, source, onProgress);
    io.progress(UploadPhase.preparing);
    final init = _uploadPolicy(
      await _request(
        'https://uplb.115.com/3.0/sampleinitupload.php',
        c,
        body: {
          'filename': source.name,
          'filesize': source.size,
          'target': 'U_1_$parent',
          'path': '',
        },
      ),
    );
    var host = Uri.tryParse(init.str('host'));
    require(
      host != null &&
          {'https', 'http'}.contains(host.scheme) &&
          host.host.endsWith('.aliyuncs.com') &&
          host.userInfo.isEmpty,
      '115 返回的上传服务器无效',
    );
    host = host!.replace(scheme: 'https');
    for (final key in [
      'object',
      'policy',
      'accessid',
      'callback',
      'signature',
    ]) {
      require(init.str(key).isNotEmpty, '115 上传凭据不完整');
    }
    final response = await io.send(
      host.toString(),
      method: 'POST',
      retry: false,
      headers: {'User-Agent': ua},
      fields: {
        'name': source.name,
        'key': init.str('object'),
        'policy': init.str('policy'),
        'OSSAccessKeyId': init.str('accessid'),
        'success_action_status': '200',
        'callback': init.str('callback'),
        'signature': init.str('signature'),
      },
    );
    final result = _checked(response);
    return io.confirm(
      () => list(s, parent, c),
      id: result.obj('data').str('file_id').ifEmpty(result.str('file_id')),
    );
  }

  Json _uploadPolicy(HttpResult response) {
    if (!response.successful) return _checked(response);
    final data = response.json;
    // Successful sampleinitupload replies contain the OSS policy directly,
    // without the state envelope used by the other 115 APIs.
    if (data.containsKey('state') ||
        data.integer('errno') != 0 ||
        data.integer('code') != 0 ||
        ![
          'object',
          'accessid',
          'host',
          'policy',
          'signature',
          'callback',
        ].every((key) => data[key] is String && data.str(key).isNotEmpty)) {
      return _checked(response);
    }
    return data;
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    _id(target);
    _ids(files);
    await _mutations.run(
      () => _call(
        '/share/receive',
        c,
        body: {
          ..._share(s),
          'file_id': files.map((f) => f.id).join(','),
          'cid': target,
        },
      ),
    );
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    _ids(files);
    final passcode = options.passcode?.trim() ?? '';
    require(
      passcode.isEmpty || RegExp(r'^[A-Za-z0-9]{4}$').hasMatch(passcode),
      '115 提取码需为 4 位字母或数字',
    );
    final days = options.expiryDays;
    require(days == null || days >= 0, '分享有效期无效');
    return _mutations.run(() async {
      final data = (await _call(
        '/share/send',
        c,
        body: {
          'file_ids': files.map((f) => f.id).join(','),
          'ignore_warn': 1,
          'is_asc': 1,
          'order': 'file_name',
        },
      )).obj('data');
      final code = data.str('share_code');
      require(RegExp(r'^[A-Za-z0-9]+$').hasMatch(code), '115 未返回分享标识');
      await _call(
        '/share/updateshare',
        c,
        body: {
          'share_code': code,
          'share_duration': days == null || days == 0 ? -1 : days,
          if (passcode.isNotEmpty) 'receive_code': passcode,
        },
      );
      return ShareCreation(
        'https://115cdn.com/s/$code',
        passcode.ifEmpty(data.str('receive_code')),
        options.title,
      );
    });
  }
}
