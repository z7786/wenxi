import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'core/json.dart';
import 'diagnostics/app_log.dart';
import 'data/backup.dart';
import 'data/backgrounds.dart';
import 'domain/appearance.dart';
import 'domain/background.dart';
import 'data/cleanup_outbox.dart';
import 'data/resource_link_checks.dart';
import 'data/resource_link_probe.dart';
import 'data/cloud_repository.dart';
import 'data/cloud_favorites.dart';
import 'data/cloud_command_history.dart';
import 'data/http.dart';
import 'data/remote_control_http.dart';
import 'data/remote_control_service.dart';
import 'data/announcement_service.dart';
import 'data/parser_rules/hub.dart';
import 'data/parser_rules/native_http.dart';
import 'data/app_update_service.dart';
import 'data/github_update_service.dart';
import 'data/providers/uc.dart';
import 'data/providers/github.dart';
import 'data/providers/baidu.dart';
import 'data/providers/quark.dart';
import 'data/providers/pan123.dart';
import 'data/providers/tianyi.dart';
import 'data/providers/xunlei.dart';
import 'data/providers/guangya.dart';
import 'data/providers/aliyun.dart';
import 'data/legacy_import.dart';
import 'data/state_store.dart';
import 'domain/auth.dart';
import 'domain/models.dart';
import 'domain/settings.dart';
import 'download/download_manager.dart';
import 'download/mobile_data_download_guard.dart';
import 'download/transfer_activity.dart';
import 'download/navigation_transfers.dart';
import 'upload/upload_manager.dart';
import 'lan/lan_service.dart';
import 'lan/lan_files.dart';
import 'download/download_shutdown.dart';
import 'download/download_overlay.dart';
import 'download/transfer_http.dart';
import 'platform/file_access.dart';
import 'platform/download_network.dart';
import 'platform/app_update_installer.dart';
import 'platform/clipboard_links.dart';
import 'platform/external_open.dart';
import 'platform/native_engine.dart';
import 'platform/windows_actions.dart';
import 'platform/windows_webview.dart';
import 'data/providers/ilanzou.dart';
import 'data/providers/lanzou.dart';
import 'data/providers/ctfile.dart';
import 'data/providers/feijipan.dart';
import 'data/providers/pikpak.dart';
import 'data/providers/weiyun.dart';
import 'data/providers/wopan.dart';
import 'data/providers/pan115.dart';
import 'data/sources/service.dart';
import 'data/resource_search.dart';
import 'data/resource_search_api.dart';

class AppServices extends ChangeNotifier {
  AppServices({
    required this.store,
    required this.dataDirectory,
    required this.cacheDirectory,
    required NativeTransport transport,
    required this.files,
    JsonHttp? http,
    TransferHttp? transferHttp,
    Future<DownloadNetwork> Function()? downloadNetworkReader,
    this.platformFeatures = true,
    this.clock = DateTime.now,
    Future<String?> Function()? clipboardReader,
    String controlUrl = RemoteControlService.buildUrl,
    bool controlEnabled = RemoteControlService.buildEnabled,
    RemoteControlFetcher? controlFetcher,
    String announcementsUrl = AnnouncementService.buildUrl,
    RemoteControlFetcher? announcementFetcher,
    GitHubUpdateService? githubUpdates,
    WindowsActions? windowsActions,
    RandomAccessFile? instanceLock,
    LanService? lanService,
    ParserRuleHub? parserRuleHub,
    RemoteSources? remoteSources,
    ResourceSearch? resourceSearch,
  }) : _instanceLock = instanceLock,
       _preloadResources = platformFeatures || resourceSearch != null {
    vault = Vault(store);
    announcements = AnnouncementService(
      store,
      url: announcementsUrl,
      fetcher: announcementFetcher,
      clock: clock,
    );
    control = RemoteControlService(
      store,
      platform: Platform.operatingSystem,
      currentBuild: int.parse(applicationVersion.split('+').last),
      configUrl: controlUrl,
      enabled: controlEnabled,
      fetcher: controlFetcher,
      currentVersion: applicationVersion,
      githubUpdates:
          githubUpdates ??
          (platformFeatures && controlEnabled
              ? GitHubUpdateService(
                  platform: Platform.operatingSystem,
                  clock: clock,
                )
              : null),
      clock: clock,
    );
    _enabledClouds.addAll(CloudPlatform.values.where(control.cloudEnabled));
    clipboard = ClipboardLinks(
      store,
      read: clipboardReader ?? (platformFeatures ? null : () async => null),
    );
    cleanups = CleanupOutbox(store, http ?? DioJsonHttp());
    this.resourceSearch =
        resourceSearch ??
        ResourceSearch(
          store: store,
          api: HttpResourceSearchApi(
            cleanups.http,
            store: store,
            localSearch: platformFeatures,
            browserEnvironment: webEnvironment,
          ),
          linkChecks: ResourceLinkChecks(
            LocalResourceLinkCheckApi(clock: clock),
            clock: clock,
          ),
          clock: clock,
        );
    parserRules =
        parserRuleHub ??
        ParserRuleHub(
          store: vault,
          directory: dataDirectory,
          url: platformFeatures ? ParserRuleHub.buildUrl : '',
          passwordDocumentHttp: platformFeatures
              ? NativeParserRuleHttp(transport)
              : null,
          clock: clock,
        );
    parserRules.updateEndpoint(control.config.parserHubUrl);
    sources =
        remoteSources ??
        RemoteSources(
          hub: parserRules,
          directory: dataDirectory,
          enabled: platformFeatures,
          clock: clock,
          retainedArchives: () => downloads.tasks
              .map((task) => task.spec.source?.str('catalogId') ?? '')
              .where((id) => id.isNotEmpty)
              .toSet(),
        );
    cloud = CloudRepository(
      cleanups.http,
      vault,
      cleanups,
      clock: clock,
      parserHub: parserRules,
      checkAccess: control.checkCloud,
      preparationRetries: () => settings.retries,
      githubAcceleration: () => settings.githubAcceleration,
      directShareDownloadEnabled: (platform, authenticated) {
        final current = settings;
        return switch ((platform, authenticated)) {
          (CloudPlatform.quark, false) => current.quarkGuestDirectDownload,
          (CloudPlatform.quark, true) =>
            current.quarkAuthenticatedDirectDownload,
          (CloudPlatform.uc, false) => current.ucGuestDirectDownload,
          (CloudPlatform.uc, true) => false,
          _ => false,
        };
      },
    );
    login = AccountLoginService(
      vault,
      (p, c) => cloud.connector(p).account(c),
      checkAccess: control.checkCloud,
      webAuthenticators: {
        CloudPlatform.github:
            (cloud.connector(CloudPlatform.github) as GitHubConnector)
                .authenticate,
        CloudPlatform.baidu:
            (cloud.connector(CloudPlatform.baidu) as BaiduConnector)
                .authenticate,
        CloudPlatform.ctfile:
            (cloud.connector(CloudPlatform.ctfile) as CtfileConnector)
                .authenticate,
        CloudPlatform.pikpak:
            (cloud.connector(CloudPlatform.pikpak) as PikPakConnector)
                .authenticate,
        CloudPlatform.feijipan:
            (cloud.connector(CloudPlatform.feijipan) as FeijipanConnector)
                .authenticate,
        CloudPlatform.lanzou:
            (cloud.connector(CloudPlatform.lanzou) as LanzouConnector)
                .authenticate,
        CloudPlatform.pan115:
            (cloud.connector(CloudPlatform.pan115) as Pan115Connector)
                .authenticate,
        CloudPlatform.xunlei:
            (cloud.connector(CloudPlatform.xunlei) as XunleiConnector)
                .authenticate,
        CloudPlatform.ilanzou:
            (cloud.connector(CloudPlatform.ilanzou) as ILanzouConnector)
                .authenticate,
        CloudPlatform.weiyun:
            (cloud.connector(CloudPlatform.weiyun) as WeiyunConnector)
                .authenticate,
        CloudPlatform.wopan:
            (cloud.connector(CloudPlatform.wopan) as WopanConnector)
                .authenticate,
        CloudPlatform.guangya:
            (cloud.connector(CloudPlatform.guangya) as GuangyaConnector)
                .authenticate,
        CloudPlatform.aliyun:
            (cloud.connector(CloudPlatform.aliyun) as AliyunConnector)
                .authenticate,
        CloudPlatform.pan123:
            (cloud.connector(CloudPlatform.pan123) as Pan123Connector)
                .authenticate,
        CloudPlatform.quark:
            (cloud.connector(CloudPlatform.quark) as QuarkConnector)
                .authenticate,
        CloudPlatform.uc:
            (cloud.connector(CloudPlatform.uc) as UcConnector).authenticate,
        CloudPlatform.tianyi:
            (cloud.connector(CloudPlatform.tianyi) as TianyiConnector)
                .authenticate,
      },
    );
    favorites = CloudFavorites(store, cloud);
    backgrounds = BackgroundRepository(
      dataDirectory,
      current: () => settings.background,
    );
    backup = BackupRepository(store, backgrounds: backgrounds);
    final engineGeneration = store.data.str('engineStorageGeneration');
    require(
      engineGeneration.isEmpty ||
          RegExp(r'^[a-f0-9]{32}$').hasMatch(engineGeneration),
      '下载组件存储配置无效，原文件已保留',
    );
    engine = GopeedEngine(
      transport,
      store,
      vault,
      Directory(
        p.join(
          dataDirectory.path,
          engineGeneration.isEmpty ? 'gopeed' : 'gopeed-$engineGeneration',
        ),
      ),
      cacheDirectory,
    );
    transfer = transferHttp ?? TransferHttp();
    final backgroundTransfers =
        platformFeatures && (Platform.isAndroid || Platform.isWindows);
    lan =
        lanService ??
        LanService(
          store: store,
          files: LanFiles(android: platformFeatures && Platform.isAndroid),
          foreground: backgroundTransfers
              ? () => transferActivity.sync()
              : null,
        );
    transferActivity = TransferActivity(
      downloads: () => downloads.activity,
      uploads: () => uploads.activity,
      lan: () => lan.activity,
      publish: (activity) async {
        if (!backgroundTransfers) return;
        try {
          await nativeChannel.invokeMethod<void>('foreground', activity);
        } on PlatformException catch (e) {
          throw AppException(e.message ?? '后台传输服务启动失败');
        }
      },
    );
    uploads = UploadManager(
      store: store,
      cloud: cloud,
      foreground: backgroundTransfers ? transferActivity.sync : null,
    );
    mobileDataDownloads = MobileDataDownloadGuard(
      supported:
          downloadNetworkReader != null ||
          platformFeatures && Platform.isAndroid,
      readNetwork: downloadNetworkReader ?? readDownloadNetwork,
      reminderEnabled: () => settings.warnOnMobileDataDownload,
      disableReminder: () =>
          updateSettings({'warnOnMobileDataDownload': false}),
    );
    downloads = DownloadManager(
      store: store,
      engine: engine,
      files: files,
      cleanups: cleanups,
      http: transfer,
      refreshSource: (spec) => RemoteSources.owns(spec)
          ? sources.refreshDownload(spec)
          : cloud.refresh(spec),
      checkNewCloudTask: control.checkCloud,
      onGuestDownload: requestGuestDownloadNotice,
      confirmDownload: mobileDataDownloads.supported
          ? mobileDataDownloads.confirm
          : null,
      foreground: backgroundTransfers ? (_) => transferActivity.sync() : null,
    );
    navigationTransfers = NavigationTransfers(
      changes: Listenable.merge([downloads, uploads]),
      downloads: () => downloads.activeTasks,
      uploads: () => uploads.activeTasks,
      downloadById: downloads.task,
      uploadById: uploads.task,
    );
    windows =
        windowsActions ??
        WindowsActions(supported: platformFeatures && Platform.isWindows);
    appUpdates = AppUpdateService(
      platform: control.platform,
      cloud: cloud,
      downloads: downloads,
      files: files,
      installer: AppUpdateInstaller(
        platform: control.platform,
        windows: windows,
      ),
      currentUpdate: () => control.availableUpdate,
      inForeground: () => control.inForeground,
      openDownloads: requestDownloadManager,
    );
    downloadShutdown = DownloadShutdown(
      supported: windows.supported,
      changes: Listenable.merge([downloads, uploads, lan]),
      tasks: () => downloads.tasks,
      busy: () =>
          downloads.activeCount > 0 ||
          uploads.activeCount > 0 ||
          lan.activeConnections > 0,
      shutdown: windows.shutdown,
      hibernate: windows.hibernate,
      flush: store.flush,
    );
    downloadOverlay = DownloadOverlay(
      supported: platformFeatures && Platform.isAndroid,
      changes: Listenable.merge([downloads, uploads, store]),
      tasks: () => downloads.tasks,
      uploadTasks: () => uploads.tasks,
      retryUpload: uploads.retry,
      openUploads: requestUploadManager,
      pause: downloads.pause,
      resume: downloads.resume,
      pauseAll: downloads.pauseAll,
      resumeAll: downloads.resumeAll,
      openDownloads: requestDownloadManager,
      dark: () =>
          settings.theme == 'Dark' ||
          settings.theme == 'System' &&
              PlatformDispatcher.instance.platformBrightness == Brightness.dark,
      appearance: (dark) =>
          settings.themePalette.colors(dark).overlay(settings.glassStyle),
    );
    control.addListener(_controlChanged);
  }
  final StateStore store;
  final Directory dataDirectory, cacheDirectory;
  final FileAccess files;
  final bool platformFeatures;
  final bool _preloadResources;
  final DateTime Function() clock;
  final RandomAccessFile? _instanceLock;
  late final Vault vault;
  late final RemoteControlService control;
  late final AnnouncementService announcements;
  final _enabledClouds = <CloudPlatform>{};
  late final ClipboardLinks clipboard;
  late final CleanupOutbox cleanups;
  late final CloudRepository cloud;
  late final CloudFavorites favorites;
  late final commandHistory = CloudCommandHistory(store);
  late final AccountLoginService login;
  late final BackupRepository backup;
  late final BackgroundRepository backgrounds;
  late final GopeedEngine engine;
  late final DownloadManager downloads;
  late final MobileDataDownloadGuard mobileDataDownloads;
  late final UploadManager uploads;
  late final LanService lan;
  late final TransferActivity transferActivity;
  late final NavigationTransfers navigationTransfers;
  final transferTab = ValueNotifier<int>(0);
  late final AppUpdateService appUpdates;
  late final WindowsActions windows;
  late final DownloadShutdown downloadShutdown;
  late final DownloadOverlay downloadOverlay;
  late final TransferHttp transfer;
  final accounts = <CloudPlatform, CloudAccount>{},
      accountErrors = <CloudPlatform, String>{};
  final accountLoading = <CloudPlatform>{},
      _revisions = <CloudPlatform, (String?, int?)>{};
  final accountNeedsLogin = <CloudPlatform>{};
  final sharedText = ValueNotifier<String?>(null);
  final downloadNavigation = ValueNotifier<int>(0);
  final resourceNavigation = ValueNotifier<int>(0);
  final lanNavigation = ValueNotifier<int>(0);
  final guestDownloadNotice = ValueNotifier<bool>(false);

  late final ParserRuleHub parserRules;
  late final RemoteSources sources;
  late final ResourceSearch resourceSearch;

  void refreshEntryData() {
    if (_closed) return;
    parserRules.start();
    unawaited(parserRules.refresh());
    sources.start();
    if (_preloadResources) unawaited(resourceSearch.preload());
  }

  void requestGuestDownloadNotice() {
    if (!_closed && !settings.hideGuestDownloadNotice) {
      guestDownloadNotice.value = true;
    }
  }

  void requestDownloadManager() {
    if (!_closed) {
      transferTab.value = 0;
      downloadNavigation.value++;
    }
  }

  void requestUploadManager() {
    if (!_closed) {
      transferTab.value = 1;
      downloadNavigation.value++;
    }
  }

  void requestResourceSearch() {
    if (!_closed) resourceNavigation.value++;
  }

  void requestLanPage() {
    if (!_closed) lanNavigation.value++;
  }

  Future<void> stopTransfers() async {
    await lan.stop();
    await uploads.stopAll();
    await downloads.pauseAll();
  }

  final externalOpens = ExternalOpenInbox(
    channel: Platform.isWindows ? windowsExternalOpenChannel : nativeChannel,
  );
  String? migrationError;
  bool _closed = false;
  late final _webHost = WindowsWebViewHost(
    primaryFolder: p.join(dataDirectory.path, 'webview'),
    recoveryFolder: p.join(
      (Platform.environment['LOCALAPPDATA'] ?? '').ifEmpty(dataDirectory.path),
      'WenxiAssistant',
      'WebView2',
      'login-${DiagnosticLog.reference(p.normalize(dataDirectory.absolute.path))}',
    ),
  );
  AppSettings get settings => AppSettings.fromJson(store.data.obj('settings'));

  static Future<AppServices> open() async {
    Directory data, cache, destination;
    NativeTransport transport;
    if (Platform.isAndroid) {
      final paths = asJson(await nativeChannel.invokeMethod<Object?>('paths'));
      require(
        paths.str('data').isNotEmpty && paths.str('cache').isNotEmpty,
        '无法读取应用存储路径',
      );
      data = Directory(paths.str('data'));
      cache = Directory(paths.str('cache'));
      destination = cache;
      transport = AndroidGopeedTransport();
    } else {
      require(Platform.isWindows, '当前版本支持 Android 和 Windows');
      data = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'AsterLink'),
      );
      cache = Directory(p.join(data.path, 'downloads'));
      destination = Directory(
        p.join(
          (await getDownloadsDirectory() ??
                  await getApplicationDocumentsDirectory())
              .path,
          'AsterLink',
        ),
      );
      transport = DesktopGopeedTransport(
        executable: p.join(
          p.dirname(Platform.resolvedExecutable),
          'asterlink_gopeed.exe',
        ),
      );
    }
    await data.create(recursive: true);
    await cache.create(recursive: true);
    final lock = await File(
      p.join(data.path, 'instance.lock'),
    ).open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on FileSystemException {
      await lock.close();
      throw const AppException('文析助手已在运行，请打开已有窗口');
    }
    try {
      final startup = Stopwatch()..start();
      DiagnosticLog.event('app.state_read_start');
      final store = await StateStore.open(data);
      DiagnosticLog.event(
        'app.state_read',
        fields: {
          'elapsedMs': startup.elapsedMilliseconds,
          'tasks': (store.data['tasks'] as List? ?? []).length,
        },
      );
      final result = AppServices(
        store: store,
        dataDirectory: data,
        cacheDirectory: cache,
        transport: transport,
        files: PlatformFileAccess(transport, destination),
        instanceLock: lock,
      );
      await result.initialize();
      DiagnosticLog.event(
        'app.services_ready',
        fields: {
          'elapsedMs': startup.elapsedMilliseconds,
          'tasks': result.downloads.tasks.length,
        },
      );
      return result;
    } catch (error, stack) {
      DiagnosticLog.error('app.initialize_failed', error, stack);
      await lock.close();
      rethrow;
    }
  }

  Future<void> initialize() async {
    // Entry refresh starts after MainShell's first frame. Cached search rules
    // are verified synchronously and remote updates share this store's write
    // gate; neither should compete with local account/queue initialization.
    if (platformFeatures && Platform.isWindows) {
      windowsExternalOpenChannel.setMethodCallHandler((call) async {
        if (call.method == 'externalOpenAvailable') {
          await externalOpens.refresh();
        }
      });
      await externalOpens.refresh();
    }
    if (platformFeatures && Platform.isAndroid) {
      await importLegacy();
      nativeChannel.setMethodCallHandler((call) async {
        if (call.method == 'openTransfers') {
          final target = await nativeChannel.invokeMethod<String>(
            'takeTransferNavigation',
          );
          if (target == 'lan') {
            requestLanPage();
          } else if (target == 'uploads') {
            requestUploadManager();
          } else if (target != null) {
            requestDownloadManager();
          }
        }
        if (call.method == 'downloadOverlayState') {
          downloadOverlay.stateChanged(asJson(call.arguments));
        }
        if (call.method == 'downloadOverlayAction') {
          await downloadOverlay.action(asJson(call.arguments));
        }
        if (call.method == 'exportProgress' && files is PlatformFileAccess) {
          (files as PlatformFileAccess).exportProgress(asJson(call.arguments));
        }
        if (call.method == 'sharedText') {
          sharedText.value = call.arguments as String?;
        }
        if (call.method == 'externalOpenAvailable') {
          await externalOpens.refresh();
        }
        if (call.method == 'pauseAll' ||
            call.method == 'serviceTimeout' ||
            call.method == 'downloadServiceStalled') {
          await lan.stop();
          await uploads.stopAll(reason: '后台传输已停止，返回应用后可重新上传');
          await downloads.pauseAll(
            reason: switch (call.method) {
              'serviceTimeout' => '系统已暂停长时间后台下载，返回应用后可继续',
              'downloadServiceStalled' => '后台下载状态已中断，请返回应用继续',
              _ => '',
            },
          );
        }
        if (call.method == 'downloadServiceRestarted') {
          await downloads.recoverInterrupted();
        }
        if (call.method == 'downloadDiscardRecovery') {
          await downloads.discardInterrupted();
        }
      });
      await externalOpens.refresh();
    }
    await vault.initializeAccounts();
    await uploads.initialize();
    await downloads.initialize();
    if (platformFeatures && Platform.isAndroid) {
      final recoveryExpected = await nativeChannel.invokeMethod<bool>(
        'downloadsReady',
      );
      if (recoveryExpected != true) await downloads.discardInterrupted();
      final target = await nativeChannel.invokeMethod<String>(
        'takeTransferNavigation',
      );
      if (target == 'lan') {
        requestLanPage();
      } else if (target == 'uploads') {
        requestUploadManager();
      } else if (target != null) {
        requestDownloadManager();
      }
    }
    store.addListener(_changed);
    _changed();
  }

  Future<void> importLegacy() async {
    if (store.data.boolean('legacyImported')) return;
    try {
      final raw = await nativeChannel.invokeMethod<String>('legacySnapshot');
      require(raw != null, '无法读取旧版数据');
      await LegacyImporter(store).import(asJson(jsonDecode(raw!)));
      migrationError = null;
    } catch (error, stack) {
      DiagnosticLog.error('app.legacy_import_failed', error, stack);
      migrationError = '旧版数据未能导入，原数据已保留。可在“我的”中重试导入。';
    }
  }

  Future<void> retryLegacyImport() async {
    await downloads.importPausedQueue(importLegacy);
    notifyListeners();
  }

  void _changed() {
    for (final platform in CloudPlatform.values) {
      final credential = vault.credential(platform),
          revision = (vault.activeAccountId(platform), credential?.updatedAt);
      if (_revisions.containsKey(platform) &&
          _revisions[platform] == revision) {
        if ({
              CloudPlatform.pan123,
              CloudPlatform.tianyi,
              CloudPlatform.xunlei,
            }.contains(platform) &&
            credential?.field('autoLoginBlocked') == '1') {
          accounts.remove(platform);
          accountNeedsLogin.add(platform);
          accountErrors[platform] = switch (platform) {
            CloudPlatform.pan123 => Pan123Connector.autoLoginFailureMessage,
            CloudPlatform.xunlei => XunleiConnector.autoLoginFailureMessage,
            _ => TianyiConnector.autoLoginFailureMessage,
          };
        }
        continue;
      }
      _revisions[platform] = revision;
      accounts.remove(platform);
      accountErrors.remove(platform);
      accountNeedsLogin.remove(platform);
      if (LoginCredentials.stored(platform, credential)) {
        unawaited(refreshAccount(platform));
      }
    }
    notifyListeners();
  }

  Future<void> refreshAccount(CloudPlatform platform) async {
    final owner = vault.activeAccountId(platform);
    final credential = vault.credential(platform);
    if (!control.cloudEnabled(platform) ||
        !LoginCredentials.stored(platform, credential) ||
        !accountLoading.add(platform)) {
      return;
    }
    notifyListeners();
    try {
      final account = await vault.withAccount(
        platform,
        owner,
        () => cloud.connector(platform).account(credential!),
      );
      if (vault.activeAccountId(platform) == owner &&
          vault.credential(platform)?.updatedAt == credential!.updatedAt) {
        if (owner != null) {
          await vault.updateAccountNickname(
            platform,
            owner,
            credential.updatedAt,
            account.nickname,
          );
        }
        if (vault.activeAccountId(platform) != owner ||
            vault.credential(platform)?.updatedAt != credential.updatedAt) {
          return;
        }
        accounts[platform] = account;
        accountErrors.remove(platform);
        accountNeedsLogin.remove(platform);
      }
    } catch (e, stack) {
      DiagnosticLog.error(
        'cloud.account_failed',
        e,
        stack,
        fields: {'platform': platform.key},
      );
      if (vault.activeAccountId(platform) == owner &&
          vault.credential(platform)?.updatedAt == credential?.updatedAt) {
        if (e is AccountLoginRequired) {
          accounts.remove(platform);
          accountNeedsLogin.add(platform);
          accountErrors[platform] = e.message;
        } else {
          accountNeedsLogin.remove(platform);
          accountErrors[platform] = '容量读取失败，点击重试';
        }
      }
    } finally {
      accountLoading.remove(platform);
      if (!_closed) {
        notifyListeners();
        if (vault.activeAccountId(platform) != owner ||
            vault.credential(platform)?.updatedAt != credential?.updatedAt) {
          unawaited(refreshAccount(platform));
        }
      }
    }
  }

  Future<void> refreshAccounts() async =>
      Future.wait(CloudPlatform.values.map(refreshAccount));

  Future<void> switchCloudAccount(CloudPlatform platform, String id) async {
    login.invalidate(platform);
    if (platform == CloudPlatform.uc) {
      (cloud.connector(platform) as UcConnector).tv.cancelAuthorization();
    }
    await vault.activate(platform, id);
  }

  Future<void> removeCloudAccount(CloudPlatform platform, String id) async {
    login.invalidate(platform);
    if (platform == CloudPlatform.uc) {
      (cloud.connector(platform) as UcConnector).tv.cancelAuthorization();
    }
    await vault.removeAccount(platform, id);
  }

  void _controlChanged() {
    if (_closed) return;
    parserRules.updateEndpoint(control.config.parserHubUrl);
    for (final platform in CloudPlatform.values) {
      if (control.cloudEnabled(platform)) {
        if (_enabledClouds.add(platform)) unawaited(refreshAccount(platform));
      } else if (_enabledClouds.remove(platform)) {
        login.invalidate(platform);
        if (platform == CloudPlatform.uc) {
          final connector = cloud.connector(platform);
          if (connector is UcConnector) connector.tv.cancelAuthorization();
        }
      }
    }
    notifyListeners();
  }

  Future<void> updateSettings(Json changes) async {
    await store.change((draft) {
      draft['settings'] = AppSettings.fromJson(
        draft.obj('settings'),
      ).update(changes).toJson();
    });
    await downloads.settingsChanged();
  }

  Future<void> updateAppearance({
    required String mode,
    required AppPalette palette,
    required GlassStyle glassStyle,
    BackgroundSettings? background,
    bool? hideResourceNavigation,
  }) async {
    await store.change((draft) {
      require(['System', 'Light', 'Dark'].contains(mode), '外观模式无效');
      draft['settings'] = AppSettings.fromJson(draft.obj('settings')).update({
        'theme': mode,
        'themePalette': palette.name,
        'glassStyle': glassStyle.name,
        if (background != null) 'background': background.toJson(),
        'hideResourceNavigation': ?hideResourceNavigation,
      }).toJson();
    });
    if (background != null) await backgrounds.collectUnused();
  }

  Future<int> updateDownloadDestination(
    String? destination, {
    bool includeUnfinished = false,
  }) => downloads.changeDestination(
    destination,
    includeUnfinished: includeUnfinished,
  );

  Future<void> updateBrowserDisplay(
    CloudPlatform platform, {
    String? view,
    String? sort,
    bool? searchSubfolders,
  }) => store.change((draft) {
    require(view == null || ['list', 'grid'].contains(view), '显示方式无效');
    require(sort == null || ['name', 'size', 'date'].contains(sort), '排序方式无效');
    final current = AppSettings.fromJson(draft.obj('settings'));
    final previous = current.browserDisplayFor(platform);
    final updated = BrowserDisplaySettings(
      view: view ?? previous.view,
      sort: sort ?? previous.sort,
      searchSubfolders: searchSubfolders ?? previous.searchSubfolders,
      ascending: sort == null
          ? previous.ascending
          : sort == previous.sort
          ? !previous.ascending
          : true,
    );
    draft['settings'] = current.update({
      'browserDisplays': {
        for (final entry in current.browserDisplays.entries)
          entry.key: entry.value.toJson(),
        platform.key: updated.toJson(),
      },
    }).toJson();
  });

  Future<void> copyText(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    await clipboard.acknowledgeText(value);
  }

  Future<void> remember(
    ParsedLink link, {
    String? title,
    int? itemCount,
    String? commandText,
    bool Function()? canCommit,
  }) => store.change((draft) {
    if (canCommit?.call() == false) return;
    final createdAt = clock().millisecondsSinceEpoch;
    final existing = draft.list('history');
    draft['history'] = [
      {
        'id': link.id,
        'platform': link.platform?.key,
        'sourceText': link.source,
        'normalizedUrl': link.url,
        'fileName': title,
        'link': link.toJson(),
        'createdAt': createdAt,
        'status': 'parsed',
        'itemCount': itemCount,
      },
      ...existing.where((e) => e.str('normalizedUrl') != link.url).take(299),
    ];
    if (commandText != null) {
      CloudCommandHistory.record(
        draft,
        link,
        commandText,
        title: title,
        itemCount: itemCount,
        createdAt: createdAt,
      );
    }
  });
  Future<WebViewEnvironment?> webEnvironment() async {
    if (!Platform.isWindows) return null;
    return _webHost.get();
  }

  void invalidateWebEnvironment(WebViewEnvironment? environment) {
    if (Platform.isWindows) _webHost.invalidate(environment);
  }

  Json diagnostics() => {
    'application': '文析助手',
    'version': applicationVersion,
    'engine': 'Gopeed 1.8.1',
    'os': Platform.operatingSystem,
    'date': DateTime.now().toUtc().toIso8601String(),
    'legacyImported': store.data.boolean('legacyImported'),
    'settings': settings.toJson()..remove('destination'),
    'remoteControl': control.diagnostics(),
    'parserRules': parserRules.diagnostics(),
    'sources': sources.diagnostics(),
    'accounts': {
      for (final platform in CloudPlatform.values)
        platform.key: LoginCredentials.stored(
          platform,
          vault.credential(platform),
        ),
    },
    'taskCount': downloads.tasks.length,
    'tasksTruncated': downloads.tasks.length > 100,
    'tasks': [
      for (final task in downloads.tasks.take(100))
        {
          'status': task.status.name,
          'total': task.total,
          'downloaded': task.downloaded,
          'connections': task.connections,
          'hasSource': task.spec.source != null,
          'hasExport': task.savedPath != null,
          'hasError': task.error.isNotEmpty,
        },
    ],
    'pendingCleanups': cleanups.pendingCount,
    'pendingDownloadRemovals':
        (store.data['downloadRemovals'] as List? ?? []).length,
  };
  Future<void> close() async {
    if (_closed) return;
    resourceSearch.dispose();
    mobileDataDownloads.close();
    await cloud.publicPasswords.close();
    await sources.close();
    await parserRules.close();
    downloadShutdown.close();
    await downloadOverlay.close();
    control.removeListener(_controlChanged);
    appUpdates.close();
    control.close();
    await control.flushCache();
    await announcements.close();
    navigationTransfers.dispose();
    await lan.close();
    await uploads.close();
    await downloads.close();
    cleanups.progress.close();
    _closed = true;
    clipboard.dispose();
    externalOpens.dispose();
    if (platformFeatures && Platform.isWindows) {
      windowsExternalOpenChannel.setMethodCallHandler(null);
    }
    downloadNavigation.dispose();
    resourceNavigation.dispose();
    lanNavigation.dispose();
    transferTab.dispose();
    guestDownloadNotice.dispose();
    mobileDataDownloads.dispose();
    store.removeListener(_changed);
    await _webHost.close();
    await _instanceLock?.close();
  }
}
