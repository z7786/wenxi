import 'dart:async';
import 'dart:io' show Platform;
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/providers/baidu.dart';
import '../data/providers/pan123.dart';
import '../data/providers/uc_tv.dart';
import '../data/providers/xunlei.dart';
import '../data/providers/xunlei_login.dart';
import '../data/providers/xunlei_protocol.dart';
import '../domain/auth.dart';
import '../domain/aliyun_web_password.dart';
import '../domain/baidu_web_login.dart';
import '../domain/models.dart';
import '../domain/weiyun_web_login.dart';
import '../domain/tianyi_web_login.dart';
import '../diagnostics/app_log.dart';
import '../diagnostics/web_login_diagnostics.dart';
import 'common.dart';
import 'loading_indicator.dart';
import 'native_password_login_page.dart';
import 'github_login_page.dart';
import 'guangya_sms_login_page.dart';
import 'quark_login_page.dart';
import 'baidu_login_panel.dart';
import 'wopan_sms_login_page.dart';
import 'login_webview.dart';
import 'uc_tv_authorization_page.dart';
import 'cloud_accounts_page.dart';
import 'account_cookie.dart';
import 'account_info_page.dart';
export 'native_password_login_page.dart';
export 'login_webview.dart' show webSettings, desktopLoginViewportScript;

final _loginRoutes = Expando<MaterialPageRoute<void>>();

Future<void> openLogin(
  BuildContext context,
  AppServices services,
  CloudPlatform platform, {
  bool addAccount = false,
  String? accountId,
}) async {
  if (!context.mounted) return;
  if (!allowCloudAction(context, services.control, platform)) return;
  if (!platform.requiresAccount) {
    message(context, '支持不登录解析');
    return;
  }
  final navigator = Navigator.of(context);
  if (_loginRoutes[navigator]?.isActive ?? false) return;
  final created =
      addAccount ||
      (accountId == null && services.vault.activeAccountId(platform) == null);
  final entry = _LoginEntry(
    services,
    platform,
    created: created,
    accountId: accountId ?? services.vault.activeAccountId(platform),
  );
  final route = MaterialPageRoute<void>(builder: (_) => _LoginEntryPage(entry));
  _loginRoutes[navigator] = route;
  // Start the write on the caller's event loop, but push before awaiting it.
  // The login route survives state rebuilds and shows a wait or a storage error.
  unawaited(entry.prepare());
  try {
    await navigator.push(route);
  } catch (error, stack) {
    DiagnosticLog.error(
      'login.open_failed',
      error,
      stack,
      fields: {'platform': platform.key},
    );
    if (context.mounted) message(context, errorText(error));
  } finally {
    if (identical(_loginRoutes[navigator], route)) {
      _loginRoutes[navigator] = null;
    }
    try {
      await entry.close();
    } catch (error, stack) {
      DiagnosticLog.error(
        'login.account_cleanup_failed',
        error,
        stack,
        fields: {'platform': platform.key},
      );
      if (context.mounted) message(context, errorText(error));
    } finally {
      entry.dispose();
    }
  }
}

class _LoginEntry extends ChangeNotifier {
  _LoginEntry(
    this.services,
    this.platform, {
    required this.created,
    String? accountId,
  }) : owner = created ? null : accountId;

  final AppServices services;
  final CloudPlatform platform;
  final bool created;
  final _zone = Zone.current;
  String? owner;
  Object? error;
  bool loading = true, _closed = false;
  Future<void>? _pending;

  Future<void> prepare() => _pending ??= _zone.run<Future<void>>(() async {
    try {
      if (created) owner = await services.vault.createAccount(platform);
    } catch (failure, stack) {
      error = failure;
      DiagnosticLog.error(
        'login.account_prepare_failed',
        failure,
        stack,
        fields: {'platform': platform.key},
      );
    } finally {
      loading = false;
      if (!_closed) notifyListeners();
    }
  });

  void retry() {
    if (_closed || loading) return;
    error = null;
    loading = true;
    _pending = null;
    notifyListeners();
    unawaited(prepare());
  }

  Future<void> close() async {
    _closed = true;
    // A cancelled route can finish reserving its slot later. Wait for it before
    // cleaning up, and never remove a successfully authenticated account.
    await _pending;
    if (created && owner != null) {
      await services.vault.removeAccount(platform, owner!, onlyIfEmpty: true);
    }
  }
}

class _LoginEntryPage extends StatelessWidget {
  const _LoginEntryPage(this.entry);
  final _LoginEntry entry;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: entry,
    builder: (context, _) {
      if (!entry.loading && entry.error == null) {
        final services = entry.services, platform = entry.platform;
        final owner = entry.owner;
        return switch (platform) {
          CloudPlatform.github => GitHubLoginPage(services, accountId: owner),
          CloudPlatform.xunlei ||
          CloudPlatform.ctfile ||
          CloudPlatform.feijipan ||
          CloudPlatform.pikpak ||
          CloudPlatform.pan123 ||
          CloudPlatform.lanzou ||
          CloudPlatform.tianyi ||
          CloudPlatform.aliyun ||
          CloudPlatform.ilanzou ||
          CloudPlatform.wopan ||
          CloudPlatform.quark ||
          CloudPlatform.baidu ||
          CloudPlatform.guangya => PasswordLoginFlow(
            services,
            platform,
            accountId: owner,
          ),
          _ => WebLoginPage(
            services,
            WebLoginTarget.targets[platform]!,
            accountId: owner,
          ),
        };
      }
      return PageFrame(
        title: '${entry.platform.shortName}登录',
        child: entry.loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppLoadingIndicator(),
                    SizedBox(height: 16),
                    Text('正在准备登录…'),
                  ],
                ),
              )
            : EmptyPanel(
                '无法打开登录',
                errorText(entry.error!),
                icon: CupertinoIcons.exclamationmark_circle,
                action: FilledButton.icon(
                  onPressed: entry.retry,
                  icon: const Icon(CupertinoIcons.arrow_clockwise, size: 18),
                  label: const Text('重试'),
                ),
              ),
      );
    },
  );
}

// Keep both methods in one route so callers await the final login, including
// when the user switches methods while a previous request is still finishing.
class PasswordLoginFlow extends StatefulWidget {
  const PasswordLoginFlow(
    this.services,
    this.platform, {
    super.key,
    this.accountId,
  });
  final AppServices services;
  final CloudPlatform platform;
  final String? accountId;
  @override
  State<PasswordLoginFlow> createState() => _PasswordLoginFlowState();
}

enum _LoginMethod { password, sms, web, manual }

class _PasswordLoginFlowState extends State<PasswordLoginFlow> {
  late _LoginMethod _method = _defaultMethod;
  _LoginMethod get _defaultMethod =>
      {
        CloudPlatform.guangya,
        CloudPlatform.wopan,
        CloudPlatform.quark,
        CloudPlatform.baidu,
      }.contains(widget.platform)
      ? _LoginMethod.sms
      : _LoginMethod.password;
  AliyunWebPassword? _webPassword;
  String get _nativeLoginLabel => switch (widget.platform) {
    CloudPlatform.quark => '切换手机号登录',
    CloudPlatform.baidu => '切换手机号或扫码登录',
    _ => _defaultMethod == _LoginMethod.sms ? '切换短信验证码登录' : '切换账号密码登录',
  };

  void _switch(_LoginMethod method) {
    _webPassword?.clear();
    setState(() {
      _webPassword = null;
      _method = method;
    });
  }

  @override
  void dispose() {
    _webPassword?.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_method) {
    _LoginMethod.sms when widget.platform == CloudPlatform.baidu =>
      WebLoginPage(
        widget.services,
        WebLoginTarget.targets[CloudPlatform.baidu]!,
        key: const ValueKey('baidu-native-login'),
        accountId: widget.accountId,
        baiduNativeLogin: true,
        onUsePassword: () => _switch(_LoginMethod.web),
        nativeLoginLabel: '其他登录方式（网页）',
      ),
    _LoginMethod.sms when widget.platform == CloudPlatform.quark =>
      QuarkLoginPage(
        widget.services,
        accountId: widget.accountId,
        onUseWeb: () => _switch(_LoginMethod.web),
        onUseManual: () => _switch(_LoginMethod.manual),
      ),
    _LoginMethod.sms when widget.platform == CloudPlatform.wopan =>
      WopanSmsLoginPage(
        widget.services,
        accountId: widget.accountId,
        onUseWeb: () => _switch(_LoginMethod.web),
        onUseManual: () => _switch(_LoginMethod.manual),
      ),
    _LoginMethod.sms => GuangyaSmsLoginPage(
      widget.services,
      accountId: widget.accountId,
      onUsePassword: () => _switch(_LoginMethod.password),
      onUseWeb: () => _switch(_LoginMethod.web),
      onUseManual: () => _switch(_LoginMethod.manual),
    ),
    _LoginMethod.web => WebLoginPage(
      widget.services,
      WebLoginTarget.targets[widget.platform]!,
      accountId: widget.accountId,
      passwordLogin: _webPassword,
      onUsePassword: () => _switch(_defaultMethod),
      nativeLoginLabel: _nativeLoginLabel,
    ),
    _LoginMethod.manual => ManualLoginPage(
      widget.services,
      widget.platform,
      accountId: widget.accountId,
      onUsePassword: () => _switch(_defaultMethod),
      nativeLoginLabel: _nativeLoginLabel,
    ),
    _LoginMethod.password when widget.platform == CloudPlatform.xunlei =>
      XunleiLoginPage(
        widget.services,
        accountId: widget.accountId,
        onUseWeb: () => _switch(_LoginMethod.web),
      ),
    _LoginMethod.password => NativePasswordLoginPage(
      widget.services,
      widget.platform,
      accountId: widget.accountId,
      onUseWeb: () => _switch(_LoginMethod.web),
      onUseManual: () => _switch(_LoginMethod.manual),
      onUseSms: widget.platform == CloudPlatform.guangya
          ? () => _switch(_LoginMethod.sms)
          : null,
      onSubmitWebPassword: widget.platform == CloudPlatform.aliyun
          ? (username, password) {
              _webPassword?.clear();
              setState(() {
                _webPassword = AliyunWebPassword(username, password);
                _method = _LoginMethod.web;
              });
            }
          : null,
    ),
  };
}

Future<void> accountMenu(
  BuildContext context,
  AppServices services,
  CloudPlatform platform, {
  String? command,
}) async {
  if (!platform.requiresAccount) {
    message(context, '支持不登录解析');
    return;
  }
  final accountId = services.vault.activeAccountId(platform);
  final stored = LoginCredentials.stored(
    platform,
    services.vault.credentialFor(platform, accountId),
  );
  final loginInfo = savedAccountLoginInfo(services.vault, platform, accountId);
  final action =
      command ??
      await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: PlatformMark(platform: platform, size: 32),
                  title: Text(platform.label),
                ),
                ListTile(
                  leading: const Icon(CupertinoIcons.slider_horizontal_3),
                  title: const Text('账号配置'),
                  subtitle: const Text('查看与复制 Cookie、Token 等登录信息'),
                  onTap: () => Navigator.pop(context, 'info'),
                ),
                ListTile(
                  leading: const Icon(CupertinoIcons.arrow_clockwise),
                  title: Text(
                    platform == CloudPlatform.github ? '刷新账号信息' : '刷新账号容量',
                  ),
                  onTap: () => Navigator.pop(context, 'refresh'),
                ),
                ListTile(
                  leading: const Icon(CupertinoIcons.person_crop_circle),
                  title: Text(stored ? '重新登录当前账号' : '登录账号'),
                  onTap: () => Navigator.pop(context, 'login'),
                ),
                ListTile(
                  leading: const Icon(CupertinoIcons.person_2),
                  title: const Text('多账号管理'),
                  subtitle: Text(
                    '已保存 ${services.vault.profiles(platform).length} 个账号',
                  ),
                  onTap: () => Navigator.pop(context, 'accounts'),
                ),
                ListTile(
                  leading: const Icon(CupertinoIcons.doc_on_clipboard),
                  title: const Text('手动填写登录信息'),
                  onTap: () => Navigator.pop(context, 'manual'),
                ),
                if (services.vault.credentialFor(platform, accountId) != null)
                  ListTile(
                    leading: const Icon(CupertinoIcons.doc_on_doc),
                    title: Text(loginInfo.copyLabel),
                    onTap: () => Navigator.pop(context, 'copyLogin'),
                  ),
                if (platform == CloudPlatform.uc && stored)
                  ListTile(
                    leading: const Icon(CupertinoIcons.tv),
                    title: const Text('TV 播放授权'),
                    subtitle: Text(
                      UcTvService.status(services.vault.credential(platform)),
                    ),
                    onTap: () => Navigator.pop(context, 'ucTv'),
                  ),
                if (stored)
                  ListTile(
                    leading: const Icon(
                      CupertinoIcons.square_arrow_right,
                      color: Colors.red,
                    ),
                    title: const Text(
                      '退出账号',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: () => Navigator.pop(context, 'logout'),
                  ),
              ],
            ),
          ),
        ),
      );
  if (!context.mounted ||
      (services.vault.activeAccountId(platform) != accountId &&
          action != 'copyLogin' &&
          action != 'info')) {
    return;
  }
  if (action != null &&
      action != 'logout' &&
      action != 'copyLogin' &&
      action != 'info' &&
      !allowCloudAction(context, services.control, platform)) {
    return;
  }
  switch (action) {
    case 'copyLogin':
      await copyCloudAccountLoginInfo(
        context,
        services.vault,
        platform,
        accountId,
      );
    case 'info':
      await openCloudAccountInfo(context, services.vault, platform, accountId);
    case 'accounts':
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => CloudAccountsPage(services, platform: platform),
        ),
      );
    case 'refresh':
      await services.refreshAccount(platform);
    case 'login':
      await openLogin(context, services, platform);
    case 'manual':
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => platform == CloudPlatform.github
              ? GitHubLoginPage(services, accountId: accountId)
              : ManualLoginPage(services, platform),
        ),
      );
    case 'ucTv':
      if (await openUcTvAuthorization(context, services) && context.mounted) {
        message(context, 'UC TV 播放授权已完成');
      }
    case 'logout':
      if (await confirm(
            context,
            '退出${platform.shortName}账号',
            '已添加的下载仍保留；需要刷新地址的任务需重新登录后添加。',
          ) &&
          context.mounted) {
        await busy(context, () => services.login.remove(platform));
      }
  }
}

class WebLoginPage extends StatefulWidget {
  const WebLoginPage(
    this.services,
    this.target, {
    this.onUsePassword,
    this.nativeLoginLabel = '切换账号密码登录',
    this.passwordLogin,
    this.baiduNativeLogin = false,
    this.accountId,
    super.key,
  });
  final AppServices services;
  final WebLoginTarget target;
  final String? accountId;
  final VoidCallback? onUsePassword;
  final String nativeLoginLabel;
  final AliyunWebPassword? passwordLogin;
  final bool baiduNativeLogin;
  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginWindow {
  _WebLoginWindow(this.id);
  final int id;
  InAppWebViewController? controller;
}

class _WebLoginPageState extends State<WebLoginPage>
    with WidgetsBindingObserver {
  WebViewEnvironment? environment;
  InAppWebViewController? controller;
  InAppWebViewController? checkingWeb;
  CookieManager? cookies;
  Timer? timer;
  final clock = Stopwatch()..start(), policy = LoginPollingPolicy();
  final _storageSession = newId();
  final _baiduSession = newId();
  Widget? _baiduView;
  int _baiduViewRevision = 0;
  late final String? _baiduSelection;
  Map<String, dynamic> _baiduState = {};
  bool _baiduWebVisible = false, _baiduQrMode = false, _baiduExecuting = false;
  bool _baiduAutoReturn = false;
  String _baiduError = '';
  bool get _baiduNative =>
      widget.baiduNativeLogin && widget.target.platform == CloudPlatform.baidu;
  bool get _baiduBusy =>
      _baiduExecuting ||
      const {
        'sending',
        'submitting',
        'completing',
      }.contains(_baiduState['phase']);
  final _windows = <_WebLoginWindow>[];
  int _pollSequence = 0;
  bool get _flushLogin =>
      Platform.isWindows && widget.target.platform == CloudPlatform.baidu;
  String _weiyunCaptureState = '';
  String _tianyiBrowserId = '', _tianyiCaptureState = '';
  bool ready = false,
      completed = false,
      leaving = false,
      manualOpen = false,
      visible = true,
      passwordDocumentReady = false,
      passwordUnavailable = false,
      passwordSent = false,
      passwordFallback = false;
  double progress = 0;
  String get _initialStatus => widget.target.platform == CloudPlatform.xunlei
      ? '小米账号可在网页底部「更多方式」中登录，完成后自动保存'
      : '完成网页登录后将自动保存登录信息';
  late String status = _initialStatus;
  String error = '';
  bool get active => mounted && !leaving && !completed;
  bool get checking => checkingWeb != null;
  late final diagnostics = WebLoginDiagnostics(widget.target.platform);
  // Creation and event callbacks can wrap the same native controller twice.
  bool _sameWeb(InAppWebViewController? left, InAppWebViewController? right) =>
      left != null && right != null && identical(left.platform, right.platform);
  bool _current(InAppWebViewController web) =>
      active &&
      ready &&
      (_sameWeb(controller, web) ||
          _windows.any((window) => _sameWeb(window.controller, web)));

  Future<void> _forgetBrowserCookies({
    bool logFailure = true,
    bool requireSuccess = false,
  }) async {
    final manager = cookies;
    if (manager == null) return;
    try {
      diagnostics.record(
        'cookie_cleanup_started',
        stage: 'cleanup',
        flush: _flushLogin,
      );
      await manager.deleteAllCookies();
      diagnostics.record(
        'cookie_cleanup_completed',
        stage: 'cleanup',
        flush: _flushLogin,
      );
    } catch (error, stack) {
      if (requireSuccess) rethrow;
      if (!logFailure) return;
      diagnostics.record(
        'cookie_cleanup_failed',
        level: 'warning',
        stage: 'cleanup',
        error: error,
        stack: stack,
      );
    }
  }

  void _cancel() {
    if (leaving || completed) return;
    diagnostics.record('cancel_requested', stage: 'close', flush: _flushLogin);
    leaving = true;
    if (_baiduNative) unawaited(_baiduLifecycle('close'));
    widget.passwordLogin?.clear();
    timer?.cancel();
    widget.services.login.invalidate(widget.target.platform);
    unawaited(_forgetBrowserCookies(logFailure: false));
  }

  void _switchToPassword() {
    if (!active || widget.onUsePassword == null) return;
    _cancel();
    widget.onUsePassword!();
  }

  @override
  void initState() {
    super.initState();
    _baiduSelection = widget.services.vault.activeAccountId(
      CloudPlatform.baidu,
    );
    if (widget.passwordLogin != null) status = '正在打开官方密码登录，出现安全验证时请按网页提示完成';
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    visible = state == AppLifecycleState.resumed;
    if (_baiduNative) {
      unawaited(
        _baiduLifecycle(visible ? 'resume' : 'pause').then((_) {
          if (visible) unawaited(_poll());
        }),
      );
    } else if (visible) {
      unawaited(_poll());
    }
  }

  Future<void> _baiduLifecycle(String action) async {
    try {
      await controller
          ?.evaluateJavascript(
            source: BaiduWebLogin.command(_baiduSession, action),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // The document may already be closing or navigating to official SSO.
    }
  }

  bool _baiduOwnerCurrent() =>
      widget.services.vault.activeAccountId(CloudPlatform.baidu) ==
      _baiduSelection;

  Future<void> _syncBaidu() async {
    final web = controller;
    if (!_baiduNative ||
        web == null ||
        !_current(web) ||
        !visible ||
        manualOpen) {
      return;
    }
    if (!_baiduOwnerCurrent()) {
      await _baiduLifecycle('close');
      if (active) setState(() => _baiduError = '账号已发生变化，请返回后重新登录');
      return;
    }
    try {
      final url = (await web.getUrl().timeout(
        const Duration(seconds: 3),
      ))?.toString();
      if (!_current(web) || manualOpen) return;
      if (!BaiduWebLogin.trusted(url)) {
        if (url != null && url.startsWith('https://')) {
          setState(() => _baiduWebVisible = true);
        }
        return;
      }
      await web
          .evaluateJavascript(source: BaiduWebLogin.bootstrap(_baiduSession))
          .timeout(const Duration(seconds: 3));
      final state = BaiduWebLogin.decode(
        await web
            .evaluateJavascript(source: BaiduWebLogin.read(_baiduSession))
            .timeout(const Duration(seconds: 3)),
      );
      final currentUrl = (await web.getUrl().timeout(
        const Duration(seconds: 3),
      ))?.toString();
      if (!_current(web) ||
          manualOpen ||
          !_baiduOwnerCurrent() ||
          !BaiduWebLogin.trusted(currentUrl) ||
          state.isEmpty) {
        return;
      }
      final previous = _baiduState['phase'];
      setState(() {
        _baiduState = state;
        if (state['mode'] == 'sms' || state['mode'] == 'qrcode') {
          _baiduQrMode = state['mode'] == 'qrcode';
        }
        if (_baiduAutoReturn &&
            state['phase'] == 'sent' &&
            previous != 'sent' &&
            _windows.isEmpty) {
          _baiduWebVisible = false;
          _baiduAutoReturn = false;
          status = '验证码已发送，请输入6位短信验证码';
        } else if (previous != state['phase'] &&
            (state['phase'] == 'verify' || state['phase'] == 'completing')) {
          _baiduWebVisible = true;
          status = state['phase'] == 'completing'
              ? '正在完成百度登录…'
              : '请在百度官方页面完成验证或按提示重试';
        }
      });
    } catch (_) {
      // A redirect can replace the SDK. Keep its page available for the user.
    }
  }

  Future<void> _baiduAction(String action, Map<String, Object?> data) async {
    final web = controller;
    if (!active ||
        !visible ||
        manualOpen ||
        !ready ||
        web == null ||
        _baiduBusy) {
      return;
    }
    if (!_baiduOwnerCurrent()) {
      setState(() => _baiduError = '账号已发生变化，请返回后重新登录');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _baiduExecuting = true;
      _baiduError = '';
      if (action == 'send' || action == 'submit') {
        _baiduAutoReturn = action == 'send';
        _baiduWebVisible = true;
        status = action == 'send'
            ? '请在百度页面完成可能出现的验证码，发送成功后将返回填写短信验证码'
            : '正在登录，出现安全验证时请在百度页面完成';
      }
    });
    try {
      widget.services.control.checkCloud(CloudPlatform.baidu);
      if (!BaiduWebLogin.trusted(
        (await web.getUrl().timeout(const Duration(seconds: 3)))?.toString(),
      )) {
        throw const AppException('请先在百度页面完成当前验证，或刷新后重新登录');
      }
      if (!_current(web) || !visible || manualOpen || !_baiduOwnerCurrent()) {
        return;
      }
      // Dispatch once to the current document. Never retry a send or submit on
      // navigation, timeout, resume, or a delayed SDK initialization.
      final result = await web
          .evaluateJavascript(
            source: BaiduWebLogin.command(_baiduSession, action, {
              ...data,
              'id': newId(),
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (!_current(web) || manualOpen || !_baiduOwnerCurrent()) return;
      if (result != 'started' && result != 'ready') {
        throw const AppException('百度登录尚未就绪或正在验证，请在官方页面继续，也可刷新后重试');
      }
      if (action == 'mode') {
        setState(() => _baiduQrMode = data['mode'] == 'qrcode');
      }
      await _syncBaidu();
    } catch (e) {
      if (_current(web) && !manualOpen) {
        setState(() {
          _baiduError = e is AppException
              ? e.message
              : '操作未确认，请在百度页面查看结果；不要重复发送验证码';
          _baiduWebVisible = true;
        });
      }
    } finally {
      if (active) setState(() => _baiduExecuting = false);
    }
  }

  void _showBaiduOfficial() {
    if (!active) return;
    setState(() {
      _baiduAutoReturn = false;
      _baiduWebVisible = true;
      status = '请在百度官方页面完成验证，登录成功后将自动保存';
    });
  }

  Future<void> _returnBaiduNative() async {
    if (!active) return;
    if (_baiduState['mode'] == 'normal' && !_baiduBusy) {
      await _baiduAction('mode', {'mode': 'sms'});
    }
    if (!active) return;
    setState(() {
      _baiduWebVisible = false;
      _baiduAutoReturn = false;
    });
  }

  Future<void> _openManual() async {
    if (manualOpen || !active) return;
    manualOpen = true;
    widget.passwordLogin?.clear();
    widget.services.login.invalidate(widget.target.platform);
    if (_baiduNative) await _baiduLifecycle('pause');
    if (!mounted || !active) return;
    try {
      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => ManualLoginPage(
            widget.services,
            widget.target.platform,
            accountId: widget.accountId,
          ),
        ),
      );
      if (result == true && mounted && !leaving) {
        await _forgetBrowserCookies();
        if (!mounted || leaving) return;
        completed = true;
        timer?.cancel();
        if (mounted) Navigator.pop(context);
      }
    } finally {
      manualOpen = false;
      if (_baiduNative && active) await _baiduLifecycle('resume');
    }
  }

  Future<void> _initialize() async {
    timer?.cancel();
    diagnostics.record('initialize_started', stage: 'initialize');
    try {
      widget.services.control.checkCloud(widget.target.platform);
      environment = await widget.services.webEnvironment();
      if (!active) return;
      diagnostics.record(
        'environment_ready',
        stage: 'initialize',
        flush: _flushLogin,
      );
      widget.services.control.checkCloud(widget.target.platform);
      cookies = CookieManager.instance(webViewEnvironment: environment);
      // SSO cookies may live on authentication hosts that are not part of the
      // provider API domain list. Clear the whole browser jar before rendering
      // so adding an account can never silently reuse the previous login.
      await _forgetBrowserCookies(requireSuccess: true);
      if (!active) return;
      _tianyiBrowserId = '';
      _tianyiCaptureState = '';
      _baiduView = null;
      _baiduViewRevision++;
      setState(() => ready = true);
      diagnostics.record(
        'initialize_completed',
        stage: 'initialize',
        flush: _flushLogin,
      );
      timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
    } catch (e, stack) {
      if (active) {
        diagnostics.record(
          'initialize_failed',
          level: 'error',
          stage: 'initialize',
          error: e,
          stack: stack,
        );
        setState(
          () => error = e is AppException ? e.message : '网页登录组件初始化失败，可使用手动登录',
        );
      }
    }
  }

  Future<String> _readCredentials(InAppWebViewController web, int poll) async {
    final target = widget.target;
    final readCookies =
        target.localStorageKey == null ||
        target.platform == CloudPlatform.feijipan ||
        target.platform == CloudPlatform.ilanzou ||
        target.platform == CloudPlatform.wopan;
    String? page;
    try {
      diagnostics.record(
        'location_read_started',
        stage: 'read_credentials',
        fields: {'poll': poll},
        flush: _flushLogin,
      );
      page = (await web.getUrl().timeout(
        const Duration(seconds: 3),
      ))?.toString();
      diagnostics.record(
        'location_read_completed',
        stage: 'read_credentials',
        fields: {'poll': poll, 'hasPage': page != null},
        flush: _flushLogin,
      );
    } catch (_) {
      if (!readCookies) rethrow;
    }
    if (!_current(web) || manualOpen) return '';
    Object? storage;
    if (target.localStorageKey != null && target.canPrepareLocalStorage(page)) {
      final preparation = await web
          .evaluateJavascript(
            source: target.prepareStorageScript(_storageSession),
          )
          .timeout(const Duration(seconds: 5));
      if (!_current(web) || manualOpen) return '';
      if (preparation == 'cleared') {
        // Fallback for older WebViews without document-start injection. Reset
        // the page's in-memory state once, before accepting this new session.
        await web.reload();
        return '';
      }
      if (preparation != 'ready') {
        throw const AppException('网页登录存储尚未就绪，请稍候再检测或刷新网页');
      }
      if (!target.canReadLocalStorage(page)) return '';
      if (_sameWeb(web, controller)) await _submitWebPassword(web);
      if (!_current(web) || manualOpen) return '';
      if (widget.passwordLogin != null && !passwordSent && !passwordFallback) {
        return '';
      }
      storage = await web
          .evaluateJavascript(source: target.readStorageScript)
          .timeout(const Duration(seconds: 5));
      if (!target.canReadLocalStorage(
        (await web.getUrl().timeout(const Duration(seconds: 3)))?.toString(),
      )) {
        return '';
      }
    }
    if (target.platform == CloudPlatform.tianyi) {
      if (TianyiWebLogin.trusted(page)) {
        try {
          await web
              .evaluateJavascript(source: TianyiWebLogin.bootstrapScript)
              .timeout(const Duration(seconds: 3));
          final captured = TianyiWebLogin.decode(
            await web
                .evaluateJavascript(source: TianyiWebLogin.readScript)
                .timeout(const Duration(seconds: 3)),
          );
          final id = TianyiWebLogin.browserId(captured['browserId']);
          if (id.isNotEmpty) {
            final currentPage = (await web.getUrl().timeout(
              const Duration(seconds: 3),
            ))?.toString();
            if (_current(web) &&
                !manualOpen &&
                TianyiWebLogin.trusted(currentPage)) {
              _tianyiBrowserId = id;
            }
          }
        } catch (_) {
          // A redirect can replace the page after the login iframe was read.
        }
      }
      storage = {'browserId': _tianyiBrowserId};
    }
    if (target.platform == CloudPlatform.weiyun &&
        WeiyunWebLogin.trusted(page)) {
      try {
        await web
            .evaluateJavascript(source: WeiyunWebLogin.bootstrapScript)
            .timeout(const Duration(seconds: 3));
        storage = await web
            .evaluateJavascript(source: WeiyunWebLogin.readScript)
            .timeout(const Duration(seconds: 3));
        if (!WeiyunWebLogin.trusted(
          (await web.getUrl().timeout(const Duration(seconds: 3)))?.toString(),
        )) {
          storage = null;
        }
      } catch (_) {
        // Navigation can replace the document. Native cookies are still read.
        storage = null;
      }
    }
    if (!_current(web) || manualOpen) return '';
    final stored = LoginCredentials.fromBrowser(
      target.platform,
      storage: storage,
    );
    if (stored.isNotEmpty && target.platform != CloudPlatform.weiyun) {
      return stored;
    }
    final values = <String>[];
    if (readCookies) {
      Object? readError;
      var successfulReads = 0;
      var hostIndex = 0;
      for (final url in target.cookieUrls(page)) {
        if (!_current(web) || manualOpen) return '';
        final readClock = Stopwatch()..start();
        final index = hostIndex++;
        try {
          diagnostics.record(
            'browser_state_read_started',
            stage: 'read_credentials',
            fields: {'poll': poll, 'hostIndex': index},
            flush: _flushLogin,
          );
          final pairs = await cookies!
              .getCookies(url: WebUri(url), webViewController: web)
              .timeout(const Duration(seconds: 3));
          successfulReads++;
          diagnostics.record(
            'browser_state_read_completed',
            stage: 'read_credentials',
            fields: {
              'poll': poll,
              'hostIndex': index,
              'entryCount': pairs.length,
              'durationMs': readClock.elapsedMilliseconds,
              if (target.platform == CloudPlatform.baidu)
                'hasLoginSession': pairs.any(
                  (entry) => entry.name == 'BDUSS' && entry.value.isNotEmpty,
                ),
            },
            flush: _flushLogin,
          );
          values.add(pairs.map((c) => '${c.name}=${c.value}').join('; '));
        } catch (e) {
          readError = e;
          diagnostics.record(
            'browser_state_read_failed',
            level: 'warning',
            stage: 'read_credentials',
            fields: {
              'poll': poll,
              'hostIndex': index,
              'durationMs': readClock.elapsedMilliseconds,
              'type': e.runtimeType.toString(),
            },
            flush: _flushLogin,
          );
        }
        if (!_current(web) || manualOpen) return '';
      }
      if (successfulReads == 0 && readError != null && stored.isEmpty) {
        throw const AppException('网页登录信息读取失败，请稍候再检测或刷新网页');
      }
    }
    if (target.platform == CloudPlatform.tianyi) {
      final native = LoginCredentials.cookiePairs(
        LoginCredentials.mergeCookies(values),
      );
      final fields = <String, Object?>{
        'nativeEntryCount': native.length,
        'hasBrowserBinding': _tianyiBrowserId.isNotEmpty,
        'hasPersistentSession': native.containsKey('COOKIE_LOGIN_USER'),
        'hasPortalSession': native.containsKey('LOGIN_USER'),
      };
      final state = jsonEncode(fields);
      if (state != _tianyiCaptureState) {
        _tianyiCaptureState = state;
        diagnostics.record(
          'capture_state',
          stage: 'read_credentials',
          fields: fields,
        );
      }
    }
    if (target.platform == CloudPlatform.weiyun) {
      final captured = WeiyunWebLogin.decode(storage);
      final native = LoginCredentials.cookiePairs(
        LoginCredentials.mergeCookies(values),
      );
      final fields = <String, Object?>{
        'nativeEntryCount': native.length,
        'pageEntryCount': LoginCredentials.cookiePairs(
          captured.str('cookie'),
        ).length,
        'hasRequestIdentity': WeiyunWebLogin.tokenInfo(
          captured['tokenInfo'],
        ).isNotEmpty,
        'hasRequestCsrf': WeiyunWebLogin.csrf(captured['csrf']).isNotEmpty,
        'hasQqOpenId': native.containsKey('weiyun_qq_openid'),
        'hasLegacyQqKey': native.containsKey('p_skey'),
      };
      final state = jsonEncode(fields);
      if (state != _weiyunCaptureState) {
        _weiyunCaptureState = state;
        diagnostics.record(
          'capture_state',
          stage: 'read_credentials',
          fields: fields,
        );
      }
    }
    return LoginCredentials.fromBrowser(
      target.platform,
      storage: storage,
      cookies: values,
    );
  }

  Future<void> _poll({bool userInitiated = false}) async {
    if (!active ||
        !visible ||
        manualOpen ||
        !ready ||
        completed ||
        checking ||
        controller == null) {
      return;
    }
    var web = controller!;
    checkingWeb = web;
    final poll = ++_pollSequence;
    final pollClock = Stopwatch()..start();
    diagnostics.record(
      'poll_started',
      stage: 'read_credentials',
      fields: {
        'poll': poll,
        'popupCount': _windows.length,
        'userInitiated': userInitiated,
      },
      flush: _flushLogin,
    );
    var candidate = '';
    var stage = 'read_credentials';
    try {
      if (_baiduNative) {
        await _syncBaidu();
        if (!active || manualOpen || !_baiduOwnerCurrent()) return;
      }
      if (userInitiated) setState(() => status = '正在检测登录信息…');
      final target = widget.target;
      final browsers = [
        for (final window in _windows.reversed)
          if (window.controller != null) window.controller!,
        controller!,
      ];
      Object? readError;
      StackTrace? readStack;
      for (final browser in browsers) {
        if (!_current(browser) || manualOpen) continue;
        web = browser;
        checkingWeb = web;
        try {
          candidate = await _readCredentials(web, poll);
        } catch (e, stack) {
          readError = e;
          readStack = stack;
          candidate = '';
        }
        if (candidate.isNotEmpty && _current(web)) break;
      }
      if (!_current(web) || manualOpen) return;
      if (candidate.isEmpty && readError != null) {
        Error.throwWithStackTrace(readError, readStack!);
      }
      if (!LoginCredentials.plausible(target.platform, candidate)) {
        if (userInitiated) {
          diagnostics.record('credentials_pending', stage: 'read_credentials');
          setState(
            () => status = switch (target.platform) {
              CloudPlatform.weiyun => '暂未读取到完整凭据，请刷新网页中的文件列表后再检测',
              CloudPlatform.tianyi => '天翼登录尚未完成，请在网页完成验证码或安全验证后再检测',
              CloudPlatform.lanzou => '请完成蓝奏网页登录并进入「我的文件」，系统会自动检测并保存登录信息',
              CloudPlatform.ctfile => '请完成城通网页登录，系统会自动检测并保存登录信息',
              _ => '尚未读取到完整登录信息，请进入网盘首页后再检测',
            },
          );
        }
        return;
      }
      if (target.platform == CloudPlatform.c139 &&
          !LoginCredentials.c139WebReady(candidate)) {
        setState(() => status = '正在等待云盘完成登录，请在网页进入网盘首页…');
        return;
      }
      if (!userInitiated &&
          !policy.canAttempt(candidate, clock.elapsedMilliseconds)) {
        return;
      }
      stage = 'validation';
      policy.started(clock.elapsedMilliseconds);
      diagnostics.record(
        'validation_started',
        stage: 'validation',
        fields: {'poll': poll},
        flush: _flushLogin,
      );
      if (mounted) setState(() => status = '正在验证登录信息…');
      await widget.services.login.submitWeb(
        target.platform,
        candidate,
        accountId: widget.accountId,
        rememberedLogin: passwordSent
            ? widget.passwordLogin?.rememberedLogin ?? const {}
            : const {},
      );
      // Closing an SSO popup does not cancel its parent login. The account
      // service has already checked cancellation and account ownership.
      if (!active || !ready || manualOpen) return;
      diagnostics.record(
        'validation_succeeded',
        stage: 'validation',
        fields: {'poll': poll},
        flush: _flushLogin,
      );
      await _forgetBrowserCookies();
      if (!active || !ready || manualOpen) return;
      completed = true;
      widget.passwordLogin?.clear();
      timer?.cancel();
      if (mounted && !leaving && !manualOpen) {
        diagnostics.record(
          'close_requested',
          stage: 'close',
          fields: {'completed': true},
          flush: _flushLogin,
        );
        message(context, '${target.platform.shortName}登录成功');
        Navigator.pop(context);
      }
    } catch (e, stack) {
      if ((stage == 'validation' ? active && ready : _current(web)) &&
          (!_baiduNative || _sameWeb(web, controller)) &&
          !manualOpen) {
        policy.failed(candidate, clock.elapsedMilliseconds);
        diagnostics.record(
          stage == 'validation'
              ? 'validation_failed'
              : 'credential_read_failed',
          level: 'warning',
          stage: stage,
          error: e,
          stack: stack,
        );
        setState(() {
          status = errorText(e);
          if (_baiduNative) {
            _baiduError = status;
            _baiduWebVisible = true;
          }
        });
      }
    } finally {
      diagnostics.record(
        'poll_completed',
        stage: stage,
        fields: {
          'poll': poll,
          'durationMs': pollClock.elapsedMilliseconds,
          'completed': completed,
        },
        flush: _flushLogin,
      );
      if (_sameWeb(checkingWeb, web)) {
        checkingWeb = null;
        if (active) setState(() {});
      }
    }
  }

  Future<void> _submitWebPassword(InAppWebViewController web) async {
    final attempt = widget.passwordLogin;
    if (attempt == null ||
        passwordUnavailable ||
        passwordFallback ||
        !passwordDocumentReady ||
        !_current(web) ||
        manualOpen) {
      return;
    }
    void unavailable() {
      attempt.clear();
      passwordUnavailable = true;
      passwordSent = false;
      if (_current(web) && !manualOpen) {
        setState(() => status = '自动填入未完成，可在网页继续登录，或返回账号密码页面重试');
      }
    }

    if (attempt.pending && attempt.expired) {
      unavailable();
      return;
    }
    try {
      if (!widget.target.canReadLocalStorage(
        (await web.getUrl())?.toString(),
      )) {
        return;
      }
      final state = await web.evaluateJavascript(source: attempt.statusScript);
      if (!_current(web) || manualOpen) return;
      if (state == 'ready' && attempt.pending) {
        final script = attempt.takeSubmissionScript();
        if (script == null) {
          unavailable();
          return;
        }
        final result = await web.evaluateJavascript(source: script);
        if (!_current(web) || manualOpen) return;
        if (result != 'sent') {
          unavailable();
          return;
        }
        passwordSent = true;
        setState(() => status = '已填入账号密码，请按官方页面提示完成登录或安全验证');
      } else if (state == 'unavailable') {
        unavailable();
      }
    } catch (_) {
      // A navigating frame can disappear between readiness and submission.
      // A consumed password is never automatically replayed into a new page.
      if (!attempt.pending) unavailable();
    }
  }

  void _continueWebLogin() {
    if (!active) return;
    widget.passwordLogin?.clear();
    widget.services.login.invalidate(widget.target.platform);
    setState(() {
      passwordFallback = true;
      status = _initialStatus;
    });
  }

  Future<void> _loaded(InAppWebViewController web, WebUri? uri) async {
    if (!_current(web)) return;
    diagnostics.pageLoaded();
    try {
      if (widget.target.desktopMode && !_baiduNative) {
        await web.evaluateJavascript(source: desktopLoginViewportScript);
      }
      if (widget.target.platform == CloudPlatform.tianyi && _current(web)) {
        await web.evaluateJavascript(source: TianyiWebLogin.mobileFormScript);
      }
      final attempt = widget.passwordLogin;
      if (attempt != null && _current(web)) {
        await web.evaluateJavascript(source: attempt.bootstrapScript);
      }
      if (_baiduNative && _sameWeb(web, controller)) await _syncBaidu();
    } catch (_) {
      // A navigation can replace the document; cookie detection can still run.
    }
    if (!_current(web)) return;
    if (_sameWeb(web, controller)) passwordDocumentReady = true;
    await _poll();
  }

  void _rendererGone(
    InAppWebViewController web,
    RenderProcessGoneDetail detail,
  ) {
    if (!_current(web)) return;
    diagnostics.rendererGone(
      didCrash: detail.didCrash,
      priority: detail.rendererPriorityAtExit?.toNativeValue(),
    );
    final popup = _windows
        .where((window) => _sameWeb(window.controller, web))
        .firstOrNull;
    if (popup != null) {
      _closeWindow(popup.id);
      setState(() => status = '授权页面已关闭，请在登录页重新打开');
      return;
    }
    timer?.cancel();
    widget.services.login.invalidate(widget.target.platform);
    // A dead renderer cannot be reused. Removing the platform view
    // lets the explicit retry create a fresh one instead of reloading it.
    controller = null;
    _baiduView = null;
    widget.services.invalidateWebEnvironment(environment);
    checkingWeb = null;
    _windows.clear();
    setState(() {
      ready = false;
      error = '登录页面已停止运行，请重试或切换登录方式';
    });
  }

  void _closeWindow(int id) {
    if (!active) return;
    final index = _windows.indexWhere((window) => window.id == id);
    if (index < 0) return;
    diagnostics.record(
      'popup_close_requested',
      stage: 'close',
      fields: {'popupCount': _windows.length},
      flush: _flushLogin,
    );
    setState(() => _windows.removeRange(index, _windows.length));
    unawaited(_poll());
  }

  Widget _webView({_WebLoginWindow? popup}) => InAppWebView(
    key: ValueKey(
      popup?.id ??
          (_baiduNative
              ? 'baidu-login-window-$_baiduViewRevision'
              : 'main-login-window'),
    ),
    webViewEnvironment: environment,
    windowId: popup?.id,
    initialUrlRequest: popup == null
        ? URLRequest(url: WebUri(widget.target.url))
        : null,
    initialSettings:
        webSettings(
            userAgent: widget.target.userAgent,
            desktopMode: widget.target.desktopMode,
            isPopup: popup != null,
          )
          ..useOnRenderProcessGone = true
          ..supportMultipleWindows = true
          ..javaScriptCanOpenWindowsAutomatically = true,
    initialUserScripts: UnmodifiableListView([
      if (widget.target.desktopMode && !_baiduNative) desktopLoginUserScript(),
      if (_baiduNative && popup == null)
        UserScript(
          source: BaiduWebLogin.bootstrap(_baiduSession),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: const {BaiduWebLogin.origin},
        ),
      if (widget.target.platform == CloudPlatform.tianyi)
        UserScript(
          source: TianyiWebLogin.mobileFormScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: const {'https://open.e.189.cn'},
        ),
      if (widget.target.platform == CloudPlatform.tianyi)
        UserScript(
          source: TianyiWebLogin.bootstrapScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: TianyiWebLogin.origins,
        ),
      if (widget.target.platform == CloudPlatform.weiyun)
        UserScript(
          source: WeiyunWebLogin.bootstrapScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: WeiyunWebLogin.origins,
        ),
      if (widget.target.localStorageKey != null)
        UserScript(
          source: widget.target.prepareStorageScript(_storageSession),
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: true,
          allowedOriginRules: widget.target.storageOriginRules,
        ),
      if (widget.passwordLogin != null && popup == null)
        UserScript(
          source: widget.passwordLogin!.bootstrapScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
          allowedOriginRules: AliyunWebPassword.origins,
        ),
    ]),
    onWebViewCreated: (web) {
      if (!active || !ready) return;
      diagnostics.record(
        'view_created',
        stage: 'initialize',
        fields: {'popup': popup != null},
        flush: _flushLogin,
      );
      if (popup == null) {
        controller = web;
      } else if (_windows.contains(popup)) {
        popup.controller = web;
      }
    },
    onCreateWindow: (web, action) async {
      if (!_current(web) || _windows.length >= 3) return false;
      final url = action.request.url;
      if (url != null && !{'http', 'https', 'about'}.contains(url.scheme)) {
        return false;
      }
      setState(() => _windows.add(_WebLoginWindow(action.windowId)));
      if (_baiduNative) setState(() => _baiduWebVisible = true);
      diagnostics.record('authorization_window_opened');
      return true;
    },
    onCloseWindow: (web) {
      if (popup != null) _closeWindow(popup.id);
    },
    onLoadStart: (web, _) {
      if (_current(web)) {
        if (_sameWeb(web, controller)) passwordDocumentReady = false;
        diagnostics.pageStarted();
      }
    },
    onLoadStop: _loaded,
    onUpdateVisitedHistory: (web, _, _) {
      if (_current(web)) unawaited(_poll());
    },
    onProgressChanged: (web, value) {
      if (_current(web)) setState(() => progress = value / 100);
    },
    onReceivedError: (web, request, error) {
      if (!_current(web)) return;
      diagnostics.resourceFailed(
        isMainFrame: request.isForMainFrame,
        type: error.type.toValue(),
        code: error.type.toNativeValue(),
      );
      if (request.isForMainFrame == true && active) {
        setState(() => status = '网页加载失败，可刷新后重试');
      }
    },
    onReceivedHttpError: (web, request, response) {
      if (!_current(web)) return;
      diagnostics.httpFailed(
        isMainFrame: request.isForMainFrame,
        status: response.statusCode,
      );
      if (request.isForMainFrame == true) {
        setState(() => status = '登录页面暂时不可用，可刷新后重试');
      }
    },
    onRenderProcessGone: _rendererGone,
    shouldOverrideUrlLoading: (web, action) async {
      final url = action.request.url;
      if (_current(web) &&
          widget.target.platform == CloudPlatform.tianyi &&
          action.isForMainFrame &&
          TianyiWebLogin.isCompletionLanding(url?.toString())) {
        // The official mobile SSO callback has already stored its HttpOnly
        // cookies. Its home/redirect document would send this mobile UA to a
        // client promotion page. Validate the native jar before that hop.
        diagnostics.record('completion_redirect', stage: 'read_credentials');
        unawaited(_poll(userInitiated: true));
        return NavigationActionPolicy.CANCEL;
      }
      return active &&
              url != null &&
              {'http', 'https', 'about'}.contains(url.scheme)
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
  );

  Future<void> _refresh() async {
    if (!active) return;
    if (_baiduNative) {
      widget.services.login.invalidate(CloudPlatform.baidu);
      await _baiduLifecycle('close');
      if (!active) return;
      timer?.cancel();
      controller = null;
      checkingWeb = null;
      _windows.clear();
      setState(() {
        ready = false;
        error = '';
        progress = 0;
        status = _initialStatus;
        _baiduView = null;
        _baiduState = {};
        _baiduWebVisible = false;
        _baiduQrMode = false;
        _baiduExecuting = false;
        _baiduAutoReturn = false;
        _baiduError = '';
      });
      await _initialize();
      return;
    }
    if (error.isNotEmpty) {
      setState(() {
        error = '';
        ready = false;
        progress = 0;
        status = _initialStatus;
      });
      await _initialize();
      return;
    }
    try {
      final web = _windows.isEmpty ? controller : _windows.last.controller;
      if (widget.target.platform == CloudPlatform.tianyi) {
        await web?.loadUrl(
          urlRequest: URLRequest(url: WebUri(widget.target.url)),
        );
      } else {
        await web?.reload();
      }
    } catch (e, stack) {
      if (active) {
        diagnostics.record(
          'page_script_failed',
          level: 'warning',
          stage: 'reload',
          error: e,
          stack: stack,
        );
        setState(() => status = '网页刷新失败，请返回后重新打开登录页面');
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _cancel();
    diagnostics.close(completed: completed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _windows.isEmpty && (!_baiduNative || !_baiduWebVisible),
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) {
        _cancel();
      } else if (_windows.isNotEmpty) {
        _closeWindow(_windows.last.id);
      } else if (_baiduNative && _baiduWebVisible) {
        unawaited(_returnBaiduNative());
      }
    },
    child: PageFrame(
      title: _baiduNative
          ? '百度${_baiduWebVisible ? '登录验证' : '登录'}'
          : '${widget.target.platform.shortName}${widget.passwordLogin == null || passwordFallback ? '网页登录' : '登录验证'}',
      actions: [
        IconButton(
          tooltip: '刷新网页',
          onPressed: _refresh,
          icon: const Icon(CupertinoIcons.arrow_clockwise, size: 20),
        ),
        TextButton(onPressed: _openManual, child: const Text('手动')),
      ],
      child: Column(
        children: [
          if (progress < 1 && ready) LinearProgressIndicator(value: progress),
          if (!_baiduNative || _baiduWebVisible)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                children: [
                  Icon(
                    checking
                        ? CupertinoIcons.clock
                        : CupertinoIcons.lock_shield,
                    size: 16,
                    color: themeAccent(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      status,
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                  ),
                  TextButton(
                    onPressed: checking
                        ? null
                        : () => _poll(userInitiated: true),
                    child: const Text('检测登录', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          if (_baiduNative && _baiduWebVisible)
            TextButton.icon(
              key: const ValueKey('baidu-return-native'),
              onPressed: _returnBaiduNative,
              icon: const Icon(CupertinoIcons.back, size: 18),
              label: const Text('返回手机号或扫码登录'),
            ),
          if ((!_baiduNative || error.isNotEmpty) &&
              (widget.onUsePassword != null ||
                  widget.passwordLogin != null && !passwordFallback))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                children: [
                  if (widget.onUsePassword != null)
                    TextButton.icon(
                      key: const ValueKey('web-login-password'),
                      onPressed: _switchToPassword,
                      icon: const Icon(CupertinoIcons.keyboard, size: 18),
                      label: Text(widget.nativeLoginLabel),
                    ),
                  if (widget.passwordLogin != null && !passwordFallback)
                    TextButton.icon(
                      key: const ValueKey('web-login-continue-web'),
                      onPressed: _continueWebLogin,
                      icon: const Icon(CupertinoIcons.globe, size: 18),
                      label: const Text('继续网页登录'),
                    ),
                ],
              ),
            ),
          Expanded(
            child: error.isNotEmpty
                ? EmptyPanel(
                    '无法打开登录页面',
                    error,
                    icon: CupertinoIcons.globe,
                    action: TextButton(
                      onPressed: _refresh,
                      child: const Text('重试'),
                    ),
                  )
                : !ready
                ? const Center(child: CircularProgressIndicator())
                : IndexedStack(
                    index: _baiduNative && !_baiduWebVisible ? 1 : 0,
                    children: [
                      Stack(
                        children: [
                          Positioned.fill(
                            child: _baiduNative
                                ? _baiduView ??= _webView()
                                : _webView(),
                          ),
                          for (final popup in _windows)
                            Positioned.fill(
                              key: ValueKey('login-popup-${popup.id}'),
                              child: ColoredBox(
                                color: Theme.of(
                                  context,
                                ).scaffoldBackgroundColor,
                                child: Column(
                                  children: [
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton.icon(
                                        onPressed: () => _closeWindow(popup.id),
                                        icon: const Icon(
                                          CupertinoIcons.back,
                                          size: 18,
                                        ),
                                        label: const Text('返回登录页面'),
                                      ),
                                    ),
                                    Expanded(child: _webView(popup: popup)),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (_baiduNative)
                        ColoredBox(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: BaiduLoginPanel(
                            qrMode: _baiduQrMode,
                            ready: _baiduState['ready'] == true,
                            busy: _baiduBusy,
                            state: _baiduState,
                            error: _baiduError,
                            onMode: (qr) => _baiduAction('mode', {
                              'mode': qr ? 'qrcode' : 'sms',
                            }),
                            onAction: _baiduAction,
                            onShowOfficial: _showBaiduOfficial,
                            onUseWeb: _switchToPassword,
                            onUseManual: _openManual,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}

class ManualLoginPage extends StatefulWidget {
  const ManualLoginPage(
    this.services,
    this.platform, {
    super.key,
    this.accountId,
    this.onUsePassword,
    this.nativeLoginLabel = '切换账号密码登录',
  });
  final AppServices services;
  final CloudPlatform platform;
  final String? accountId;
  final VoidCallback? onUsePassword;
  final String nativeLoginLabel;
  @override
  State<ManualLoginPage> createState() => _ManualLoginPageState();
}

class _ManualLoginPageState extends State<ManualLoginPage> {
  final primary = TextEditingController(),
      secondaryInput = TextEditingController(),
      appId = TextEditingController(),
      deviceId = TextEditingController(),
      clientId = TextEditingController(),
      clientSecret = TextEditingController();
  bool working = false,
      visible = false,
      passwordMode = false,
      completed = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    final old = widget.services.vault.credentialFor(
      widget.platform,
      widget.accountId ??
          widget.services.vault.activeAccountId(widget.platform),
    );
    appId.text = (old?.field('appId') ?? '').ifEmpty(
      widget.platform == CloudPlatform.baidu ? old?.secondary ?? '' : '',
    );
    clientId.text = old?.field('clientId') ?? XunleiProtocol.clientId;
    clientSecret.text =
        old?.field('clientSecret') ?? XunleiProtocol.clientSecret;
    deviceId.text = old?.field('deviceId') ?? '';
  }

  @override
  void dispose() {
    if (!completed) widget.services.login.invalidate(widget.platform);
    for (final c in [
      primary,
      secondaryInput,
      appId,
      deviceId,
      clientId,
      clientSecret,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (working) return;
    setState(() {
      working = true;
      error = '';
    });
    try {
      final p = widget.platform, services = widget.services;
      if (p == CloudPlatform.pan123 && passwordMode) {
        await services.login.submit(p, (_) async {
          require(
            primary.text.trim().isNotEmpty && secondaryInput.text.isNotEmpty,
            '请输入账号和密码',
          );
          return (services.cloud.connector(p) as Pan123Connector).password(
            primary.text.trim(),
            secondaryInput.text,
          );
        }, accountId: widget.accountId);
      } else if (p == CloudPlatform.xunlei) {
        await services.login.submit(p, (_) async {
          require(primary.text.trim().isNotEmpty, '请输入 Access Token');
          final c = Credential(p.label, {
            'primary': primary.text.trim(),
            'accessToken': primary.text.trim(),
            'refreshToken': secondaryInput.text.trim(),
            'secondary': secondaryInput.text.trim(),
            'deviceId': deviceId.text.trim(),
            'clientId': clientId.text.trim(),
            'clientSecret': clientSecret.text.trim(),
            'clientVersion': XunleiProtocol.version,
          });
          return (services.cloud.connector(p) as XunleiConnector).authenticate(
            c,
          );
        }, accountId: widget.accountId);
      } else {
        var value = primary.text.trim();
        if (p == CloudPlatform.c139 && secondaryInput.text.trim().isNotEmpty) {
          final pairs = LoginCredentials.cookiePairs(value)
            ..['authorization'] = secondaryInput.text.trim();
          value = pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
        }
        await services.login.submitWeb(
          p,
          value,
          appId: appId.text.trim(),
          accountId: widget.accountId,
        );
      }
      completed = true;
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      enabled: !working,
      obscureText: secret && !visible,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: secret
            ? IconButton(
                tooltip: visible ? '隐藏' : '显示',
                icon: Icon(
                  visible ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                  size: 20,
                ),
                onPressed: () => setState(() => visible = !visible),
              )
            : null,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final platform = widget.platform;
    return PageFrame(
      title: '${platform.shortName}登录信息',
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 560,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  PlatformMark(platform: platform),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      platform == CloudPlatform.baidu
                          ? '登录信息加密保存在本机；下载和播放时，必要凭据会加密发送至取链服务，用你的账号获取下载地址'
                          : '登录信息加密保存在本机',
                      style: TextStyle(fontSize: 13, color: secondary(context)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (platform == CloudPlatform.pan123)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('网页登录 Token')),
                      ButtonSegment(value: true, label: Text('账号密码')),
                    ],
                    selected: {passwordMode},
                    onSelectionChanged: working
                        ? null
                        : (v) => setState(() {
                            passwordMode = v.first;
                            primary.clear();
                            secondaryInput.clear();
                          }),
                  ),
                ),
              _field(
                primary,
                platform == CloudPlatform.ctfile
                    ? 'Session Token'
                    : platform == CloudPlatform.xunlei
                    ? 'Access Token'
                    : platform == CloudPlatform.pan123
                    ? passwordMode
                          ? '账号'
                          : 'authorToken'
                    : platform == CloudPlatform.aliyun
                    ? 'Refresh Token 或登录凭据 JSON'
                    : platform == CloudPlatform.wopan
                    ? 'Refresh Token 或登录凭据 JSON'
                    : platform == CloudPlatform.ilanzou ||
                          platform == CloudPlatform.feijipan
                    ? 'appToken 或登录凭据 JSON'
                    : platform == CloudPlatform.guangya
                    ? '登录凭据 JSON 或 Access Token'
                    : '完整 Cookie',
                secret: !passwordMode,
              ),
              if (platform == CloudPlatform.pan123 && passwordMode)
                _field(secondaryInput, '密码', secret: true),
              if (platform == CloudPlatform.baidu)
                _field(appId, '应用 ID（可选，默认 ${BaiduConnector.defaultAppId}）'),
              if (platform == CloudPlatform.c139)
                _field(
                  secondaryInput,
                  'Authorization（Cookie 中缺失时填写）',
                  secret: true,
                ),
              if (platform == CloudPlatform.xunlei) ...[
                _field(secondaryInput, 'Refresh Token（可选）', secret: true),
                _field(deviceId, 'Device ID（可选）'),
                _field(clientId, 'Client ID'),
                _field(clientSecret, 'Client Secret', secret: true),
              ],
              Text(
                platform == CloudPlatform.xunlei ||
                        platform == CloudPlatform.pan123 && passwordMode
                    ? '验证成功后会保存账号信息。'
                    : LoginCredentials.hint(platform),
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
              const SizedBox(height: 20),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(error, style: const TextStyle(color: Colors.red)),
                ),
              FilledButton(
                onPressed: working ? null : _save,
                child: Text(working ? '正在验证…' : '验证并保存'),
              ),
              if (widget.onUsePassword != null)
                TextButton.icon(
                  key: const ValueKey('manual-login-password'),
                  onPressed: () {
                    widget.services.login.invalidate(platform);
                    widget.onUsePassword!();
                  },
                  icon: const Icon(CupertinoIcons.keyboard, size: 18),
                  label: Text(widget.nativeLoginLabel),
                ),
              if (working)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class XunleiLoginPage extends StatefulWidget {
  const XunleiLoginPage(
    this.services, {
    super.key,
    this.accountId,
    required this.onUseWeb,
  });
  final AppServices services;
  final String? accountId;
  final VoidCallback onUseWeb;
  @override
  State<XunleiLoginPage> createState() => _XunleiLoginPageState();
}

class _XunleiLoginPageState extends State<XunleiLoginPage> {
  final username = TextEditingController(),
      password = TextEditingController(),
      mobile = TextEditingController(),
      code = TextEditingController();
  bool working = false, visible = false, smsMode = false, completed = false;
  bool leaving = false;
  String error = '';
  SmsChallenge? challenge;
  XunleiVerificationRequired? verification;
  int cooldown = 0;
  Timer? timer;
  RequestScope? request;
  @override
  void initState() {
    super.initState();
    final saved = widget.services.vault.credentialFor(
      CloudPlatform.xunlei,
      widget.accountId ??
          widget.services.vault.activeAccountId(CloudPlatform.xunlei),
    );
    if (LoginCredentials.hasXunleiPassword(saved)) {
      username.text = saved!.field('username');
      password.text = saved.field('password');
    }
  }

  void _cancel() {
    if (completed || leaving) return;
    leaving = true;
    request?.cancel();
    timer?.cancel();
    widget.services.login.invalidate(CloudPlatform.xunlei);
  }

  void _useWeb() {
    if (completed || leaving) return;
    _cancel();
    password.clear();
    code.clear();
    FocusScope.of(context).unfocus();
    widget.onUseWeb();
  }

  @override
  void dispose() {
    _cancel();
    timer?.cancel();
    for (final c in [username, password, mobile, code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _action(Future<void> Function() action) async {
    if (working || leaving || completed) return;
    setState(() {
      working = true;
      error = '';
    });
    request = RequestScope();
    try {
      widget.services.control.checkCloud(CloudPlatform.xunlei);
      await widget.services.vault.withAccount(
        CloudPlatform.xunlei,
        widget.accountId ??
            widget.services.vault.activeAccountId(CloudPlatform.xunlei),
        () => request!.run(action),
      );
    } on XunleiVerificationRequired catch (e) {
      if (mounted && !leaving) {
        setState(() {
          verification = e;
          smsMode = true;
          challenge = null;
          code.clear();
          if (XunleiLoginService.isMobile(username.text)) {
            mobile.text = username.text;
          }
          error = e.message;
        });
      }
    } catch (e) {
      if (mounted && !leaving) setState(() => error = errorText(e));
    } finally {
      if (mounted && !leaving) setState(() => working = false);
    }
  }

  Future<void> _login({bool sms = false}) => _action(() async {
    await widget.services.login.submit(
      CloudPlatform.xunlei,
      (_) => sms
          ? widget.services.cloud.xunleiLogin.verifySms(challenge!, code.text)
          : widget.services.cloud.xunleiLogin.password(
              username.text,
              password.text,
              rememberPassword: true,
            ),
      accountId: widget.accountId,
    );
    if (!mounted || leaving) return;
    completed = true;
    password.clear();
    code.clear();
    if (mounted) Navigator.pop(context);
  });
  Future<void> _send() => _action(() async {
    challenge = await widget.services.cloud.xunleiLogin.sendSms(mobile.text);
    code.clear();
    cooldown = 60;
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || cooldown <= 0) {
        t.cancel();
        return;
      }
      setState(() => cooldown--);
    });
  });
  Future<void> _verifyWeb() async {
    final value = verification;
    if (value == null || !XunleiProtocol.trustedPage(value.url)) return;
    final verified = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => XunleiVerificationPage(widget.services, value),
      ),
    );
    if (verified == true && mounted) await _login();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '迅雷网盘登录',
    actions: [
      TextButton(
        key: const ValueKey('xunlei-login-web'),
        onPressed: _useWeb,
        child: const Text('网页登录'),
      ),
    ],
    child: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: 560,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Row(
              children: [
                PlatformMark(platform: CloudPlatform.xunlei),
                SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '登录后浏览和管理网盘文件',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('账号密码')),
                ButtonSegment(value: true, label: Text('短信登录')),
              ],
              selected: {smsMode},
              onSelectionChanged: working
                  ? null
                  : (v) => setState(() {
                      smsMode = v.first;
                      error = '';
                    }),
            ),
            const SizedBox(height: 24),
            if (!smsMode) ...[
              TextField(
                key: const ValueKey('xunlei-login-username'),
                controller: username,
                enabled: !working,
                decoration: const InputDecoration(labelText: '手机号 / 邮箱'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('xunlei-login-password'),
                controller: password,
                enabled: !working,
                obscureText: !visible,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '密码',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => visible = !visible),
                    icon: Icon(
                      visible ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const ValueKey('xunlei-login-submit'),
                onPressed: working ? null : _login,
                child: const Text('登录'),
              ),
            ] else ...[
              TextField(
                controller: mobile,
                enabled: !working,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: '账号绑定的手机号'),
                onChanged: (_) {
                  challenge = null;
                  code.clear();
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: working || cooldown > 0 ? null : _send,
                child: Text(cooldown > 0 ? '$cooldown 秒后重新发送' : '发送验证码'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: code,
                enabled: !working,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '短信验证码'),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: working || challenge == null
                    ? null
                    : () => _login(sms: true),
                child: const Text('验证并登录'),
              ),
              if (verification?.url.isNotEmpty == true)
                OutlinedButton(
                  onPressed: working ? null : _verifyWeb,
                  child: const Text('打开网页安全验证'),
                ),
            ],
            if (working)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: LinearProgressIndicator(),
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(error, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 20),
            Text(
              smsMode ? '短信需由你主动发送并填写验证码。' : '账号密码加密保存，下次自动保持登录，需要安全验证时会提示你完成。',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
      ),
    ),
  );
}

class XunleiVerificationPage extends StatefulWidget {
  const XunleiVerificationPage(this.services, this.challenge, {super.key});
  final AppServices services;
  final XunleiVerificationRequired challenge;
  @override
  State<XunleiVerificationPage> createState() => _XunleiVerificationPageState();
}

class _XunleiVerificationPageState extends State<XunleiVerificationPage> {
  InAppWebViewController? controller;
  WebViewEnvironment? environment;
  Timer? timer;
  bool ready = false, finished = false, polling = false;
  String error = '';
  late final sign = XunleiProtocol.deviceSign(widget.challenge.deviceId);
  late final url = XunleiProtocol.withDeviceSign(widget.challenge.url, sign);
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      environment = await widget.services.webEnvironment();
      if (mounted) setState(() => ready = true);
      timer = Timer.periodic(const Duration(milliseconds: 700), (_) => _poll());
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    }
  }

  void _finish() {
    if (!finished && mounted) {
      finished = true;
      Navigator.pop(context, true);
    }
  }

  Future<void> _poll() async {
    if (!mounted || finished || polling || controller == null) return;
    polling = true;
    try {
      if (!XunleiProtocol.trustedPage(
        (await controller!.getUrl())?.toString(),
      )) {
        return;
      }
      final signal = await controller!.evaluateJavascript(
        source: "window.__asterVerifySignal || ''",
      );
      if (!XunleiProtocol.trustedPage(
        (await controller!.getUrl())?.toString(),
      )) {
        return;
      }
      if (signal == 'verified') _finish();
      if (signal == 'closed' && mounted) {
        finished = true;
        Navigator.pop(context, false);
      }
    } catch (_) {
      /* Navigation may replace the document during polling. */
    } finally {
      polling = false;
    }
  }

  String get script =>
      '''
    (function(){
      if(window.__asterVerificationInstalled)return;
      window.__asterVerificationInstalled=true; window.__asterVerifySignal='';
      window.XLJSWebViewBridge={onVerifyResult:function(){window.__asterVerifySignal='verified';},close:function(){window.__asterVerifySignal='closed';}};
      window.env='android'; window.appid='40'; window.appName='ANDROID-com.xunlei.downloadprovider';
      window.clientVersion=${jsonEncode(XunleiProtocol.version)}; window.deviceid=${jsonEncode(sign)};
      window.platformVersion='10'; window.event='login3';
      function initialize(){
        if(!window.XlCaptcha||typeof window.XlCaptcha.init!=='function')return false;
        try{
          if(typeof window.XlCaptcha.isMobileSDK!=='function')window.XlCaptcha.isMobileSDK=function(){return false;};
          window.XlCaptcha.init({appid:'40',appName:window.appName,clientVersion:window.clientVersion,
            deviceid:window.deviceid,event:'login3',platformVersion:'10',IFRAME_BOX_ID:'captch-wrap',
            VERTIFYSUCCFUNC:function(){window.XLJSWebViewBridge.onVerifyResult();}});
          return true;
        }catch(e){return false;}
      }
      if(!initialize()){var t=setInterval(function(){if(initialize())clearInterval(t);},120);setTimeout(function(){clearInterval(t);},10000);}
    })();
  ''';
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '迅雷安全验证',
    actions: [TextButton(onPressed: _finish, child: const Text('已完成验证'))],
    child: error.isNotEmpty
        ? EmptyPanel('验证页面不可用', error)
        : !ready
        ? const Center(child: CircularProgressIndicator())
        : InAppWebView(
            webViewEnvironment: environment,
            initialUrlRequest: URLRequest(url: WebUri(url)),
            initialSettings: webSettings(),
            initialUserScripts: UnmodifiableListView([
              desktopLoginUserScript(),
            ]),
            onWebViewCreated: (web) => controller = web,
            onLoadStop: (web, page) async {
              if (XunleiProtocol.trustedPage(page?.toString()) &&
                  XunleiProtocol.trustedPage(
                    (await web.getUrl())?.toString(),
                  )) {
                await web.evaluateJavascript(
                  source: desktopLoginViewportScript,
                );
                await web.evaluateJavascript(source: script);
              }
            },
            shouldOverrideUrlLoading: (web, action) async {
              final target = action.request.url?.toString();
              if (action.isForMainFrame &&
                  XunleiProtocol.trustedCallback(target)) {
                if (XunleiProtocol.trustedPage(
                  (await web.getUrl())?.toString(),
                )) {
                  _finish();
                }
                return NavigationActionPolicy.CANCEL;
              }
              return XunleiProtocol.trustedPage(target)
                  ? NavigationActionPolicy.ALLOW
                  : NavigationActionPolicy.CANCEL;
            },
          ),
  );
}
