import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/providers/quark.dart';
import '../data/providers/quark_login.dart';
import '../domain/models.dart';
import 'common.dart';
import 'quark_sms_verification_page.dart';

class QuarkLoginPage extends StatefulWidget {
  const QuarkLoginPage(
    this.services, {
    required this.onUseWeb,
    required this.onUseManual,
    this.accountId,
    this.verifyCaptcha,
    super.key,
  });
  final AppServices services;
  final String? accountId;
  final VoidCallback onUseWeb, onUseManual;
  final QuarkCaptchaPrompt? verifyCaptcha;

  @override
  State<QuarkLoginPage> createState() => _QuarkLoginPageState();
}

class _QuarkLoginPageState extends State<QuarkLoginPage> {
  static const _platform = CloudPlatform.quark;
  final _mobile = TextEditingController(), _code = TextEditingController();
  late final _login = QuarkLoginService(widget.services.cloud.http);
  late final String? _selection;
  QuarkSmsChallenge? _sms;
  RequestScope? _request;
  Timer? _ticker;
  DateTime? _resendAt;
  bool _busy = false, _agreed = false;
  bool _leaving = false, _completed = false;
  int _generation = 0;
  String _error = '', _status = '';

  bool get _active => mounted && !_leaving && !_completed;
  int get _seconds => _resendAt == null
      ? 0
      : ((_resendAt!.difference(DateTime.now()).inMilliseconds + 999) ~/ 1000)
            .clamp(0, 60);
  @override
  void initState() {
    super.initState();
    _selection = widget.services.vault.activeAccountId(_platform);
    final saved = widget.services.vault.credentialFor(
      _platform,
      widget.accountId ?? _selection,
    );
    final username = saved?.field('username') ?? '';
    if (QuarkLoginService.validMobile(username)) _mobile.text = username;
    _mobile.addListener(_mobileChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_active) return;
      final resendExpired = _resendAt != null && _seconds == 0;
      if (_seconds > 0 || resendExpired) {
        setState(() {
          if (resendExpired) _resendAt = null;
        });
      }
    });
  }

  void _mobileChanged() {
    if (_sms != null && _sms!.mobile != _mobile.text.trim()) {
      _sms!.close();
      _sms = null;
      _code.clear();
    }
  }

  void _guard(int generation) {
    require(_active && generation == _generation, '登录已取消，请重新登录');
    require(
      widget.services.vault.activeAccountId(_platform) == _selection,
      '账号已发生变化，请返回后重新登录',
    );
    widget.services.control.checkCloud(_platform);
  }

  Future<T> _run<T>(
    RequestScope request,
    int generation,
    Future<T> Function() action,
  ) => request.run(
    () => RequestScope.guarded(() async {
      _guard(generation);
      return action();
    }, () => _guard(generation)),
  );

  void _cancelRequests() {
    _generation++;
    _request?.cancel();
    _request = null;
    _sms?.close();
    _sms = null;
    widget.services.login.invalidate(_platform);
  }

  void _cancel() {
    if (_leaving || _completed) return;
    _leaving = true;
    _cancelRequests();
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
    _ticker?.cancel();
    _sms?.close();
    _mobile.dispose();
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  bool _validateMobile() {
    final error = !QuarkLoginService.validMobile(_mobile.text)
        ? '请输入正确的手机号'
        : !_agreed
        ? '请先阅读并同意夸克用户协议和隐私政策'
        : '';
    if (error.isEmpty) return true;
    setState(() => _error = error);
    return false;
  }

  Future<QuarkCaptchaProof?> _captcha({required bool useSlider}) {
    if (!_active) return Future.value();
    if (widget.verifyCaptcha != null) {
      return widget.verifyCaptcha!(useSlider: useSlider);
    }
    return Navigator.push<QuarkCaptchaProof>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            QuarkSmsVerificationPage(widget.services, useSlider: useSlider),
      ),
    );
  }

  Future<void> _send() async {
    if (!_active || _busy || _seconds > 0 || !_validateMobile()) {
      return;
    }
    final mobile = _mobile.text.trim(), generation = _generation;
    final request = RequestScope();
    _request = request;
    _sms?.close();
    _sms = null;
    _code.clear();
    setState(() {
      _busy = true;
      _error = '';
      _status = '正在准备安全验证…';
    });
    try {
      final challenge = await _run(
        request,
        generation,
        () => _login.sendSms(
          mobile,
          verifyCaptcha: _captcha,
          onStatus: (status) {
            if (!_active || generation != _generation) return;
            setState(() {
              _status = status;
              if (status == '正在发送验证码…' && _seconds == 0) {
                _resendAt = DateTime.now().add(const Duration(seconds: 60));
              }
            });
          },
        ),
      );
      if (!_active ||
          generation != _generation ||
          mobile != _mobile.text.trim()) {
        challenge.close();
        return;
      }
      setState(() {
        _sms = challenge;
        _status = '验证码已发送，请查看手机短信';
      });
    } catch (error) {
      if (_active && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (identical(_request, request)) _request = null;
      if (_active && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _submitSms() async {
    if (!_active || _busy || !_validateMobile()) return;
    final challenge = _sms;
    if (challenge == null || challenge.mobile != _mobile.text.trim()) {
      setState(() => _error = '请先获取当前手机号的验证码');
      return;
    }
    if (!QuarkLoginService.validCode(_code.text)) {
      setState(() => _error = '请输入4位短信验证码');
      return;
    }
    final code = _code.text, request = RequestScope(), generation = _generation;
    _request = request;
    setState(() {
      _busy = true;
      _error = '';
      _status = '正在登录…';
    });
    FocusScope.of(context).unfocus();
    try {
      await _run(
        request,
        generation,
        () => widget.services.login.submit(_platform, (_) async {
          final credential = await _login.sms(challenge, code);
          RequestScope.checkpoint();
          return (widget.services.cloud.connector(_platform) as QuarkConnector)
              .authenticate(credential);
        }, accountId: widget.accountId),
      );
      if (_active && generation == _generation) _finish();
    } catch (error) {
      if (_active && generation == _generation) {
        setState(() => _error = errorText(error));
      }
    } finally {
      if (identical(_request, request)) _request = null;
      if (_active && generation == _generation) setState(() => _busy = false);
    }
  }

  void _finish() {
    _completed = true;
    _ticker?.cancel();
    _sms?.close();
    _code.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    message(context, '夸克登录成功');
    Navigator.pop(context);
  }

  Future<void> _policy(String url) async {
    try {
      if (!await launchUrl(Uri.parse(url)) && mounted) {
        message(context, '暂时无法打开，请通过网页登录查看协议');
      }
    } catch (_) {
      if (mounted) message(context, '暂时无法打开，请通过网页登录查看协议');
    }
  }

  Widget _policies() => Wrap(
    children: [
      TextButton(
        onPressed: () => _policy(QuarkLoginService.serviceAgreement),
        child: const Text('《用户协议》'),
      ),
      TextButton(
        onPressed: () => _policy(QuarkLoginService.privacyPolicy),
        child: const Text('《隐私政策》'),
      ),
    ],
  );

  Widget _spinner({bool onPrimary = false}) => SizedBox(
    width: 22,
    height: 22,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: onPrimary ? Theme.of(context).colorScheme.onPrimary : null,
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _cancel();
    },
    child: PageFrame(
      title: '夸克登录',
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: AutofillGroup(
            onDisposeAction: AutofillContextAction.cancel,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
              children: [
                Row(
                  children: [
                    const PlatformMark(platform: _platform, size: 52),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '手机号验证码登录',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '夸克网盘',
                            style: TextStyle(
                              color: secondary(context),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                TextField(
                  key: const ValueKey('quark-sms-mobile'),
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
                    prefixIcon: Icon(CupertinoIcons.phone, size: 20),
                    prefixText: '+86 ',
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  key: const ValueKey('quark-sms-code'),
                  controller: _code,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  onSubmitted: (_) => _submitSms(),
                  decoration: InputDecoration(
                    labelText: '短信验证码',
                    prefixIcon: const Icon(CupertinoIcons.lock, size: 20),
                    suffixIcon: TextButton(
                      key: const ValueKey('quark-sms-send'),
                      onPressed: _busy || _seconds > 0 ? null : _send,
                      child: Text(_seconds > 0 ? '${_seconds}s 后重发' : '获取验证码'),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      key: const ValueKey('quark-sms-agreement'),
                      value: _agreed,
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _agreed = value == true),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          Text(
                            '我已阅读并同意，未注册手机号将自动注册',
                            style: TextStyle(
                              fontSize: 13,
                              color: secondary(context),
                            ),
                          ),
                          _policies(),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 18),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ),
                FilledButton(
                  key: const ValueKey('quark-sms-submit'),
                  onPressed: _busy ? null : _submitSms,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  child: _busy ? _spinner(onPrimary: true) : const Text('登录'),
                ),
                const SizedBox(height: 16),
                if (_status.isNotEmpty)
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: secondary(context), fontSize: 13),
                  ),
                const SizedBox(height: 14),
                TextButton.icon(
                  key: const ValueKey('native-login-web'),
                  onPressed: () => _switch(widget.onUseWeb),
                  icon: const Icon(CupertinoIcons.globe, size: 18),
                  label: const Text('其他登录方式（网页）'),
                ),
                TextButton.icon(
                  key: const ValueKey('native-login-manual'),
                  onPressed: () => _switch(widget.onUseManual),
                  icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 18),
                  label: const Text('手动提交登录信息'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
