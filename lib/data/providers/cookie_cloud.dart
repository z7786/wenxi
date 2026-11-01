import 'dart:async';
import '../../core/json.dart';
import '../../core/operation_progress.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../../domain/file_types.dart';
import '../../download/download_request.dart';
import '../http.dart';
import '../state_store.dart';
import 'quark_uc.dart';

class UcOriginalContentMismatch extends AppException {
  const UcOriginalContentMismatch() : super('UC 返回的内容与所选文件不一致，可能受到外部播放或会员限制');
}

class _ShareDirectUnavailable extends AppException {
  const _ShareDirectUnavailable(super.message);
}

/// Shared UC/Quark session lifetime; each connector keeps its protocol headers.
class CookieCloudConnector extends QuarkUcConnector {
  CookieCloudConnector(
    CloudPlatform platform,
    JsonHttp http, {
    required String webUserAgent,
    required String apiUserAgent,
    CredentialStore? store,
    Future<void> Function(DownloadCleanup)? stageCleanup,
    Duration taskDelay = const Duration(milliseconds: 750),
    int Function()? now,
    bool Function(bool authenticated)? directShareDownloadEnabled,
  }) : this._(
         platform,
         _CookieCloudHttp(
           http,
           store,
           now,
           platform,
           webUserAgent,
           apiUserAgent,
         ),
         taskDelay,
         stageCleanup,
         directShareDownloadEnabled,
       );

  CookieCloudConnector._(
    CloudPlatform platform,
    this._sessions,
    Duration delay,
    Future<void> Function(DownloadCleanup)? stageCleanup,
    this.directShareDownloadEnabled,
  ) : super(platform, _sessions, taskDelay: delay, stageCleanup: stageCleanup);

  final _CookieCloudHttp _sessions;
  final bool Function(bool authenticated)? directShareDownloadEnabled;
  @override
  String get ua => quark ? _sessions.apiUserAgent : _sessions.webUserAgent;
  @override
  Map<String, String> headers(String cookie, {bool transfer = false}) => {
    'Cookie': _sessions.current?.cookie ?? cookie,
    'User-Agent': ua,
    'Origin': transfer ? 'https://fast.uc.cn' : origin,
    'Referer': '${transfer ? 'https://fast.uc.cn' : origin}/',
  };
  @override
  String url(String path, [Map<String, Object?> extra = const {}]) =>
      super.url(path, {
        if (path == 'file/sort') '_fetch_sub_dirs': 0,
        if (quark && path == 'file/sort') ...{
          'uc_param_str': '',
          'fetch_all_file': 1,
          'fetch_risk_file_name': 1,
        },
        if (quark && path == 'share/sharepage/detail') ...{
          'force': 0,
          '_fetch_banner': 0,
          '_fetch_share': 0,
          'fetch_relate_conversation': 0,
        },
        if (quark &&
            {
              'file/delete',
              'file/rename',
              'file/move',
              'share',
              'share/password',
            }.contains(path))
          'uc_param_str': '',
        ...extra,
      });

  @override
  Json success(HttpResult result) {
    if (_CookieCloudHttp.loginRequired(result)) {
      throw AccountLoginRequired('${platform.shortName} 登录已失效，请重新网页登录');
    }
    final json = result.json;
    final status = int.tryParse(json.str('status'));
    final code = int.tryParse(json.str('code'));
    if (!result.successful ||
        !(status == 200 || status == null && code == 0) ||
        json.containsKey('code') && code != 0) {
      throw providerError(
        json.str('message'),
        '${platform.shortName} 请求失败（HTTP ${result.status}）',
        code: code,
      );
    }
    require(
      json['data'] is Map || json['data'] is List,
      '${platform.shortName} 响应缺少有效数据，请重试',
    );
    return json['data'] is Map ? json.obj('data') : {'data': json['data']};
  }

  /// Keep renewed cookies from candidate validation in the final login result;
  /// the login service remains responsible for atomically replacing the account.
  Future<LoginResult> authenticate(Credential credential) =>
      _sessions.run(credential, '', (session) async {
        CloudAccount account;
        try {
          account = await _account(credential);
        } on AccountLoginRequired {
          rethrow;
        } on AppException {
          _sessions.checkpoint();
          account = CloudAccount(
            credential.field('nickname').ifEmpty('${platform.shortName} 用户'),
          );
        }
        return LoginResult(
          credential.withFields({
            'primary': session.cookie,
            if (session.refreshedAt > 0)
              _sessions.refreshField: '${session.refreshedAt}',
          }),
          account,
        );
      });

  @override
  Future<CloudAccount> account(Credential credential) =>
      _sessions.run(credential, '', (_) => _account(credential));

  Future<CloudAccount> _account(Credential credential) async {
    final data = success(
      await http.get(
        url('member', {'fetch_subscribe': true, '_ch': 'home'}),
        headers(credential.primary),
      ),
    );
    final used = int.tryParse(data.str('use_capacity'));
    final total = int.tryParse(data.str('total_capacity'));
    require(
      used != null && used >= 0 && total != null && total > 0,
      '${platform.shortName} 未返回有效容量，请重试',
    );
    var nickname = data
        .str('nickname')
        .ifEmpty(data.str('username'))
        .ifEmpty(credential.field('nickname'));
    if (nickname.isEmpty) {
      try {
        final result = await http.get(
          '$origin/account/info',
          headers(credential.primary),
        );
        final json = result.json;
        if (result.successful && json.boolean('success')) {
          nickname = json.obj('data').str('nickname');
        }
      } on AppException {
        _sessions.checkpoint();
        // The cloud quota already authenticated the account. Web display-name
        // failures do not invalidate that successful cloud response.
      }
    }
    return CloudAccount(
      nickname.ifEmpty('${platform.shortName} 用户'),
      used: used!,
      total: total!,
    );
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async {
    final cookie = LoginCredentials.normalize(platform, credential.primary);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: '我的${platform.shortName}网盘',
      rootId: '0',
      metadata: {'cookie': cookie},
    );
  }

  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? credential) =>
      _sessions.run(credential, '', (_) async {
        final session = await super.openShare(link, credential);
        require(
          session.meta('stoken').isNotEmpty,
          '${platform.shortName} 未返回分享凭证，请重新解析',
        );
        return session;
      });

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) => _sessions.run(credential, session.meta('cookie'), (_) async {
    if (session.mode == BrowseMode.personal && credential == null) {
      throw AccountLoginRequired('请先登录 ${platform.shortName} 网盘');
    }
    return super.list(session, parentId.ifEmpty('0'), credential);
  });

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    final direct = await tryShareDownload(
      session,
      file,
      credential,
      onRefreshed: (freshSession, freshFile) {
        session = freshSession;
        file = freshFile;
      },
    );
    return direct ?? await downloadFallback(session, file, credential);
  }

  Future<DownloadSpec> downloadFallback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => _prepare(session, file, credential, forPlayback: false);

  /// Guest cookies remain isolated from saved accounts. Unavailable direct
  /// endpoints permit an account retry; only access restrictions permit transfer.
  Future<DownloadSpec?> tryShareDownload(
    BrowseSession session,
    CloudFile file,
    Credential? credential, {
    void Function(BrowseSession, CloudFile)? onRefreshed,
  }) async {
    if (session.mode != BrowseMode.share) return null;
    // With no selected account, guest access is always attempted. With an
    // account, the guest and authenticated routes have independent settings.
    final directEnabled = directShareDownloadEnabled;
    return _tryShareDownload(
      session,
      file,
      credential,
      guestEnabled: credential == null || (directEnabled?.call(false) ?? true),
      accountEnabled: credential != null && (directEnabled?.call(true) ?? true),
      onRefreshed: onRefreshed,
    );
  }

  Future<DownloadSpec?> _tryShareDownload(
    BrowseSession session,
    CloudFile file,
    Credential? credential, {
    required bool guestEnabled,
    required bool accountEnabled,
    String? reason,
    void Function(BrowseSession, CloudFile)? onRefreshed,
  }) async {
    if (session.mode != BrowseMode.share) return null;
    if (!guestEnabled && !accountEnabled) return null;
    require(!file.isDirectory, '文件夹不能直接下载');
    var refreshed = false;
    Future<void> refreshTokens(Credential? account) async {
      final link = session.sourceLink;
      require(link != null, '原分享链接已缺失，请重新解析');
      RequestScope.checkpoint();
      final freshSession = await openShare(link!, account);
      final parent = file.parentId == session.rootId || file.parentId.isEmpty
          ? freshSession.rootId
          : file.parentId;
      final files = await list(freshSession, parent, account);
      final matches = files.where(
        (candidate) => candidate.id == file.id && !candidate.isDirectory,
      );
      require(matches.length == 1, '原文件已不在分享目录中，请重新解析');
      final freshFile = matches.single;
      require(file.size <= 0 || freshFile.size == file.size, '分享文件大小已变化，请重新解析');
      require(
        (file.hashValue ?? '').isEmpty ||
            (freshFile.hashValue ?? '').isEmpty ||
            file.hashValue == freshFile.hashValue,
        '分享文件内容已变化，请重新解析',
      );
      session = freshSession;
      file = freshFile;
      refreshed = true;
      onRefreshed?.call(session, file);
      DiagnosticLog.event(
        'share.download_fallback',
        fields: {
          'platform': platform.key,
          'stage': 'refresh_share_credentials',
        },
      );
    }

    Future<DownloadSpec?> attempt(Credential? account) =>
        _sessions.run(account, '', (_) async {
          if (account != null) await _sessions.ensureFresh();
          if (session.meta('stoken').isEmpty || file.token.isEmpty) {
            throw const _ShareDirectUnavailable('分享下载凭证缺失');
          }
          return _shareDownload(session, file);
        }, isolated: true);
    Future<DownloadSpec?> recover(Credential? account) async {
      try {
        return await attempt(account);
      } on _ShareDirectUnavailable {
        if (refreshed) rethrow;
        await refreshTokens(account);
        return attempt(account);
      }
    }

    String? guestFailure;
    DownloadSpec? guest;
    if (guestEnabled) {
      // A signed-in attempt may still finish on the account route. Successful
      // guest downloads are identified by guestDownload on the returned spec.
      if (credential == null) {
        DownloadRequestContext.current?.onGuestDownload?.call();
      }
      try {
        guest = await _sessions.run(
          null,
          '',
          (_) => recover(null),
          isolated: true,
        );
      } on _ShareDirectUnavailable catch (error) {
        guestFailure = error.message;
      } on AccountLoginRequired {
        if (!quark || credential == null) rethrow;
        RequestScope.checkpoint();
        // Guest share-token renewal can require login even while the selected
        // account remains valid. Continue with its independent account route.
        guestFailure = '游客分享接口要求登录';
      } on UcOriginalContentMismatch {
        RequestScope.checkpoint();
        // A restricted guest response says nothing about the selected account's
        // access. Keep its cookies isolated and try the normal account route.
        guestFailure = '游客接口未返回所选原文件';
      } on HttpRequestFailure {
        RequestScope.checkpoint();
        if (quark || credential == null) rethrow;
        guestFailure = '游客接口连接暂不可用';
      }
    }
    if (guest != null) return guest.copyWith(guestDownload: true);
    if (credential == null) {
      if (guestFailure != null) {
        throw AccountLoginRequired(
          '${platform.shortName}游客下载暂不可用，'
          '${refreshed ? '已刷新分享凭证重试；' : ''}'
          '请登录后重试（$guestFailure）',
        );
      }
      throw AccountLoginRequired(
        quark
            ? '夸克游客不支持超过50MB文件下载，请登录夸克网盘再试'
            : '${platform.shortName}此文件不支持游客下载，请登录后重试',
      );
    }
    if (!accountEnabled) {
      DiagnosticLog.event(
        'share.download_fallback',
        fields: {
          'platform': platform.key,
          'stage': 'account_transfer',
          'reason': guestFailure ?? 'guest_access_restricted',
        },
      );
      return null;
    }
    DiagnosticLog.event(
      'share.download_fallback',
      fields: {
        'platform': platform.key,
        'stage': 'authenticated_direct',
        'reason':
            reason ??
            guestFailure ??
            (guestEnabled ? 'guest_access_restricted' : 'guest_disabled'),
      },
    );
    try {
      return await recover(credential);
    } on _ShareDirectUnavailable catch (error) {
      throw AppException(
        '${platform.shortName}分享直链接口暂不可用：${error.message}；请稍后重试',
      );
    }
  }

  Future<DownloadSpec?> _shareDownload(
    BrowseSession session,
    CloudFile file,
  ) async {
    final shareUa = quark
        ? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 QuarkPC/6.9.7.761 QuarkCloudDrivePC/6.9.7.761 quark-cloud-drive/2.5.40'
        : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/1.8.8 Chrome/100.0.4896.160 Electron/18.3.5.16-b62cf9c50d Safari/537.36 Channel/ucpan_other_ch';
    final clientHeaders = {
      'User-Agent': shareUa,
      if (!quark)
        'Sec-Ch-Ua':
            '"Not=A?Brand";v="99", "Chromium";v="100", "Google Chrome";v="100"',
    };
    final owner = _sessions.current!.owner;
    final response = await _sessions.transport.postJsonRead(
      url('file/download', {
        'sys': 'win32',
        've': quark ? '6.9.7.761' : '1.8.8',
      }),
      {
        'fids': [file.id],
        'fids_token': [file.token],
        'pwd_id': session.meta('shareId'),
        'stoken': session.meta('stoken'),
        if (quark) ...{'speedup_session': '', 'token': ''},
      },
      {...headers(''), ...clientHeaders},
    );
    await _sessions._accept(response, owner);
    _sessions.checkpoint();
    if ({404, 405}.contains(response.status)) {
      throw _ShareDirectUnavailable('下载接口返回 HTTP ${response.status}');
    }
    if (!quark && {408, 429, 500, 502, 503, 504}.contains(response.status)) {
      throw HttpRequestFailure(
        'UC 游客下载暂不可用（HTTP ${response.status}），请稍后重试或登录账号下载',
        kind: 'uc_guest',
        status: response.status,
        retryable: true,
      );
    }
    if ({401, 403}.contains(response.status)) return null;
    late Json json;
    try {
      json = response.json;
    } on AppException {
      throw const _ShareDirectUnavailable('下载接口响应格式异常');
    }
    if ({14001, 41020}.contains(json.integer('code'))) {
      throw const _ShareDirectUnavailable('分享下载凭证已失效');
    }
    if ({23018, 31001}.contains(json.integer('code'))) {
      return null;
    }
    final checked = success(response);
    if (checked['data'] is! List || checked.list('data').isEmpty) {
      throw const _ShareDirectUnavailable('下载接口未返回直链数据');
    }
    final data = checked.list('data');
    require(
      data.length == 1 && data.single.str('fid') == file.id,
      '${platform.shortName} 返回的下载文件与所选文件不一致，请刷新列表后重试',
    );
    final item = data.single;
    final address = item.str('download_url');
    final uri = Uri.tryParse(address);
    final domain = quark ? 'quark.cn' : 'uc.cn';
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.userInfo.isEmpty &&
          uri.host.endsWith('.$domain'),
      '${platform.shortName} 未返回有效的分享下载地址',
    );
    require(
      file.size <= 0 || item.integer('size') == file.size,
      '${platform.shortName} 返回的文件大小与所选文件不一致',
    );
    final downloadHeaders = {
      ...clientHeaders,
      'Cookie': _sessions.current!.cookie,
      'Referer': '$origin/',
    };
    final probe = await _sessions.transport.peek(
      address,
      {...downloadHeaders, 'Accept-Encoding': 'identity'},
      maxBytes: 1,
      followRedirects: false,
    );
    _sessions.checkpoint();
    if ({401, 403, 412}.contains(probe.status)) return null;
    final range = RegExp(
      r'^bytes 0-0/(\d+)$',
    ).firstMatch(probe.header('content-range'));
    final total = probe.status == 206 && range != null
        ? int.tryParse(range[1]!)
        : probe.status == 200
        ? int.tryParse(probe.header('content-length'))
        : null;
    final encoding = probe.header('content-encoding').toLowerCase();
    final length = int.tryParse(probe.header('content-length'));
    require(
      probe.successful &&
          total != null &&
          total > 0 &&
          (encoding.isEmpty || encoding == 'identity') &&
          (probe.status != 206 || length == null || length == 1),
      '${platform.shortName} 分享文件长度检查失败，请稍后重试',
    );
    if ((file.size > 0 && total != file.size) ||
        (item.integer('size') > 0 && total != item.integer('size'))) {
      if (!quark) {
        DiagnosticLog.event(
          'uc.original_content_mismatch',
          fields: {
            'file': DiagnosticLog.reference(file.id),
            'route': 'share',
            'expectedBytes': file.size,
            'receivedTotal': total,
          },
        );
        throw const UcOriginalContentMismatch();
      }
      throw const AppException('夸克返回的文件内容与所选文件不一致');
    }
    return DownloadSpec(
      url: address,
      fileName: file.name,
      expectedSize: total!,
      headers: downloadHeaders,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
    );
  }

  @override
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => _prepare(session, file, credential, forPlayback: true);

  /// Share transfer still uses the web account, while a stream resolver owns
  /// its separate authorization, media size, and CDN headers.
  Future<DownloadSpec> prepareStream(
    BrowseSession session,
    CloudFile file,
    Credential credential,
    Future<DownloadSpec> Function(String fid) resolve, {
    bool forPlayback = true,
  }) => _sessions.run(credential, session.meta('cookie'), (_) async {
    require(!file.isDirectory, forPlayback ? '文件夹不能直接播放' : '文件夹不能直接下载');
    if (session.mode == BrowseMode.share) {
      require(
        session.meta('stoken').isNotEmpty && file.token.isNotEmpty,
        '${platform.shortName} 分享凭证已缺失，请重新打开分享列表',
      );
    }
    if (session.mode == BrowseMode.share || !forPlayback) {
      await _sessions.ensureFresh();
    }
    final result = await super.prepareFile(
      session,
      file,
      credential,
      forPlayback: forPlayback,
      resolveStream: resolve,
    );
    _sessions.checkpoint();
    return result;
  });

  /// Read only a bounded prefix without buffering the complete media object.
  Future<HttpResult> probeDownload(
    String address,
    Map<String, String> requestHeaders, {
    bool followRedirects = true,
  }) async {
    _sessions.checkpoint();
    final result = await _sessions.transport.peek(
      address,
      requestHeaders,
      maxBytes: 1,
      followRedirects: followRedirects,
    );
    _sessions.checkpoint();
    RequestScope.checkpoint();
    return result;
  }

  Future<DownloadSpec> _prepare(
    BrowseSession session,
    CloudFile file,
    Credential? credential, {
    required bool forPlayback,
  }) => _sessions.run(credential, session.meta('cookie'), (_) async {
    require(!file.isDirectory, '文件夹不能直接下载');
    if (session.mode == BrowseMode.personal && credential == null) {
      throw AccountLoginRequired('请先登录 ${platform.shortName} 网盘');
    }
    if (session.mode == BrowseMode.share) {
      require(
        session.meta('stoken').isNotEmpty && file.token.isNotEmpty,
        '${platform.shortName} 分享下载凭证已缺失，请重新打开分享列表',
      );
    }
    await _sessions.ensureFresh();
    late DownloadSpec spec;
    try {
      spec = await super.prepareFile(
        session,
        file,
        credential,
        forPlayback: forPlayback,
      );
    } on QuarkUcCapacityExceeded {
      if (!quark ||
          forPlayback ||
          session.mode != BrowseMode.share ||
          credential == null) {
        rethrow;
      }
      _sessions.checkpoint();
      // Transfer may have renewed the account cookies. Keep the same account
      // revision and use its current session for this download only.
      final current = _sessions.current!;
      final account = (current.owner ?? credential).withFields({
        'primary': current.cookie,
        _sessions.refreshField: '${current.refreshedAt}',
      }, preserveRevision: true);
      final direct = await OperationProgress.step(
        OperationStage.downloadLink,
        () => _tryShareDownload(
          session,
          file,
          account,
          guestEnabled: false,
          accountEnabled: true,
          reason: 'cloud_capacity_limit',
        ),
      );
      _sessions.checkpoint();
      if (direct == null) {
        throw const QuarkUcCapacityExceeded(
          '夸克网盘空间不足，已自动尝试免转存下载但未成功，请清理网盘空间后重试',
        );
      }
      return direct;
    }
    _sessions.checkpoint();
    final uri = Uri.tryParse(spec.url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '${platform.shortName} 未返回有效下载地址',
    );
    require(
      file.size <= 0 ||
          spec.expectedSize <= 0 ||
          file.size == spec.expectedSize,
      '${platform.shortName} 返回的文件大小与所选文件不一致，请刷新列表后重试',
    );
    var expectedSize = spec.expectedSize > 0 ? spec.expectedSize : file.size;
    // UC may return a valid MP4 containing a membership notice, with its own
    // matching MD5 but the original file's size and fid in JSON. A checksum
    // alone cannot establish that this is the selected media. Check length
    // before either playback or download; never accept a replacement object.
    if (!quark &&
        (fileKind(file.name) == FileKind.video ||
            spec.checksumType == 'md5' &&
                RegExp(r'^[0-9a-f]{32}$').hasMatch(spec.checksumValue ?? ''))) {
      final probe = await probeDownload(spec.url, {
        ...headers(''),
        'Accept-Encoding': 'identity',
      });
      _sessions.checkpoint();
      require(probe.successful, 'UC 文件长度检查失败（HTTP ${probe.status}），请重试');
      final encoding = probe.header('content-encoding').toLowerCase();
      final range = RegExp(
        r'^bytes 0-0/(\d+)$',
      ).firstMatch(probe.header('content-range'));
      final length = int.tryParse(probe.header('content-length'));
      final total =
          probe.status == 206 &&
              range != null &&
              (length == null || length == 1)
          ? int.tryParse(range.group(1)!)
          : probe.status == 200
          ? length
          : null;
      require(
        (encoding.isEmpty || encoding == 'identity') &&
            total != null &&
            total > 0,
        'UC 未返回可验证的文件长度，请稍后重试',
      );
      if (expectedSize > 0 && expectedSize != total) {
        DiagnosticLog.event(
          'uc.original_content_mismatch',
          fields: {
            'file': DiagnosticLog.reference(file.id),
            'route': 'web',
            'expectedBytes': expectedSize,
            'receivedTotal': total,
          },
        );
        throw const UcOriginalContentMismatch();
      }
      expectedSize = total!;
    }
    return DownloadSpec(
      url: spec.url,
      fileName: spec.fileName,
      expectedSize: expectedSize,
      checksumType: spec.checksumType,
      checksumValue: spec.checksumValue,
      headers: headers(''),
      cleanup: spec.cleanup,
    );
  });

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.createFolder(s, parent, name, c));
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) => _sessions.run(
    c,
    '',
    (_) => super.upload(s, parent, source, c, onProgress: onProgress),
  );
  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.rename(s, f, name, c));
  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.move(s, files, target, c));
  @override
  Future<void> delete(BrowseSession s, List<CloudFile> files, Credential c) =>
      _sessions.run(c, '', (_) => super.delete(s, files, c));
  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.saveShare(s, files, target, c));
  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) => _sessions.run(c, '', (_) => super.createShare(s, files, options, c));
}

class _CookieCloudSession {
  _CookieCloudSession(this.cookie, this.owner, this.refreshedAt);
  String cookie;
  Credential? owner;
  int refreshedAt;
  bool refreshAttempted = false;
}

class _CookieCloudRefreshGate {
  final gate = AsyncGate();
  int users = 0;
}

class _CookieCloudHttp extends JsonHttp {
  _CookieCloudHttp(
    this.transport,
    this.store,
    int Function()? now,
    this.platform,
    this.webUserAgent,
    this.apiUserAgent,
  ) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);
  final CloudPlatform platform;
  final String webUserAgent, apiUserAgent;
  String get refreshField => platform == CloudPlatform.uc
      ? 'ucSessionRefreshedAt'
      : 'quarkSessionRefreshedAt';
  String get origin => platform == CloudPlatform.uc
      ? 'https://drive.uc.cn'
      : 'https://pan.quark.cn';
  String get config => platform == CloudPlatform.uc
      ? 'https://pc-api.uc.cn/1/clouddrive/config?pr=UCBrowser&fr=pc'
      : 'https://drive-pc.quark.cn/1/clouddrive/config?pr=ucpro&fr=pc';
  final JsonHttp transport;
  final CredentialStore? store;
  final int Function() now;
  final _zoneKey = Object();
  final _refreshGates = <(String, int), _CookieCloudRefreshGate>{};
  _CookieCloudSession? get current =>
      Zone.current[_zoneKey] as _CookieCloudSession?;
  static const _interval = 90 * 60 * 1000;

  Future<T> run<T>(
    Credential? credential,
    String fallback,
    Future<T> Function(_CookieCloudSession) action, {
    bool isolated = false,
  }) async {
    final nested = isolated ? null : current;
    if (nested != null) {
      checkpoint();
      return action(nested);
    }
    final stored = store?.credential(platform);
    // Cookie renewal keeps the explicit login revision. A snapshot captured
    // before another request renewed it must still use this account's latest
    // cookie; login candidates and replacement accounts remain isolated.
    final owner =
        credential != null &&
            stored != null &&
            LoginCredentials.sameUcSession(credential, stored)
        ? stored
        : null;
    final effective = owner ?? credential;
    final raw = effective?.primary ?? fallback;
    final cookie = raw
        .trim()
        .replaceFirst(RegExp(r'^Cookie:', caseSensitive: false), '')
        .trim();
    if (credential != null && !LoginCredentials.plausible(platform, cookie)) {
      throw AccountLoginRequired('${platform.shortName} 登录信息不完整，请重新网页登录');
    }
    require(
      !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(cookie),
      '${platform.shortName} Cookie 格式无效',
    );
    final session = _CookieCloudSession(
      cookie,
      owner,
      int.tryParse(effective?.field(refreshField) ?? '') ?? 0,
    );
    return runZoned(() => action(session), zoneValues: {_zoneKey: session});
  }

  static bool loginRequired(HttpResult response) {
    if (response.status == 401) return true;
    try {
      final json = response.json;
      return json.integer('status') == 401 || json.integer('code') == 31001;
    } on AppException {
      return false;
    }
  }

  void checkpoint() {
    if (RequestScope.current?.isCancelled == true) {
      throw const AppException('请求已取消');
    }
    final session = current, owner = current?.owner;
    if (session == null || owner == null) return;
    final latest = store!.credential(platform);
    require(
      latest != null && latest.updatedAt == owner.updatedAt,
      '${platform.shortName} 账号已变化，请重新打开文件列表',
    );
    if (!owner.sameAs(latest)) {
      session.cookie = latest!.primary;
      session.owner = latest;
      session.refreshedAt = int.tryParse(latest.field(refreshField)) ?? 0;
    }
  }

  Map<String, String> _cookieUpdates(HttpResult response) {
    final updates = <String, String>{};
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() != 'set-cookie') continue;
      for (final header in entry.value) {
        final pair = header.split(';').first.trim();
        final eq = pair.indexOf('=');
        if (eq <= 0 || eq >= pair.length - 1) continue;
        final name = pair.substring(0, eq).trim();
        final value = pair.substring(eq + 1).trim();
        if ({'__pus', '__puus', '__pugs'}.contains(name) &&
            value.isNotEmpty &&
            !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
          updates[name] = value;
        }
      }
    }
    return updates;
  }

  Future<bool> _accept(HttpResult response, Credential? sentOwner) async {
    final session = current!;
    checkpoint();
    if (!response.successful || loginRequired(response)) return false;
    final updates = _cookieUpdates(response);
    if (updates.isEmpty) return false;
    // A later response from a concurrent request must not undo a renewal that
    // another request already committed, or write into a replacement account.
    if (sentOwner != null && !sentOwner.sameAs(session.owner)) return false;
    final pairs = LoginCredentials.cookiePairs(session.cookie)..addAll(updates);
    final merged = pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final stamp = updates.containsKey('__puus') ? now() : session.refreshedAt;
    if (sentOwner != null) {
      final replacement = sentOwner.withFields({
        'primary': merged,
        refreshField: '$stamp',
      }, preserveRevision: true);
      final cancel = RequestScope.current;
      final committed = await store!.replaceCredential(
        platform,
        sentOwner,
        replacement,
        canCommit: () => cancel?.isCancelled != true,
      );
      checkpoint();
      if (!committed || !replacement.sameAs(session.owner)) return false;
    }
    session.cookie = merged;
    session.refreshedAt = stamp;
    return updates.containsKey('__puus');
  }

  Future<bool> _refresh() {
    checkpoint();
    final session = current!, owner = current!.owner;
    if (!quark || owner == null) return _refreshSession();
    final accounts = store;
    final accountId = accounts is Vault
        ? accounts.accountId(platform) ?? owner.label
        : owner.label;
    final key = (accountId, owner.updatedAt);
    final entry = _refreshGates.putIfAbsent(key, _CookieCloudRefreshGate.new);
    entry.users++;
    final before = session.cookie;
    final pending = entry.gate
        .run(() {
          checkpoint();
          // Another download may have renewed the same account while we waited.
          // Issuing another refresh can invalidate its freshly returned cookie.
          if (session.cookie != before) return Future.value(true);
          return _refreshSession();
        })
        .whenComplete(() {
          if (--entry.users == 0 && identical(_refreshGates[key], entry)) {
            _refreshGates.remove(key);
          }
        });
    return RequestScope.cancellable(pending);
  }

  bool get quark => platform == CloudPlatform.quark;

  Future<bool> _refreshSession() async {
    final session = current!;
    checkpoint();
    if (session.refreshAttempted) return false;
    session.refreshAttempted = true;
    final pairs = LoginCredentials.cookiePairs(session.cookie)
      ..remove('__puus');
    if (!pairs.containsKey('__pus')) return false;
    final owner = session.owner;
    try {
      final result = await transport.get(config, {
        'Cookie': pairs.entries.map((e) => '${e.key}=${e.value}').join('; '),
        'User-Agent': platform == CloudPlatform.quark
            ? apiUserAgent
            : webUserAgent,
        'Origin': origin,
        'Referer': '$origin/',
      });
      return await _accept(result, owner);
    } on AppException {
      checkpoint();
      // A temporary refresh failure can leave the existing session usable.
      return false;
    }
  }

  Future<void> ensureFresh() async {
    checkpoint();
    final stamp = current!.refreshedAt, time = now();
    if (stamp > 0 && time >= stamp && time - stamp < _interval) return;
    await _refresh();
  }

  @override
  Future<HttpResult> request(
    String method,
    String url, {
    Object? body,
    Map<String, String> headers = const {},
    bool followRedirects = true,
    String? contentType,
  }) async {
    final session = current;
    require(session != null, '${platform.shortName} 请求缺少账号上下文');
    final uri = Uri.parse(url);
    final domain = platform == CloudPlatform.quark ? 'quark.cn' : 'uc.cn';
    if (uri.host != domain && !uri.host.endsWith('.$domain')) {
      checkpoint();
      final result = await transport.request(
        method,
        url,
        body: body,
        headers: headers,
        followRedirects: followRedirects,
        contentType: contentType,
      );
      checkpoint();
      return result;
    }
    final cloud =
        platform == CloudPlatform.quark ||
        uri.path.endsWith('/member') ||
        uri.path.endsWith('/file/sort') ||
        uri.path.endsWith('/file/download') &&
            !uri.queryParameters.containsKey('entry');
    for (var attempt = 0; attempt < 2; attempt++) {
      checkpoint();
      final owner = session!.owner;
      final sentCookie = session.cookie;
      final result = await transport.request(
        method,
        url,
        body: body,
        headers: {
          ...headers,
          'Cookie': sentCookie,
          'User-Agent': cloud ? apiUserAgent : webUserAgent,
        },
        followRedirects: followRedirects,
        contentType: contentType,
      );
      await _accept(result, owner);
      if (attempt == 0 &&
          loginRequired(result) &&
          (session.cookie != sentCookie || await _refresh())) {
        continue;
      }
      return result;
    }
    throw AccountLoginRequired('${platform.shortName} 登录已失效，请重新网页登录');
  }
}
