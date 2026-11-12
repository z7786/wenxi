import 'dart:collection';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../app_services.dart';
import '../data/providers/guangya_login.dart';
import '../domain/models.dart';
import 'common.dart';
import 'login_webview.dart';

class GuangyaVerificationPage extends StatefulWidget {
  const GuangyaVerificationPage(
    this.services,
    this.challenge, {
    super.key,
    this.userAgent,
  });
  final AppServices services;
  final GuangyaCaptchaChallenge challenge;
  final String? userAgent;

  @override
  State<GuangyaVerificationPage> createState() =>
      _GuangyaVerificationPageState();
}

class _GuangyaVerificationPageState extends State<GuangyaVerificationPage> {
  WebViewEnvironment? _environment;
  bool _ready = false, _finished = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      widget.services.control.checkCloud(CloudPlatform.guangya);
      _environment = await widget.services.webEnvironment();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _error = '验证页面初始化失败，请返回后重试或切换网页登录');
    }
  }

  bool _callback(String? url) {
    if (!mounted || _finished) return false;
    final token = widget.challenge.tokenFromCallback(url);
    if (token == null) return false;
    _finished = true;
    Navigator.pop(context, token);
    return true;
  }

  @override
  Widget build(BuildContext context) => PageFrame(
    title: '光鸭安全验证',
    child: Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('请完成官方安全验证，完成后将自动继续登录'),
        ),
        Expanded(
          child: _error.isNotEmpty
              ? EmptyPanel('验证页面不可用', _error, icon: CupertinoIcons.lock_shield)
              : !_ready
              ? const Center(child: CircularProgressIndicator())
              : InAppWebView(
                  webViewEnvironment: _environment,
                  initialUrlRequest: URLRequest(
                    url: WebUri.uri(widget.challenge.url),
                  ),
                  initialSettings: webSettings(
                    userAgent:
                        widget.userAgent ??
                        widget.services.cloud.browserUa.selected(
                          CloudPlatform.guangya,
                        ),
                  ),
                  initialUserScripts: UnmodifiableListView([
                    desktopLoginUserScript(),
                  ]),
                  onLoadStop: (web, url) async {
                    if (_callback(url?.toString()) || !mounted) return;
                    try {
                      await web.evaluateJavascript(
                        source: desktopLoginViewportScript,
                      );
                    } catch (_) {
                      // The verification redirect may replace the document.
                    }
                  },
                  onReceivedError: (_, request, _) {
                    if (mounted &&
                        !_finished &&
                        request.isForMainFrame == true) {
                      setState(() => _error = '验证网页加载失败，请返回后重试');
                    }
                  },
                  shouldOverrideUrlLoading: (_, action) async {
                    if (!mounted || _finished) {
                      return NavigationActionPolicy.CANCEL;
                    }
                    final url = action.request.url?.toString();
                    if (action.isForMainFrame && _callback(url)) {
                      return NavigationActionPolicy.CANCEL;
                    }
                    return GuangyaCaptchaChallenge.trustedPage(url)
                        ? NavigationActionPolicy.ALLOW
                        : NavigationActionPolicy.CANCEL;
                  },
                ),
        ),
      ],
    ),
  );
}
