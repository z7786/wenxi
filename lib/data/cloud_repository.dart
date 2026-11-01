import 'dart:async';
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../diagnostics/app_log.dart';
import '../download/download_request.dart';
import '../domain/models.dart';
import '../domain/baidu_share_route.dart';
import '../domain/public_share_route.dart';
import '../domain/uploads.dart';
import '../domain/auth.dart';
import '../domain/downloads.dart';
import '../domain/uc_video_download.dart';
import '../domain/download_retries.dart';
import '../domain/github_acceleration.dart';
import 'state_store.dart';
import 'http.dart';
import 'http_retry.dart';
import 'cleanup_outbox.dart';
import 'providers/baidu.dart';
import 'providers/baidu_public_parser.dart';
import 'providers/baidu_public_password.dart';
import 'parser_rules/hub.dart';
import 'providers/ctfile.dart';
import 'providers/feijipan.dart';
import 'providers/pikpak.dart';
import 'providers/github.dart';
import 'providers/quark.dart';
import 'providers/uc.dart';
import 'providers/pan123.dart';
import 'providers/c139.dart';
import 'providers/tianyi.dart';
import 'providers/tianyi_login.dart';
import 'providers/lanzou.dart';
import 'providers/guangya.dart';
import 'providers/aliyun.dart';
import 'providers/ilanzou.dart';
import 'providers/weiyun.dart';
import 'providers/wopan.dart';
import 'providers/pan115.dart';
import 'providers/xunlei.dart';
import 'providers/xunlei_protocol.dart';
import 'providers/xunlei_login.dart';
import 'cloud_command_resolver.dart';

class CloudRepository {
  CloudRepository(
    JsonHttp transport,
    this.vault,
    this.cleanups, {
    this.checkAccess,
    this.preparationRetries,
    this.retryWait,
    this.directShareDownloadEnabled,
    GitHubAcceleration Function()? githubAcceleration,
    ParserRuleHub? parserHub,
    DateTime Function()? clock,
  }) : http = transport is RetryingJsonHttp
           ? transport
           : RetryingJsonHttp(transport) {
    final devices = XunleiDevices(vault);
    publicPasswords = BaiduPublicPasswords(
      http,
      store: vault,
      clock: clock,
      cleanups: cleanups,
    );
    publicParser = BaiduPublicParser(
      http,
      passwords: publicPasswords,
      hub: parserHub,
    );
    connectors = {
      CloudPlatform.github: GitHubConnector(
        http,
        acceleration: githubAcceleration,
      ),
      CloudPlatform.pikpak: PikPakConnector(
        http,
        vault,
        stageCleanup: _stageCleanup,
      ),
      CloudPlatform.feijipan: FeijipanConnector(http, vault),
      CloudPlatform.ctfile: CtfileConnector(http),
      CloudPlatform.baidu: BaiduConnector(
        http,
        store: vault,
        stageCleanup: _stageCleanup,
        publicParser: publicParser,
      ),
      CloudPlatform.quark: QuarkConnector(
        http,
        store: vault,
        stageCleanup: _stageCleanup,
        directShareDownloadEnabled: directShareDownloadEnabled == null
            ? null
            : (authenticated) => directShareDownloadEnabled!(
                CloudPlatform.quark,
                authenticated,
              ),
      ),
      CloudPlatform.uc: UcConnector(
        http,
        store: vault,
        stageCleanup: _stageCleanup,
        directShareDownloadEnabled: directShareDownloadEnabled == null
            ? null
            : (authenticated) =>
                  directShareDownloadEnabled!(CloudPlatform.uc, authenticated),
      ),
      CloudPlatform.pan123: Pan123Connector(
        http,
        vault,
        stageCleanup: _stageCleanup,
      ),
      CloudPlatform.xunlei: XunleiConnector(
        http,
        vault,
        devices,
        stageCleanup: _stageCleanup,
        passwordLogin: (username, password) =>
            xunleiLogin.password(username, password, rememberPassword: true),
      ),
      CloudPlatform.c139: C139Connector(http, stageCleanup: _stageCleanup),
      CloudPlatform.tianyi: TianyiConnector(
        http,
        store: vault,
        stageCleanup: _stageCleanup,
        passwordLogin: (username, password) =>
            tianyiLogin.password(username, password),
      ),
      CloudPlatform.lanzou: LanzouConnector(http),
      CloudPlatform.guangya: GuangyaConnector(
        http,
        vault,
        stageCleanup: _stageCleanup,
      ),
      CloudPlatform.ilanzou: ILanzouConnector(http, vault),
      CloudPlatform.weiyun: WeiyunConnector(http, vault),
      CloudPlatform.wopan: WopanConnector(http, vault),
      CloudPlatform.pan115: Pan115Connector(http),
      CloudPlatform.aliyun: AliyunConnector(
        http,
        vault,
        stageCleanup: _stageCleanup,
      ),
    };
    xunleiLogin = XunleiLoginService(http, devices);
    tianyiLogin = TianyiLoginService(
      http,
      connectors[CloudPlatform.tianyi] as TianyiConnector,
    );
    cleanups.executeAction = (action) async {
      final platform = CloudPlatform.fromKey(action.str('platform'));
      require(
        {
              CloudPlatform.pan123,
              CloudPlatform.c139,
              CloudPlatform.tianyi,
              CloudPlatform.xunlei,
              CloudPlatform.aliyun,
              CloudPlatform.guangya,
              CloudPlatform.pikpak,
            }.contains(platform) &&
            action.str('kind') == 'temporary-folder',
        '无法识别云端清理任务',
      );
      final owner = _ownerForRevision(
        platform!,
        action.integer('accountRevision'),
        action['accountId']?.toString(),
      );
      await _withAccount(platform, owner, () async {
        final account = credential(platform);
        require(
          account.updatedAt == action.integer('accountRevision'),
          '账号已变化，原账号的临时文件清理暂缓',
        );
        final spaceId = action.str('driveId');
        final session = platform.supportsPersonalSpaces && spaceId.isNotEmpty
            ? await connector(
                platform,
              ).openPersonalSpace(CloudSpace(spaceId, ''), account)
            : await connector(platform).openPersonal(account);
        require(
          vault.credential(platform)?.updatedAt == account.updatedAt,
          '账号已变化，临时文件清理暂缓',
        );
        final id = action.str('folderId');
        require(
          id.isNotEmpty &&
              id != session.rootId &&
              RegExp(
                r'^AsterLink临时转存_[0-9a-f-]{36}$',
              ).hasMatch(action.str('name')),
          '临时目录标识无效',
        );

        // A delete request can reach the provider while its response is lost.
        // Treat a subsequent not-found result as success, but keep failures
        // for folders that still exist so a renamed or moved folder is never
        // silently discarded.
        Future<void> deleteOrAcceptMissing(
          Future<void> Function() action,
        ) async {
          try {
            await action();
          } catch (error, stack) {
            try {
              final current = (await connector(platform).list(
                session,
                session.rootId,
                account,
              )).where((file) => file.id == id).firstOrNull;
              if (current == null) return;
            } catch (_) {
              // Preserve the original deletion failure when verification is
              // unavailable due to a transient network or account error.
            }
            Error.throwWithStackTrace(error, stack);
          }
        }

        if (platform == CloudPlatform.xunlei) {
          // Renew credentials at cleanup time; a download may outlive its tokens.
          await deleteOrAcceptMissing(
            () => (connector(platform) as XunleiConnector)
                .deleteTemporaryFolder(id, credential(platform)),
          );
          return;
        }
        if (platform == CloudPlatform.pikpak) {
          await deleteOrAcceptMissing(
            () =>
                (connector(platform) as PikPakConnector).deleteTemporaryFolder(
                  id,
                  action.str('name'),
                  credential(platform),
                ),
          );
          return;
        }
        if (platform == CloudPlatform.aliyun) {
          await deleteOrAcceptMissing(
            () =>
                (connector(platform) as AliyunConnector).deleteTemporaryFolder(
                  session,
                  id,
                  action.str('name'),
                  credential(platform),
                ),
          );
          return;
        }
        if (platform == CloudPlatform.guangya) {
          await deleteOrAcceptMissing(
            () =>
                (connector(platform) as GuangyaConnector).deleteTemporaryFolder(
                  session,
                  id,
                  action.str('name'),
                  credential(platform),
                ),
          );
          return;
        }
        await deleteOrAcceptMissing(
          () => connector(platform).delete(session, [
            CloudFile(
              id: id,
              name: action.str('name'),
              isDirectory: true,
              parentId: session.rootId,
            ),
          ], account),
        );
      });
    };
  }
  final JsonHttp http;
  final CredentialStore vault;
  final CleanupOutbox cleanups;
  late final BaiduPublicPasswords publicPasswords;
  late final BaiduPublicParser publicParser;
  final void Function(CloudPlatform)? checkAccess;
  final int Function()? preparationRetries;
  final Future<void> Function(Duration)? retryWait;
  final bool Function(CloudPlatform platform, bool authenticated)?
  directShareDownloadEnabled;
  final _preparationKey = Object();
  final _continuationKey = Object();
  final _readPreparationKey = Object();

  T _withAccount<T>(CloudPlatform p, String? id, T Function() action) =>
      vault is Vault ? (vault as Vault).withAccount(p, id, action) : action();

  String? _currentId(CloudPlatform p) =>
      vault is Vault ? (vault as Vault).accountId(p) : null;

  String? _ownerForRevision(CloudPlatform p, int? revision, String? id) {
    if (id != null) return id.isEmpty ? null : id;
    if (vault is! Vault || revision == null) return null;
    return (vault as Vault).accountForRevision(p, revision);
  }

  BrowseSession bindSession(BrowseSession session) =>
      vault is Vault && session.accountId == null
      ? session.withAccount(_currentId(session.platform))
      : session;

  T withSession<T>(BrowseSession session, T Function() action) {
    final id = session.accountId;
    return _withAccount(
      session.platform,
      id == null
          ? _currentId(session.platform)
          : id.isEmpty
          ? null
          : id,
      action,
    );
  }

  Credential? sessionCredential(BrowseSession session) =>
      withSession(session, () => vault.credential(session.platform));

  void ensureAvailable(CloudPlatform platform) {
    if (Zone.current[_continuationKey] != true) checkAccess?.call(platform);
  }

  // Only refreshes for already-owned tasks may bypass a maintenance switch.
  // Keeping this scope private prevents a new browse/parse from inheriting it.
  Future<T> _continue<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_continuationKey: true});
  Future<void> _stageCleanup(DownloadCleanup cleanup) async {
    final platform = CloudPlatform.fromKey(cleanup.action?.str('platform'));
    await cleanups.stage(
      cleanup,
      accountId: platform != null && vault is Vault
          ? _currentId(platform) ?? ''
          : null,
    );
    (Zone.current[_preparationKey] as List<DownloadCleanup>?)?.add(cleanup);
  }

  late final Map<CloudPlatform, CloudConnector> connectors;
  late final XunleiLoginService xunleiLogin;
  late final TianyiLoginService tianyiLogin;
  CloudConnector connector(CloudPlatform p) => connectors[p]!;
  Credential credential(CloudPlatform p) =>
      vault.credential(p) ?? (throw AccountLoginRequired('请先登录${p.label}'));
  Future<BrowseSession> personal(
    CloudPlatform p, {
    String? accountId,
    String? spaceId,
  }) => _withAccount(p, accountId ?? _currentId(p), () async {
    ensureAvailable(p);
    require(p.requiresAccount, '支持不登录解析');
    final account = credential(p);
    require(spaceId == null || p.supportsPersonalSpaces, '该网盘不支持切换存储空间');
    final result = spaceId == null
        ? await connector(p).openPersonal(account)
        : await connector(
            p,
          ).openPersonalSpace(CloudSpace(spaceId, ''), account);
    _checkAccount(p, account);
    return bindSession(result);
  });

  Future<List<CloudSpace>> personalSpaces(
    CloudPlatform platform, {
    String? accountId,
  }) => _withAccount(platform, accountId ?? _currentId(platform), () async {
    ensureAvailable(platform);
    require(platform.supportsPersonalSpaces, '该网盘不支持切换存储空间');
    final account = credential(platform);
    final spaces = await connector(platform).personalSpaces(account);
    _checkAccount(platform, account);
    return spaces;
  });

  void _checkAccount(CloudPlatform platform, Credential account) {
    ensureAvailable(platform);
    RequestScope.checkpoint();
    require(
      vault.credential(platform)?.updatedAt == account.updatedAt,
      '账号已变化，请重新打开网盘',
    );
  }

  Future<List<CloudSpace>> familySpaces(CloudPlatform p, {String? accountId}) =>
      _withAccount(p, accountId ?? _currentId(p), () async {
        ensureAvailable(p);
        require(p.supportsFamilyCloud, '该网盘暂不支持家庭云');
        final account = credential(p);
        final spaces = await connector(p).familySpaces(account);
        _checkAccount(p, account);
        return spaces;
      });

  Future<BrowseSession> family(
    CloudPlatform p,
    String id, {
    String? accountId,
  }) => _withAccount(p, accountId ?? _currentId(p), () async {
    ensureAvailable(p);
    require(p.supportsFamilyCloud && id.isNotEmpty, '家庭云信息不完整');
    final account = credential(p), provider = connector(p);
    final spaces = await provider.familySpaces(account);
    _checkAccount(p, account);
    final space = spaces.where((s) => s.id == id).firstOrNull;
    require(space != null, '当前账号已无法访问该家庭云，请重新选择家庭');
    final session = await provider.openFamily(space!, account);
    _checkAccount(p, account);
    require(
      session.platform == p && session.isFamily && session.familyId == id,
      '家庭云来源不一致，请重新选择',
    );
    return bindSession(session);
  });

  Future<BrowseSession> reopenSpace(BrowseSession previous) => withSession(
    previous,
    () => previous.isFamily
        ? family(previous.platform, previous.familyId)
        : personal(
            previous.platform,
            spaceId: previous.personalSpaceId.isEmpty
                ? null
                : previous.personalSpaceId,
          ),
  );

  Future<BrowseSession> share(
    ParsedLink link, {
    BaiduShareRoute baiduRoute = BaiduShareRoute.account,
    String? parserSiteId,
    String? parserPasswordGrant,
  }) async {
    final p = link.platform;
    require(p != null, '此链接不是支持的网盘分享');
    require(p!.supportsShareParsing, p.shareUnavailableMessage);
    return _withAccount(p, _currentId(p), () async {
      ensureAvailable(p);
      final account = vault.credential(p);
      final provider = connector(p);
      final result = await OperationProgress.step(
        OperationStage.verifyShare,
        () => p != CloudPlatform.baidu && parserSiteId != null
            ? publicParser.openShare(
                link,
                parserSiteId: parserSiteId,
                passwordGrant: parserPasswordGrant,
              )
            : provider is BaiduConnector
            ? provider.openShare(
                link,
                account,
                route: baiduRoute,
                parserSiteId: parserSiteId,
                parserPasswordGrant: parserPasswordGrant,
              )
            : provider.openShare(link, account),
      );
      ensureAvailable(p);
      require(
        vault.credential(p)?.updatedAt == account?.updatedAt,
        '账号已变化，请重新解析分享',
      );
      return bindSession(result.withLink(link));
    });
  }

  Future<ParsedLink> resolveCommand(CloudPlatform platform, String text) async {
    ensureAvailable(platform);
    final result = await CloudCommandResolver(http).resolve(platform, text);
    ensureAvailable(platform);
    return result;
  }

  Future<void> ensureParserPassword(BrowseSession session) async {
    if (!PublicShareRoute.uses(session)) return;
    final provider = connector(session.platform);
    if (session.platform == CloudPlatform.baidu) {
      if (provider is BaiduConnector) {
        await provider.ensurePublicPassword(session);
      }
    } else {
      await publicParser.ensurePassword(session);
    }
  }

  Future<List<CloudFile>> list(BrowseSession session, String parent) =>
      withSession(session, () async {
        ensureAvailable(session.platform);
        final account = session.mode == BrowseMode.personal
            ? credential(session.platform)
            : vault.credential(session.platform);
        final result = await OperationProgress.step(
          OperationStage.readFiles,
          () =>
              session.platform != CloudPlatform.baidu &&
                  PublicShareRoute.uses(session)
              ? publicParser.list(session, parent)
              : connector(session.platform).list(session, parent, account),
        );
        ensureAvailable(session.platform);
        require(
          vault.credential(session.platform)?.updatedAt == account?.updatedAt,
          '账号已变化，请重新打开文件列表',
        );
        return result;
      });

  String directoryId(BrowseSession session, CloudFile file) =>
      session.platform == CloudPlatform.baidu
      ? file.token.ifEmpty(file.id)
      : file.id;

  Future<void> saveShare(
    BrowseSession session,
    List<CloudFile> files,
    String target,
  ) => withSession(session, () async {
    final provider = connector(session.platform),
        account = credential(session.platform);
    if (!PublicShareRoute.uses(session) ||
        session.platform == CloudPlatform.baidu) {
      return provider.saveShare(session, files, target, account);
    }
    final link = session.sourceLink;
    require(link != null, '原分享信息缺失，请重新解析');
    final native = await provider.openShare(link!, account);
    final parents = <String, List<CloudFile>>{};
    final selected = <CloudFile>[];
    for (final file in files) {
      final parent = file.parentId == session.rootId
          ? native.rootId
          : file.parentId;
      final entries = parents[parent] ??= await provider.list(
        native,
        parent,
        account,
      );
      final fresh = entries
          .where((f) => f.id == file.id && f.isDirectory == file.isDirectory)
          .firstOrNull;
      require(
        fresh != null && (file.size <= 0 || fresh.size == file.size),
        '分享文件已变化，请切换常规解析后再转存',
      );
      selected.add(fresh!);
    }
    RequestScope.checkpoint();
    await provider.saveShare(native, selected, target, account);
  });

  Future<CloudFile> createFolder(
    BrowseSession session,
    String parent,
    String name,
  ) => _writeFile(session, parent, name, (provider, account) {
    require(provider.canCreateFolderIn(session, parent), '当前目录不支持创建文件夹');
    return provider.createFolder(session, parent, name, account);
  });

  Future<CloudFile> upload(
    BrowseSession session,
    String parent,
    UploadFile source, {
    UploadProgressCallback? onProgress,
  }) => _writeFile(session, parent, source.name, (provider, account) {
    require(provider.canUploadTo(session, parent), '当前目录不支持上传，请先进入代码目录或发布附件');
    return provider.upload(
      session,
      parent,
      source.guarded(RequestScope.checkpoint),
      account,
      onProgress: onProgress,
    );
  });

  Future<CloudFile> _writeFile(
    BrowseSession session,
    String parent,
    String name,
    Future<CloudFile> Function(CloudConnector, Credential) action,
  ) => withSession(session, () async {
    require(session.canManageFiles, '请在个人网盘中执行此操作');
    require(
      name.trim().isNotEmpty &&
          name != '.' &&
          name != '..' &&
          !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name),
      '文件或文件夹名称无效',
    );
    final account = credential(session.platform),
        provider = connector(session.platform);
    void guard() {
      ensureAvailable(session.platform);
      require(
        vault.credential(session.platform)?.updatedAt == account.updatedAt,
        '账号已变化，请重新打开文件列表',
      );
    }

    return RequestScope.guarded(() async {
      RequestScope.checkpoint();
      final existing = await provider.list(session, parent, account);
      require(
        !existing.any(
          (entry) => entry.name.toLowerCase() == name.toLowerCase(),
        ),
        '目录中已有同名项目，请更改名称后重试',
      );
      RequestScope.checkpoint();
      final result = await action(provider, account);
      RequestScope.checkpoint();
      return result;
    }, guard);
  });

  BrowseSession _bindNewDownloadSession(BrowseSession session) {
    // A share opened before login is pinned to an empty owner. New downloads
    // can use the newly selected account; stored tasks keep their original owner.
    if (session.platform == CloudPlatform.quark &&
        session.mode == BrowseMode.share &&
        session.accountId == '' &&
        !PublicShareRoute.uses(session) &&
        vault is Vault) {
      final accounts = vault as Vault;
      final owner = accounts.activeAccountId(session.platform);
      if (accounts.credentialFor(session.platform, owner) != null) {
        return session.withAccount(owner);
      }
    }
    return session;
  }

  DownloadSpec planDownload(BrowseSession session, CloudFile file) {
    session = _bindNewDownloadSession(session);
    return withSession(session, () {
      ensureAvailable(session.platform);
      RequestScope.checkpoint();
      require(file.id.isNotEmpty && !file.isDirectory, '下载文件信息不完整');
      final account = session.mode == BrowseMode.personal
          ? credential(session.platform)
          : vault.credential(session.platform);
      return DownloadSpec(
        url: '',
        fileName: file.name,
        expectedSize: session.platform.exactFileSize ? file.size : 0,
        profile: PublicShareRoute.uses(session)
            ? PublicShareRoute.profile(session.platform)
            : null,
        checksumType: file.hashType,
        checksumValue: file.hashValue,
        source: DownloadOrigin(
          bindSession(session),
          file,
          account?.updatedAt,
        ).toJson(),
      );
    });
  }

  Future<DownloadSpec> prepare(BrowseSession session, CloudFile file) =>
      _prepare(_bindNewDownloadSession(session), file, playback: false);

  Future<DownloadSpec> preparePlayback(BrowseSession session, CloudFile file) =>
      _prepare(session, file, playback: true);

  Future<DownloadSpec> prepareUcPlayable(
    BrowseSession session,
    CloudFile file,
  ) => _prepare(session, file, playback: false, ucPlayable: true);

  Future<DownloadSpec> _prepare(
    BrowseSession session,
    CloudFile file, {
    required bool playback,
    bool ucPlayable = false,
    UcVideoDownload? ucVideo,
  }) => withSession(
    session,
    () => _prepareBound(
      bindSession(session),
      file,
      playback: playback,
      ucPlayable: ucPlayable,
      ucVideo: ucVideo,
    ),
  );

  Future<DownloadSpec> _prepareBound(
    BrowseSession session,
    CloudFile file, {
    required bool playback,
    bool ucPlayable = false,
    UcVideoDownload? ucVideo,
  }) async {
    ensureAvailable(session.platform);
    RequestScope.checkpoint();
    final c = session.mode == BrowseMode.personal
        ? credential(session.platform)
        : vault.credential(session.platform);
    final revision = c?.updatedAt;
    final staged = <DownloadCleanup>[];
    return _prepareReads(
      session,
      revision,
      () => runZoned(() async {
        try {
          final provider = connector(session.platform);
          require(!ucPlayable || provider is UcConnector, '可播放版本下载仅支持 UC 网盘');
          final result = await (ucPlayable
              ? (provider as UcConnector).downloadPlayable(
                  session,
                  file,
                  c,
                  resolution: ucVideo?.resolution,
                )
              : session.platform != CloudPlatform.baidu &&
                    PublicShareRoute.uses(session)
              ? publicParser.download(session, file)
              : playback
              ? provider.playback(session, file, c)
              : provider.download(session, file, c));
          if (ucVideo != null) {
            require(
              ucVideo.sameAs(UcVideoDownload.fromSpec(result)!),
              'UC 可播放版本的画质或大小已变化，无法续传，请重新创建下载任务',
            );
          }
          try {
            ensureAvailable(session.platform);
          } catch (_) {
            await cleanups.ready(result.cleanup);
            rethrow;
          }
          if (RequestScope.current?.isCancelled == true) {
            await cleanups.ready(result.cleanup);
            RequestScope.checkpoint();
          }
          if (vault.credential(session.platform)?.updatedAt != revision) {
            await cleanups.ready(result.cleanup);
            throw const AppException('账号已变化，请重新打开文件列表');
          }
          if (session.platform == CloudPlatform.uc && result.guestDownload ||
              session.platform == CloudPlatform.quark &&
                  result.cleanup == null) {
            // Recovery can succeed without a temporary transfer after an
            // account attempt staged one. Retry any remaining cleanup safely.
            for (final cleanup in staged) {
              await cleanups.ready(cleanup);
            }
          }
          cleanups.retain(result.cleanup);
          return result.copyWith(
            source: {
              ...DownloadOrigin(session, file, revision).toJson(),
              if (ucPlayable) 'ucVideo': result.source!['ucVideo'],
              if (provider is BaiduConnector &&
                  result.source?['baiduTransfer'] != null)
                'baiduTransfer': result.source!['baiduTransfer'],
            },
          );
        } catch (_) {
          for (final cleanup in staged) {
            await cleanups.ready(cleanup);
          }
          rethrow;
        }
      }, zoneValues: {_preparationKey: staged}),
      playback: playback,
    );
  }

  Future<DownloadSpec> _prepareReads(
    BrowseSession session,
    int? revision,
    Future<DownloadSpec> Function() action, {
    String phase = 'prepare',
    bool playback = false,
  }) async {
    if (Zone.current[_readPreparationKey] == true) return action();
    final context = DownloadRequestContext.current;
    final ref = DiagnosticLog.reference(context?.id ?? newId());
    final clock = Stopwatch()..start();
    final event = playback ? 'playback.prepare' : 'download.prepare';
    final fields = <String, Object?>{
      'ref': ref,
      'platform': session.platform.key,
      'phase': phase,
    };
    void checkpoint() {
      RequestScope.checkpoint();
      ensureAvailable(session.platform);
      final account = vault.credential(session.platform);
      if (revision != null && account == null) {
        throw AccountLoginRequired('请先登录${session.platform.label}');
      }
      require(account?.updatedAt == revision, '账号已变化，请重新打开文件列表');
    }

    final scope = ReadRetryScope(
      retries:
          context?.retries ??
          preparationRetries?.call() ??
          defaultDownloadRetries,
      checkpoint: checkpoint,
      wait: retryWait ?? RequestScope.wait,
      onRetry: (attempt) async {
        DiagnosticLog.event(
          '$event.retry',
          fields: {
            ...fields,
            'stage': OperationProgress.currentStage?.name,
            'attempt': attempt.number,
            'waitMs': attempt.delay.inMilliseconds,
            'kind': attempt.failure.kind,
            'status': attempt.failure.status ?? 0,
          },
        );
        await context?.onRetry?.call(attempt.delay);
      },
    );
    DiagnosticLog.event('$event.start', fields: fields);
    try {
      checkpoint();
      final result = await scope.run(
        () => runZoned(action, zoneValues: {_readPreparationKey: true}),
      );
      DiagnosticLog.event(
        '$event.ready',
        fields: {...fields, 'elapsedMs': clock.elapsedMilliseconds},
      );
      return result;
    } catch (error, stack) {
      if (RequestScope.current?.isCancelled == true) {
        DiagnosticLog.event('$event.cancelled', fields: fields);
      } else {
        DiagnosticLog.error(
          '$event.failed',
          error,
          stack,
          fields: {
            ...fields,
            'elapsedMs': clock.elapsedMilliseconds,
            if (error is HttpRequestFailure) 'kind': error.kind,
            if (error is HttpRequestFailure) 'status': error.status ?? 0,
          },
        );
      }
      rethrow;
    }
  }

  Future<DownloadSpec> refresh(DownloadSpec previous) => _continue(() async {
    require(previous.source != null, '下载地址已失效，请重新添加链接');
    final origin = DownloadOrigin.fromJson(previous.source!);
    return _withAccount(
      origin.session.platform,
      _ownerForRevision(
        origin.session.platform,
        origin.accountRevision,
        origin.session.accountId,
      ),
      () => _prepareReads(
        origin.session,
        origin.accountRevision,
        () async {
          final provider = connector(origin.session.platform);
          if (provider is BaiduConnector &&
              origin.session.mode == BrowseMode.share &&
              !BaiduShareRoute.usesPublicParser(origin.session) &&
              !previous.needsPreparation) {
            final reused = await provider.refreshTransfer(
              previous,
              credential(origin.session.platform),
            );
            if (reused != null) {
              RequestScope.checkpoint();
              ensureAvailable(origin.session.platform);
              require(
                vault.credential(origin.session.platform)?.updatedAt ==
                    origin.accountRevision,
                '帐号已变化，请重新打开文件列表',
              );
              cleanups.retain(reused.cleanup);
              return reused;
            }
          }
          final restored = await restoreOrigin(origin);
          final ucVideo = UcVideoDownload.fromSpec(previous);
          require(
            ucVideo == null || origin.session.platform == CloudPlatform.uc,
            '下载来源与视频画质信息不一致',
          );
          return (await _prepare(
            restored.session,
            restored.file,
            playback: false,
            ucPlayable: ucVideo != null,
            ucVideo: ucVideo,
          )).copyWith(
            fileName: previous.fileName,
            relativePath: previous.relativePath,
          );
        },
        phase: previous.needsPreparation ? 'prepare' : 'refresh',
      ),
    );
  });

  Future<DownloadSpec> refreshPlayback(DownloadOrigin origin) =>
      _continue(() async {
        final restored = await restoreOrigin(origin);
        return preparePlayback(restored.session, restored.file);
      });

  Future<DownloadSpec> continuePlayback(
    BrowseSession session,
    CloudFile file,
  ) => _continue(() => preparePlayback(session, file));

  /// Reopen the original share or personal directory with current credentials.
  /// History and expired downloads share the same identity checks and never
  /// try to replay a temporary transferred file that has already been cleaned.
  Future<({BrowseSession session, CloudFile file, List<CloudFile> siblings})>
  restoreOrigin(DownloadOrigin origin) => _withAccount(
    origin.session.platform,
    _ownerForRevision(
      origin.session.platform,
      origin.accountRevision,
      origin.session.accountId,
    ),
    () => _restoreOrigin(origin),
  );

  Future<({BrowseSession session, CloudFile file, List<CloudFile> siblings})>
  _restoreOrigin(DownloadOrigin origin) async {
    ensureAvailable(origin.session.platform);
    final platform = origin.session.platform,
        current = vault.credential(origin.session.platform);
    RequestScope.checkpoint();
    if (origin.accountRevision != null && current == null) {
      throw AccountLoginRequired('请先登录${platform.label}');
    }
    require(
      origin.accountRevision == current?.updatedAt,
      '${platform.shortName}账号已更新，请从原文件列表重新打开一次',
    );
    require(origin.file.id.isNotEmpty && !origin.file.isDirectory, '播放文件信息不完整');
    final link = origin.session.sourceLink;
    BrowseSession session;
    if (origin.session.mode == BrowseMode.share) {
      require(
        link != null &&
            link.platform == platform &&
            link.kind == LinkKind.cloudShare,
        '原分享信息已缺失，请重新解析分享链接',
      );
      session = await share(
        link!,
        baiduRoute: BaiduShareRoute.fromSession(origin.session),
        parserSiteId: origin.session.meta('parserSiteId').isEmpty
            ? null
            : origin.session.meta('parserSiteId'),
        parserPasswordGrant: origin.session.meta('parserPasswordGrant'),
      );
    } else {
      session = await reopenSpace(origin.session);
    }
    RequestScope.checkpoint();
    require(
      origin.accountRevision == vault.credential(platform)?.updatedAt,
      '账号已变化，请重新打开文件',
    );
    final parent = origin.file.parentId == origin.session.rootId
        ? session.rootId
        : origin.file.parentId;
    List<CloudFile> files;
    try {
      files = await list(session, parent);
    } on AppException catch (error) {
      // Older share tasks stored the owner's physical parent for root entries.
      // Recover only an exact file match in the current share's root.
      final invalidShareParent =
          platform == CloudPlatform.quark &&
              error.message.trimLeft().startsWith('文件没有被分享') ||
          platform == CloudPlatform.xunlei &&
              error is XunleiShareParentUnavailable ||
          platform == CloudPlatform.guangya &&
              error is GuangyaApiException &&
              error.code == '143';
      final isRoot =
          parent == session.rootId ||
          platform == CloudPlatform.quark &&
              parent.ifEmpty('0') == session.rootId.ifEmpty('0');
      if (!invalidShareParent || session.mode != BrowseMode.share || isRoot) {
        rethrow;
      }
      RequestScope.checkpoint();
      final rootFiles = await list(session, session.rootId);
      if (!rootFiles.any((f) => !f.isDirectory && f.id == origin.file.id)) {
        rethrow;
      }
      files = rootFiles;
      DiagnosticLog.event(
        '${platform.name}.share_parent_recovered',
        fields: {
          'ref': DiagnosticLog.reference(
            DownloadRequestContext.current?.id ?? origin.file.id,
          ),
        },
      );
    }
    final fresh = files
        .where((f) => !f.isDirectory && f.id == origin.file.id)
        .firstOrNull;
    require(fresh != null, '源文件已移动、删除或分享已失效，请重新打开文件列表');
    require(
      !(origin.file.size > 0 &&
              fresh!.size > 0 &&
              origin.file.size != fresh.size) &&
          !(origin.file.hashValue?.isNotEmpty == true &&
              fresh!.hashValue?.isNotEmpty == true &&
              origin.file.hashType == fresh.hashType &&
              origin.file.hashValue!.toLowerCase() !=
                  fresh.hashValue!.toLowerCase()),
      '源文件内容已变化，请从文件列表重新打开',
    );
    require(
      origin.accountRevision == vault.credential(platform)?.updatedAt,
      '账号已变化，请重新打开文件',
    );
    RequestScope.checkpoint();
    return (session: session, file: fresh!, siblings: files);
  }

  Future<List<(CloudFile, String)>> collect(
    BrowseSession session,
    List<CloudFile> selected,
  ) async {
    ensureAvailable(session.platform);
    final result = <(CloudFile, String)>[], visited = <String>{};
    final watch = Stopwatch()..start();
    Future<void> walk(CloudFile file, String relative, int depth) async {
      RequestScope.checkpoint();
      require(depth <= 32 && result.length < 10000, '目录层级或文件数量过多，请分批下载');
      require(
        connector(session.platform).canDownloadFile(session, file),
        '请先进入代码目录或发布附件列表再选择下载，也可下载仓库源码 ZIP',
      );
      if (!file.isDirectory) {
        result.add((file, relative));
        if (result.length % 128 == 0) await RequestScope.wait(Duration.zero);
        return;
      }
      final id = directoryId(session, file);
      if (!visited.add(id)) return;
      final next = relative.isEmpty ? file.name : '$relative/${file.name}';
      for (final child in await list(session, id)) {
        await walk(child, next, depth + 1);
      }
    }

    for (final file in selected) {
      await walk(file, '', 0);
    }
    DiagnosticLog.event(
      'download.files_collected',
      fields: {
        'platform': session.platform.key,
        'files': result.length,
        'folders': visited.length,
        'elapsedMs': watch.elapsedMilliseconds,
      },
    );
    return result;
  }
}
