import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/providers/guangya.dart';
import '../data/providers/ilanzou.dart';
import '../data/providers/pan123.dart';
import '../data/providers/lanzou.dart';
import '../data/providers/ctfile.dart';
import '../data/providers/feijipan.dart';
import '../data/providers/pikpak.dart';
import '../data/providers/tianyi_captcha.dart';
import '../data/providers/tianyi_login.dart';
import '../diagnostics/app_log.dart';
import '../domain/ctfile_captcha.dart';
import '../domain/models.dart';
import 'common.dart';
import 'ctfile_verification_page.dart';
import 'guangya_verification_page.dart';

class NativePasswordLoginPage extends StatefulWidget {
  const NativePasswordLoginPage(
    this.services,
    this.platform, {
    this.onUseWeb,
    this.onUseManual,
    this.onUseSms,
    this.onSubmitWebPassword,
    this.accountId,
    super.key,
  }) : assert(
         platform == CloudPlatform.pan123 ||
             platform == CloudPlatform.lanzou ||
             platform == CloudPlatform.ctfile ||
             platform == CloudPlatform.feijipan ||
             platform == CloudPlatform.pikpak ||
             platform == CloudPlatform.tianyi ||
             platform == CloudPlatform.aliyun ||
             platform == CloudPlatform.ilanzou ||
             platform == CloudPlatform.guangya,
       );
  final AppServices services;
  final CloudPlatform platform;
  final String? accountId;
  final VoidCallback? onUseWeb;
  final VoidCallback? onUseManual;
  final VoidCallback? onUseSms;
  final void Function(String username, String password)? onSubmitWebPassword;
  @override
  State<NativePasswordLoginPage> createState() =>
      _NativePasswordLoginPageState();
}

class _NativePasswordLoginPageState extends State<NativePasswordLoginPage> {
  final _form = GlobalKey<FormState>();
  final _username = TextEditingController(),
      _password = TextEditingController();
  bool _working = false, _visible = false, _completed = false, _leaving = false;
  String _error = '', _status = '';

  @override
  void initState() {
    super.initState();
    final saved = widget.services.vault.credentialFor(
      widget.platform,
      widget.accountId ??
          widget.services.vault.activeAccountId(widget.platform),
    );
    if (widget.platform == CloudPlatform.pan123) {
      if (saved?.field('secondary').isNotEmpty == true) {
        _username.text = saved!.primary;
        _password.text = saved.field('secondary');
      }
    } else if (saved?.field('authType') == 'passwordCookie') {
      _username.text = saved!.field('username');
      _password.text = saved.field('password');
    } else if (widget.platform == CloudPlatform.guangya ||
        widget.platform == CloudPlatform.feijipan ||
        widget.platform == CloudPlatform.pikpak ||
        widget.platform == CloudPlatform.ilanzou) {
      _username.text = saved?.field('username') ?? '';
      _password.text = saved?.field('password') ?? '';
    } else if (widget.platform == CloudPlatform.aliyun) {
      _username.text = saved?.field('loginUsername') ?? '';
      _password.text = saved?.field('loginPassword') ?? '';
    }
  }

  void _switchMethod(VoidCallback? action) {
    if (_leaving || _completed || action == null) return;
    _cancel();
    _password.clear();
    FocusScope.of(context).unfocus();
    TextInput.finishAutofillContext(shouldSave: false);
    action();
  }

  void _cancel() {
    if (_completed || _leaving) return;
    _leaving = true;
    widget.services.login.invalidate(widget.platform);
  }

  @override
  void dispose() {
    _cancel();
    _password.clear();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _setStatus(String status) {
    if (mounted && !_leaving) setState(() => _status = status);
  }

  Future<void> _login() async {
    if (_working || _leaving || !_form.currentState!.validate()) return;
    final username = _username.text.trim(), password = _password.text;
    FocusScope.of(context).unfocus();
    setState(() {
      _working = true;
      _error = '';
      _status = '正在验证账号…';
    });
    final platform = widget.platform, services = widget.services;
    DiagnosticLog.event(
      'login.password.start',
      fields: {'platform': platform.key},
    );
    try {
      if (platform == CloudPlatform.aliyun) {
        final submit = widget.onSubmitWebPassword;
        require(submit != null, '请重新打开阿里云盘登录页面');
        _switchMethod(() => submit!(username, password));
        return;
      }
      await services.login.submit(platform, (_) async {
        if (platform == CloudPlatform.pikpak) {
          return (services.cloud.connector(platform) as PikPakConnector)
              .password(username, password);
        }
        if (platform == CloudPlatform.feijipan) {
          return (services.cloud.connector(platform) as FeijipanConnector)
              .password(username, password);
        }
        if (platform == CloudPlatform.ctfile) {
          return (services.cloud.connector(platform) as CtfileConnector)
              .password(
                username,
                password,
                onStatus: _setStatus,
                verifyCaptcha: (challenge) async {
                  if (!mounted || _leaving) return null;
                  return Navigator.push<CtfileCaptchaProof>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          CtfileVerificationPage(services, challenge),
                    ),
                  );
                },
              );
        }
        if (platform == CloudPlatform.pan123) {
          return (services.cloud.connector(platform) as Pan123Connector)
              .password(username, password);
        }
        if (platform == CloudPlatform.lanzou) {
          return (services.cloud.connector(platform) as LanzouConnector)
              .password(username, password);
        }
        if (platform == CloudPlatform.ilanzou) {
          return (services.cloud.connector(platform) as ILanzouConnector)
              .password(username, password);
        }
        if (platform == CloudPlatform.guangya) {
          return (services.cloud.connector(platform) as GuangyaConnector)
              .password(
                username,
                password,
                onStatus: _setStatus,
                verifyCaptcha: (challenge) async {
                  if (!mounted || _leaving) return null;
                  return Navigator.push<String>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          GuangyaVerificationPage(services, challenge),
                    ),
                  );
                },
              );
        }
        return services.cloud.tianyiLogin.password(
          username,
          password,
          onStatus: _setStatus,
          verifyCaptcha: (client) async {
            if (!mounted || _leaving) {
              client.cancel();
              return null;
            }
            return showDialog<TianyiCaptchaProof>(
              context: context,
              barrierDismissible: false,
              builder: (_) => TianyiCaptchaDialog(client),
            );
          },
          verifySms: (challenge) async {
            if (!mounted || _leaving) {
              challenge.cancel();
              return null;
            }
            return showDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (_) => TianyiSmsDialog(challenge),
            );
          },
        );
      }, accountId: widget.accountId);
      _completed = true;
      _password.clear();
      TextInput.finishAutofillContext(shouldSave: false);
      DiagnosticLog.event(
        'login.password.success',
        fields: {'platform': platform.key},
      );
      if (mounted && !_leaving) {
        message(context, '${platform.shortName}登录成功');
        Navigator.pop(context);
      }
    } catch (error) {
      DiagnosticLog.event(
        'login.password.failed',
        fields: {'platform': platform.key, 'reason': errorText(error)},
      );
      if (mounted && !_leaving) setState(() => _error = errorText(error));
    } finally {
      if (mounted && !_leaving) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = widget.platform;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _cancel();
      },
      child: PageFrame(
        title: '${platform.shortName}登录',
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: AutofillGroup(
              onDisposeAction: AutofillContextAction.cancel,
              child: Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
                  children: [
                    Row(
                      children: [
                        PlatformMark(platform: platform, size: 52),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '账号密码登录',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                platform.label,
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
                    const SizedBox(height: 32),
                    TextFormField(
                      key: const ValueKey('native-login-username'),
                      controller: _username,
                      enabled: !_working,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.username],
                      decoration: InputDecoration(
                        labelText: '账号',
                        hintText: platform == CloudPlatform.pikpak
                            ? '邮箱 / 手机号（含国家区号）'
                            : platform == CloudPlatform.ctfile
                            ? '注册邮箱'
                            : platform == CloudPlatform.lanzou
                            ? '蓝奏云用户名 / 账号'
                            : platform == CloudPlatform.tianyi
                            ? '手机号 / 邮箱 / 别名'
                            : platform == CloudPlatform.guangya
                            ? '手机号 / 邮箱 / 用户名'
                            : '手机号',
                        prefixIcon: const Icon(CupertinoIcons.person, size: 20),
                      ),
                      validator: (value) =>
                          value?.trim().isNotEmpty == true ? null : '请输入账号',
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      key: const ValueKey('native-login-password'),
                      controller: _password,
                      enabled: !_working,
                      obscureText: !_visible,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: '密码',
                        prefixIcon: const Icon(CupertinoIcons.lock, size: 20),
                        suffixIcon: IconButton(
                          tooltip: _visible ? '隐藏密码' : '显示密码',
                          onPressed: _working
                              ? null
                              : () => setState(() => _visible = !_visible),
                          icon: Icon(
                            _visible
                                ? CupertinoIcons.eye_slash
                                : CupertinoIcons.eye,
                            size: 20,
                          ),
                        ),
                      ),
                      validator: (value) =>
                          value?.isNotEmpty == true ? null : '请输入密码',
                      onFieldSubmitted: (_) => _login(),
                    ),
                    const SizedBox(height: 24),
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
                      key: const ValueKey('native-login-submit'),
                      onPressed: _working ? null : _login,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                      ),
                      child: _working
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: themeOnAccent(context),
                              ),
                            )
                          : const Text('登录'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _working
                          ? _status
                          : switch (platform) {
                              CloudPlatform.pikpak =>
                                '登录令牌加密保存在本机并自动续期；遇到安全验证可切换网页登录',
                              CloudPlatform.ctfile =>
                                '支持注册邮箱登录；登录凭据加密保存在本机，过期后请重新登录',
                              CloudPlatform.lanzou =>
                                '账号密码加密保存在本机，登录失效时可重新登录；遇到安全验证可切换网页登录',
                              CloudPlatform.aliyun =>
                                '账号密码由官方页面验证并加密记住，登录后自动续期',
                              CloudPlatform.guangya =>
                                '账号密码加密保存在本机，未设置密码可切换短信登录',
                              _ => '账号密码加密保存在本机，登录失效时自动重登',
                            },
                      textAlign: TextAlign.center,
                      style: TextStyle(color: secondary(context), fontSize: 13),
                    ),
                    if (widget.onUseSms != null)
                      TextButton.icon(
                        key: const ValueKey('native-login-sms'),
                        onPressed: () => _switchMethod(widget.onUseSms),
                        icon: const Icon(CupertinoIcons.chat_bubble, size: 18),
                        label: const Text('切换短信验证码登录'),
                      ),
                    if (widget.onUseWeb != null) ...[
                      const SizedBox(height: 14),
                      TextButton.icon(
                        key: const ValueKey('native-login-web'),
                        onPressed: () => _switchMethod(widget.onUseWeb),
                        icon: const Icon(CupertinoIcons.globe, size: 18),
                        label: const Text('切换网页登录'),
                      ),
                    ],
                    if (widget.onUseManual != null)
                      TextButton.icon(
                        key: const ValueKey('native-login-manual'),
                        onPressed: () => _switchMethod(widget.onUseManual),
                        icon: const Icon(
                          CupertinoIcons.doc_on_clipboard,
                          size: 18,
                        ),
                        label: const Text('手动提交登录信息'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TianyiCaptchaDialog extends StatefulWidget {
  const TianyiCaptchaDialog(this.client, {super.key});
  final TianyiCaptchaClient client;
  @override
  State<TianyiCaptchaDialog> createState() => _TianyiCaptchaDialogState();
}

class _TianyiCaptchaDialogState extends State<TianyiCaptchaDialog> {
  TianyiCaptchaImage? _data;
  bool _working = true, _completed = false, _closing = false;
  String _error = '';
  double _height = 155,
      _pieceWidth = 47,
      _pieceHeight = 155,
      _offset = 0,
      _startX = 0;
  final _clock = Stopwatch();
  final _drag = <(double, int)>[];
  final _points = <(Offset, int)>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (!_completed) widget.client.cancel();
    super.dispose();
  }

  void _cancel() {
    if (_closing) return;
    _closing = true;
    widget.client.cancel();
    Navigator.pop(context);
  }

  Future<Size> _dimensions(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        require(
          descriptor.width > 0 &&
              descriptor.height > 0 &&
              descriptor.width <= 2048 &&
              descriptor.height <= 2048,
          '验证码图片尺寸无效，请刷新',
        );
        return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  Future<void> _load() async {
    setState(() {
      _working = true;
      _error = '';
      _data = null;
      _points.clear();
      _drag.clear();
      _offset = 0;
    });
    try {
      final data = await widget.client.load();
      final background = await _dimensions(data.background);
      final piece = data.piece == null ? null : await _dimensions(data.piece!);
      final ratio = TianyiCaptchaImage.width / background.width;
      require(
        background.height * ratio <= 620 &&
            (piece == null ||
                piece.width < background.width &&
                    piece.height <= background.height),
        '验证码图片尺寸无效，请刷新',
      );
      if (mounted && !_closing) {
        setState(() {
          _data = data;
          _height = background.height * ratio;
          _pieceWidth = (piece?.width ?? 0) * ratio;
          _pieceHeight = (piece?.height ?? 0) * ratio;
        });
      }
    } catch (error) {
      if (mounted && !_closing) setState(() => _error = errorText(error));
    } finally {
      if (mounted && !_closing) setState(() => _working = false);
    }
  }

  Future<void> _verify(TianyiCaptchaGesture gesture) async {
    final data = _data;
    if (_working || data == null) return;
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      final proof = await widget.client.verify(data, gesture);
      if (!mounted || _closing) return;
      _completed = true;
      Navigator.pop(context, proof);
    } catch (error) {
      if (mounted && !_closing) {
        setState(() {
          _error = errorText(error);
          _data = null;
        });
      }
    } finally {
      if (mounted && !_closing && !_completed) setState(() => _working = false);
    }
  }

  void _beginDrag(DragStartDetails details, double scale) {
    if (_working || _data?.type != 1) return;
    _clock
      ..reset()
      ..start();
    _startX = details.globalPosition.dx / scale;
    _drag
      ..clear()
      ..add((0, 0));
    setState(() => _offset = 0);
  }

  void _moveDrag(DragUpdateDetails details, double scale) {
    if (_working || _drag.isEmpty) return;
    final position = (details.globalPosition.dx / scale - _startX).clamp(
      0.0,
      TianyiCaptchaImage.width - max(_pieceWidth, 44),
    );
    _drag.add((position, _clock.elapsedMilliseconds));
    setState(() => _offset = position);
  }

  void _endDrag(DragEndDetails _) {
    if (_working || _drag.isEmpty) return;
    _drag.add((_offset, _clock.elapsedMilliseconds));
    final samples = _drag.length <= 50
        ? List.of(_drag)
        : [
            for (var i = 0; i < 50; i++)
              _drag[(i * (_drag.length - 1) / 49).round()],
          ];
    final rates = <Map<String, num>>[
      for (var i = 0; i < samples.length; i++)
        {
          'pointDiff': i == 0 ? 0 : (samples[i].$1 - samples[i - 1].$1).round(),
          'timeDiff': i == 0 ? 0 : samples[i].$2 - samples[i - 1].$2,
        },
    ];
    _drag.clear();
    unawaited(
      _verify(
        TianyiCaptchaGesture(
          [
            {'x': _offset, 'y': 0},
          ],
          rates,
          _clock.elapsedMilliseconds,
        ),
      ),
    );
  }

  void _tap(TapDownDetails details, double scale) {
    if (_working || _data?.type != 2 || _points.length >= 3) return;
    if (_points.isEmpty) {
      _clock
        ..reset()
        ..start();
    }
    final position = details.localPosition / scale;
    setState(
      () => _points.add((
        Offset(position.dx.clamp(0, 310), position.dy.clamp(0, _height)),
        _clock.elapsedMilliseconds,
      )),
    );
    if (_points.length == 3) {
      unawaited(
        _verify(
          TianyiCaptchaGesture(
            [
              for (final point in _points) {'x': point.$1.dx, 'y': point.$1.dy},
            ],
            const [],
            _points.last.$2 - _points.first.$2,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop && !_completed) {
        _closing = true;
        widget.client.cancel();
      }
    },
    child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 354),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '安全验证',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新验证码',
                    onPressed: _working ? null : _load,
                    icon: const Icon(CupertinoIcons.arrow_clockwise, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_data != null)
                _canvas(context)
              else
                SizedBox(
                  height: 175,
                  child: Center(
                    child: _working
                        ? const CircularProgressIndicator()
                        : TextButton.icon(
                            onPressed: _load,
                            icon: const Icon(CupertinoIcons.arrow_clockwise),
                            label: const Text('重新获取验证码'),
                          ),
                  ),
                ),
              if (_working && _data != null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              TextButton(onPressed: _cancel, child: const Text('取消登录')),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _canvas(BuildContext context) {
    final data = _data!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = min(TianyiCaptchaImage.width, constraints.maxWidth),
            scale = width / TianyiCaptchaImage.width;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: GestureDetector(
                key: const ValueKey('tianyi-captcha-image'),
                onTapDown: _working || data.type != 2
                    ? null
                    : (details) => _tap(details, scale),
                child: SizedBox(
                  width: width,
                  height: _height * scale,
                  child: Stack(
                    children: [
                      Image.memory(
                        data.background,
                        width: width,
                        height: _height * scale,
                        fit: BoxFit.fill,
                        gaplessPlayback: false,
                        semanticLabel: '天翼安全验证图片',
                      ),
                      if (data.piece != null)
                        Positioned(
                          left: _offset * scale,
                          top: 0,
                          child: IgnorePointer(
                            child: Image.memory(
                              data.piece!,
                              width: _pieceWidth * scale,
                              height: _pieceHeight * scale,
                              fit: BoxFit.fill,
                              gaplessPlayback: false,
                            ),
                          ),
                        ),
                      for (var i = 0; i < _points.length; i++)
                        Positioned(
                          left: _points[i].$1.dx * scale - 13,
                          top: _points[i].$1.dy * scale - 13,
                          child: IgnorePointer(
                            child: CircleAvatar(
                              radius: 13,
                              backgroundColor: themeAccent(context),
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  color: themeOnAccent(context),
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (data.type == 1)
              SizedBox(
                width: width,
                height: 44 * scale,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: fill(context),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: Text(
                          '拖动滑块',
                          style: TextStyle(
                            color: secondary(context),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Positioned(
                        left: _offset * scale,
                        top: 0,
                        bottom: 0,
                        child: GestureDetector(
                          key: const ValueKey('tianyi-captcha-slider'),
                          onHorizontalDragStart: _working
                              ? null
                              : (d) => _beginDrag(d, scale),
                          onHorizontalDragUpdate: _working
                              ? null
                              : (d) => _moveDrag(d, scale),
                          onHorizontalDragEnd: _working ? null : _endDrag,
                          onHorizontalDragCancel: () {
                            _drag.clear();
                            if (mounted) setState(() => _offset = 0);
                          },
                          child: Container(
                            width: 44 * scale,
                            decoration: BoxDecoration(
                              color: themeAccent(context),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              CupertinoIcons.chevron_right_2,
                              color: themeOnAccent(context),
                              size: 19,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              data.type == 2 ? '请依次点击：${data.instruction}' : data.instruction,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            if (data.type == 2)
              TextButton(
                onPressed: _points.isEmpty || _working
                    ? null
                    : () => setState(() => _points.removeLast()),
                child: const Text('撤销上一步'),
              ),
          ],
        );
      },
    );
  }
}

class TianyiSmsDialog extends StatefulWidget {
  const TianyiSmsDialog(this.challenge, {super.key});
  final TianyiSmsChallenge challenge;
  @override
  State<TianyiSmsDialog> createState() => _TianyiSmsDialogState();
}

class _TianyiSmsDialogState extends State<TianyiSmsDialog> {
  final _code = TextEditingController();
  bool _working = false, _completed = false, _closing = false;
  String _error = '', _status = '';
  Timer? _timer;
  @override
  void dispose() {
    _timer?.cancel();
    if (!_completed) widget.challenge.cancel();
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  void _cancel() {
    if (_closing) return;
    _closing = true;
    widget.challenge.cancel();
    Navigator.pop(context);
  }

  Future<void> _action(Future<void> Function() action) async {
    if (_working || _closing) return;
    setState(() {
      _working = true;
      _error = '';
    });
    try {
      await action();
    } catch (error) {
      if (mounted && !_closing) setState(() => _error = errorText(error));
    } finally {
      if (mounted && !_closing && !_completed) setState(() => _working = false);
    }
  }

  Future<void> _send() => _action(() async {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_closing) setState(() {});
    });
    await widget.challenge.sendCode();
    if (mounted && !_closing) setState(() => _status = '验证码已发送');
  });
  Future<void> _verify() => _action(() async {
    final target = await widget.challenge.verify(_code.text);
    if (!mounted || _closing) return;
    _completed = true;
    _code.clear();
    Navigator.pop(context, target);
  });
  @override
  Widget build(BuildContext context) => PopScope(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop && !_completed) {
        _closing = true;
        widget.challenge.cancel();
      }
    },
    child: AlertDialog(
      title: const Text('天翼短信验证'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('当前设备需要验证账号身份，请输入发送至${widget.challenge.phoneHint}的短信验证码。'),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('tianyi-sms-code'),
                controller: _code,
                enabled: !_working,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                autofillHints: const [AutofillHints.oneTimeCode],
                decoration: const InputDecoration(labelText: '短信验证码'),
                onSubmitted: (_) => _verify(),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _working || widget.challenge.resendSeconds > 0
                    ? null
                    : _send,
                child: Text(
                  widget.challenge.resendSeconds > 0
                      ? '${widget.challenge.resendSeconds} 秒后重发'
                      : '获取验证码',
                ),
              ),
              if (_status.isNotEmpty)
                Text(
                  _status,
                  style: TextStyle(color: secondary(context), fontSize: 13),
                ),
              if (_error.isNotEmpty)
                Text(
                  _error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_working)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('取消登录')),
        FilledButton(
          onPressed: _working ? null : _verify,
          child: const Text('验证并登录'),
        ),
      ],
    ),
  );
}
