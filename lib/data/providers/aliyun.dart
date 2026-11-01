import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import '../../core/json.dart';
import '../../core/operation_progress.dart';
import '../../diagnostics/app_log.dart';
import '../../domain/auth.dart';
import '../../domain/aliyun_share.dart';
import '../../domain/file_types.dart';
import '../../domain/models.dart';
import '../../domain/uploads.dart';
import '../http.dart';
import '../http_retry.dart';
import '../uploads/upload_io.dart';
import '../state_store.dart';
import 'aliyun_playback.dart';
import 'aliyun_signature.dart';
import 'token_session.dart';

class AliyunApiException extends AppException {
  const AliyunApiException(
    super.message,
    this.code, {
    this.status,
    this.retryAfter = '',
  });
  final String code;
  final int? status;
  final String retryAfter;

  bool get rateLimited =>
      status == 429 ||
      code.toLowerCase().contains('toomanyrequests') ||
      message.toLowerCase().contains('toomanyrequests');
}

class _AliyunListRead {
  int pages = 0, items = 0, retries = 0;
}

class AliyunConnector extends CloudConnector {
  AliyunConnector(
    this.http,
    CredentialStore store, {
    this.stageCleanup,
    this.taskDelay = const Duration(milliseconds: 750),
    this.listRequestInterval = const Duration(seconds: 1),
    this.listWait = RequestScope.wait,
    this.albumLookupTimeout = const Duration(seconds: 5),
    int Function()? now,
  }) : sessions = TokenSessions(CloudPlatform.aliyun, store, now: now);
  final JsonHttp http;
  final TokenSessions sessions;
  late final playbackApi = AliyunPlaybackApi(
    http,
    sessions,
    renew: _renew,
    userAgent: userAgent,
  );
  final Future<void> Function(DownloadCleanup)? stageCleanup;
  final Duration taskDelay;
  final Duration listRequestInterval;
  final Future<void> Function(Duration) listWait;
  final Duration albumLookupTimeout;
  final _albumGate = AsyncGate();
  final _albumRetryAfter = <String, int>{};
  // Browsing, search and upload name checks share a list request queue. Keep it
  // separate from the token gate, which can be acquired by the request itself.
  final _listGate = AsyncGate();
  final _listIdle = Stopwatch();
  Duration _listPause = Duration.zero;
  bool _listCoolingDown = false;
  static const _listRetryDelays = [2, 5, 10];
  static const api = 'https://api.aliyundrive.com';
  static const web = 'https://www.alipan.com';
  static const downloadCanary = 'client=Android,app=adrive,version=v4.1.0';
  // OSS includes this exact Referer in signed download and video URLs.
  static const downloadReferer = 'https://www.aliyundrive.com/';
  static const userAgent =
      '${WebLoginTarget.desktop}Chrome/131.0.0.0 Safari/537.36';
  @override
  CloudPlatform get platform => CloudPlatform.aliyun;

  @override
  bool canDownloadFile(BrowseSession session, CloudFile file) =>
      !AliyunShareLink.isFastTransfer(session);

  static const _fastTransferCanary = 'client=web,app=adrive,version=v0.0.1';
  static const _fastTransferErrors = {
    'ShareExpired',
    'ShareNotFound',
    'SharePunished',
    'ShareMaxSaveUserCountExceed',
    'ShareNoValidFile',
    'ShareTokenExpired',
    'ShareTokenInvalid',
    'ShareTokenlnvalid',
  };

  Map<String, String> _headers(
    TokenSession? session, {
    String shareToken = '',
    String? signature,
    String? canary,
  }) => {
    'Content-Type': 'application/json',
    'User-Agent': userAgent,
    'Referer': '$web/',
    'Origin': web,
    'X-Canary': canary ?? 'client=web,app=adrive,version=v6.8.12',
    'X-Request-Id': newId(),
    if (session != null) ...{
      'Authorization': 'Bearer ${session.access}',
      'X-Device-Id': session.field('deviceId'),
      if ((signature ?? session.field('signature')).isNotEmpty)
        'X-Signature': signature ?? session.field('signature'),
    },
    if (shareToken.isNotEmpty) 'X-Share-Token': shareToken,
  };

  bool _authError(HttpResult response, Json data) =>
      response.status == 401 &&
          !_fastTransferErrors.contains(data.str('code')) ||
      const {
        'AccessTokenInvalid',
        'AccessTokenExpired',
        'InvalidAccessToken',
      }.contains(data.str('code'));
  bool _deviceError(Json data) => const {
    'DeviceSessionSignatureInvalid',
    'UserDeviceOffline',
    'DeviceSessionNotFound',
    'SignatureInvalid',
    'InvalidDeviceSession',
  }.contains(data.str('code'));

  Json _checked(
    HttpResult response,
    Json data, {
    Set<String> successCodes = const {'0'},
  }) {
    if (_authError(response, data)) {
      throw const AccountLoginRequired('阿里云盘登录已过期，请重新网页登录');
    }
    final code = data.str('code');
    if (!response.successful ||
        code.isNotEmpty && !successCodes.contains(code) ||
        data['success'] == false) {
      final message = switch (code) {
        'InvalidResource.SharePwd' => '阿里分享提取码错误或缺失',
        'ShareLink.Cancelled' => '阿里分享已取消',
        'ShareLink.Expired' => '阿里分享已过期',
        'ShareLink.Forbidden' => '阿里分享不可访问',
        'NotFound.ShareLink' => '阿里分享不存在或已失效',
        'ShareExpired' => '阿里快传链接已过期，请让分享者重新发送',
        'ShareNotFound' => '阿里快传链接不存在或已取消',
        'SharePunished' => '阿里快传文件暂不可访问',
        'ShareMaxSaveUserCountExceed' => '阿里快传保存人数已达上限',
        'ShareNoValidFile' => '阿里快传中已没有可保存的文件',
        'ShareTokenExpired' ||
        'ShareTokenInvalid' ||
        'ShareTokenlnvalid' => '阿里快传凭据已失效，请刷新链接后重试',
        'NotFound.FileId' => '阿里云盘文件已移动或删除',
        'QuotaExhausted.Drive' => '阿里云盘空间不足',
        'ForbiddenFileInTheRecycleBin' => '文件已在回收站中',
        'DeviceSessionSignatureInvalid' ||
        'UserDeviceOffline' => '阿里设备会话已失效，请重新登录',
        _ =>
          data
              .str('display_message')
              .ifEmpty(data.str('message'))
              .ifEmpty(
                '阿里云盘请求失败（HTTP ${response.status}${code.isEmpty ? '' : '，$code'}）',
              ),
      };
      throw AliyunApiException(
        message,
        code,
        status: response.status,
        retryAfter: response.header('retry-after'),
      );
    }
    return data;
  }

  Future<void> _renew(TokenSession session) async {
    final response = await http.postJson(
      'https://auth.aliyundrive.com/v2/account/token',
      {'refresh_token': session.refresh, 'grant_type': 'refresh_token'},
      _headers(null),
    );
    sessions.checkpoint(session);
    if (response.status == 400 || response.status == 401) {
      throw const AccountLoginRequired('阿里云盘登录凭据已失效，请重新网页登录');
    }
    final data = response.json;
    if (data.str('code') == 'InvalidParameter.RefreshToken') {
      throw const AccountLoginRequired('阿里云盘登录凭据已失效，请重新网页登录');
    }
    await sessions.update(
      session,
      sessions.refreshedFields(session, _checked(response, data)),
    );
  }

  Future<void> _device(TokenSession session, {String? rejected}) async {
    await RequestScope.cancellable(
      sessions.gate.run(() async {
        sessions.checkpoint(session);
        if (rejected != null &&
            session.field('signature').isNotEmpty &&
            rejected != session.field('deviceSessionId')) {
          return;
        }
        if (rejected == null &&
            session.field('signature').isNotEmpty &&
            (int.tryParse(session.field('sessionExpiresAt')) ?? 0) >
                sessions.now() + 60000) {
          return;
        }
        require(session.field('userId').isNotEmpty, '阿里云盘未返回账号标识，请重新登录');
        if (session.field('deviceId').isEmpty ||
            session.field('devicePrivateKey').isEmpty) {
          await sessions.update(session, {
            if (session.field('deviceId').isEmpty) 'deviceId': newId(),
            if (session.field('devicePrivateKey').isEmpty)
              'devicePrivateKey': AliyunSignature.privateKey(),
          });
        }
        final signed = AliyunSignature.sign(
          privateKey: session.field('devicePrivateKey'),
          deviceId: session.field('deviceId'),
          userId: session.field('userId'),
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          final response = await http.postJson(
            '$api/users/v1/users/device/create_session',
            {
              'deviceName': 'AsterLink',
              'modelName': 'Windows网页版',
              'pubKey': signed.publicKey,
            },
            _headers(session, signature: signed.signature),
          );
          sessions.checkpoint(session);
          Json data;
          try {
            data = response.json;
          } on AppException {
            if (response.status != 401) rethrow;
            data = {};
          }
          if (_authError(response, data) &&
              attempt == 0 &&
              session.refresh.isNotEmpty) {
            await _renew(session);
            continue;
          }
          _checked(response, data);
          require(data.boolean('result'), '阿里设备会话创建失败，请在官网检查已登录设备后重新登录');
          await sessions.update(session, {
            'signature': signed.signature,
            'deviceSessionId': newId(),
            'sessionExpiresAt': '${sessions.now() + 25 * 60 * 1000}',
          });
          return;
        }
      }),
    );
  }

  Future<Json> _post(
    String path,
    Json body, {
    TokenSession? session,
    bool read = false,
    bool signed = true,
    String shareToken = '',
    String? canary,
    Set<String> successCodes = const {'0'},
  }) async {
    if (session != null) {
      await sessions.fresh(session, _renew);
      if (signed) await _device(session);
    }
    var renewed = false, deviceRenewed = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (session != null) sessions.checkpoint(session);
      final access = session?.access,
          deviceSession = session?.field('deviceSessionId');
      final response = await (read ? http.postJsonRead : http.postJson)(
        path.startsWith('https://') ? path : '$api$path',
        body,
        _headers(
          session,
          shareToken: shareToken,
          signature: signed ? null : '',
          canary: canary,
        ),
      );
      if (session != null) sessions.checkpoint(session);
      Json data;
      try {
        data = response.json;
      } on AppException {
        if (response.status != 401) {
          throw AliyunApiException(
            '阿里云盘接口返回异常（HTTP ${response.status}）',
            'InvalidResponse',
            status: response.status,
            retryAfter: response.header('retry-after'),
          );
        }
        data = {};
      }
      if (_authError(response, data) && session != null && !renewed) {
        renewed = true;
        await sessions.fresh(
          session,
          _renew,
          force: true,
          rejectedAccess: access,
        );
        continue;
      }
      if (_deviceError(data) && session != null && signed && !deviceRenewed) {
        deviceRenewed = true;
        await _device(session, rejected: deviceSession);
        continue;
      }
      return _checked(response, data, successCodes: successCodes);
    }
    throw const AccountLoginRequired('阿里云盘会话失效，请重新网页登录');
  }

  Future<TokenSession> _session(
    Credential credential, {
    bool candidate = false,
  }) async {
    final session = sessions.open(credential, candidate: candidate);
    await sessions.fresh(session, _renew);
    if (session.field('userId').isEmpty) await _driveInfo(session);
    return session;
  }

  Future<Json> _driveInfo(TokenSession session) async {
    final data = await _post(
      'https://user.aliyundrive.com/v2/user/get',
      {},
      session: session,
      signed: false,
      read: true,
    );
    require(data.str('user_id').isNotEmpty, '阿里云盘账号信息缺失');
    await sessions.update(session, {
      if (data.str('user_id').isNotEmpty) 'userId': data.str('user_id'),
      if (data.str('nick_name').ifEmpty(data.str('name')).isNotEmpty)
        'nickname': data.str('nick_name').ifEmpty(data.str('name')),
      for (final pair in const [
        ('default_drive_id', 'defaultDriveId'),
        ('resource_drive_id', 'resourceDriveId'),
        ('backup_drive_id', 'backupDriveId'),
      ])
        if (data.str(pair.$1).isNotEmpty) pair.$2: data.str(pair.$1),
    });
    return data;
  }

  Future<CloudAccount> _account(TokenSession session) async {
    final info = await _driveInfo(session);
    final data = await _post(
      '/v2/databox/get_personal_info',
      {},
      session: session,
      read: true,
    );
    final space = data.obj('personal_space_info');
    require(
      space.containsKey('used_size') && space.containsKey('total_size'),
      '阿里云盘未返回有效容量信息',
    );
    return CloudAccount(
      info
          .str('nick_name')
          .ifEmpty(info.str('name'))
          .ifEmpty(session.field('nickname'))
          .ifEmpty('阿里云盘用户'),
      used: space.integer('used_size'),
      total: space.integer('total_size'),
    );
  }

  Future<LoginResult> authenticate(Credential credential) async {
    final session = await _session(credential, candidate: true);
    final account = await _account(session);
    return LoginResult(session.credential, account);
  }

  @override
  Future<CloudAccount> account(Credential credential) async =>
      _account(await _session(credential));

  Future<void> _albumInfo(TokenSession session) => RequestScope.cancellable(
    _albumGate.run(() async {
      sessions.checkpoint(session);
      final now = sessions.now(), owner = session.field('userId');
      final checked = int.tryParse(session.field('albumDriveCheckedAt'));
      if (checked != null && now >= checked && now - checked < 300000 ||
          (_albumRetryAfter[owner] ?? 0) > now) {
        return;
      }
      // Album metadata uses a separate API. Keep this optional lookup bounded
      // so an unavailable album service cannot block the ordinary drives.
      final lookup = RequestScope(), parent = RequestScope.current;
      var finished = false, timedOut = false;
      parent?.whenCancel.then((_) {
        if (!finished) lookup.cancel();
      });
      final timer = Timer(albumLookupTimeout, () {
        timedOut = true;
        lookup.cancel();
      });
      try {
        await lookup.run(
          () => RequestScope.cancellable(() async {
            final response = await _post(
              '/adrive/v1/user/albums_info',
              {},
              session: session,
              read: true,
              successCodes: const {'0', '200'},
            );
            final data = response.obj('data');
            require(data['driveId'] is String, '阿里云盘未返回有效相册空间');
            await sessions.update(session, {
              'albumDriveId': data.str('driveId'),
              'albumDriveCheckedAt': '${sessions.now()}',
            });
            _albumRetryAfter.remove(owner);
          }()),
        );
      } on AccountLoginRequired {
        rethrow;
      } on AppException catch (error) {
        // Recheck the original scope and account before treating an error as
        // optional. Cancellation and account changes must still propagate.
        sessions.checkpoint(session);
        _albumRetryAfter[owner] = sessions.now() + 30000;
        DiagnosticLog.event(
          'aliyun.album.discovery_unavailable',
          fields: {
            'timedOut': timedOut,
            'usingSavedSpace': session.field('albumDriveId').isNotEmpty,
            if (error is AliyunApiException) 'status': error.status,
            if (error is AliyunApiException) 'code': error.code,
          },
        );
      } finally {
        finished = true;
        timer.cancel();
        lookup.cancel();
      }
    }),
  );

  List<CloudSpace> _spaces(TokenSession session) {
    final result = <CloudSpace>[], ids = <String>{};
    for (final pair in [
      (session.field('resourceDriveId'), '资源库'),
      (
        session.field('backupDriveId').ifEmpty(session.field('defaultDriveId')),
        '备份盘',
      ),
      (session.field('defaultDriveId'), '个人盘'),
      (session.field('albumDriveId'), '相册'),
    ]) {
      if (pair.$1.isNotEmpty && ids.add(pair.$1)) {
        result.add(CloudSpace(pair.$1, pair.$2));
      }
    }
    require(result.isNotEmpty, '阿里云盘未返回可用存储空间');
    return result;
  }

  BrowseSession _browse(CloudSpace space) => BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    title: '阿里云盘 · ${space.name}',
    rootId: 'root',
    metadata: {'driveId': space.id, 'driveName': space.name},
  );

  @override
  Future<List<CloudSpace>> personalSpaces(Credential credential) async {
    final session = await _session(credential);
    await _driveInfo(session);
    await _albumInfo(session);
    return _spaces(session);
  }

  @override
  Future<BrowseSession> openPersonal(Credential credential) async =>
      _browse((await personalSpaces(credential)).first);

  @override
  Future<BrowseSession> openPersonalSpace(
    CloudSpace space,
    Credential credential,
  ) async {
    final spaces = await personalSpaces(credential);
    final chosen = spaces.where((item) => item.id == space.id).firstOrNull;
    require(chosen != null, '当前阿里账号已无法访问此存储空间，请重新选择');
    return _browse(chosen!);
  }

  String _drive(BrowseSession session, TokenSession token) {
    final id = session.personalSpaceId;
    require(
      id.isNotEmpty && _spaces(token).any((space) => space.id == id),
      '阿里存储空间不属于当前账号，请重新打开网盘',
    );
    return id;
  }

  @override
  String destinationId(BrowseSession session, String parentId) =>
      'aliyun:${Uri.encodeComponent(session.personalSpaceId)}:${Uri.encodeComponent(parentId)}';

  (String, String) _destination(
    String target,
    TokenSession token, {
    String fallbackDrive = '',
  }) {
    final parts = target.split(':');
    final (drive, parent) = parts.length == 3 && parts.first == 'aliyun'
        ? (Uri.decodeComponent(parts[1]), Uri.decodeComponent(parts[2]))
        : (fallbackDrive.ifEmpty(_spaces(token).first.id), target);
    require(
      parent.isNotEmpty && _spaces(token).any((s) => s.id == drive),
      '阿里目标目录信息无效',
    );
    return (drive, parent);
  }

  Future<String> _shareToken(BrowseSession s) async {
    final id = s.meta('shareId').ifEmpty(s.sourceLink?.shareId ?? '');
    require(id.isNotEmpty, '阿里分享信息缺失，请重新解析');
    final data = await _post('/v2/share_link/get_share_token', {
      'share_id': id,
      'share_pwd': s.sourceLink?.passcode ?? s.meta('passcode'),
    }, read: true);
    require(data.str('share_token').isNotEmpty, '阿里未返回分享凭据，请检查提取码');
    return data.str('share_token');
  }

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    require(link.shareId?.isNotEmpty == true, '阿里分享链接无效');
    final route = AliyunShareLink.parse(Uri.parse(link.url));
    require(route != null && route.id == link.shareId, '阿里分享链接无效');
    if (route!.fastTransfer) {
      final data = await _fastTransferInfo(route.id);
      return BrowseSession(
        platform: platform,
        mode: BrowseMode.share,
        rootId: 'root',
        title: data.str('name').ifEmpty('阿里云盘快传'),
        sourceLink: link,
        metadata: {'shareId': route.id, 'aliyunShareType': 'fastTransfer'},
      );
    }
    final data = await _post('/adrive/v3/share_link/get_share_by_anonymous', {
      'share_id': link.shareId,
    }, read: true);
    final session = BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      rootId: 'root',
      title: data.str('share_name').ifEmpty('阿里云盘分享'),
      sourceLink: link,
      metadata: {'shareId': link.shareId!, 'passcode': link.passcode ?? ''},
    );
    await _shareToken(session);
    return session;
  }

  Future<Json> _fastTransferInfo(String id) async {
    require(id.isNotEmpty, '阿里快传信息缺失，请重新解析');
    final data = await _post(
      '/adrive/v1/share/getByAnonymous',
      {'share_id': id},
      read: true,
      canary: _fastTransferCanary,
    );
    require(
      data.str('share_id') == id &&
          data['preview_file_list'] is List &&
          data.list('preview_file_list').isNotEmpty &&
          (data['preview_file_list'] as List).every((item) => item is Map),
      '阿里快传未返回有效文件信息，请刷新链接后重试',
    );
    return data;
  }

  static CloudFile file(Json data, String parent) {
    final checksum = cloudChecksum(
      data.str('content_hash_name', 'sha1'),
      data.str('content_hash'),
    );
    require(
      data.str('file_id').isNotEmpty && data.str('name').isNotEmpty,
      '阿里云盘返回的文件信息不完整',
    );
    return CloudFile(
      id: data.str('file_id'),
      name: data.str('name'),
      isDirectory: data.str('type') == 'folder',
      size: data.integer('size'),
      parentId: data.str('parent_file_id').ifEmpty(parent),
      modifiedAt: data.str('updated_at').ifEmpty(data.str('created_at')),
      thumbnailUrl: data.str('thumbnail'),
      hashType: checksum.$1,
      hashValue: checksum.$2,
    );
  }

  Duration _listRetryAfter(String value) {
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds >= 0) {
      return Duration(seconds: seconds.clamp(0, 86400));
    }
    try {
      final remaining = HttpDate.parse(
        value,
      ).difference(DateTime.now().toUtc());
      return remaining.isNegative ? Duration.zero : remaining;
    } catch (_) {
      return Duration.zero;
    }
  }

  Future<Json> _listPage(
    String path,
    Json body,
    _AliyunListRead read, {
    TokenSession? session,
    String shareToken = '',
  }) => RequestScope.cancellable(
    _listGate.run(() async {
      while (true) {
        RequestScope.checkpoint();
        if (session != null) sessions.checkpoint(session);
        final remaining = _listPause - _listIdle.elapsed;
        OperationProgress.reportFiles(
          read.items,
          waitingForRetry: _listCoolingDown && remaining > Duration.zero,
        );
        if (_listCoolingDown && remaining > const Duration(seconds: 30)) {
          throw const AliyunApiException(
            '阿里云盘读取文件列表过于频繁，请稍后再试',
            'TooManyRequests',
          );
        }
        if (_listIdle.isRunning && remaining > Duration.zero) {
          await listWait(remaining);
        }
        RequestScope.checkpoint();
        if (session != null) sessions.checkpoint(session);
        OperationProgress.reportFiles(read.items);
        _listPause = listRequestInterval;
        _listCoolingDown = false;
        AliyunApiException limited;
        var sharedRetriesExhausted = false;
        try {
          return await _post(
            path,
            body,
            session: session,
            shareToken: shareToken,
            read: true,
          );
        } on AliyunApiException catch (error) {
          if (!error.rateLimited) rethrow;
          limited = error;
        } on HttpRequestFailure catch (error) {
          if (error.status != 429) rethrow;
          limited = AliyunApiException(
            error.message,
            'TooManyRequests',
            status: error.status,
            retryAfter: error.retryAfter,
          );
          // Preparation already has an HTTP retry budget. Do not replay that
          // exhausted budget in a second retry loop.
          sharedRetriesExhausted = ReadRetryScope.current != null;
        } finally {
          _listIdle
            ..reset()
            ..start();
        }
        RequestScope.checkpoint();
        final normal = Duration(
          seconds:
              _listRetryDelays[math.min(
                read.retries,
                _listRetryDelays.length - 1,
              )],
        );
        final server = _listRetryAfter(limited.retryAfter);
        _listPause = server > normal ? server : normal;
        if (_listPause < listRequestInterval) _listPause = listRequestInterval;
        _listCoolingDown = true;
        final exhausted =
            read.retries >= _listRetryDelays.length ||
            sharedRetriesExhausted ||
            server > const Duration(seconds: 30);
        DiagnosticLog.event(
          'aliyun.list.throttled',
          fields: {
            'page': read.pages + 1,
            'itemsRead': read.items,
            'retries': read.retries,
            'status': limited.status,
            'waitMs': _listPause.inMilliseconds,
            'willRetry': !exhausted,
          },
        );
        if (exhausted) {
          throw AliyunApiException(
            '阿里云盘读取文件列表过于频繁，请稍后再试',
            'TooManyRequests',
            status: limited.status,
            retryAfter: limited.retryAfter,
          );
        }
        read.retries++;
      }
    }),
  );

  Future<List<CloudFile>> _list(
    String parent, {
    TokenSession? session,
    String drive = '',
    String shareId = '',
    String shareToken = '',
  }) async {
    final result = <CloudFile>[], ids = <String>{}, markers = <String>{};
    final read = _AliyunListRead();
    var marker = '';
    try {
      for (var page = 0; page < 1000; page++) {
        final data = await _listPage(
          shareId.isNotEmpty
              ? '/adrive/v2/file/list_by_share'
              : '/adrive/v3/file/list',
          {
            if (shareId.isNotEmpty) 'share_id': shareId else 'drive_id': drive,
            'parent_file_id': parent,
            'limit': 200,
            'marker': marker,
            'all': false,
            'fields': '*',
            'url_expire_sec': 14400,
            'order_by': 'name',
            'order_direction': 'ASC',
          },
          read,
          session: session,
          shareToken: shareToken,
        );
        require(
          data['items'] is List &&
              (data['items'] as List).every((item) => item is Map),
          '阿里云盘未返回有效文件列表，请重试',
        );
        var added = 0;
        for (final raw in data.list('items')) {
          final item = file(raw, parent);
          if (ids.add(item.id)) {
            result.add(item);
            added++;
          }
        }
        RequestScope.checkpoint();
        read.pages++;
        read.items = result.length;
        OperationProgress.reportFiles(read.items);
        marker = data.str('next_marker');
        if (marker.isEmpty) {
          if (read.pages > 1 || read.retries > 0) {
            DiagnosticLog.event(
              'aliyun.list.completed',
              fields: {
                'pages': read.pages,
                'itemsRead': read.items,
                'retries': read.retries,
              },
            );
          }
          return result;
        }
        require(added > 0 && markers.add(marker), '阿里云盘分页重复，请刷新列表重试');
      }
      throw const AppException('阿里目录项目过多，请分目录打开');
    } catch (error, stack) {
      if (RequestScope.current?.isCancelled != true) {
        DiagnosticLog.error(
          'aliyun.list.failed',
          error,
          stack,
          fields: {
            'page': read.pages + 1,
            'itemsRead': read.items,
            'retries': read.retries,
            'mode': shareId.isEmpty ? 'personal' : 'share',
          },
        );
      }
      rethrow;
    }
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    if (AliyunShareLink.isFastTransfer(s)) {
      require(parentId == s.rootId, '快传文件需先转存到网盘，再打开查看');
      final data = await _fastTransferInfo(s.meta('shareId'));
      return [
        CloudFile(
          id: AliyunShareLink.bundleId(s.meta('shareId')),
          name: data.str('name').ifEmpty('阿里云盘快传'),
          isDirectory: true,
          parentId: s.rootId,
        ),
      ];
    }
    if (s.mode == BrowseMode.share) {
      return _list(
        parentId,
        shareId: s.meta('shareId'),
        shareToken: await _shareToken(s),
      );
    }
    if (c == null) throw const AccountLoginRequired('请先登录阿里云盘');
    final token = await _session(c);
    return _list(parentId, session: token, drive: _drive(s, token));
  }

  Future<DownloadSpec> _download(
    TokenSession token,
    String drive,
    CloudFile f,
  ) async {
    return OperationProgress.step(OperationStage.downloadLink, () async {
      var data = <String, dynamic>{};
      try {
        data = await _post(
          '/v2/file/get_download_url',
          {'drive_id': drive, 'file_id': f.id, 'expire_sec': 14400},
          session: token,
          canary: downloadCanary,
          read: true,
        );
      } on AliyunApiException catch (error) {
        if (!{404, 405, 501}.contains(error.status) ||
            !{
              '',
              'InvalidResponse',
              'NotFound',
              'NotFound.Api',
              'NotImplemented',
            }.contains(error.code)) {
          rethrow;
        }
      }
      void validate(Json value) {
        require(value.str('type') != 'folder', '文件夹不能直接下载');
        require(
          value.str('file_id').isEmpty || value.str('file_id') == f.id,
          '阿里返回的文件标识不一致，请刷新列表后重试',
        );
        final size = value.integer('size');
        require(
          size <= 0 || f.size <= 0 || size == f.size,
          '阿里源文件大小已变化，请刷新列表后重试',
        );
      }

      validate(data);
      final sourceSize = data.integer('size');
      String address(Json value, {bool detail = false}) {
        // File-detail `url` may be an image/video preview. Only the dedicated
        // download API's generic URL is an original-file download address.
        for (final key in [
          'download_url',
          if (!detail) ...['cdn_url', 'url'],
        ]) {
          final raw = value.str(key), uri = Uri.tryParse(value.str(key));
          if (uri != null &&
              {'http', 'https'}.contains(uri.scheme) &&
              uri.host.isNotEmpty &&
              uri.userInfo.isEmpty &&
              !RegExp(r'[\x00-\x20\x7f]').hasMatch(raw)) {
            return raw;
          }
        }
        return '';
      }

      var url = address(data);
      if (url.isEmpty) {
        data = await _post(
          '/v2/file/get',
          {
            'drive_id': drive,
            'file_id': f.id,
            'fields': '*',
            'url_expire_sec': 14400,
          },
          session: token,
          canary: downloadCanary,
          read: true,
        );
        url = address(data, detail: true);
      }
      validate(data);
      final size = data.integer('size', sourceSize);
      return DownloadSpec(
        url: checkedCloudUrl(url, '阿里未返回原文件下载地址，请确认文件下载权限'),
        fileName: f.name,
        expectedSize: f.size > 0 ? f.size : size,
        checksumType: f.hashType,
        checksumValue: f.hashValue,
        headers: {'Referer': downloadReferer, 'User-Agent': userAgent},
        profile: 'aliyun',
      );
    });
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    require(!AliyunShareLink.isFastTransfer(s), '快传文件需先转存到网盘，再选择文件下载');
    require(f.id.isNotEmpty && !f.isDirectory, '请选择要下载的文件');
    if (c == null) throw const AccountLoginRequired('阿里分享下载需要先登录阿里云盘');
    final token = await _session(c);
    if (s.mode == BrowseMode.share) return _shareSource(s, f, token);
    return _download(token, _drive(s, token), f);
  }

  @override
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    require(!AliyunShareLink.isFastTransfer(session), '快传文件需先转存到网盘，再选择文件播放');
    if (fileKind(file.name) != FileKind.video) {
      return download(session, file, credential);
    }
    require(file.id.isNotEmpty && !file.isDirectory, '请选择要播放的视频');
    if (credential == null) {
      throw const AccountLoginRequired('阿里视频播放需要先登录阿里云盘');
    }
    final token = await _session(credential);
    if (session.mode == BrowseMode.share) {
      return _shareSource(session, file, token, forPlayback: true);
    }
    return _playback(token, _drive(session, token), file);
  }

  Future<DownloadSpec> _playback(
    TokenSession token,
    String drive,
    CloudFile file,
  ) => OperationProgress.step(OperationStage.playbackLink, () async {
    await playbackApi.fresh(token);
    Json data;
    try {
      data = await playbackApi
          .request(token, 'openFile/getVideoPreviewPlayInfo', {
            'drive_id': drive,
            'file_id': file.id,
            'category': 'live_transcoding',
            'url_expire_sec': '14400',
          });
    } on AliyunPlaybackApiException catch (error) {
      if (error.fileUnavailable) rethrow;
      return _playbackOriginal(token, drive, file);
    } on HttpRequestFailure catch (error) {
      RequestScope.checkpoint();
      if (!error.retryable) rethrow;
      return _playbackOriginal(token, drive, file);
    }
    require(
      (data.str('file_id').isEmpty || data.str('file_id') == file.id) &&
          (data.str('drive_id').isEmpty || data.str('drive_id') == drive),
      '阿里返回的视频标识不一致，请刷新列表后重试',
    );
    final candidates = <(Json, String)>[];
    final preview = data.obj('video_preview_play_info');
    final tasks = preview['quick_video_list'] is List
        ? preview.list('quick_video_list')
        : preview.list('live_transcoding_task_list');
    for (final task in tasks) {
      final status = task.str('status').toLowerCase();
      if (status.isNotEmpty && status != 'finished') continue;
      try {
        // Quick-video tasks can omit status. Both lists must provide a full
        // `url`; `preview_url` can be a limited trial of the original video.
        final url = checkedCloudUrl(task.str('url'), '阿里视频播放地址无效');
        candidates.add((task, url));
      } on AppException {
        continue;
      }
    }
    int width(Json task) {
      final width = task.integer('template_width');
      if (width > 0) return width;
      return switch (task.str('template_id').toUpperCase()) {
        'LD' => 640,
        'SD' => 960,
        'HD' => 1280,
        'FHD' => 1920,
        'QHD' => 2560,
        _ => 0,
      };
    }

    candidates.sort((a, b) => width(b.$1).compareTo(width(a.$1)));
    if (candidates.isEmpty) return _playbackOriginal(token, drive, file);
    return DownloadSpec(
      url: candidates.first.$2,
      fileName: file.name,
      // HLS bytes and hashes do not describe the original file. Downloads
      // resolve their own original-file specification through download().
      headers: {'Referer': downloadReferer, 'User-Agent': userAgent},
      profile: 'aliyun',
    );
  });

  Future<DownloadSpec> _playbackOriginal(
    TokenSession token,
    String drive,
    CloudFile file,
  ) async {
    final data = await playbackApi.request(token, 'openFile/getDownloadUrl', {
      'drive_id': drive,
      'file_id': file.id,
    });
    require(
      (data.str('file_id').isEmpty || data.str('file_id') == file.id) &&
          (data.str('drive_id').isEmpty || data.str('drive_id') == drive) &&
          data.str('type') != 'folder',
      '阿里返回的原文件标识不一致，请刷新列表后重试',
    );
    final size = data.integer('size');
    require(
      size <= 0 || file.size <= 0 || size == file.size,
      '阿里源文件大小已变化，请刷新列表后重试',
    );
    return DownloadSpec(
      url: checkedCloudUrl(data.str('url'), '阿里开放接口未返回原画播放地址'),
      fileName: file.name,
      expectedSize: file.size > 0 ? file.size : size,
      checksumType: file.hashType,
      checksumValue: file.hashValue,
      headers: {'Referer': downloadReferer, 'User-Agent': userAgent},
      profile: 'aliyun',
    );
  }

  Future<String> _playbackResourceDrive(TokenSession token) async {
    final data = await playbackApi.request(token, 'user/getDriveInfo', {});
    require(
      data.str('user_id').isEmpty ||
          data.str('user_id') == token.field('userId'),
      '阿里开放授权账号不一致，请重新登录',
    );
    final drive = data.str('resource_drive_id');
    require(drive.isNotEmpty, '阿里开放接口未返回资源库，无法转存分享视频');
    await sessions.update(token, {
      'resourceDriveId': drive,
      if (data.str('backup_drive_id').isNotEmpty)
        'backupDriveId': data.str('backup_drive_id'),
    });
    return drive;
  }

  Future<CloudFile> _playbackFolder(
    TokenSession token,
    String drive,
    String name,
  ) async {
    final data = await playbackApi.request(token, 'openFile/create', {
      'drive_id': drive,
      'parent_file_id': 'root',
      'name': name,
      'type': 'folder',
      'check_name_mode': 'refuse',
    }, read: false);
    require(
      data.str('file_id').isNotEmpty &&
          data.str('type') != 'file' &&
          !data.boolean('exist'),
      '阿里未创建新的播放临时目录，请稍后重试',
    );
    return AliyunConnector.file({
      ...data,
      'name': data.str('name').ifEmpty(name),
      'type': 'folder',
    }, 'root');
  }

  Future<List<CloudFile>> _playbackFiles(
    TokenSession token,
    String drive,
    String parent,
  ) async {
    final data = await playbackApi.request(token, 'openFile/list', {
      'drive_id': drive,
      'parent_file_id': parent,
      'limit': 100,
    });
    require(
      data['items'] is List && data.str('next_marker').isEmpty,
      '阿里播放临时目录返回异常，请稍后重试',
    );
    return data.list('items').map((item) => file(item, parent)).toList();
  }

  Future<void> _waitTask(Json data, TokenSession token) async {
    final id = data.str('async_task_id');
    if (id.isEmpty) return;
    for (var attempt = 0; attempt < 80; attempt++) {
      final result = await _post(
        '/v2/async_task/get',
        {'async_task_id': id},
        session: token,
        read: true,
      );
      final state = result.str('state').toLowerCase();
      if (state == 'succeed' || state == 'success') return;
      require(
        !{'failed', 'fail', 'cancelled'}.contains(state),
        result.str('message').ifEmpty('阿里文件操作失败'),
      );
      require(
        {'running', 'pending', 'waiting'}.contains(state),
        '阿里返回的任务状态无效，请刷新列表确认',
      );
      await RequestScope.wait(taskDelay);
    }
    throw const AppException('阿里操作仍在处理中，请稍后刷新列表确认结果');
  }

  Future<List<Json>> _batch(
    String path,
    List<Json> bodies,
    TokenSession token, {
    String shareToken = '',
  }) async {
    final result = <Json>[];
    for (var offset = 0; offset < bodies.length; offset += 100) {
      final chunk = bodies.skip(offset).take(100).toList();
      final data = await _post(
        '/adrive/v4/batch',
        {
          'resource': 'file',
          'requests': [
            for (var i = 0; i < chunk.length; i++)
              {
                'id': '${offset + i}',
                'method': 'POST',
                'url': path,
                'headers': {'Content-Type': 'application/json'},
                'body': chunk[i],
              },
          ],
        },
        session: token,
        shareToken: shareToken,
      );
      final replies = data.list('responses');
      require(
        replies.length == chunk.length &&
            replies.map((r) => r.str('id')).toSet().containsAll([
              for (var i = 0; i < chunk.length; i++) '${offset + i}',
            ]),
        '阿里未返回完整操作结果，请刷新列表确认',
      );
      for (final reply in replies) {
        final body = _checked(
          HttpResult(reply.integer('status'), ''),
          reply.obj('body'),
        );
        await _waitTask(body, token);
        result.add(body);
      }
    }
    return result;
  }

  Future<CloudFile> _mkdir(
    TokenSession token,
    String drive,
    String parent,
    String name,
  ) async {
    cloudFileName(name);
    final data = await _post('/adrive/v2/file/createWithFolders', {
      'drive_id': drive,
      'parent_file_id': parent,
      'name': name,
      'type': 'folder',
      'check_name_mode': 'refuse',
    }, session: token);
    require(
      data.str('file_id').isNotEmpty &&
          data.str('type') != 'file' &&
          !data.boolean('exist'),
      '阿里未创建新文件夹，请检查同名项目',
    );
    return file({
      ...data,
      'name': data.str('name').ifEmpty(name),
      'type': 'folder',
    }, parent);
  }

  void _personal(BrowseSession session) =>
      require(session.canManageFiles, '请在个人网盘中执行此操作');

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    _personal(s);
    cloudFileName(source.name);
    final token = await _session(c), drive = _drive(s, token);
    final io = UploadIO(http, source, onProgress);
    io.progress(UploadPhase.preparing);
    final chunkSize = math.max(10 * 1024 * 1024, (source.size / 9000).ceil());
    final count = math.max(1, (source.size / chunkSize).ceil());
    final task = await _post('/adrive/v2/file/createWithFolders', {
      'drive_id': drive,
      'parent_file_id': parent,
      'name': source.name,
      'type': 'file',
      'size': source.size,
      'check_name_mode': 'refuse',
      'content_hash_name': 'none',
      'proof_version': 'v1',
      'part_info_list': [
        for (var i = 1; i <= count; i++) {'part_number': i},
      ],
    }, session: token);
    require(!task.boolean('exist'), '已有同名文件，请重命名后上传');
    final id = task.str('file_id'), uploadId = task.str('upload_id');
    require(id.isNotEmpty, '阿里未返回上传文件标识');
    if (!task.boolean('rapid_upload')) {
      final parts = task.list('part_info_list').toList()
        ..sort(
          (a, b) =>
              a.integer('part_number').compareTo(b.integer('part_number')),
        );
      require(uploadId.isNotEmpty && parts.length == count, '阿里未返回完整上传分段');
      for (var i = 0; i < parts.length; i++) {
        sessions.checkpoint(token);
        require(parts[i].integer('part_number') == i + 1, '阿里上传分段序号异常');
        final type = parts[i].str('content_type');
        await io.send(
          parts[i].str('upload_url'),
          start: i * chunkSize,
          end: math.min(source.size, (i + 1) * chunkSize),
          contentType: type,
          includeContentType: type.isNotEmpty,
        );
      }
      io.progress(UploadPhase.finishing, source.size);
      await _post('/v2/file/complete', {
        'drive_id': drive,
        'file_id': id,
        'upload_id': uploadId,
      }, session: token);
    }
    return io.confirm(() => list(s, parent, c), id: id);
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    _personal(s);
    final token = await _session(c);
    return _mkdir(token, _drive(s, token), parent, name);
  }

  @override
  Future<void> rename(
    BrowseSession s,
    CloudFile f,
    String name,
    Credential c,
  ) async {
    _personal(s);
    cloudFileName(name);
    final token = await _session(c);
    await _batch('/file/update', [
      {
        'drive_id': _drive(s, token),
        'file_id': f.id,
        'name': name,
        'check_name_mode': 'refuse',
      },
    ], token);
  }

  @override
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    _personal(s);
    if (files.isEmpty) return;
    final token = await _session(c), drive = _drive(s, token);
    final to = _destination(target, token, fallbackDrive: drive);
    require(
      !files.any((f) => f.isDirectory && f.id == to.$2 && drive == to.$1),
      '不能移动到文件夹自身',
    );
    await _batch('/file/move', [
      for (final f in files)
        {
          'drive_id': drive,
          'file_id': f.id,
          'to_drive_id': to.$1,
          'to_parent_file_id': to.$2,
          'check_name_mode': 'refuse',
        },
    ], token);
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    _personal(s);
    if (files.isEmpty) return;
    final token = await _session(c), drive = _drive(s, token);
    for (final file in files) {
      require(file.id.isNotEmpty && file.id != 'root', '不能删除网盘根目录');
      await _waitTask(
        await _post('/v2/recyclebin/trash', {
          'drive_id': drive,
          'file_id': file.id,
        }, session: token),
        token,
      );
    }
  }

  Future<void> deleteTemporaryFolder(
    BrowseSession session,
    String id,
    String name,
    Credential credential,
  ) async {
    require(
      id.isNotEmpty &&
          id != 'root' &&
          RegExp(r'^AsterLink临时转存_[0-9a-f-]{36}$').hasMatch(name),
      '临时目录标识无效',
    );
    final token = await _session(credential), drive = _drive(session, token);
    try {
      final folder = await _post(
        '/v2/file/get',
        {'drive_id': drive, 'file_id': id},
        session: token,
        read: true,
      );
      require(
        folder.str('file_id') == id &&
            folder.str('type') == 'folder' &&
            folder.str('name') == name &&
            folder.str('parent_file_id') == 'root',
        '临时目录已被修改，已保留目录，请在网盘中确认',
      );
      await _waitTask(
        await _post('/v2/recyclebin/trash', {
          'drive_id': drive,
          'file_id': id,
        }, session: token),
        token,
      );
    } on AliyunApiException catch (error) {
      if (!{
        'NotFound.FileId',
        'ForbiddenFileInTheRecycleBin',
      }.contains(error.code)) {
        rethrow;
      }
    }
  }

  @override
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  ) async {
    _personal(s);
    require(files.isNotEmpty, '请先选择文件');
    final token = await _session(c);
    final data = await _post('/adrive/v2/share_link/create', {
      'drive_id': _drive(s, token),
      'file_id_list': files.map((f) => f.id).toList(),
      'share_name': options.title,
      'share_pwd': options.passcode ?? '',
      'expiration': (options.expiryDays ?? 0) <= 0
          ? ''
          : DateTime.fromMillisecondsSinceEpoch(
              sessions.now(),
              isUtc: true,
            ).add(Duration(days: options.expiryDays!)).toIso8601String(),
    }, session: token);
    final id = data.str('share_id');
    return ShareCreation(
      checkedCloudUrl(
        data.str('share_url').ifEmpty(id.isEmpty ? '' : '$web/s/$id'),
        '阿里未返回分享链接',
      ),
      data.str('share_pwd').ifEmpty(options.passcode ?? ''),
      options.title,
    );
  }

  Future<List<Json>> _save(
    BrowseSession s,
    List<CloudFile> files,
    String drive,
    String parent,
    TokenSession token,
  ) async {
    final shareToken = await _shareToken(s);
    return _batch(
      '/file/copy',
      [
        for (final f in files)
          {
            'share_id': s.meta('shareId'),
            'file_id': f.id,
            'to_drive_id': drive,
            'to_parent_file_id': parent,
            'auto_rename': true,
          },
      ],
      token,
      shareToken: shareToken,
    );
  }

  @override
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  ) async {
    require(s.mode == BrowseMode.share, '请先打开分享链接');
    if (files.isEmpty) return;
    final token = await _session(c);
    if (token.field('defaultDriveId').isEmpty) await _driveInfo(token);
    final to = _destination(target, token);
    if (AliyunShareLink.isFastTransfer(s)) {
      require(
        files.length == 1 &&
            files.single.id == AliyunShareLink.bundleId(s.meta('shareId')),
        '阿里快传仅支持整包转存，请重新打开快传链接',
      );
      await _saveFastTransfer(s.meta('shareId'), to.$1, to.$2, token);
      return;
    }
    await _save(s, files, to.$1, to.$2, token);
  }

  Future<void> _saveFastTransfer(
    String shareId,
    String drive,
    String parent,
    TokenSession token,
  ) async {
    final access = await _post(
      '/adrive/v1/share/getShareToken',
      {'share_id': shareId},
      session: token,
      read: true,
      canary: _fastTransferCanary,
    );
    require(access.str('share_token').isNotEmpty, '阿里未返回快传凭据，请刷新链接后重试');
    // saveFile copies the whole transfer. Never replay it after an ambiguous
    // network failure, or submit a subset inferred from preview_file_list.
    final data = await _post(
      '/adrive/v1/share/saveFile',
      {'share_id': shareId, 'to_drive_id': drive, 'to_parent_file_id': parent},
      session: token,
      shareToken: access.str('share_token'),
      canary: _fastTransferCanary,
    );
    require(
      data.str('to_drive_id') == drive &&
          data.str('to_parent_file_id') == parent &&
          data['items'] is List &&
          data.list('items').isNotEmpty &&
          (data['items'] as List).every(
            (item) => item is Map && item['body'] is Map,
          ),
      '阿里未返回完整转存结果，请到目标目录确认后再试',
    );
    final replies = data.list('items');
    require(
      replies.every((item) => item.str('id').isNotEmpty) &&
          replies.map((item) => item.str('id')).toSet().length ==
              replies.length,
      '阿里快传返回了重复或缺失的结果，请到目标目录确认',
    );
    var saved = 0;
    final failures = <AppException>[];
    for (final reply in replies) {
      try {
        final body = _checked(
          HttpResult(reply.integer('status'), ''),
          reply.obj('body'),
        );
        require(
          body.str('file_id').isNotEmpty ||
              body.str('async_task_id').isNotEmpty,
          '转存结果缺少文件信息，请到目标目录确认',
        );
        await _waitTask(body, token);
        saved++;
      } on AppException catch (error) {
        RequestScope.checkpoint();
        failures.add(error);
      }
    }
    if (failures.isNotEmpty) {
      throw AppException(
        '${saved > 0 ? '已转存 $saved 项，另有 ${failures.length} 项未完成' : '快传转存未完成'}：'
        '${failures.first.message}。请到目标目录确认后再试',
      );
    }
  }

  Future<DownloadSpec> _shareSource(
    BrowseSession s,
    CloudFile file,
    TokenSession token, {
    bool forPlayback = false,
  }) async {
    String drive;
    if (forPlayback) {
      drive = await _playbackResourceDrive(token);
    } else {
      await _driveInfo(token);
      drive = _spaces(token).first.id;
    }
    final name = 'AsterLink临时转存_${newId()}';
    final folder = await OperationProgress.step(
      OperationStage.createTemporary,
      () => forPlayback
          ? _playbackFolder(token, drive, name)
          : _mkdir(token, drive, 'root', name),
    );
    final cleanup = DownloadCleanup(
      url: '',
      action: {
        'kind': 'temporary-folder',
        'platform': platform.key,
        'accountRevision': token.credential.updatedAt,
        'folderId': folder.id,
        'name': name,
        'driveId': drive,
      },
    );
    var staged = false;
    try {
      await stageCleanup?.call(cleanup);
      staged = stageCleanup != null;
      final saved = await OperationProgress.step(
        OperationStage.transfer,
        () async {
          if (!forPlayback) return _save(s, [file], drive, folder.id, token);
          final shareToken = await _shareToken(s);
          final copy = await _post(
            '/adrive/v2/file/copy',
            {
              'share_id': s
                  .meta('shareId')
                  .ifEmpty(s.sourceLink?.shareId ?? ''),
              'file_id': file.id,
              'auto_rename': true,
              'to_parent_file_id': folder.id,
              'to_drive_id': drive,
            },
            session: token,
            signed: false,
            shareToken: shareToken,
          );
          require(copy.str('file_id').isNotEmpty, '阿里未返回转存后的视频标识，请稍后重试');
          await _waitTask(copy, token);
          return [copy];
        },
      );
      final savedId = saved.single.str('file_id');
      final copy = await OperationProgress.step(
        OperationStage.waitTransfer,
        () async {
          for (var attempt = 0; attempt < 30; attempt++) {
            final entries = forPlayback
                ? await _playbackFiles(token, drive, folder.id)
                : await _list(folder.id, session: token, drive: drive);
            final matches = entries
                .where(
                  (f) =>
                      !f.isDirectory &&
                      (savedId.isNotEmpty
                          ? f.id == savedId
                          : f.name == file.name),
                )
                .toList();
            require(matches.length <= 1, '阿里临时目录出现同名文件，无法确定下载目标');
            if (matches.isNotEmpty) {
              final copied = matches.single;
              require(
                file.size <= 0 || copied.size == file.size,
                '阿里转存文件大小不一致',
              );
              require(
                file.hashValue == null ||
                    copied.hashValue == null ||
                    file.hashType != copied.hashType ||
                    file.hashValue!.toLowerCase() ==
                        copied.hashValue!.toLowerCase(),
                '阿里转存文件校验信息不一致',
              );
              return copied;
            }
            await RequestScope.wait(taskDelay);
          }
          throw const AppException('阿里转存已提交，目标文件暂不可见，请稍后重试');
        },
      );
      return (await (forPlayback ? _playback : _download)(
        token,
        drive,
        copy,
      )).copyWith(fileName: file.name, cleanup: cleanup);
    } catch (_) {
      if (!staged) {
        try {
          await _post('/v2/recyclebin/trash', {
            'drive_id': drive,
            'file_id': folder.id,
          }, session: token);
        } catch (_) {
          /* The caller may retry cleanup with its saved action. */
        }
      }
      rethrow;
    }
  }
}
