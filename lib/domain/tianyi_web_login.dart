import 'dart:convert';
import '../core/json.dart';

class TianyiWebLogin {
  // The official parent creates the browser fingerprint and passes it to the
  // SSO iframe. Opening the portal API directly skips that initialization.
  static const loginUrl = 'https://cloud.189.cn/web/login.html';

  static const identityUrl =
      'https://cloud.189.cn/api/open/user/getUserInfoForPortal.action';
  // Only scopes which can actually send cookies to the portal identity API.
  // The WAP callback and /web path can hold unrelated same-name sessions.
  static const cookieUrls = [
    identityUrl,
    'https://cloud.189.cn/api/',
    'https://cloud.189.cn/',
  ];

  static const origins = {
    'https://cloud.189.cn',
    'https://m.cloud.189.cn',
    'https://h5.cloud.189.cn',
  };

  static bool trusted(String? address) {
    final uri = Uri.tryParse(address ?? '');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.hasAuthority &&
        uri.port == 443 &&
        uri.userInfo.isEmpty &&
        origins.contains(uri.origin);
  }

  static bool isCompletionLanding(String? address) {
    if (!trusted(address)) return false;
    final uri = Uri.parse(address!);
    return switch (uri.host) {
      'cloud.189.cn' => {
        '/web/redirect.html',
        '/web/main',
        '/web/main/',
      }.contains(uri.path),
      'm.cloud.189.cn' => uri.path == '/main.action',
      'h5.cloud.189.cn' => {'/', '/home.html'}.contains(uri.path),
      _ => false,
    };
  }

  static Json decode(Object? value) {
    if (value is Map) return asJson(value);
    if (value is! String ||
        value.length > 131072 ||
        !value.trimLeft().startsWith('{')) {
      return {};
    }
    try {
      return asJson(jsonDecode(value));
    } on FormatException {
      return {};
    }
  }

  static String cookie(String raw) =>
      raw.trimLeft().startsWith('{') ? decode(raw).str('cookie') : raw;

  static String browserId(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{8,256}$').hasMatch(value)
      ? value
      : '';

  static const maxCookieCandidates = 3;

  static List<String> cookieCandidates(Object? raw) {
    final result = <String>{};
    final values = decode(raw)['cookieCandidates'];
    if (values is! List) return const [];
    for (final value in values.take(maxCookieCandidates)) {
      if (value is! String ||
          value.length > 16384 ||
          RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value) ||
          !RegExp(
            r'(?:^|;)\s*(?:COOKIE_LOGIN_USER|LOGIN_USER)=[^;\s]+',
          ).hasMatch(value)) {
        continue;
      }
      result.add(value.trim());
    }
    return result.toList();
  }

  static String encode(
    String cookie,
    Object? browser, {
    List<String> candidates = const [],
  }) {
    final id = browserId(browser);
    final headers = cookieCandidates({'cookieCandidates': candidates});
    return id.isEmpty && headers.length < 2
        ? cookie
        : jsonEncode({
            'cookie': cookie,
            if (id.isNotEmpty) 'browserId': id,
            if (headers.length > 1) 'cookieCandidates': headers,
          });
  }

  static Map<String, String> fields(String raw) => {
    'primary': cookie(raw),
    if (browserId(decode(raw)['browserId']).isNotEmpty)
      'browserId': browserId(decode(raw)['browserId']),
    if (cookieCandidates(raw).length > 1)
      'cookieCandidates': jsonEncode({
        'cookieCandidates': cookieCandidates(raw),
      }),
  };

  static const formScript = r'''(() => {
    if (location.origin !== 'https://open.e.189.cn' ||
        location.pathname !== '/api/logbox/separate/web/index.html' ||
        new URL(location.href).searchParams.get('appId') !== 'cloud' || window.__asterTianyiForm) return;
    if (window.top !== window) {
      try {
        const parent = new URL(document.referrer);
        if (window.parent !== window.top || parent.origin !== 'https://cloud.189.cn' ||
            parent.username || parent.password) return;
      } catch (_) { return; }
    }
    window.__asterTianyiForm = true;
    let observer, accountSelected = false;
    const visible = el => el && el.getClientRects().length && !el.disabled;
    const select = () => {
      const sms = document.getElementById('j-jump-sms');
      if (visible(sms)) {
        observer.disconnect();
        sms.click();
        return;
      }
      const account = document.getElementById('tab-pw');
      if (!accountSelected && visible(account)) {
        accountSelected = true;
        account.click();
      }
    };
    observer = new MutationObserver(select);
    observer.observe(document, {childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'style', 'hidden']});
    select();
    setTimeout(() => observer.disconnect(), 15000);
  })()''';

  // The official login iframe and account API share a browser fingerprint.
  // Observe the value already used by that page; do not generate a replacement.
  static const bootstrapScript = r'''(() => {
    if (window.top !== window || !['https://cloud.189.cn', 'https://m.cloud.189.cn', 'https://h5.cloud.189.cn'].includes(location.origin)) return;
    if (window.__asterTianyiLogin) return;
    let latest = '';
    const identifier = value => typeof value === 'string' && /^[A-Za-z0-9_-]{8,256}$/.test(value) ? value : '';
    const api = address => {
      try {
        const url = new URL(address, location.href);
        return url.origin === 'https://cloud.189.cn' && !url.username && !url.password && url.pathname.startsWith('/api/') ? url : null;
      } catch (_) { return null; }
    };
    const remember = (address, value) => {
      const id = identifier(value);
      if (id && api(address)) latest = id;
    };
    window.__asterTianyiLogin = {read: () => {
      const frame = document.getElementById('udb_login');
      const url = frame?.src ? api(frame.src) : null;
      if (url?.pathname === '/api/portal/loginUrl.action') remember(url.href, url.searchParams.get('browserId'));
      return {browserId: latest};
    }};
    if (typeof XMLHttpRequest !== 'undefined') {
      const requests = new WeakMap();
      const open = XMLHttpRequest.prototype.open;
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, address) {
        requests.set(this, {address: String(address), id: ''});
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
        const request = requests.get(this);
        if (request && String(name).toLowerCase() === 'browser-id') request.id = identifier(value);
        return setHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        const request = requests.get(this);
        if (request) remember(request.address, request.id);
        return send.apply(this, arguments);
      };
    }
    if (typeof window.fetch === 'function') {
      const fetch = window.fetch;
      window.fetch = function(input, init) {
        try {
          const address = typeof input === 'string' || input instanceof URL ? String(input) : input?.url;
          const headers = new Headers(init?.headers ?? input?.headers);
          remember(address, headers.get('Browser-Id'));
        } catch (_) {}
        return fetch.apply(this, arguments);
      };
    }
  })()''';

  static const readScript = r'''(() => {
    if (window.top !== window || !['https://cloud.189.cn', 'https://m.cloud.189.cn', 'https://h5.cloud.189.cn'].includes(location.origin)) return '';
    return JSON.stringify(window.__asterTianyiLogin?.read() || {});
  })()''';
}
