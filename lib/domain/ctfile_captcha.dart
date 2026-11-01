import 'dart:convert';
import '../core/json.dart';
import 'models.dart';
import 'web_tokens.dart';

/// Uses the same hosted verification widgets as the official login page.
/// A proof belongs to one request and is consumed by the login endpoint.
class CtfileCaptchaChallenge {
  CtfileCaptchaChallenge(
    this.type, {
    this.message = '请完成城通安全验证',
    Map<String, String> imageHeaders = const {},
  }) : state = newId(),
       imageHeaders = Map.unmodifiable(imageHeaders) {
    require(types.contains(type), '城通验证方式已变化，请使用官网登录后的 Session Token');
  }

  static const types = {'image', 'altcha', 'cap', 'turnstile'};
  static const origin = 'https://h5.ctfile.com';
  static const restOrigin = 'https://rest.ctfile.com';
  final String type, state, message;
  final Map<String, String> imageHeaders;
  bool get isImage => type == 'image';
  String get _source =>
      type == 'turnstile' ? 'ctfile-turnstile' : 'ctfile-captcha';

  Uri get url {
    require(!isImage, '请使用图片验证码');
    return Uri.parse('$origin/captcha/$type.html').replace(
      queryParameters: {
        'source': 'p8',
        'action': 'login',
        'lang': 'zh-hans',
        'theme': 'light',
        'api': restOrigin,
      },
    );
  }

  bool trustedPage(String? value) {
    if (isImage) return false;
    final uri = Uri.tryParse(value ?? '');
    final expected = url;
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == expected.host &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        uri.path == expected.path &&
        expected.queryParameters.entries.every(
          (entry) =>
              uri.queryParametersAll[entry.key]?.length == 1 &&
              uri.queryParameters[entry.key] == entry.value,
        );
  }

  Uri imageUrl(String id) {
    require(isImage && RegExp(r'^[a-f0-9]{32}$').hasMatch(id), '城通验证码标识无效');
    return Uri.parse(
      '$restOrigin/p8/public/captcha/get',
    ).replace(queryParameters: {'act': 'login', 'id': id, 'lang': 'zh-hans'});
  }

  CtfileCaptchaProof imageProof(String id, String answer) {
    imageUrl(id);
    final value = answer.trim();
    require(RegExp(r'^[A-Za-z0-9]{5}$').hasMatch(value), '请输入图片中的五位验证码');
    return CtfileCaptchaProof._(state, type, value, id);
  }

  CtfileCaptchaProof? proofFromMessage(Object? value) {
    final data = asJson(value);
    if (isImage ||
        data['source'] != _source ||
        data['type'] != type ||
        data['event'] != 'success' ||
        data['token'] is! String ||
        !WebTokens.validToken(data['token'] as String)) {
      return null;
    }
    return CtfileCaptchaProof._(state, type, data['token'] as String);
  }

  String get _pageGuard =>
      "window === window.top && location.origin === '$origin' && "
      'location.pathname === ${jsonEncode(url.path)}';

  // Official pages post through ReactNativeWebView when hosted directly.
  // Keep messages in memory so fast automatic checks cannot race bridge setup.
  String get installScript =>
      '''(() => {
    if (!($_pageGuard) || window.__asterCtfileCaptureInstalled) return;
    window.__asterCtfileCaptureInstalled = true;
    const receive = raw => {
      let message;
      try { message = typeof raw === 'string' ? JSON.parse(raw) : raw; } catch (_) { return; }
      if (!message || message.source !== ${jsonEncode(_source)} ||
          message.type !== ${jsonEncode(type)} ||
          !['ready','verifying','interactive','success','expired','error'].includes(message.event)) return;
      window.__asterCtfileCaptcha = {
        source: message.source, type: message.type, event: message.event,
        token: typeof message.token === 'string' ? message.token : '',
        error: typeof message.error === 'string' ? message.error : ''
      };
    };
    window.ReactNativeWebView = {postMessage: receive};
    // Older WebViews may inject at page-start after the widget has loaded.
    // Collect an already verified official widget, or its next verified event.
    if (${jsonEncode(type)} === 'altcha') {
      const attach = () => {
        const widget = document.querySelector('altcha-widget');
        if (!widget) return;
        const success = token => receive({source: 'ctfile-captcha', type: 'altcha', event: 'success', token});
        widget.addEventListener('verified', event => success(event.detail?.payload || ''));
        if (widget.querySelector('.altcha')?.getAttribute('data-state') === 'verified') {
          success(widget.querySelector('input[type="hidden"]')?.value || '');
        }
      };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', attach, {once:true});
      else attach();
    }
  })();''';

  String get captureScript =>
      '''(() => {
    if (!($_pageGuard)) return '';
    const message = window.__asterCtfileCaptcha;
    window.__asterCtfileCaptcha = null;
    return message ? JSON.stringify(message) : '';
  })();''';
}

class CtfileCaptchaProof {
  const CtfileCaptchaProof._(
    this._state,
    this.type,
    this._value, [
    this._id = '',
  ]);
  final String _state, type, _value, _id;

  bool belongsTo(CtfileCaptchaChallenge challenge) =>
      _state == challenge.state && type == challenge.type;

  Map<String, String> get fields => type == 'image'
      ? {'captcha_id': _id, 'captcha': _value}
      : {'${type}_token': _value};
}
