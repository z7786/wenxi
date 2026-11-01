import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import '../../core/json.dart';
import '../../domain/auth.dart';
import '../../domain/baidu_share_route.dart';
import '../../domain/file_types.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../state_store.dart';
import '../uploads/upload_io.dart';
import '../../core/operation_progress.dart';
import '../../diagnostics/app_log.dart';
import 'baidu_link_service.dart';
import 'baidu_app_client.dart';
import 'baidu_public_parser.dart';
import 'baidu_playback.dart';
import 'baidu_download_resolver.dart';

class _BaiduFileMissing extends AppException {
  const _BaiduFileMissing() : super('百度文件或分享已失效');
}

class BaiduConnector extends CloudConnector {
  BaiduConnector(
    this.http, {
    this.stageCleanup,
    CredentialStore? store,
    BaiduAppClient? client,
    BaiduLinkLookup? linkLookup,
    BaiduPublicParser? publicParser,
    BaiduPlaybackClient? playbackClient,
  }) : _client = client ?? BaiduAppClient(store: store),
       _linkLookup = linkLookup ?? BaiduDownloadResolver(http).resolve,
       _publicParser = publicParser ?? BaiduPublicParser(http, store: store),
       _playbackClient = playbackClient ?? BaiduPlaybackClient(http);
  final JsonHttp http;
  final BaiduAppClient _client;
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  final BaiduLinkLookup _linkLookup;
  final BaiduPublicParser _publicParser;
  final BaiduPlaybackClient _playbackClient;
  @override
  CloudPlatform get platform => CloudPlatform.baidu;
  static const defaultAppId = '250528';
  static const webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const netdiskUa = BaiduAppClient.fallbackUserAgent;

  // The Android API accepts the existing BDUSS/STOKEN cookie. Its CSRF token
  // is MD5(BDUSS), not the token returned to browser clients.
  String _appToken(String ck) {
    final bduss = LoginCredentials.cookiePairs(ck)['BDUSS'] ?? '';
    return bduss.isEmpty ? '' : md5.convert(utf8.encode(bduss)).toString();
  }

  Future<Map<String, Object?>> _appParams(
    String ck, [
    String id = defaultAppId,
  ]) async {
    await _client.prepare();
    RequestScope.checkpoint();
    final token = _appToken(ck);
    return {
      'app_id': id,
      'clienttype': 1,
      'version': BaiduAppClient.version,
      // Keep the channel present but empty: the Android distribution channel
      // rejects browser-created sessions on the current list endpoint (errno 2).
      'channel': '',
      if (token.isNotEmpty) 'bdstoken': token,
      ..._client.parameters,
    };
  }

  String appId(Credential c) {
    final id = c
        .field('appId')
        .trim()
        .ifEmpty(c.secondary.trim())
        .ifEmpty(defaultAppId);
    require(RegExp(r'^\d+$').hasMatch(id), '百度应用 ID 格式无效，可清空后使用默认值');
    return id;
  }

  String cookie(Credential c) {
    if (!LoginCredentials.plausible(CloudPlatform.baidu, c.primary)) {
      throw const AccountLoginRequired('百度登录信息不完整，请重新网页登录');
    }
    return LoginCredentials.normalize(CloudPlatform.baidu, c.primary);
  }

  Map<String, String> webHeaders(String cookie) => {
    'Cookie': cookie,
    'User-Agent': webUa,
  };
  Map<String, String> diskHeaders(String cookie) => {
    'Cookie': cookie,
    'User-Agent': _client.userAgent,
  };
  Json check(
    HttpResult result, {
    bool allowExisting = false,
    bool allowMissingCode = false,
    bool missingShareKey = false,
  }) {
    if (result.status == 401) {
      throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
    }
    final j = result.json;
    final rawCode = j['errno'] ?? j['error_code'];
    final errno =
        int.tryParse(rawCode?.toString() ?? '') ??
        (rawCode == null && allowMissingCode && result.successful ? 0 : -1);
    if (errno == -6) {
      throw const AccountLoginRequired('百度登录已失效，请重新网页登录');
    }
    if (result.successful && {-9, 31066}.contains(errno)) {
      throw const _BaiduFileMissing();
    }
    if (errno == 8888) {
      throw const AppException('百度文件接口返回异常（8888），请稍后重试或重新网页登录');
    }
    if (missingShareKey && {2, -12}.contains(errno)) {
      throw const AppException('该百度分享需要提取码，请补充后重新解析');
    }
    final message = j
        .str('err_msg')
        .ifEmpty(j.str('show_msg'))
        .ifEmpty(j.str('errmsg'))
        .ifEmpty(j.str('error_msg'));
    require(
      result.successful &&
          (errno == 0 || allowExisting && {-8, 12}.contains(errno)),
      message.ifEmpty(switch (errno) {
        -12 => '百度提取码错误，请重新输入',
        -9 || 31066 => '百度文件或分享已失效',
        403 => '百度分享已失效或无权访问',
        _ => '百度请求失败（errno=$errno）',
      }),
    );
    // A successful batch envelope can still contain failed file operations.
    for (final item in j.list('info')) {
      if (item.containsKey('errno')) {
        require(
          item.integer('errno', -1) == 0,
          item.str('errmsg').ifEmpty('百度部分文件操作失败，请刷新列表后重试'),
        );
      }
    }
    return j;
  }

  @override
  Future<CloudAccount> account(Credential credential) async {
    final id = appId(credential), ck = cookie(credential);
    final quota = check(
      await http.get(
        query('https://pan.baidu.com/api/quota', {
          ...await _appParams(ck, id),
          'checkrecycle': 1,
        }),
        diskHeaders(ck),
      ),
    );
    final used = int.tryParse(quota.str('used')),
        total = int.tryParse(quota.str('total'));
    require(
      used != null && used >= 0 && total != null && total > 0,
      '百度未返回有效容量，请重试',
    );
    var nickname = credential.field('nickname').ifEmpty('百度用户');
    try {
      final profile = await _profile(credential);
      nickname = profile
          .str('netdisk_name')
          .ifEmpty(profile.str('baidu_name'))
          .ifEmpty(nickname);
    } on AccountLoginRequired {
      rethrow;
    } on AppException {
      // Quota is usable even if the optional display-name endpoint is unavailable.
    }
    return CloudAccount(nickname, used: used!, total: total!);
  }

  Future<LoginResult> authenticate(Credential c) async {
    final session = await openPersonal(c);
    // A quota response (or a generic account-validation fallback) does not prove
    // that the saved web session can actually read the user's files.
    await _compatibleList(session, session.rootId, c, firstPageOnly: true);
    CloudAccount profile;
    try {
      profile = await account(c);
    } on AppException {
      RequestScope.checkpoint();
      // The file list already validated this session. Quota/profile requests
      // are optional because browser sessions may not support the App endpoint.
      profile = CloudAccount(c.field('nickname').ifEmpty('百度用户'));
    }
    return LoginResult(c, profile);
  }

  Future<Json> _profile(Credential c) async => check(
    await http.get(
      query('https://pan.baidu.com/rest/2.0/xpan/nas', {
        ...await _appParams(cookie(c), appId(c)),
        'method': 'uinfo',
      }),
      diskHeaders(cookie(c)),
    ),
  );

  Future<bool> _ownsShare(BrowseSession s, Credential c) async {
    final owner = s.meta('uk');
    if (owner.isEmpty) return false;
    try {
      return (await _profile(c)).str('uk') == owner;
    } on AccountLoginRequired {
      rethrow;
    } on AppException {
      RequestScope.checkpoint();
      return false;
    }
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential, {
    BaiduShareRoute route = BaiduShareRoute.account,
    String? parserSiteId,
    String? parserPasswordGrant,
  }) async {
    if (route == BaiduShareRoute.publicParser) {
      return _publicParser.openShare(
        link,
        parserSiteId: parserSiteId,
        passwordGrant: parserPasswordGrant,
      );
    }
    final id = link.shareId;
    require(id?.isNotEmpty == true, '百度分享链接缺少短链接 ID');
    final ck = credential?.primary ?? '';
    var sekey = '';
    if (link.passcode?.isNotEmpty == true) {
      sekey = check(
        await http.postForm(
          query('https://pan.baidu.com/share/verify', {'surl': id}),
          form({'pwd': link.passcode, 'vcode_str': '', 'vcode': ''}),
          {...webHeaders(ck), 'Referer': 'https://pan.baidu.com/s/1$id'},
        ),
      ).str('randsk');
      require(sekey.isNotEmpty, '百度没有返回分享凭证');
    }
    final result = await _shareList(id!, sekey, '/', ck, 1);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: result.str('title').ifEmpty('百度分享'),
      rootId: '/',
      metadata: {
        BaiduShareRoute.metadataKey: BaiduShareRoute.account.key,
        'shortId': id,
        'sekey': sekey,
        'shareId': result.str('share_id'),
        'uk': result.str('uk'),
        'cookie': ck,
      },
      sourceLink: link,
    );
  }

  Future<void> ensurePublicPassword(BrowseSession session) =>
      _publicParser.ensurePassword(session);

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    final ck = cookie(credential);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的百度网盘',
      rootId: '/',
      metadata: {'cookie': ck},
    );
  }

  String _shareKey(String value) {
    try {
      // randsk is already URL-encoded. query() performs the single wire encoding.
      final key = Uri.decodeComponent(value);
      require(!RegExp(r'[\x00-\x1f\x7f]').hasMatch(key), '百度分享凭证无效，请重新解析');
      return key;
    } on FormatException {
      throw const AppException('百度分享凭证无效，请重新解析');
    } on ArgumentError {
      throw const AppException('百度分享凭证无效，请重新解析');
    }
  }

  String _shareCookie(String ck, String sekey) {
    final pairs = LoginCredentials.cookiePairs(ck)
      ..removeWhere((name, _) => name.toLowerCase() == 'bdclnd');
    if (sekey.isNotEmpty) {
      pairs['BDCLND'] = Uri.encodeComponent(_shareKey(sekey));
    }
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<Json> _shareList(
    String id,
    String sekey,
    String directory,
    String ck,
    int page,
  ) async => check(
    await http.get(
      query('https://pan.baidu.com/rest/2.0/xpan/share', {
        'method': 'list',
        'shorturl': id,
        'page': page,
        'num': 100,
        'root': directory.isEmpty || directory == '/' ? 1 : 0,
        'dir': directory.ifEmpty('/'),
        if (sekey.isNotEmpty) 'sekey': _shareKey(sekey),
      }),
      {
        ...webHeaders(_shareCookie(ck, sekey)),
        'Referer': 'https://pan.baidu.com/s/1$id',
      },
    ),
    missingShareKey: sekey.isEmpty,
  );
  @override
  Future<List<CloudFile>> list(BrowseSession s, String parent, Credential? c) =>
      BaiduShareRoute.usesPublicParser(s)
      ? _publicParser.list(s, parent)
      : _compatibleList(s, parent, c);

  Future<List<CloudFile>> _compatibleList(
    BrowseSession s,
    String parent,
    Credential? c, {
    bool firstPageOnly = false,
  }) async {
    try {
      return await _list(s, parent, c, firstPageOnly: firstPageOnly);
    } on AccountLoginRequired {
      if (s.mode != BrowseMode.personal || c == null) rethrow;
      cookie(c);
      RequestScope.checkpoint();
      DiagnosticLog.event(
        'baidu.personal_list_fallback',
        fields: {'reason': 'app_session_rejected'},
      );
      // Retry from page one with the same account; mixing App offsets with Web
      // pages can omit files. Share parsing never enters this fallback.
      try {
        return await _list(
          s,
          parent,
          c,
          web: true,
          firstPageOnly: firstPageOnly,
        );
      } catch (error, stack) {
        DiagnosticLog.error(
          'baidu.personal_list_failed',
          error,
          stack,
          fields: {'route': 'web'},
        );
        rethrow;
      }
    }
  }

  Future<List<CloudFile>> _list(
    BrowseSession s,
    String parent,
    Credential? c, {
    bool web = false,
    bool firstPageOnly = false,
  }) async {
    final share = s.mode == BrowseMode.share;
    if (!share && c == null) throw const AccountLoginRequired('请先登录百度网盘');
    final ck = share
        ? (c?.primary ?? '').ifEmpty(s.meta('cookie'))
        : cookie(c!);
    final files = <CloudFile>[];
    final seen = <String>{};
    for (var page = 1; page <= 100; page++) {
      final j = share
          ? await _shareList(
              s.meta('shortId'),
              s.meta('sekey'),
              parent,
              ck,
              page,
            )
          : check(
              await http.get(
                query('https://pan.baidu.com/api/list', {
                  if (web) ...{
                    'channel': 'chunlei',
                    'clienttype': 0,
                    'app_id': appId(c!),
                    'web': 1,
                    'page': page,
                    'num': 100,
                  } else ...{
                    ...await _appParams(ck, appId(c!)),
                    'start': (page - 1) * 100,
                    'limit': 100,
                    'preset': 0,
                  },
                  'order': 'time',
                  'desc': 1,
                  'dir': parent.ifEmpty('/'),
                }),
                web
                    ? {
                        ...webHeaders(ck),
                        'Referer': 'https://pan.baidu.com/disk/main',
                      }
                    : diskHeaders(ck),
              ),
            );
      require(j['list'] is List, '百度文件列表响应不完整，请刷新重试');
      final batch = j.list('list');
      var fresh = 0;
      for (final item in batch) {
        final directory = item.integer('isdir') == 1 || item.boolean('isdir');
        final path = item.str('path');
        final id = item.str('fs_id').ifEmpty(directory ? path : '');
        require(
          id.isNotEmpty && (!directory || path.startsWith('/')),
          '百度文件信息不完整，请刷新列表',
        );
        if (!seen.add(id)) continue;
        fresh++;
        // Both personal and shared folders retain fs_id; traversal uses the path token.
        files.add(
          CloudFile(
            id: id,
            name: item.str('server_filename'),
            size: item.integer('size'),
            isDirectory: directory,
            parentId: parent,
            token: path,
            modifiedAt: item.str('server_mtime'),
            thumbnailUrl: item
                .obj('thumbs')
                .str('url3')
                .ifEmpty(item.obj('thumbs').str('url2'))
                .ifEmpty(item.obj('thumbs').str('url1')),
          ),
        );
      }
      if (firstPageOnly || batch.length < 100 || fresh == 0) break;
      require(page < 100, '目录文件过多，请缩小范围后重试');
    }
    return files;
  }

  /// 视频播放直连内置的 App/DLNA 接口；下载单独获取原文件地址。
  @override
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    require(!file.isDirectory && file.id.isNotEmpty, '请选择要播放的文件');
    if (fileKind(file.name) != FileKind.video ||
        BaiduShareRoute.usesPublicParser(session) && credential == null) {
      return download(session, file, credential);
    }
    if (credential == null) {
      throw const AccountLoginRequired('百度视频播放需要登录账号');
    }
    final ck = cookie(credential);
    if (session.mode == BrowseMode.share) {
      var current = session;
      final reopened =
          session.meta('shareId').isEmpty || session.meta('uk').isEmpty;
      if (reopened) {
        final link = session.sourceLink;
        require(link != null, '百度分享信息不完整，请重新解析');
        current = await OperationProgress.step(
          OperationStage.verifyShare,
          () => openShare(link!, credential, route: BaiduShareRoute.account),
        );
      }
      var sekey = current.meta('sekey');
      final link = current.sourceLink;
      if (!reopened && link?.passcode?.isNotEmpty == true) {
        sekey = await OperationProgress.step(
          OperationStage.verifyShare,
          () async {
            final shortId = current
                .meta('shortId')
                .ifEmpty(link!.shareId ?? '');
            require(
              RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(shortId),
              '百度分享信息不完整，请重新解析',
            );
            final verified = check(
              await http.postFormRead(
                query('https://pan.baidu.com/share/verify', {'surl': shortId}),
                form({'pwd': link.passcode, 'vcode_str': '', 'vcode': ''}),
                {
                  ...webHeaders(ck),
                  'Referer': 'https://pan.baidu.com/s/1$shortId',
                },
              ),
            ).str('randsk');
            require(verified.isNotEmpty, '百度没有返回分享凭证，请重新解析');
            return verified;
          },
        );
      }
      return OperationProgress.step(
        OperationStage.playbackLink,
        () => _playbackClient.share(
          current,
          file,
          cookie: _shareCookie(ck, sekey),
          sekey: sekey.isEmpty ? '' : _shareKey(sekey),
        ),
      );
    }
    var current = file;
    if (!file.token.startsWith('/') && !file.id.startsWith('/')) {
      final files = await list(
        await openPersonal(credential),
        file.parentId.ifEmpty('/'),
        credential,
      );
      final resolved = files
          .where((f) => f.id == file.id && !f.isDirectory)
          .firstOrNull;
      require(resolved != null, '百度视频文件已失效，请刷新文件列表');
      current = resolved!;
    }
    return OperationProgress.step(
      OperationStage.playbackLink,
      () => _playbackClient.personal(current, ck),
    );
  }

  /// 账号视频下载使用在线播放取链，非视频优先中转直链再回退内置预览。
  /// 公益分享使用独立解析站；文件内容由客户端直接读取返回的媒体地址。
  /// 因百度网盘接口的特殊性，服务端取链实现暂不开源，避免公开后接口很快失效。
  /// 后续会根据接口稳定性和实际情况考虑开源；此处保留客户端对接与下载流程。
  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile file,
    Credential? c,
  ) async {
    require(!file.isDirectory, '文件夹不能直接下载');
    if (BaiduShareRoute.usesPublicParser(s)) {
      return _publicParser.download(s, file);
    }
    // Video downloads use a fresh ticket from the same API as online playback.
    // Keep ordinary files on the account relay/local-preview download route.
    if (fileKind(file.name) == FileKind.video) {
      return playback(s, file, c);
    }
    if (c == null) throw const AccountLoginRequired('百度下载需要登录账号');
    final account = c, ck = cookie(c), id = appId(c);
    DownloadCleanup? cleanup;
    Json? transfer;
    BaiduResolvedLink direct;
    if (s.mode == BrowseMode.share && !await _ownsShare(s, c)) {
      const root = '/文析助手临时转存';
      final directory = '$root/tr_${newId()}';
      await OperationProgress.step(OperationStage.createTemporary, () async {
        await _mkdir(root, account, allowExisting: true);
        await _mkdir(directory, account);
      });
      // Delete only the unique directory created by this request, never the shared root.
      cleanup = DownloadCleanup(
        url: await _managerUrl('delete', ck, id),
        body: form({
          'filelist': encoded([directory]),
        }),
        headers: {
          ...diskHeaders(ck),
          'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
        },
      );
      try {
        await stageCleanup?.call(cleanup);
        final transferred = await OperationProgress.step(
          OperationStage.transfer,
          () => _transfer(s, file, directory, account),
        );
        final path = transferred.str('to');
        require(_insideTransfer(path, directory), '百度转存未返回完整文件路径');
        final saved = await OperationProgress.step(
          OperationStage.transfer,
          () => _confirmedTransfer(
            directory,
            transferred.str('to_fs_id'),
            path,
            file.size,
            account,
          ),
        );
        require(saved != null, '百度转存文件尚未就绪，请稍后重试');
        transfer = {'directory': directory, 'file': saved!.toJson()};
        direct = await OperationProgress.step(
          OperationStage.downloadLink,
          () => _downloadUrl(saved.token, saved.id, account),
        );
        DiagnosticLog.event(
          'baidu.share_download_ready',
          fields: {'reused': false, 'preview': direct.preview},
        );
      } catch (_) {
        final pending = cleanup;
        try {
          await OperationProgress.step(OperationStage.cleanup, () async {
            check(
              await http.postForm(pending.url, pending.body!, pending.headers),
            );
          });
        } catch (_) {}
        rethrow;
      }
    } else {
      final path = file.token.ifEmpty(file.id.startsWith('/') ? file.id : '');
      direct = await OperationProgress.step(
        OperationStage.downloadLink,
        () => _downloadUrl(path, file.id, account),
      );
    }
    require(direct.url.isNotEmpty, '百度没有返回可用下载链接');
    return DownloadSpec(
      url: direct.url,
      fileName: file.name,
      expectedSize: file.size,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
      headers: direct.profile == 'baidu_direct'
          ? direct.headers
          : {
              'Cookie': ck,
              'User-Agent': _client.downloadUserAgent,
              'Referer': 'https://pan.baidu.com/',
              'Accept-Encoding': 'identity',
              'Content-Transfer-Encoding': 'binary',
            },
      cleanup: cleanup,
      source: transfer == null ? null : {'baiduTransfer': transfer},
      profile: direct.profile,
    );
  }

  bool _insideTransfer(String path, String directory) {
    if (!path.startsWith('$directory/')) return false;
    final name = path.substring(directory.length + 1);
    return name.isNotEmpty &&
        !{'..', '.'}.contains(name) &&
        !name.contains('/');
  }

  Future<CloudFile?> _confirmedTransfer(
    String directory,
    String fileId,
    String path,
    int size,
    Credential c,
  ) async {
    final personal = await openPersonal(c);
    // A transfer acknowledgement can arrive before the personal listing updates.
    // Retry visibility only; network/authentication failures must not retransfer.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await RequestScope.wait(Duration(milliseconds: attempt * 400));
      }
      RequestScope.checkpoint();
      List<CloudFile> files;
      try {
        files = await list(personal, directory, c);
      } on _BaiduFileMissing {
        files = const [];
      }
      final saved = files.where((f) => f.id == fileId).firstOrNull;
      if (saved != null) {
        require(
          !saved.isDirectory &&
              saved.token == path &&
              (size <= 0 || saved.size == size),
          '百度转存文件信息发生变化，请重新解析',
        );
        return saved;
      }
    }
    return null;
  }

  /// Refresh the task's existing copy, retaining the original share separately
  /// so a cleaned or deleted temporary copy can still be recreated by the caller.
  Future<DownloadSpec?> refreshTransfer(
    DownloadSpec previous,
    Credential c,
  ) async {
    final transfer = previous.source?.obj('baiduTransfer');
    final cleanup = previous.cleanup;
    if (transfer == null || transfer.isEmpty || cleanup == null) return null;
    final directory = transfer.str('directory');
    final file = CloudFile.fromJson(transfer.obj('file'));
    if (!RegExp(
          r'^/文析助手临时转存/tr_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(directory) ||
        !_insideTransfer(file.token, directory) ||
        file.id.isEmpty ||
        file.isDirectory) {
      return null;
    }
    // Only reuse the copy owned by this cleanup record, never arbitrary paths
    // from old or malformed persisted state.
    try {
      final endpoint = Uri.parse(cleanup.url);
      final paths = jsonDecode(
        Uri.splitQueryString(cleanup.body ?? '')['filelist'] ?? 'null',
      );
      if (endpoint.scheme != 'https' ||
          endpoint.host != 'pan.baidu.com' ||
          endpoint.path != '/api/filemanager' ||
          endpoint.queryParameters['opera'] != 'delete' ||
          cleanup.method != 'POST' ||
          cleanup.action != null ||
          paths is! List ||
          paths.length != 1 ||
          paths.single != directory) {
        return null;
      }
    } on FormatException {
      return null;
    }
    final saved = await _confirmedTransfer(
      directory,
      file.id,
      file.token,
      previous.expectedSize > 0 ? previous.expectedSize : file.size,
      c,
    );
    if (saved == null) return null;
    final result = await download(await openPersonal(c), saved, c);
    DiagnosticLog.event(
      'baidu.share_download_ready',
      fields: {'reused': true, 'preview': result.profile == 'baidu_preview'},
    );
    return result.copyWith(
      fileName: previous.fileName,
      relativePath: previous.relativePath,
      cleanup: cleanup,
      source: previous.source,
    );
  }

  Future<BaiduResolvedLink> _downloadUrl(
    String path,
    String fsId,
    Credential c,
  ) async {
    final ck = cookie(c), id = appId(c);
    await _client.prepare();
    RequestScope.checkpoint();
    final result = await _linkLookup(
      cookie: ck,
      path: path,
      fileId: fsId,
      appId: id,
      device: _client.serviceDevice,
    );
    RequestScope.checkpoint();
    return result;
  }

  Future<Json> _mkdir(
    String path,
    Credential c, {
    bool allowExisting = false,
  }) async {
    return check(
      await http.postForm(
        query('https://pan.baidu.com/api/create', {
          ...await _appParams(cookie(c), appId(c)),
          'a': 'commit',
          'norename': '',
        }),
        form({
          'path': path,
          'isdir': 1,
          'size': 0,
          'block_list': '[]',
          'local_ctime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'local_mtime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        }),
        diskHeaders(cookie(c)),
      ),
      allowExisting: allowExisting,
    );
  }

  Future<String> _managerUrl(String op, String ck, String id) async =>
      query('https://pan.baidu.com/api/filemanager', {
        ...await _appParams(ck, id),
        'async': 0,
        'onnest': 'fail',
        'opera': op,
        if (op == 'delete') 'newVerify': 1,
      });
  Future<void> _manage(String op, List<Object?> files, Credential c) async {
    check(
      await http.postForm(
        await _managerUrl(op, cookie(c), appId(c)),
        form({'filelist': encoded(files)}),
        diskHeaders(cookie(c)),
      ),
    );
  }

  void personal(BrowseSession s) =>
      require(s.mode == BrowseMode.personal, '请在个人网盘中执行此操作');

  Future<List<String>> _uploadServers(Credential c, String sign) async {
    final j = check(
      await http.get(
        query('https://d.pcs.baidu.com/rest/2.0/pcs/file', {
          ...await _appParams(cookie(c), appId(c)),
          'method': 'locateupload',
          'upload_version': '2.0',
          if (sign.isNotEmpty) 'uploadsign': sign,
        }),
        diskHeaders(cookie(c)),
      ),
      allowMissingCode: true,
    );
    final servers = <String>{};
    for (final value in [
      ...j.list('servers').map((s) => s.str('server')),
      ...j.list('bak_servers').map((s) => s.str('server')),
      if (j.str('host').isNotEmpty) 'https://${j.str('host')}',
    ]) {
      final uri = Uri.tryParse(value);
      // These endpoints receive the account cookie and file contents.
      if (uri == null ||
          uri.scheme != 'https' ||
          !uri.host.endsWith('.pcs.baidu.com') ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.port != 443 ||
          !{'', '/'}.contains(uri.path)) {
        continue;
      }
      servers.add(uri.origin);
    }
    require(servers.isNotEmpty, '百度未返回可用上传节点，请稍后重试');
    return servers.take(3).toList();
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
    require(source.size > 0, '百度网盘不支持上传空文件');
    final io = UploadIO(http, source, onProgress), ck = cookie(c);
    final path = '${parent.replaceFirst(RegExp(r'/+$'), '')}/${source.name}';
    const chunkSize = 4 * 1024 * 1024;
    final count = (source.size / chunkSize).ceil(), blocks = <String>[];
    for (var i = 0; i < count; i++) {
      blocks.add(
        await io.digest(
          md5,
          start: i * chunkSize,
          end: math.min(source.size, (i + 1) * chunkSize),
        ),
      );
    }
    final whole = await io.digest(md5),
        prefix = await io.digest(md5, end: math.min(source.size, 256 * 1024));
    final params = await _appParams(ck, appId(c));
    final pre = check(
      await http.postForm(
        query('https://pan.baidu.com/api/precreate', params),
        form({
          'path': path,
          'isdir': 0,
          'size': source.size,
          'autoinit': 1,
          'block_list': encoded(blocks),
          'rtype': 0,
          'content-md5': whole,
          'slice-md5': prefix,
        }),
        diskHeaders(ck),
      ),
    );
    if (pre.integer('return_type') != 2) {
      final uploadId = pre.str('uploadid');
      require(uploadId.isNotEmpty, '百度未创建上传任务');
      final needed = pre['block_list'];
      require(needed is List, '百度未返回待上传分段');
      final servers = (needed as List).isEmpty
          ? <String>[]
          : await _uploadServers(c, pre.str('uploadsign'));
      var serverIndex = 0;
      final uploaded = <int>{};
      for (final raw in needed) {
        final index = int.tryParse('$raw');
        require(
          index != null && index >= 0 && index < count && uploaded.add(index),
          '百度返回的上传分段序号无效',
        );
        late Json result;
        for (;;) {
          RequestScope.checkpoint();
          try {
            final response = await io.send(
              query('${servers[serverIndex]}/rest/2.0/pcs/superfile2', {
                ...params,
                'method': 'upload',
                'type': 'tmpfile',
                'path': path,
                'uploadid': uploadId,
                'partseq': index,
              }),
              method: 'POST',
              start: index! * chunkSize,
              end: math.min(source.size, (index + 1) * chunkSize),
              fields: const {},
              headers: diskHeaders(ck),
              retry: false,
            );
            result = check(response, allowMissingCode: true);
            break;
          } on HttpRequestFailure catch (error) {
            RequestScope.checkpoint();
            // uploadid + partseq identify the same temporary block on every
            // node; switching nodes never commits a second user file.
            if (!error.retryable || serverIndex + 1 >= servers.length) rethrow;
            serverIndex++;
          }
        }
        require(result.str('md5').toLowerCase() == blocks[index], '百度上传分段校验失败');
      }
      io.progress(UploadPhase.finishing, source.size);
      final completed = check(
        await http.postForm(
          query('https://pan.baidu.com/api/create', {...params, 'a': 'commit'}),
          form({
            'path': path,
            'isdir': 0,
            'size': source.size,
            'uploadid': uploadId,
            'block_list': encoded(blocks),
            'rtype': 0,
            'local_mtime': source.modifiedAt.millisecondsSinceEpoch ~/ 1000,
          }),
          diskHeaders(ck),
        ),
      );
      return io.confirm(() => list(s, parent, c), id: completed.str('fs_id'));
    }
    return io.confirm(
      () => list(s, parent, c),
      id: pre.obj('info').str('fs_id'),
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
    final path = '${parent.replaceFirst(RegExp(r'/+$'), '')}/$name';
    final created = await _mkdir(path, c);
    return CloudFile(
      id: created.str('fs_id').ifEmpty(path),
      name: name,
      isDirectory: true,
      parentId: parent,
      token: path,
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
    await _manage('rename', [
      {'path': f.token.ifEmpty(f.id), 'newname': name},
    ], c);
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    personal(s);
    await _manage(
      'move',
      files
          .map(
            (f) => {
              'path': f.token.ifEmpty(f.id),
              'dest': target,
              'newname': f.token.ifEmpty(f.id).split('/').last,
            },
          )
          .toList(),
      c,
    );
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    personal(s);
    await _manage(
      'delete',
      files.map((f) => f.token.ifEmpty(f.id)).toList(),
      c,
    );
  }

  Future<Json> _transfer(
    BrowseSession s,
    CloudFile file,
    String target,
    Credential c,
  ) async {
    final ck = cookie(c), sekey = s.meta('sekey');
    require(RegExp(r'^\d+$').hasMatch(file.id), '百度文件标识缺失，请重新打开分享列表');
    var shareId = s.meta('shareId'), uk = s.meta('uk');
    if (shareId.isEmpty || uk.isEmpty) {
      final root = await _shareList(s.meta('shortId'), sekey, '/', ck, 1);
      shareId = root.str('share_id');
      uk = root.str('uk');
    }
    require(shareId.isNotEmpty && uk.isNotEmpty, '百度分享信息不完整，请重新解析链接');
    final j = check(
      await http.postForm(
        query('https://pan.baidu.com/share/transfer', {
          ...await _appParams(ck, appId(c)),
          'shareid': shareId,
          'from': uk,
          if (sekey.isNotEmpty) 'sekey': _shareKey(sekey),
          'ondup': 'newcopy',
        }),
        form({
          'fsidlist': encoded([file.id]),
          'path': target,
          'force': 1,
        }),
        {
          ...diskHeaders(_shareCookie(ck, sekey)),
          'Origin': 'https://pan.baidu.com',
          'Referer': 'https://pan.baidu.com/s/',
        },
      ),
    );
    final item = j.obj('extra').list('list').firstOrNull;
    require(item != null && item.str('to_fs_id').isNotEmpty, '百度转存未返回文件信息');
    return item!;
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请打开分享链接');
    if (BaiduShareRoute.usesPublicParser(s)) {
      require(s.sourceLink != null, '原百度分享信息缺失，请重新解析');
      final ownSession = await openShare(
        s.sourceLink!,
        c,
        route: BaiduShareRoute.account,
      );
      return saveShare(ownSession, files, target, c);
    }
    if (await _ownsShare(s, c)) {
      // Baidu rejects transferring a share back to its owner, even into a
      // different directory. Copy the authenticated owner's original paths.
      await _manage('copy', [
        for (final file in files)
          {
            'path': file.token.ifEmpty(file.id),
            'dest': target,
            'newname': file.name,
          },
      ], c);
      return;
    }
    for (final file in files) {
      await _transfer(s, file, target, c);
    }
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    personal(s);
    final password = options.passcode ?? '';
    require(
      files.isNotEmpty &&
          files.every((f) => f.token.ifEmpty(f.id).startsWith('/')),
      '百度文件路径缺失，请刷新列表后重试',
    );
    final j = check(
      await http.postForm(
        query(
          'https://pan.baidu.com/share/pset',
          await _appParams(cookie(c), appId(c)),
        ),
        form({
          'path_list': encoded(
            files.map((f) => f.token.ifEmpty(f.id)).toList(),
          ),
          'schannel': 4,
          'channel_list': '[]',
          'period': {1, 7, 30}.contains(options.expiryDays)
              ? options.expiryDays
              : 0,
          'pwd': password,
        }),
        diskHeaders(cookie(c)),
      ),
    );
    final url = j.str('shorturl').ifEmpty(j.str('link'));
    require(url.isNotEmpty, '百度没有返回分享链接');
    return ShareCreation(url, password, options.title);
  }
}
