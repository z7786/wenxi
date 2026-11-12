import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_services.dart';
import '../data/http.dart';
import '../data/providers/guangya.dart';
import '../data/providers/guangya_login.dart';
import '../domain/models.dart';
import 'common.dart';
import 'cloud_login_layout.dart';
import 'guangya_verification_page.dart';

class GuangyaSmsLoginPage extends StatefulWidget {
  const GuangyaSmsLoginPage(
    this.services, {
    required this.onUsePassword,
    required this.onUseWeb,
    required this.onUseManual,
    this.accountId,
    super.key,
  });
  final AppServices services;
  final String? accountId;
  final VoidCallback onUsePassword, onUseWeb, onUseManual;

  @override
  State<GuangyaSmsLoginPage> createState() => _GuangyaSmsLoginPageState();
}

class _GuangyaSmsLoginPageState extends State<GuangyaSmsLoginPage> {
  final _mobile = TextEditingController(), _code = TextEditingController();
  GuangyaSmsChallenge? _challenge;
  RequestScope? _sendRequest;
  Timer? _timer;
  DateTime? _resendAt;
  bool _busy = false, _agreed = false, _leaving = false, _completed = false;
  late final _browserUserAgent = widget.services.vault.withAccount(
    CloudPlatform.guangya,
    widget.accountId ??
        widget.services.vault.activeAccountId(CloudPlatform.guangya),
    () => widget.services.cloud.browserUa.selected(CloudPlatform.guangya),
  );
  String _error = '', _status = '';

  int get _seconds => _resendAt == null
      ? 0
      : ((_resendAt!.difference(DateTime.now()).inMilliseconds + 999) ~/ 1000)
            .clamp(0, 60);
  bool get _active => mounted && !_leaving && !_completed;

  @override
  void initState() {
    super.initState();
    final saved = widget.services.vault.credentialFor(
      CloudPlatform.guangya,
      widget.accountId ??
          widget.services.vault.activeAccountId(CloudPlatform.guangya),
    );
    final username = saved?.field('username') ?? '';
    if (GuangyaSmsLogin.validMobile(username)) _mobile.text = username;
    _mobile.addListener(_mobileChanged);
  }

  void _mobileChanged() {
    if (_challenge != null && _challenge!.mobile != _mobile.text.trim()) {
      _challenge = null;
      _code.clear();
    }
  }

  void _cancel() {
    if (_leaving || _completed) return;
    _leaving = true;
    _sendRequest?.cancel();
    widget.services.login.invalidate(CloudPlatform.guangya);
  }

  void _switch(VoidCallback callback) {
    if (!_active) return;
    _cancel();
    _code.clear();
    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext(shouldSave: false);
    callback();
  }

  @override
  void dispose() {
    _cancel();
    _timer?.cancel();
    _code.clear();
    _mobile.dispose();
    _code.dispose();
    super.dispose();
  }

  void _setStatus(String value) {
    if (_active) setState(() => _status = value);
  }

  Future<String?> _captcha(GuangyaCaptchaChallenge challenge) async {
    if (!_active) return null;
    return Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => GuangyaVerificationPage(
          widget.services,
          challenge,
          userAgent: _browserUserAgent,
        ),
      ),
    );
  }

  bool _validate() {
    final error = !GuangyaSmsLogin.validMobile(_mobile.text)
        ? '请输入正确的手机号'
        : !_agreed
        ? '请先阅读并同意光鸭用户协议和隐私政策'
        : '';
    if (error.isEmpty) return true;
    setState(() => _error = error);
    return false;
  }

  Future<void> _send() async {
    if (!_active || _busy || _seconds > 0 || !_validate()) return;
    final mobile = _mobile.text.trim(), request = RequestScope();
    _sendRequest = request;
    setState(() {
      _busy = true;
      _error = '';
      _status = '正在发送验证码…';
    });
    try {
      widget.services.control.checkCloud(CloudPlatform.guangya);
      final challenge = await request.run(
        () => widget.services.cloud.browserUa.run(
          CloudPlatform.guangya,
          () => GuangyaSmsLogin(
            widget.services.cloud.browserHttp(CloudPlatform.guangya),
          ).sendSms(mobile, verifyCaptcha: _captcha, onStatus: _setStatus),
          userAgent: _browserUserAgent,
          locked: true,
        ),
      );
      if (!_active || mobile != _mobile.text.trim()) return;
      _challenge = challenge;
      _code.clear();
      _resendAt = DateTime.now().add(const Duration(seconds: 60));
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!_active || _seconds == 0) timer.cancel();
        if (_active) setState(() {});
      });
      _setStatus('验证码已发送，请查看手机短信');
    } catch (error) {
      if (_active) setState(() => _error = errorText(error));
    } finally {
      if (identical(_sendRequest, request)) _sendRequest = null;
      if (_active) setState(() => _busy = false);
    }
  }

  Future<void> _login() async {
    if (!_active || _busy || !_validate()) return;
    final challenge = _challenge;
    if (challenge == null || challenge.mobile != _mobile.text.trim()) {
      setState(() => _error = '请先获取当前手机号的验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _status = '正在登录…';
    });
    FocusScope.of(context).unfocus();
    try {
      final services = widget.services;
      await services.login.submit(
        CloudPlatform.guangya,
        (_) async {
          final candidate =
              await GuangyaSmsLogin(
                services.cloud.browserHttp(CloudPlatform.guangya),
              ).sms(
                challenge,
                _code.text,
                verifyCaptcha: _captcha,
                onStatus: _setStatus,
              );
          RequestScope.checkpoint();
          _setStatus('正在读取光鸭账号…');
          return (services.cloud.connector(CloudPlatform.guangya)
                  as GuangyaConnector)
              .authenticate(candidate);
        },
        accountId: widget.accountId,
        browserUserAgent: _browserUserAgent,
      );
      if (!mounted || !_active) return;
      _completed = true;
      _code.clear();
      TextInput.finishAutofillContext(shouldSave: false);
      message(context, '光鸭登录成功');
      Navigator.pop(context);
    } catch (error) {
      if (_active) setState(() => _error = errorText(error));
    } finally {
      if (_active) setState(() => _busy = false);
    }
  }

  Future<void> _policy(String path) async {
    try {
      final opened = await launchUrl(
        Uri.parse('https://app.guangyapan.com/pan/policy/$path'),
      );
      if (!opened && mounted) message(context, '暂时无法打开，请通过网页登录查看协议');
    } catch (_) {
      if (mounted) message(context, '暂时无法打开，请通过网页登录查看协议');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _cancel();
    },
    child: PageFrame(
      title: '光鸭登录',
      child: CloudLoginLayout(
        platform: CloudPlatform.guangya,
        method: '手机号登录',
        children: [
          TextField(
            key: const ValueKey('guangya-sms-mobile'),
            controller: _mobile,
            enabled: !_busy,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            decoration: const InputDecoration(
              labelText: '手机号',
              prefixIcon: CloudLoginFieldIcon(
                CupertinoIcons.device_phone_portrait,
              ),
              prefixText: '+86 ',
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            key: const ValueKey('guangya-sms-code'),
            controller: _code,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(8),
            ],
            onSubmitted: (_) => _login(),
            decoration: InputDecoration(
              labelText: '验证码',
              prefixIcon: const CloudLoginFieldIcon(CupertinoIcons.shield),
              suffixIcon: CloudLoginCodeAction(
                child: TextButton(
                  key: const ValueKey('guangya-sms-send'),
                  onPressed: _busy || _seconds > 0 ? null : _send,
                  child: Text(_seconds > 0 ? '${_seconds}s 后重发' : '获取验证码'),
                ),
              ),
            ),
          ),
          CloudLoginAgreement(
            checkboxKey: const ValueKey('guangya-sms-agreement'),
            value: _agreed,
            onChanged: _busy
                ? null
                : (value) => setState(() => _agreed = value == true),
            onService: () => _policy('user-agreement'),
            onPrivacy: () => _policy('privacy'),
          ),

          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          FilledButton(
            key: const ValueKey('guangya-sms-submit'),
            onPressed: _busy ? null : _login,
            child: _busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: themeOnAccent(context),
                    ),
                  )
                : const Text('登录 / 注册'),
          ),
          const SizedBox(height: 16),
          if (_status.isNotEmpty)
            Text(
              _status,
              textAlign: TextAlign.center,
              style: TextStyle(color: secondary(context), fontSize: 13),
            ),
          CloudLoginAlternatives(
            children: [
              TextButton.icon(
                key: const ValueKey('guangya-sms-password'),
                onPressed: () => _switch(widget.onUsePassword),
                icon: const Icon(CupertinoIcons.lock, size: 18),
                label: const Text('账号密码登录'),
              ),
              TextButton.icon(
                key: const ValueKey('native-login-web'),
                onPressed: () => _switch(widget.onUseWeb),
                icon: const Icon(CupertinoIcons.globe, size: 18),
                label: const Text('网页登录'),
              ),
              TextButton.icon(
                key: const ValueKey('native-login-manual'),
                onPressed: () => _switch(widget.onUseManual),
                icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 18),
                label: const Text('手动提交'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
