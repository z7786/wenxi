import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../domain/baidu_web_login.dart';
import '../domain/models.dart';
import 'common.dart';
import 'cloud_login_layout.dart';

class BaiduLoginPanel extends StatefulWidget {
  const BaiduLoginPanel({
    required this.qrMode,
    required this.ready,
    required this.busy,
    required this.state,
    required this.error,
    required this.onMode,
    required this.onAction,
    required this.onShowOfficial,
    required this.onUseWeb,
    required this.onUseManual,
    super.key,
  });
  final bool qrMode, ready, busy;
  final Map<String, dynamic> state;
  final String error;
  final Future<void> Function(bool qr) onMode;
  final Future<void> Function(String action, Map<String, Object?> data)
  onAction;
  final VoidCallback onShowOfficial, onUseWeb, onUseManual;

  @override
  State<BaiduLoginPanel> createState() => _BaiduLoginPanelState();
}

class _BaiduLoginPanelState extends State<BaiduLoginPanel> {
  final _mobile = TextEditingController(), _code = TextEditingController();
  Timer? _ticker;
  bool _agreed = false;
  String _error = '';
  int get _seconds {
    final sentAt = widget.state['sentAt'];
    if (sentAt is! num || sentAt <= 0) return 0;
    return ((sentAt.toInt() +
                60000 -
                DateTime.now().millisecondsSinceEpoch +
                999) ~/
            1000)
        .clamp(0, 60);
  }

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.state['sentAt'] != null) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant BaiduLoginPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.qrMode != widget.qrMode || oldWidget.ready && !widget.ready) {
      _code.clear();
      _error = '';
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _mobile.dispose();
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sms(bool submit) async {
    if (widget.busy || !widget.ready || !submit && _seconds > 0) return;
    final error = !BaiduWebLogin.validMobile(_mobile.text)
        ? '请输入正确的手机号'
        : !_agreed
        ? '请先阅读并同意百度网盘用户协议和隐私政策'
        : submit && !BaiduWebLogin.validCode(_code.text)
        ? '请输入6位短信验证码'
        : '';
    setState(() => _error = error);
    if (error.isNotEmpty) return;
    FocusScope.of(context).unfocus();
    final data = <String, Object?>{
      'mobile': _mobile.text.trim(),
      'agreed': _agreed,
      if (submit) 'code': _code.text,
    };
    _code.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    await widget.onAction(submit ? 'submit' : 'send', data);
  }

  Widget _policies() => Wrap(
    alignment: WrapAlignment.center,
    children: [
      for (final entry in {
        '用户协议': 'https://pan.baidu.com/disk/main#/protocol/duty_mobi',
        '隐私政策':
            'https://pan.baidu.com/disk/base/protocol#/privacy_policy_addition',
      }.entries)
        TextButton(
          onPressed: () => _policy(entry.key, entry.value),
          child: Text(entry.key, style: const TextStyle(fontSize: 12)),
        ),
    ],
  );

  Future<void> _policy(String label, String url) async {
    if (!await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        ) &&
        mounted) {
      message(context, '暂时无法打开$label，请稍后重试');
    }
  }

  String get _status => switch (widget.state['phase']) {
    'sending' => '正在发送验证码，请在百度页面完成可能出现的安全验证',
    'submitting' || 'completing' => '正在完成登录，请按百度页面提示操作',
    'verify' => '请打开百度验证页面，按提示完成验证或查看原因',
    'sent' when !widget.qrMode => '验证码已发送，请查看手机短信',
    _ when !widget.ready => '正在准备百度官方登录…',
    _ when widget.qrMode => switch (widget.state['qrState']) {
      'scanned' => '已扫码，请在手机百度网盘中确认',
      'expired' => '二维码已失效或加载失败，请重新获取',
      'waiting' => '请使用百度网盘 App 扫码并确认登录',
      _ => '正在获取登录二维码…',
    },
    _ => '如需安全验证，将显示百度官方页面',
  };

  @override
  Widget build(BuildContext context) {
    final qr = BaiduWebLogin.qrImage(widget.state['qrUrl']);
    final error = _error.isNotEmpty ? _error : widget.error;
    return CloudLoginLayout(
      platform: CloudPlatform.baidu,
      method: widget.qrMode ? '扫码登录' : '手机号登录',
      children: [
        SegmentedButton<bool>(
          key: const ValueKey('baidu-login-method'),
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('手机号登录'),
              icon: Icon(CupertinoIcons.phone),
            ),
            ButtonSegment(
              value: true,
              label: Text('扫码登录'),
              icon: Icon(CupertinoIcons.qrcode),
            ),
          ],
          selected: {widget.qrMode},
          showSelectedIcon: false,
          onSelectionChanged: widget.busy || !widget.ready
              ? null
              : (values) => widget.onMode(values.first),
        ),
        const SizedBox(height: 28),
        if (!widget.qrMode) ...[
          TextField(
            key: const ValueKey('baidu-sms-mobile'),
            controller: _mobile,
            enabled: !widget.busy,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(11),
            ],
            onChanged: (_) => _code.clear(),
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
            key: const ValueKey('baidu-sms-code'),
            controller: _code,
            enabled: !widget.busy,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            onSubmitted: (_) => _sms(true),
            decoration: InputDecoration(
              labelText: '验证码',
              helperText: '6位短信验证码',
              prefixIcon: const CloudLoginFieldIcon(CupertinoIcons.shield),
              suffixIcon: CloudLoginCodeAction(
                child: TextButton(
                  key: const ValueKey('baidu-sms-send'),
                  onPressed: widget.busy || !widget.ready || _seconds > 0
                      ? null
                      : () => _sms(false),
                  child: Text(_seconds > 0 ? '${_seconds}s 后重发' : '获取验证码'),
                ),
              ),
            ),
          ),
          CloudLoginAgreement(
            checkboxKey: const ValueKey('baidu-sms-agreement'),
            value: _agreed,
            onChanged: widget.busy
                ? null
                : (value) => setState(() => _agreed = value == true),
            onService: () => _policy(
              '用户协议',
              'https://pan.baidu.com/disk/main#/protocol/duty_mobi',
            ),
            onPrivacy: () => _policy(
              '隐私政策',
              'https://pan.baidu.com/disk/base/protocol#/privacy_policy_addition',
            ),
          ),
        ] else ...[
          Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: qr.isNotEmpty && widget.state['qrState'] != 'expired'
                  ? ColoredBox(
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Image.network(
                          qr,
                          key: const ValueKey('baidu-login-qr'),
                          fit: BoxFit.contain,
                          semanticLabel: '百度网盘登录二维码',
                          errorBuilder: (_, _, _) =>
                              const Center(child: Text('二维码加载失败，请刷新')),
                        ),
                      ),
                    )
                  : Center(
                      child:
                          !widget.ready || widget.state['qrState'] == 'loading'
                          ? const CircularProgressIndicator()
                          : Icon(
                              CupertinoIcons.qrcode,
                              size: 72,
                              color: secondary(context),
                            ),
                    ),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('baidu-qr-refresh'),
            onPressed: widget.busy || !widget.ready
                ? null
                : () => widget.onAction('refresh', const {}),
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 18),
            label: const Text('重新获取二维码'),
          ),
          Text(
            '扫码并确认登录表示你已阅读并同意',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
          _policies(),
        ],
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        if (!widget.qrMode)
          FilledButton(
            key: const ValueKey('baidu-sms-submit'),
            onPressed: widget.busy || !widget.ready ? null : () => _sms(true),
            child: const Text('登录 / 注册'),
          ),
        const SizedBox(height: 18),
        Semantics(
          liveRegion: true,
          child: Text(
            _status,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const ValueKey('baidu-show-verification'),
          onPressed: widget.onShowOfficial,
          child: const Text('打开百度验证页面'),
        ),
        CloudLoginAlternatives(
          children: [
            TextButton.icon(
              key: const ValueKey('native-login-web'),
              onPressed: widget.onUseWeb,
              icon: const Icon(CupertinoIcons.globe, size: 18),
              label: const Text('网页登录'),
            ),
            TextButton.icon(
              key: const ValueKey('native-login-manual'),
              onPressed: widget.onUseManual,
              icon: const Icon(CupertinoIcons.doc_on_clipboard, size: 18),
              label: const Text('手动提交'),
            ),
          ],
        ),
      ],
    );
  }
}
