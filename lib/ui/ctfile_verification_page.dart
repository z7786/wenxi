import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../domain/auth.dart';
import '../domain/ctfile_captcha.dart';
import '../domain/models.dart';
import 'common.dart';
import 'login_webview.dart';

class CtfileVerificationPage extends StatefulWidget {
  const CtfileVerificationPage(this.services, this.challenge, {super.key});
  final AppServices services;
  final CtfileCaptchaChallenge challenge;

  @override
  State<CtfileVerificationPage> createState() => _CtfileVerificationPageState();
}

class _CtfileVerificationPageState extends State<CtfileVerificationPage> {
  WebViewEnvironment? _environment;
  InAppWebViewController? _web;
  Timer? _timer;
  final _answer = TextEditingController();
  String _imageId = newId().replaceAll('-', '');
  bool _ready = false, _finished = false, _checking = false;
  String _error = '', _status = '正在加载城通安全验证…';
  int _generation = 0;
  bool get _active => mounted && !_finished;
  bool _sameWeb(InAppWebViewController? web) =>
      web != null && _web != null && identical(_web!.platform, web.platform);

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final generation = _generation;
    try {
      widget.services.control.checkCloud(CloudPlatform.ctfile);
      if (!widget.challenge.isImage) {
        _environment = await widget.services.webEnvironment();
      }
      if (_active && generation == _generation) {
        setState(() => _ready = true);
      }
    } catch (_) {
      if (_active && generation == _generation) {
        setState(() => _error = '城通验证初始化失败，请刷新重试');
      }
    }
  }

  void _finish(CtfileCaptchaProof proof) {
    if (!_active) return;
    _stop();
    Navigator.pop(context, proof);
  }

  Future<void> _capture() async {
    final web = _web;
    if (!_active || _checking || web == null) return;
    _checking = true;
    try {
      final url = (await web.getUrl())?.toString();
      if (!_active || !_sameWeb(web) || !widget.challenge.trustedPage(url)) {
        return;
      }
      final result = await web.evaluateJavascript(
        source: widget.challenge.captureScript,
      );
      if (!_active || !_sameWeb(web) || result is! String || result.isEmpty) {
        return;
      }
      final currentUrl = (await web.getUrl())?.toString();
      if (!_active ||
          !_sameWeb(web) ||
          !widget.challenge.trustedPage(currentUrl)) {
        return;
      }
      final data = asJson(jsonDecode(result));
      final proof = widget.challenge.proofFromMessage(data);
      if (proof != null) {
        _finish(proof);
        return;
      }
      final status = switch (data.str('event')) {
        'ready' || 'verifying' => '正在完成城通安全验证…',
        'interactive' => '请按官方页面提示完成安全验证',
        'expired' => '验证码已过期，正在重新验证…',
        'error' => '安全验证未完成，请在页面重试或刷新验证',
        _ => '',
      };
      if (status.isNotEmpty && status != _status) {
        setState(() => _status = status);
      }
    } catch (_) {
      // A document reload can replace the widget during capture; poll again.
    } finally {
      _checking = false;
    }
  }

  void _stop() {
    _finished = true;
    _generation++;
    _timer?.cancel();
    _web = null;
  }

  void _reload() {
    if (!_active) return;
    _timer?.cancel();
    _web = null;
    _generation++;
    _answer.clear();
    setState(() {
      _ready = false;
      _error = '';
      _status = '正在加载城通安全验证…';
      _imageId = newId().replaceAll('-', '');
    });
    unawaited(_initialize());
  }

  void _submitImage() {
    try {
      _finish(widget.challenge.imageProof(_imageId, _answer.text));
    } on AppException catch (error) {
      setState(() => _error = error.message);
    }
  }

  Widget _image() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: _reload,
              child: Image.network(
                widget.challenge.imageUrl(_imageId).toString(),
                headers: widget.challenge.imageHeaders,
                height: 100,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox(
                  height: 100,
                  child: Center(child: Text('验证码加载失败，点击刷新')),
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const ValueKey('ctfile-captcha-answer'),
              controller: _answer,
              autofocus: true,
              maxLength: 5,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
              ],
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: '输入图片中的五位验证码'),
              onSubmitted: (_) => _submitImage(),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton(
              key: const ValueKey('ctfile-captcha-submit'),
              onPressed: _submitImage,
              child: const Text('确认并继续登录'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _browser() => InAppWebView(
    key: ValueKey('ctfile-captcha-web-$_generation'),
    webViewEnvironment: _environment,
    initialUrlRequest: URLRequest(url: WebUri.uri(widget.challenge.url)),
    initialSettings: webSettings(
      userAgent: WebLoginTarget.desktopUserAgent,
      desktopMode: false,
    ),
    initialUserScripts: UnmodifiableListView([
      UserScript(
        source: widget.challenge.installScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
    ]),
    onWebViewCreated: (web) {
      if (_active) _web = web;
    },
    onLoadStop: (web, url) async {
      if (!_active ||
          !_sameWeb(web) ||
          !widget.challenge.trustedPage(url?.toString())) {
        return;
      }
      try {
        await web.evaluateJavascript(source: widget.challenge.installScript);
      } catch (_) {
        // A refresh can replace the document during the load callback.
      }
      if (!_active || !_sameWeb(web)) return;
      _web = web;
      _timer?.cancel();
      _timer = Timer.periodic(
        const Duration(milliseconds: 350),
        (_) => unawaited(_capture()),
      );
      unawaited(_capture());
    },
    onReceivedError: (web, request, _) {
      if (_active && _sameWeb(web) && request.isForMainFrame == true) {
        _timer?.cancel();
        setState(() => _error = '城通安全验证页面加载失败，请刷新重试');
      }
    },
    shouldOverrideUrlLoading: (_, action) async {
      if (!_active) return NavigationActionPolicy.CANCEL;
      if (action.isForMainFrame) {
        return widget.challenge.trustedPage(action.request.url?.toString())
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      }
      // Official Turnstile uses a Cloudflare iframe for human interaction.
      final uri = action.request.url?.uriValue;
      return uri != null && uri.scheme == 'https'
          ? NavigationActionPolicy.ALLOW
          : NavigationActionPolicy.CANCEL;
    },
  );

  @override
  void dispose() {
    _stop();
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _stop();
    },
    child: PageFrame(
      title: '城通安全验证',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(widget.challenge.message),
          ),
          Expanded(
            child: !_ready
                ? _error.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : EmptyPanel(
                          '验证页面不可用',
                          _error,
                          icon: CupertinoIcons.lock_shield,
                        )
                : widget.challenge.isImage
                ? _image()
                : _error.isNotEmpty
                ? EmptyPanel(
                    '验证页面不可用',
                    _error,
                    icon: CupertinoIcons.lock_shield,
                  )
                : _browser(),
          ),
          if (!widget.challenge.isImage)
            Padding(padding: const EdgeInsets.all(12), child: Text(_status)),
          TextButton.icon(
            key: const ValueKey('ctfile-captcha-refresh'),
            onPressed: _reload,
            icon: const Icon(CupertinoIcons.refresh),
            label: const Text('刷新验证'),
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}
