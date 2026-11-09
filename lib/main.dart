import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'app_services.dart';
import 'core/json.dart' show AsyncGate;
import 'diagnostics/app_log.dart';
import 'diagnostics/diagnostic_runtime.dart';
import 'ui/startup_failure_page.dart';
export 'ui/startup_failure_page.dart';
import 'domain/downloads.dart';
import 'ui/app_navigation.dart';
import 'ui/remote_control_dialogs.dart';
import 'ui/app_popup_menu.dart';
import 'ui/cloud_page.dart';
import 'ui/cloud_accounts_page.dart';
import 'ui/clipboard_link_banner.dart';
import 'ui/common.dart';
import 'ui/app_theme.dart';
import 'ui/app_text_scale.dart';
import 'ui/app_background.dart';
export 'ui/app_theme.dart' show appTheme;
import 'ui/startup_loading_page.dart';
import 'ui/transfers_page.dart';
import 'ui/mine_page.dart';
import 'ui/parse_page.dart';
import 'ui/browser_page.dart';
import 'ui/resource_home_page.dart';
import 'ui/search_security_dialog.dart';
import 'ui/announcements_page.dart';
import 'ui/device_link_page.dart';
import 'ui/donate_page.dart';
import 'ui/about_dialog.dart';
import 'ui/download_shutdown_prompt.dart';
import 'ui/guest_download_prompt.dart';
import 'ui/mobile_data_download_prompt.dart';
import 'ui/player_page.dart';
import 'ui/floating_playback_host.dart';
import 'playback/floating_playback.dart';
import 'ui/independent_player_app.dart';
import 'playback/independent_player_window.dart';
import 'platform/external_open.dart';
import 'playback/external_playback.dart';
import 'platform/windows_pip.dart';
import 'platform/windows_window_theme.dart';
import 'platform/desktop_platform.dart';

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  if (arguments.length == 2 && arguments.first == independentPlayerArgument) {
    runApp(IndependentPlayerApp(endpoint: arguments[1]));
    return;
  }
  LicenseRegistry.addLicense(() async* {
    for (final entry in {
      'Gopeed': 'Gopeed-LICENSE.txt',
      'Kelpie / goed2k ED2K': 'Kelpie-LICENSE.txt',
      'Kelpie / goed2k notices': 'Kelpie-NOTICE.txt',
      'ED2K UPnP (BSD)': 'Kelpie-UPnP-BSD.txt',
      'QuickJS-NG': 'QuickJS-NG-LICENSE.txt',
      'Android NDK / LLVM': 'android-ndk-NOTICE.txt',
      'media_kit native build': 'media-native-build-LICENSE.txt',
      'Noto Sans SC': 'NotoSansCJK-OFL.txt',
      'LanzouAPI': 'LanzouAPI-LICENSE.txt',
      '115driver m115 protocol': '115driver.txt',
      'AndroidLiquidGlass / Backdrop': 'AndroidLiquidGlass-LICENSE.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString('assets/licenses/${entry.value}'));
    }
  });
  runApp(const AppBootstrap());
}

Future<void> _initializeRuntime() async {
  await DiagnosticRuntime.start();
  MediaKit.ensureInitialized();
  if (isDesktopPlatform) {
    await windowManager.ensureInitialized();
    unawaited(
      windowManager.waitUntilReadyToShow(
        const WindowOptions(
          title: '文析助手',
          size: Size(1100, 780),
          minimumSize: appWindowMinimumSize,
          center: true,
        ),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.initializeRuntime, this.servicesLoader});
  final Future<void> Function()? initializeRuntime;
  final Future<AppServices> Function()? servicesLoader;
  @override
  State<AppBootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<AppBootstrap> {
  bool _runtimeInitialized = false;
  late Future<AppServices> services = _startServices();
  Future<AppServices> _startServices() {
    final pending = loadServices();
    // Attach an error handler immediately, before FutureBuilder's next frame.
    pending.ignore();
    return pending;
  }

  Future<AppServices> loadServices() async {
    final startup = Stopwatch()..start();
    try {
      // Prefer a loading frame, but a retained Android engine can initialize
      // without a surface. Screen-off recovery/retries must not await vsync.
      final binding = WidgetsBinding.instance;
      var submittedFrame = false;
      if (binding.framesEnabled) {
        submittedFrame = await binding.endOfFrame
            .then((_) => true)
            .timeout(const Duration(milliseconds: 500), onTimeout: () => false);
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      final firstFrameMs = startup.elapsedMilliseconds;
      if (!_runtimeInitialized) {
        await (widget.initializeRuntime ?? _initializeRuntime)();
        _runtimeInitialized = true;
      }
      DiagnosticLog.event(
        submittedFrame ? 'app.startup_frame' : 'app.startup_without_frame',
        fields: {'elapsedMs': firstFrameMs},
      );
      DiagnosticLog.event(
        'app.runtime_ready',
        fields: {'elapsedMs': startup.elapsedMilliseconds},
      );
      return await (widget.servicesLoader ?? AppServices.open)();
    } catch (error, stack) {
      DiagnosticLog.error(
        _runtimeInitialized ? 'app.services_failed' : 'app.bootstrap_failed',
        error,
        stack,
        fatal: true,
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppServices>(
    future: services,
    builder: (context, state) {
      if (state.hasData) return AsterLinkApp(state.data!);
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        builder: (context, child) => WindowsWindowTheme(child: child!),
        home: state.hasError
            ? StartupFailurePage(
                state.error!,
                onRetry: () => setState(() {
                  services = _startServices();
                }),
              )
            : const StartupLoadingPage(),
      );
    },
  );
}

class AsterLinkApp extends StatelessWidget {
  const AsterLinkApp(
    this.services, {
    super.key,
    this.initialTab = 0,
    this.fontFamily,
  });
  final AppServices services;
  final int initialTab;
  final String? fontFamily;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: services.store,
    builder: (context, _) {
      final settings = services.settings;
      return MaterialApp(
        navigatorKey: FloatingPlaybackManager.of(services.store).navigatorKey,
        title: '文析助手',
        debugShowCheckedModeBanner: false,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: appTheme(
          Brightness.light,
          fontFamily: fontFamily,
          palette: settings.themePalette,
          glassStyle: settings.glassStyle,
          glassControls: settings.glassControls,
          glassLowPower: settings.glassLowPower,
        ),
        darkTheme: appTheme(
          Brightness.dark,
          fontFamily: fontFamily,
          palette: settings.themePalette,
          glassStyle: settings.glassStyle,
          glassControls: settings.glassControls,
          glassLowPower: settings.glassLowPower,
        ),
        themeAnimationDuration:
            (MediaQuery.maybeDisableAnimationsOf(context) ??
                WidgetsBinding
                    .instance
                    .platformDispatcher
                    .accessibilityFeatures
                    .disableAnimations)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        themeAnimationCurve: Curves.easeOutCubic,
        themeMode: switch (settings.theme) {
          'Light' => ThemeMode.light,
          'Dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        builder: (context, child) => AppTextScale(
          percent: settings.fontScalePercent,
          child: WindowsWindowTheme(
            enabled: services.platformFeatures,
            child: FloatingPlaybackHost(store: services.store, child: child!),
          ),
        ),
        home: SearchSecurityHost(
          services,
          child: MainShell(services, initialTab: initialTab),
        ),
      );
    },
  );
}

class MainShell extends StatefulWidget {
  const MainShell(
    this.services, {
    super.key,
    this.initialTab = 0,
    this.externalPlayerBuilder,
  });
  final AppServices services;
  final int initialTab;
  final Widget Function(ExternalOpenRequest)? externalPlayerBuilder;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell>
    with WindowListener, TrayListener, WidgetsBindingObserver {
  late int selected = widget.initialTab;
  final _visitedTabs = <int>{};
  final parseKey = GlobalKey<ParsePageState>();
  final _windowVisibility = AsyncGate();
  bool trayReady = false, closing = false;
  bool _exiting = false;
  bool _openingExternal = false, _externalScheduled = false;
  bool _openingLan = false;
  bool _usingClipboard = false;
  late bool _hideResourceNavigation =
      widget.services.settings.hideResourceNavigation;
  double _pageSwipeDistance = 0;
  static const titles = ['分享解析', '资源', '网盘列表', '传输管理', '我的'];

  Widget _retainedTab(int index, Widget Function() builder) {
    if (index == selected) _visitedTabs.add(index);
    return TickerMode(
      enabled: index == selected,
      child: _visitedTabs.contains(index) ? builder() : const SizedBox.shrink(),
    );
  }

  List<int> get _navigationTabs =>
      AppNavigation.visibleIndices(hideResources: _hideResourceNavigation);

  bool get _hiddenResourcePage => _hideResourceNavigation && selected == 1;

  void _navigationSettingsChanged() {
    final hidden = widget.services.settings.hideResourceNavigation;
    if (mounted && hidden != _hideResourceNavigation) {
      setState(() => _hideResourceNavigation = hidden);
    }
  }

  void _selectTab(int index) {
    if (index == selected) return;
    FocusManager.instance.primaryFocus?.unfocus();
    DiagnosticLog.event(
      'ui.tab',
      fields: {
        'tab': ['parse', 'resources', 'cloud', 'downloads', 'mine'][index],
      },
    );
    setState(() => selected = index);
  }

  void _swipePage(DragEndDetails details) {
    final distance = _pageSwipeDistance;
    _pageSwipeDistance = 0;
    final threshold = (MediaQuery.sizeOf(context).width * .18).clamp(48, 96);
    final velocity = details.primaryVelocity ?? 0;
    if (distance.abs() < threshold &&
        (distance.abs() < 24 || velocity.abs() < 450)) {
      return;
    }
    final direction =
        (distance < 0 ? 1 : -1) *
        (Directionality.of(context) == TextDirection.rtl ? -1 : 1);
    final tabs = _navigationTabs;
    final position = tabs.indexOf(selected);
    _selectTab(
      tabs[((position < 0 ? 0 : position) + direction).clamp(
        0,
        tabs.length - 1,
      )],
    );
  }

  @override
  void initState() {
    super.initState();
    widget.services.sharedText.addListener(_shared);
    widget.services.store.addListener(_navigationSettingsChanged);
    if (widget.services.downloadNavigation.value > 0) selected = 3;
    widget.services.downloadNavigation.addListener(_showDownloads);
    widget.services.browserReturnNavigation.addListener(_returnToBrowser);
    widget.services.resourceNavigation.addListener(_showResources);
    widget.services.lanNavigation.addListener(_showLan);
    widget.services.transferTab.addListener(_transferTabChanged);
    widget.services.externalOpens.addListener(_externalAvailable);
    widget.services.clipboard.addListener(_clipboardChanged);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      DiagnosticLog.event('app.main_frame');
      final state = WidgetsBinding.instance.lifecycleState;
      widget.services.clipboard.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      widget.services.control.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      widget.services.announcements.setForeground(
        state == null || state == AppLifecycleState.resumed,
      );
      if (state == null || state == AppLifecycleState.resumed) {
        widget.services.refreshEntryData();
      }
      _externalAvailable();
      if (widget.services.lanNavigation.value > 0) _showLan();
    });
    if (isDesktopPlatform && widget.services.platformFeatures) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _desktop();
    }
  }

  void _clipboardChanged() {
    if (mounted) setState(() {});
  }

  void _transferTabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.services.clipboard.setForeground(state == AppLifecycleState.resumed);
    widget.services.control.setForeground(state == AppLifecycleState.resumed);
    widget.services.announcements.setForeground(
      state == AppLifecycleState.resumed,
    );
    if (state == AppLifecycleState.resumed) {
      widget.services.refreshEntryData();
      _externalAvailable();
    }
  }

  @override
  void didChangePlatformBrightness() {
    widget.services.downloadOverlay.refreshAppearance();
  }

  void _externalAvailable() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!mounted ||
        _openingExternal ||
        _externalScheduled ||
        !widget.services.externalOpens.hasPending ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    _externalScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _externalScheduled = false;
      if (mounted) unawaited(_openExternal());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _externalHome() async {
    final closing = <Future<Object?>>[];
    Navigator.of(context).popUntil((route) {
      if (route.isFirst) return true;
      if (route is TransitionRoute) closing.add(route.completed);
      return false;
    });
    // Dispose the previous player before starting another playback session.
    await Future.wait(closing);
  }

  Future<void> _openExternal() async {
    if (_openingExternal) return;
    _openingExternal = true;
    try {
      while (mounted) {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (lifecycle != null && lifecycle != AppLifecycleState.resumed) break;
        final request = widget.services.externalOpens.take();
        if (request == null) break;
        await _externalHome();
        if (!mounted) break;
        if (request.kind == ExternalOpenKind.error) {
          message(context, request.message);
        } else if (request.kind == ExternalOpenKind.play) {
          final controller = widget.externalPlayerBuilder == null
              ? externalPlayback(widget.services, request)
              : null;
          final page =
              widget.externalPlayerBuilder?.call(request) ??
              PlayerPage(
                controller!,
                subtitleDirectory: Directory(
                  '${widget.services.cacheDirectory.path}/playback-subtitles',
                ),
              );
          unawaited(
            Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => page),
            ).whenComplete(() {
              if (controller != null) {
                widget.services.finishPlaybackInBackground(controller.close());
              }
            }),
          );
          await WidgetsBinding.instance.endOfFrame;
        } else {
          final url = request.downloadUrl;
          if (url != null) {
            widget.services.transferTab.value = 0;
            setState(() => selected = 3);
            await directDownloadDialog(
              context,
              widget.services,
              initial: url,
              fileName: request.name,
              headers: request.headers,
              external: true,
            );
          } else {
            setState(() => selected = 0);
            widget.services.sharedText.value = null;
            widget.services.sharedText.value = request.sharedText;
          }
        }
      }
    } catch (error, stack) {
      DiagnosticLog.error('app.external_open_failed', error, stack);
      if (mounted) message(context, errorText(error));
    } finally {
      _openingExternal = false;
      if (mounted) _externalAvailable();
    }
  }

  @override
  void onWindowFocus() {
    widget.services.clipboard.setForeground(true);
    widget.services.control.setForeground(true);
    widget.services.announcements.setForeground(true);
    widget.services.refreshEntryData();
  }

  @override
  void onWindowBlur() {
    widget.services.clipboard.setForeground(false);
    widget.services.control.setForeground(false);
    widget.services.announcements.setForeground(false);
  }

  Future<void> _useClipboard() async {
    final suggestion = widget.services.clipboard.suggestion;
    if (!mounted || suggestion == null || _usingClipboard) return;
    _usingClipboard = true;
    try {
      setState(() => selected = 0);
      unawaited(widget.services.clipboard.acknowledge(suggestion));
      // Let the parser become active when opening from another tab.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || selected != 0) return;
      final parser = parseKey.currentState;
      parser?.acceptClipboard(suggestion.text);
      await parser?.parse();
    } finally {
      _usingClipboard = false;
    }
  }

  void _shared() {
    if (mounted && widget.services.sharedText.value?.isNotEmpty == true) {
      setState(() => selected = 0);
    }
  }

  void _showDownloads() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => selected = 3);
    DiagnosticLog.event('ui.tab', fields: {'tab': 'downloads'});
  }

  bool _returningToBrowser = false;
  Future<void> _returnToBrowser() async {
    final target = widget.services.browserReturn.value;
    if (!mounted || target == null || _returningToBrowser) return;
    _returningToBrowser = true;
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => selected = 0);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => BrowserPage(
            widget.services,
            target.session,
            initialItems: target.items,
            initialCursor: target.cursor,
            initialTrail: target.trail,
            initialScrollOffset: target.scrollOffset,
            initialSearchText: target.searchText,
            poolPreview: target.poolPreview,
          ),
        ),
      );
    } finally {
      _returningToBrowser = false;
    }
  }

  void _showResources() {
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() => selected = 1);
    DiagnosticLog.event('ui.tab', fields: {'tab': 'resources'});
  }

  void _showLan() => unawaited(_openLan());

  Future<void> _openLan() async {
    if (!mounted || _openingLan) return;
    _openingLan = true;
    try {
      final text = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceLinkPage(
            widget.services,
            initialText: parseKey.currentState?.input.text ?? '',
          ),
        ),
      );
      if (!mounted || text == null || text.isEmpty) return;
      setState(() => selected = 0);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final parser = parseKey.currentState;
      parser?.acceptClipboard(text);
      await parser?.parse();
    } finally {
      _openingLan = false;
    }
  }

  Future<void> _desktop() async {
    try {
      await _windowVisibility.run(() async {
        if (!mounted || _exiting) return;
        await windowManager.setPreventClose(true);
        await trayManager.setIcon(
          Platform.isMacOS ? 'assets/icons/app.png' : 'assets/icons/app.ico',
        );
        await trayManager.setToolTip('文析助手 · 单击打开，右键菜单');
        await trayManager.setContextMenu(
          Menu(
            items: [
              MenuItem(key: 'show', label: '打开文析助手'),
              MenuItem.separator(),
              MenuItem(key: 'pause', label: '停止全部传输'),
              MenuItem(key: 'exit', label: '退出'),
            ],
          ),
        );
        trayReady = true;
      });
      // Also handles a minimize that happened while the tray was starting.
      onWindowMinimize();
    } catch (error, stack) {
      DiagnosticLog.error('app.tray_init_failed', error, stack);
    }
  }

  Future<void> _hideToTray({bool minimizedOnly = false}) =>
      _windowVisibility.run(() async {
        if (!mounted || !trayReady || _exiting) return;
        if (minimizedOnly) {
          if (closing || !await windowManager.isMinimized()) return;
          if (!mounted || closing || _exiting) return;
        }
        await windowManager.hide();
      });

  Future<void> _showWindow() => _windowVisibility.run(() async {
    if (!mounted || _exiting) return;
    // show() restores only minimized windows, preserving maximized/PiP bounds.
    await windowManager.show();
    if (!mounted || _exiting) return;
    await windowManager.focus();
  });

  @override
  void onWindowMinimize() {
    unawaited(
      _hideToTray(minimizedOnly: true).catchError((
        Object error,
        StackTrace stack,
      ) {
        DiagnosticLog.error('app.tray_hide_failed', error, stack);
      }),
    );
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(
      _showWindow().catchError((Object error, StackTrace stack) {
        DiagnosticLog.error('app.tray_restore_failed', error, stack);
      }),
    );
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    if (!mounted || _exiting) return;
    if (item.key == 'show') onTrayIconMouseDown();
    if (item.key == 'pause') {
      busy(context, widget.services.stopTransfers, label: '停止传输…');
    }
    if (item.key == 'exit') _close(forceExit: true);
  }

  @override
  void onWindowClose() {
    _close();
  }

  Future<void> _close({bool forceExit = false}) async {
    if (closing || _exiting || !mounted) return;
    closing = true;
    try {
      final active =
          widget.services.downloads.tasks.any((t) => t.active) ||
          widget.services.uploads.activeCount > 0 ||
          widget.services.lan.running;
      if (active) {
        await _showWindow();
        if (!mounted) return;
        final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('还有传输任务'),
            content: Text(
              widget.services.lan.running
                  ? '设备互联正在运行。可保留后台传输；退出应用会结束文件分享。'
                  : '可保留后台传输，或停止任务后退出。中断的上传需要重新上传。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              if (trayReady && !forceExit)
                TextButton(
                  onPressed: () => Navigator.pop(context, 'background'),
                  child: const Text('后台传输'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'exit'),
                child: const Text('暂停并退出'),
              ),
            ],
          ),
        );
        if (action == null) return;
        if (action == 'background') {
          await _hideToTray();
          return;
        }
      }
      _exiting = true;
      await _windowVisibility.run(() async {
        await widget.services.close();
        if (trayReady) {
          await trayManager.destroy();
          trayReady = false;
        }
        DiagnosticRuntime.stop();
        await windowManager.destroy();
      });
    } catch (e, stack) {
      _exiting = false;
      DiagnosticLog.error('app.close_failed', e, stack);
      if (mounted) message(context, errorText(e));
    } finally {
      closing = false;
    }
  }

  @override
  void dispose() {
    widget.services.sharedText.removeListener(_shared);
    widget.services.store.removeListener(_navigationSettingsChanged);
    widget.services.downloadNavigation.removeListener(_showDownloads);
    widget.services.browserReturnNavigation.removeListener(_returnToBrowser);
    widget.services.resourceNavigation.removeListener(_showResources);
    widget.services.lanNavigation.removeListener(_showLan);
    widget.services.transferTab.removeListener(_transferTabChanged);
    widget.services.externalOpens.removeListener(_externalAvailable);
    WidgetsBinding.instance.removeObserver(this);
    widget.services.clipboard.removeListener(_clipboardChanged);
    widget.services.clipboard.setForeground(false);
    widget.services.control.setForeground(false);
    widget.services.announcements.setForeground(false);
    if (isDesktopPlatform && widget.services.platformFeatures) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _clearDownloads({bool failedOnly = false}) async {
    final tasks = widget.services.downloads.tasks
        .where((task) => !failedOnly || task.status == DownloadStatus.failed)
        .toList(growable: false);
    if (tasks.isEmpty) {
      message(context, failedOnly ? '暂无可清理的失败任务' : '暂无可清理的下载记录');
      return;
    }
    // Fix the selection before confirmation so a newly added download is kept.
    final ids = tasks.map((task) => task.id).toList(growable: false);
    final unfinished = tasks.any(
      (task) => task.status != DownloadStatus.completed,
    );
    var deleteFiles = false;
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(failedOnly ? '清理失败任务' : '清理下载记录'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failedOnly
                      ? '将清理当前 ${ids.length} 个失败任务。下载目录中的文件默认保留。'
                      : '将清理当前全部 ${ids.length} 条下载记录。下载目录中的文件默认保留。',
                ),
                if (unfinished) ...[
                  const SizedBox(height: 12),
                  Text(
                    failedOnly
                        ? '失败任务的临时缓存将自动清理，清理后无法续传。'
                        : '未完成任务会先停止，临时缓存将自动清理，清理后无法续传。',
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  key: const Key('downloads-clear-files'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('同时删除文件'),
                  subtitle: const Text('删除对应的已下载文件和残留文件'),
                  value: deleteFiles,
                  onChanged: (value) =>
                      update(() => deleteFiles = value ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('downloads-confirm-clear'),
              onPressed: () => Navigator.pop(context, deleteFiles),
              child: const Text('清理'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final selected = ids
        .where(
          (id) =>
              !failedOnly ||
              widget.services.downloads.task(id)?.status ==
                  DownloadStatus.failed,
        )
        .toList(growable: false);
    if (selected.isEmpty) {
      message(context, '暂无可清理的失败任务');
      return;
    }
    final result = await busy(
      context,
      () => widget.services.downloads.batch(
        selected,
        DownloadBatchAction.delete,
        deleteFiles: choice,
      ),
      label: failedOnly ? '正在清理失败任务…' : '正在清理下载记录…',
    );
    if (mounted && result != null && result.failed.isNotEmpty) {
      message(
        context,
        '已清理 ${result.succeeded.length} 条记录，${result.failed.length} 条暂未清理，请稍后重试',
      );
    }
  }

  Future<void> _menu(String action) async {
    switch (action) {
      case 'new':
        await directDownloadDialog(context, widget.services);
      case 'accounts':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => CloudAccountsPage(widget.services)),
        );
      case 'cloud-layout':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => CloudListSettingsPage(widget.services),
          ),
        );
      case 'refresh':
        await widget.services.refreshAccounts();
      case 'pause':
        await busy(
          context,
          widget.services.downloads.pauseAll,
          label: '暂停全部任务…',
        );
      case 'resume':
        await busy(context, widget.services.downloads.resumeAll);
      case 'clear':
        await _clearDownloads();
      case 'clear-failed':
        await _clearDownloads(failedOnly: true);
      case 'about':
        await showWenxiAbout(context, widget.services.control);
      case 'donate':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => const DonatePage()),
        );
      case 'stop-uploads':
        if (await confirm(context, '停止全部上传', '未完成任务将停止，重试时会从头上传。') && mounted) {
          await busy(context, widget.services.uploads.stopAll);
        }
      case 'clear-uploads':
        await busy(context, widget.services.uploads.clearCompleted);
    }
  }

  List<AppMenuAction<String>> get menu => switch (selected) {
    2 => const [
      AppMenuAction(
        value: 'cloud-layout',
        label: '排序与隐藏',
        icon: CupertinoIcons.slider_horizontal_3,
      ),
      AppMenuAction(
        value: 'accounts',
        label: '账号管理',
        icon: CupertinoIcons.person_2,
      ),
      AppMenuAction(
        value: 'refresh',
        label: '刷新全部账号',
        icon: CupertinoIcons.arrow_clockwise,
      ),
    ],
    3 when widget.services.transferTab.value == 1 => const [
      AppMenuAction(
        value: 'stop-uploads',
        label: '停止全部上传',
        icon: CupertinoIcons.stop,
      ),
      AppMenuAction(
        value: 'clear-uploads',
        label: '清理完成记录',
        icon: CupertinoIcons.trash,
      ),
    ],
    3 => const [
      AppMenuAction(
        value: 'new',
        label: '新建下载',
        icon: CupertinoIcons.plus_circle,
      ),
      AppMenuAction(value: 'pause', label: '全部暂停', icon: CupertinoIcons.pause),
      AppMenuAction(
        value: 'resume',
        label: '继续未完成任务',
        icon: CupertinoIcons.play,
      ),
      AppMenuAction(
        value: 'clear',
        label: '清理下载记录',
        icon: CupertinoIcons.trash,
      ),
      AppMenuAction(
        value: 'clear-failed',
        label: '清理失败任务',
        icon: CupertinoIcons.exclamationmark_circle,
      ),
    ],
    _ => const [
      AppMenuAction(value: 'donate', label: '打赏作者', icon: CupertinoIcons.gift),
      AppMenuAction(
        value: 'about',
        label: '关于文析助手',
        icon: CupertinoIcons.info_circle,
      ),
    ],
  };
  Widget _navigation(BuildContext context, {required bool rail}) =>
      AppNavigation(
        selectedIndex: selected,
        hideResources: _hideResourceNavigation,
        transfers: widget.services.navigationTransfers,
        rail: rail,
        onSelected: _selectTab,
      );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (var i = 0; i < _navigationTabs.length; i++)
        SingleActivator(
          [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
            LogicalKeyboardKey.digit5,
          ][i],
          control: true,
        ): () =>
            _selectTab(_navigationTabs[i]),
      const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
        setState(() => selected = 0);
        parseKey.currentState?.focusInput();
      },
    },
    child: Focus(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return AppBackground(
            repository: widget.services.backgrounds,
            settings: widget.services.settings.background,
            child: Builder(
              builder: (context) {
                final rail = constraints.maxWidth >= 820;
                final desktopHeader =
                    (selected == 0 || selected == 4) &&
                    Theme.of(context).platform == TargetPlatform.windows;
                final content = Scaffold(
                  extendBody: !rail,
                  backgroundColor: BackgroundScope.of(context)?.active == true
                      ? Colors.transparent
                      : Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xff101012)
                      : const Color(0xfff7f8fb),
                  appBar: AppBar(
                    backgroundColor: backgroundSurface(context),
                    leading: _hiddenResourcePage
                        ? BackButton(
                            key: const Key('resource-back-to-parse'),
                            onPressed: () => _selectTab(0),
                          )
                        : null,
                    title: Text(titles[selected]),
                    centerTitle: desktopHeader ? false : null,
                    titleSpacing: desktopHeader ? 28 : null,
                    toolbarHeight: desktopHeader ? 52 : null,
                    actions: [
                      if (selected == 0)
                        AnimatedBuilder(
                          animation: widget.services.lan,
                          builder: (context, _) => Tooltip(
                            message: '设备互联',
                            child: TextButton.icon(
                              key: const Key('parse-device-link'),
                              onPressed: _showLan,
                              icon: Badge.count(
                                count: widget.services.lan.unread,
                                isLabelVisible: widget.services.lan.unread > 0,
                                child: const Icon(
                                  Icons.devices_rounded,
                                  size: 21,
                                ),
                              ),
                              label: const Text('互联'),
                            ),
                          ),
                        ),
                      if (selected != 1)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: selected == 0
                              ? AnnouncementButton(
                                  widget.services.announcements,
                                )
                              : AppPopupMenuButton<String>(
                                  tooltip: '更多操作',
                                  onSelected: _menu,
                                  actions: menu,
                                  icon: CupertinoIcons.ellipsis,
                                ),
                        ),
                    ],
                  ),
                  body: SafeArea(
                    top: false,
                    bottom: rail,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1120),
                        child: Column(
                          children: [
                            RemoteControlPrompts(
                              widget.services.control,
                              updater: widget.services.appUpdates,
                            ),
                            GuestDownloadPrompt(widget.services),
                            MobileDataDownloadPrompt(
                              widget.services.mobileDataDownloads,
                            ),
                            DownloadShutdownPrompt(
                              widget.services.downloadShutdown,
                              showWindow:
                                  widget.services.platformFeatures &&
                                      Platform.isWindows
                                  ? _showWindow
                                  : null,
                            ),
                            if (widget.services.clipboard.suggestion
                                case final suggestion?)
                              ClipboardLinkBanner(
                                suggestion: suggestion,
                                onUse: _useClipboard,
                                onDismiss: () => unawaited(
                                  widget.services.clipboard.acknowledge(
                                    suggestion,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: GestureDetector(
                                key: const Key('main-page-swipe-area'),
                                behavior: HitTestBehavior.translucent,
                                onHorizontalDragStart: (_) =>
                                    _pageSwipeDistance = 0,
                                onHorizontalDragUpdate: (details) =>
                                    _pageSwipeDistance += details.delta.dx,
                                onHorizontalDragEnd: _swipePage,
                                onHorizontalDragCancel: () =>
                                    _pageSwipeDistance = 0,
                                child: IndexedStack(
                                  index: selected,
                                  children: [
                                    TickerMode(
                                      enabled: selected == 0,
                                      child: ParsePage(
                                        widget.services,
                                        key: parseKey,
                                        active: selected == 0,
                                        resourceActive: selected == 1,
                                      ),
                                    ),
                                    _retainedTab(
                                      1,
                                      () => ResourceHomePage(
                                        widget.services,
                                        active: selected == 1,
                                        onOpen: (hit) async {
                                          final parser = parseKey.currentState;
                                          if (parser != null) {
                                            await parser.openResource(hit);
                                          }
                                        },
                                      ),
                                    ),
                                    _retainedTab(
                                      2,
                                      () => CloudPage(
                                        widget.services,
                                        onParseShare: () {
                                          setState(() => selected = 0);
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                                if (mounted && selected == 0) {
                                                  parseKey.currentState?.focus
                                                      .requestFocus();
                                                }
                                              });
                                        },
                                      ),
                                    ),
                                    _retainedTab(
                                      3,
                                      () => TransfersPage(
                                        widget.services,
                                        active: selected == 3,
                                      ),
                                    ),
                                    _retainedTab(
                                      4,
                                      () => MinePage(widget.services),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  bottomNavigationBar: rail
                      ? null
                      : _navigation(context, rail: false),
                );
                return PopScope(
                  canPop: !_hiddenResourcePage,
                  onPopInvokedWithResult: (didPop, _) {
                    if (!didPop && _hiddenResourcePage) _selectTab(0);
                  },
                  child: rail
                      ? Row(
                          children: [
                            _navigation(context, rail: true),
                            Expanded(child: content),
                          ],
                        )
                      : content,
                );
              },
            ),
          );
        },
      ),
    ),
  );
}
