import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/parser_rules/password_document.dart';
import '../data/parser_rules/password_web_flow.dart';
import '../data/parser_rules/site_protection.dart';
import '../diagnostics/app_log.dart';
import '../platform/windows_webview.dart';
import 'common.dart';
import 'login_webview.dart';

class ParserPasswordWebPage extends StatefulWidget {
  const ParserPasswordWebPage({
    super.key,
    required this.siteId,
    required this.siteName,
    required this.flow,
    required this.directory,
    this.resolveUcPassword,
    this.documentHttp,
  });
  final String siteId, siteName;
  final ParserPasswordWebFlow flow;
  final Directory directory;
  final Future<String> Function(String command)? resolveUcPassword;
  final JsonHttp? documentHttp;

  static bool get isSupported =>
      !kIsWeb &&
      const {
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      }.contains(defaultTargetPlatform);

  @override
  State<ParserPasswordWebPage> createState() => _ParserPasswordWebPageState();
}

class _ParserPasswordWebPageState extends State<ParserPasswordWebPage> {
  InAppWebViewController? _web;
  WindowsWebViewHost? _host;
  WebViewEnvironment? _environment;
  Timer? _timer;
  RequestScope? _ucScope;
  RequestScope? _documentScope;
  ParserPasswordDocument? _compatibilityDocument;
  bool _compatibilityAttempted = false;
  String _verificationError = '';
  String _ucCommand = '', _ucPassword = '', _ucError = '';
  int _ucAttempts = 0;
  final _elapsed = Stopwatch();
  int _generation = 0;
  bool _ready = false,
      _documentReady = false,
      _polling = false,
      _halted = false,
      _closing = false,
      _agentReady = false,
      _allowBootstrapBlank = false;
  String? _userAgent;
  int? _pageHttpStatus;
  String _pageCfRay = '';
  String _status = '正在打开密码获取页面…';
  double _progress = 0;
  bool get _active => mounted && !_closing;
  bool get _needsNativeAgent => widget.flow.userAgent == 'uc';
  bool _isBootstrapBlank(Uri? uri) =>
      _allowBootstrapBlank && uri?.toString() == 'about:blank';
  InAppWebViewSettings get _settings =>
      webSettings(userAgent: _userAgent, desktopMode: false)
        ..userAgent = _userAgent
        // Android implements incognito by deleting the process-wide Cookie
        // jar. Keep this site's verification session when reopening the page.
        ..incognito = defaultTargetPlatform == TargetPlatform.windows
        ..cacheEnabled = true
        ..cacheMode = CacheMode.LOAD_DEFAULT
        ..requestedWithHeaderOriginAllowList = <String>{}
        ..useShouldInterceptRequest =
            defaultTargetPlatform == TargetPlatform.android &&
            widget.documentHttp != null
        ..useOnRenderProcessGone = true
        ..supportMultipleWindows = false
        ..javaScriptCanOpenWindowsAutomatically = false;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  void _record(
    String stage, {
    String? errorType,
    Map<String, Object?> details = const {},
  }) {
    DiagnosticLog.event(
      'parser.password_web.$stage',
      fields: {
        'siteId': widget.siteId,
        'host': Uri.parse(widget.flow.url).host,
        'elapsedMs': _elapsed.elapsedMilliseconds,
        'errorType': ?errorType,
        ...details,
      },
    );
  }

  Future<void> _prepare() async {
    final generation = ++_generation;
    try {
      if (!ParserPasswordWebPage.isSupported) {
        throw UnsupportedError('webview');
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        _host ??= WindowsWebViewHost(
          primaryFolder: '${widget.directory.path}/password-webview',
          recoveryFolder: '${widget.directory.path}/password-webview-recovery',
        );
        _environment = await _host!.get();
      }
      if (!_active || generation != _generation) return;
      _agentReady = !_needsNativeAgent;
      _allowBootstrapBlank = _needsNativeAgent;
      _userAgent = _needsNativeAgent ? null : widget.flow.resolveUserAgent('');
      setState(() => _ready = true);
      if (_agentReady) _startPolling();
      _record('opened');
    } catch (error) {
      if (!_active || generation != _generation) return;
      _record('initialize_failed', errorType: error.runtimeType.toString());
      setState(
        () => _status = defaultTargetPlatform == TargetPlatform.windows
            ? '网页组件启动失败，请检查 Edge WebView2 Runtime，或返回手动填写密码'
            : '网页组件启动失败，可重新加载或返回手动填写密码',
      );
    }
  }

  Future<void> _loadPage(InAppWebViewController web) async {
    final generation = _generation;
    bool current() => _active && generation == _generation && _web == web;
    try {
      if (!_agentReady) {
        // Windows has no native static getDefaultUserAgent implementation.
        // Read the real engine settings from an empty, created browser first.
        final settings = await web.getSettings().timeout(
          const Duration(seconds: 10),
        );
        if (!current()) return;
        final nativeAgent = settings?.userAgent;
        if (nativeAgent == null || nativeAgent.trim().isEmpty) {
          throw StateError('Native browser user agent unavailable');
        }
        _userAgent = widget.flow.resolveUserAgent(nativeAgent);
        await web
            .setSettings(settings: _settings)
            .timeout(const Duration(seconds: 10));
        if (!current()) return;
        _agentReady = true;
        _record(
          'browser_ready',
          details: {
            'engineVersion':
                RegExp(
                  r'(?:Chrome|Chromium)/([0-9.]+)',
                ).firstMatch(nativeAgent)?.group(1) ??
                'unknown',
            'androidVersion':
                RegExp(
                  r'Android ([0-9.]+)',
                ).firstMatch(nativeAgent)?.group(1) ??
                'not_android',
          },
        );
      }
      _startPolling();
      await web
          .loadUrl(urlRequest: URLRequest(url: WebUri(widget.flow.url)))
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      if (!current()) return;
      _timer?.cancel();
      _record('load_failed', errorType: error.runtimeType.toString());
      setState(() {
        _progress = 1;
        _status = '网页加载失败，请重新加载后再试，或返回手动填写密码';
      });
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _halted = false;
    _elapsed
      ..reset()
      ..start();
    _timer = Timer.periodic(widget.flow.interval, (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (!_active || _polling || _halted) return;
    if (_elapsed.elapsed >= widget.flow.timeout) {
      _timer?.cancel();
      ++_generation;
      _clearUc();
      _documentScope?.cancel();
      _compatibilityDocument = null;
      _record('timeout');
      setState(() => _status = '获取超时，请重新加载后再试，或返回手动填写密码');
      return;
    }
    final web = _web, generation = _generation;
    if (web == null || !_documentReady) return;
    _polling = true;
    try {
      final uri = await web.getUrl().timeout(const Duration(seconds: 4));
      if (!_active || generation != _generation || !widget.flow.allows(uri)) {
        return;
      }
      final raw = await web
          .evaluateJavascript(
            source: widget.flow.evaluation(
              ucCommand: _ucCommand,
              ucPassword: _ucPassword,
              ucCommandSupported: widget.resolveUcPassword != null,
            ),
          )
          .timeout(const Duration(seconds: 8));
      if (!mounted || _closing || generation != _generation) return;
      final result = ParserPasswordWebResult.read(raw);
      if (result.status == 'ucPassword') {
        _readUcPassword(result.command);
      } else if (result.status == 'success') {
        _record('captured');
        _stop();
        Navigator.pop(context, result.password);
      } else {
        if ((_verificationError.isEmpty || result.status == 'error') &&
            result.message.isNotEmpty &&
            result.message != _status) {
          setState(() => _status = result.message);
        }
        if (result.status == 'error') {
          _halted = true;
          ++_generation;
          _timer?.cancel();
          _clearUc();
          final blocked = result.code == 'CF_BLOCKED';
          _record(
            blocked ? 'blocked' : 'recipe_failed',
            details: {
              if (blocked) 'code': result.code,
              if (blocked && _pageHttpStatus != null)
                'httpStatus': _pageHttpStatus,
              if (blocked && (result.cfRay.isNotEmpty || _pageCfRay.isNotEmpty))
                'cfRay': result.cfRay.isNotEmpty ? result.cfRay : _pageCfRay,
            },
          );
          if (blocked &&
              !_compatibilityAttempted &&
              defaultTargetPlatform == TargetPlatform.android &&
              widget.documentHttp != null &&
              _userAgent?.isNotEmpty == true) {
            unawaited(_loadCompatibilityDocument());
          }
          if (result.message.isEmpty) setState(() => _status = '获取失败，请重新加载后再试');
        }
      }
    } catch (error) {
      if (!_active || generation != _generation) return;
      _timer?.cancel();
      _clearUc();
      _record('read_failed', errorType: error.runtimeType.toString());
      setState(() => _status = '读取网页失败，请重新加载后再试');
    } finally {
      _polling = false;
    }
  }

  void _clearUc() {
    _ucScope?.cancel();
    _ucScope = null;
    _ucCommand = _ucPassword = _ucError = '';
  }

  void _readUcPassword(String command) {
    final resolve = widget.resolveUcPassword;
    if (!widget.flow.usesUcCommand || resolve == null) {
      setState(() => _status = '当前取密规则未启用 UC 口令解析，请手动填写访问密码');
      return;
    }
    if (command == _ucCommand) {
      if (_ucError.isNotEmpty) setState(() => _status = _ucError);
      return;
    }
    _clearUc();
    _ucCommand = command;
    if (++_ucAttempts > 3) {
      _ucError = '网页口令多次变化，请重新加载后再试';
      setState(() => _status = _ucError);
      return;
    }
    final scope = _ucScope = RequestScope(), generation = _generation;
    bool current() =>
        _active &&
        generation == _generation &&
        identical(_ucScope, scope) &&
        !scope.token.isCancelled;
    setState(() => _status = '正在解析 UC 口令并读取首行中文密码…');
    _record('uc_started');
    unawaited(() async {
      try {
        final password = await scope
            .run(() => RequestScope.cancellable(resolve(command)))
            .timeout(const Duration(seconds: 45));
        if (!current()) return;
        final uri = await _web?.getUrl().timeout(const Duration(seconds: 4));
        if (!current() || !widget.flow.allows(uri)) return;
        require(
          ParserPasswordWebResult.validPassword(password),
          'UC 文件没有有效的访问密码',
        );
        _ucPassword = password;
        _record('uc_captured');
        setState(() => _status = '已读取访问密码，请在网页中完成验证');
      } catch (error) {
        if (!current()) return;
        _record('uc_failed', errorType: error.runtimeType.toString());
        _ucError = error is AppException ? error.message : 'UC 口令取密失败，请重新加载后再试';
        setState(() => _status = _ucError);
      } finally {
        if (identical(_ucScope, scope)) _ucScope = null;
        scope.cancel();
      }
    }());
  }

  void _stop() {
    _closing = true;
    _generation++;
    _timer?.cancel();
    _clearUc();
    _documentScope?.cancel();
    _compatibilityDocument = null;
    _elapsed.stop();
  }

  Future<void> _reload() async {
    if (!_active) return;
    ++_generation;
    _timer?.cancel();
    _clearUc();
    _documentScope?.cancel();
    _compatibilityDocument = null;
    _compatibilityAttempted = false;
    _verificationError = '';
    _ucAttempts = 0;
    setState(() {
      _documentReady = false;
      _progress = 0;
      _status = '正在重新加载…';
    });
    final web = _web;
    if (web == null) return _prepare();
    await _loadPage(web);
  }

  Future<void> _loadCompatibilityDocument() async {
    final web = _web, http = widget.documentHttp, agent = _userAgent;
    if (web == null || http == null || agent == null || !_active) return;
    _compatibilityAttempted = true;
    final generation = _generation;
    final scope = _documentScope = RequestScope();
    bool current() =>
        _active &&
        generation == _generation &&
        identical(_documentScope, scope) &&
        !scope.token.isCancelled &&
        _web == web;
    setState(() => _status = '正在尝试兼容方式打开页面…');
    _record('compatibility_started');
    try {
      final document = await scope
          .run(() => ParserPasswordDocument.load(widget.flow, http, agent))
          .timeout(const Duration(seconds: 25));
      if (!current()) return;
      _compatibilityDocument = document;
      _documentReady = false;
      _verificationError = '';
      await _loadPage(web);
    } catch (error) {
      if (!current()) return;
      _compatibilityDocument = null;
      _record('compatibility_failed', errorType: error.runtimeType.toString());
      setState(() => _status = '兼容加载未能打开页面，请使用浏览器打开后取得密码');
    } finally {
      scope.cancel();
      if (_documentScope == scope) _documentScope = null;
    }
  }

  Future<void> _openBrowser() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(widget.flow.url),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // A missing browser can be reported as false or a platform exception.
    }
    if (!mounted || _closing) return;
    message(
      context,
      opened
          ? '请在浏览器中完成验证，取得最终解析密码后返回填写；此站可能需要 UC 浏览器'
          : '无法打开浏览器，请复制网址到 UC 浏览器打开',
    );
  }

  Future<void> _copyUrl() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.flow.url));
      if (mounted && !_closing) message(context, '网址已复制，可粘贴到 UC 浏览器打开');
    } catch (_) {
      if (mounted && !_closing) message(context, '复制失败，请稍后重试');
    }
  }

  @override
  void dispose() {
    _stop();
    final host = _host;
    // The child platform view is removed first; release its environment on the
    // next event-loop turn, after the widget's native disposal was requested.
    if (host != null) {
      unawaited(
        Future<void>(() async {
          try {
            await host.close();
          } catch (_) {
            /* Already released. */
          }
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _stop();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.siteName} · 获取密码',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            key: const ValueKey('password-web-reload'),
            tooltip: '重新加载',
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回填写'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 15),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        Uri.parse(widget.flow.url).host,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(_status, key: const ValueKey('password-web-status')),
                const SizedBox(height: 4),
                Text(
                  widget.flow.sharePassword
                      ? '在下方完成验证，获取成功后会自动继续解析；有效密码会自动共享。'
                      : '在下方完成验证，获取成功后会自动继续解析。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('password-web-external'),
                      onPressed: _openBrowser,
                      icon: const Icon(
                        Icons.open_in_browser_outlined,
                        size: 17,
                      ),
                      label: const Text('浏览器打开'),
                    ),
                    TextButton.icon(
                      key: const ValueKey('password-web-copy-url'),
                      onPressed: _copyUrl,
                      icon: const Icon(Icons.copy_outlined, size: 17),
                      label: const Text('复制网址'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_ready && _progress < 1)
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
          Expanded(
            child: !_ready
                ? Center(
                    child: TextButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重新加载'),
                    ),
                  )
                : InAppWebView(
                    key: const ValueKey('parser-password-webview'),
                    webViewEnvironment: _environment,
                    initialUrlRequest: URLRequest(
                      url: WebUri(
                        _needsNativeAgent ? 'about:blank' : widget.flow.url,
                      ),
                    ),
                    initialSettings: _settings,
                    shouldInterceptRequest: (_, request) async {
                      final document = _compatibilityDocument;
                      if (!_active ||
                          document == null ||
                          !document.matches(
                            request.url,
                            mainFrame: request.isForMainFrame == true,
                            method: request.method ?? '',
                          )) {
                        return null;
                      }
                      _compatibilityDocument = null;
                      _record('compatibility_loaded');
                      return WebResourceResponse(
                        statusCode: 200,
                        reasonPhrase: 'OK',
                        contentType: 'text/html',
                        contentEncoding: 'utf-8',
                        headers: document.headers,
                        data: document.data,
                      );
                    },
                    onConsoleMessage: (_, message) {
                      if (!_active) return;
                      final code = RegExp(
                        r'\[Cloudflare Turnstile\] Error:\s*(\d{6})\b',
                      ).firstMatch(message.message)?.group(1);
                      if (code == null || code == _verificationError) return;
                      _verificationError = code;
                      _record('verification_failed', details: {'code': code});
                      setState(() => _status = '网页人机验证失败（$code），可重新加载或使用浏览器打开');
                    },
                    onWebViewCreated: (web) {
                      if (!_active) return;
                      _web = web;
                      if (_needsNativeAgent) unawaited(_loadPage(web));
                    },
                    onLoadStart: (web, uri) {
                      if (!_active) return;
                      _documentReady = false;
                      if (_isBootstrapBlank(uri)) return;
                      _generation++;
                      _documentScope?.cancel();
                      if (uri?.toString() != _compatibilityDocument?.url) {
                        _compatibilityDocument = null;
                      }
                      _verificationError = '';
                      _clearUc();
                      _pageHttpStatus = null;
                      _pageCfRay = '';
                      _allowBootstrapBlank = false;
                      if (uri != null && !widget.flow.allows(uri)) {
                        _compatibilityDocument = null;
                        unawaited(web.stopLoading().catchError((_) {}));
                        setState(() => _status = '网页跳转到了未配置的站点，请刷新规则后重试');
                      }
                    },
                    onLoadStop: (web, uri) {
                      if (!_active || !widget.flow.allows(uri)) return;
                      _compatibilityDocument = null;
                      _allowBootstrapBlank = false;
                      _documentReady = true;
                      unawaited(_poll());
                    },
                    onProgressChanged: (_, value) {
                      if (_active) setState(() => _progress = value / 100);
                    },
                    shouldOverrideUrlLoading: (_, action) async {
                      final uri = action.request.url;
                      final allowed = action.isForMainFrame
                          ? widget.flow.allows(uri) || _isBootstrapBlank(uri)
                          : uri != null &&
                                {'https', 'about'}.contains(uri.scheme);
                      return _active && allowed
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onCreateWindow: (_, _) async => false,
                    onPermissionRequest: (_, request) async =>
                        PermissionResponse(
                          resources: request.resources,
                          action: PermissionResponseAction.DENY,
                        ),
                    onReceivedHttpError: (_, request, response) {
                      final uri = request.url;
                      if (!_active ||
                          !(widget.flow.allows(uri) ||
                              uri.host == 'challenges.cloudflare.com')) {
                        return;
                      }
                      String header(String key) {
                        for (final entry
                            in (response.headers ?? <String, String>{})
                                .entries) {
                          if (entry.key.toLowerCase() == key) {
                            return entry.value;
                          }
                        }
                        return '';
                      }

                      final ray = ParserSiteProtection.rayId(header('cf-ray'));
                      if (request.isForMainFrame == true) {
                        _pageHttpStatus = response.statusCode;
                        _pageCfRay = ray;
                      }
                      _record(
                        'http_error',
                        details: {
                          'resourceHost': uri.host,
                          'isMainFrame': request.isForMainFrame == true,
                          'httpStatus': ?response.statusCode,
                          if (ray.isNotEmpty) 'cfRay': ray,
                          'cloudflare':
                              header(
                                'server',
                              ).toLowerCase().contains('cloudflare') ||
                              ray.isNotEmpty,
                        },
                      );
                      // HTTP 403 may still contain an interactive challenge.
                      // Let the page load; only its actual block text stops polling.
                    },
                    onReceivedError: (_, request, error) {
                      if (!_active) return;
                      if (request.isForMainFrame != true) {
                        if (request.url.host == 'challenges.cloudflare.com') {
                          _record(
                            'verification_resource_failed',
                            errorType: error.type.toValue(),
                          );
                        }
                        return;
                      }
                      _documentReady = false;
                      _documentScope?.cancel();
                      _compatibilityDocument = null;
                      _clearUc();
                      _record(
                        'network_failed',
                        errorType: error.type.toValue(),
                      );
                      setState(() => _status = '密码页面加载失败，请检查网络后重新加载');
                    },
                    onRenderProcessGone: (_, _) {
                      if (!_active) return;
                      _generation++;
                      _timer?.cancel();
                      _clearUc();
                      _documentScope?.cancel();
                      _compatibilityDocument = null;
                      _web = null;
                      _host?.invalidate(_environment);
                      _record('renderer_stopped');
                      setState(() {
                        _ready = false;
                        _documentReady = false;
                        _status = '网页组件已停止，请重新加载后再试';
                      });
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
