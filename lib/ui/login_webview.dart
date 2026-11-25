import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../domain/auth.dart';
import '../domain/models.dart';

WebLoginTarget webLoginTarget(CloudPlatform cloud, {TargetPlatform? platform}) {
  final target = WebLoginTarget.targets[cloud]!;
  if (cloud != CloudPlatform.aliyun ||
      (platform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return target;
  }
  // Aliyun's Android login/captcha expects a mobile browser. Keep the original
  // desktop target and token/cookie capture rules for the other clients.
  return WebLoginTarget(
    target.platform,
    target.url,
    target.cookieDomains,
    userAgent: WebLoginTarget.mobileUserAgent,
    desktopMode: false,
    localStorageKey: target.localStorageKey,
    clearCookieDomains: target.clearCookieDomains,
    storageOrigins: target.storageOrigins,
  );
}

InAppWebViewSettings webSettings({
  CloudPlatform? cloud,
  String? userAgent,
  bool desktopMode = true,
  bool isPopup = false,
  TargetPlatform? platform,
}) => InAppWebViewSettings(
  javaScriptEnabled: true,
  domStorageEnabled: true,
  allowFileAccess: false,
  allowContentAccess: false,
  useShouldOverrideUrlLoading: true,
  userAgent:
      userAgent ??
      (desktopMode
          ? WebLoginTarget.desktopUserAgent
          : WebLoginTarget.mobileUserAgent),
  preferredContentMode: desktopMode
      ? UserPreferredContentMode.DESKTOP
      : UserPreferredContentMode.MOBILE,
  useWideViewPort: true,
  loadWithOverviewMode: desktopMode,
  mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
  thirdPartyCookiesEnabled: true,
  // WebView2 requires authorization windows to share the opener's InPrivate
  // profile. Android popups must avoid clearing the shared cookie jar again.
  // WK CookieManager reads the default website store. Keep Apple login
  // windows and their SSO popups in that store so HttpOnly cookies are visible.
  // Tianyi waits for Android cookie cleanup before opening its portal. Plugin
  // incognito would start another global, unawaited removeAllCookies call.
  incognito:
      !usesAppleWebStore(platform) &&
      !(cloud == CloudPlatform.tianyi &&
          (platform ?? defaultTargetPlatform) == TargetPlatform.android) &&
      (!isPopup ||
          (platform ?? defaultTargetPlatform) == TargetPlatform.windows),
  cacheEnabled: usesAppleWebStore(platform),
  saveFormData: false,
  supportZoom: true,
  builtInZoomControls: true,
  displayZoomControls: false,
  ignoresViewportScaleLimits: true,
);

bool usesAppleWebStore([TargetPlatform? platform]) =>
    switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };

bool loginCookieDomain(WebLoginTarget target, String? domain) {
  final host = (domain ?? '').replaceFirst(RegExp(r'^\.'), '').toLowerCase();
  if (host.isEmpty) return false;
  final roots = <String>{
    ...target.platform.hosts,
    for (final value in [
      target.url,
      ...target.cookieDomains,
      ...target.clearCookieDomains,
      ...target.storageOrigins,
    ])
      Uri.parse(value).host.toLowerCase(),
  };
  return roots.any((root) => host == root || host.endsWith('.$root'));
}

Future<void> forgetWebLoginCookies(
  CookieManager manager,
  WebLoginTarget target, {
  TargetPlatform? platform,
}) async {
  if (!usesAppleWebStore(platform)) {
    await manager.deleteAllCookies();
    return;
  }
  // Apple login and search share WK's default store. Clear only this provider's
  // cookies so adding an account cannot erase an unrelated search challenge.
  for (final cookie in await manager.getAllCookies()) {
    if (!loginCookieDomain(target, cookie.domain)) continue;
    final domain = cookie.domain!.replaceFirst(RegExp(r'^\.'), '');
    final path = cookie.path ?? '/';
    await manager.deleteCookie(
      url: WebUri(Uri(scheme: 'https', host: domain, path: path).toString()),
      name: cookie.name,
      domain: cookie.domain,
      path: path,
    );
  }
}

// A desktop UA alone does not override a site's mobile viewport. Keep the main
// document wide and zoomable, including when an SPA replaces its viewport tag.
// Nested login/captcha frames keep the dimensions chosen by their parent page.
const desktopLoginViewportScript = r'''(() => {
  if (window.top !== window || location.protocol !== 'https:' ||
      window.__asterDesktopViewport) return;
  window.__asterDesktopViewport = true;
  const apply = () => {
    if (!document.head) return;
    const login = location.hostname === 'www.guangyapan.com' &&
      (location.hash.split('?')[0] === '#/oauth/login' || location.pathname === '/oauth/login');
    const tianyiParent = location.origin === 'https://cloud.189.cn' &&
      location.pathname === '/web/login.html';
    const tianyi = tianyiParent || (location.origin === 'https://open.e.189.cn' &&
      location.pathname === '/api/logbox/separate/web/index.html');
    const content = login
      ? 'width=device-width,initial-scale=1,minimum-scale=0.5,maximum-scale=8,user-scalable=yes'
      : tianyi
      ? 'width=400,minimum-scale=0.1,maximum-scale=8,user-scalable=yes'
      : 'width=1280,minimum-scale=0.1,maximum-scale=8,user-scalable=yes';
    document.documentElement?.toggleAttribute('data-aster-guangya-login', login);
    document.documentElement?.toggleAttribute('data-aster-tianyi-login', tianyiParent);
    if (tianyiParent && !document.getElementById('aster-tianyi-login-layout')) {
      const style = document.createElement('style');
      style.id = 'aster-tianyi-login-layout';
      style.textContent = 'html[data-aster-tianyi-login] .main-contain{min-width:400px!important;width:100%!important;' +
        'display:flex!important;justify-content:center!important;align-items:flex-start!important;box-sizing:border-box;margin:0!important;padding:24px 0!important}' +
        'html[data-aster-tianyi-login] .main-contain>.main-center,html[data-aster-tianyi-login] .main-contain>.robot-bg{display:none!important}' +
        'html[data-aster-tianyi-login] .main-contain>.login-pannel{position:static!important;margin:0!important;transform:none!important;flex:none!important}' +
        'html[data-aster-tianyi-login] #J_narBar,html[data-aster-tianyi-login] .behind-content,' +
        'html[data-aster-tianyi-login] .footer-container,html[data-aster-tianyi-login] .ad-placeholder-blank{display:none!important}';
      document.head.appendChild(style);
    }
    if (login && !document.getElementById('aster-guangya-login-layout')) {
      const style = document.createElement('style');
      style.id = 'aster-guangya-login-layout';
      style.textContent = 'html[data-aster-guangya-login] #app{min-width:0!important;width:100%!important}' +
        'html[data-aster-guangya-login] #app>div{max-width:480px;margin-inline:auto;width:100%}';
      document.head.appendChild(style);
    }
    let tags = [...document.head.querySelectorAll('meta[name="viewport"]')];
    if (!tags.length) {
      const tag = document.createElement('meta');
      tag.name = 'viewport';
      document.head.appendChild(tag);
      tags = [tag];
    }
    for (const tag of tags) {
      if (tag.content !== content) tag.content = content;
    }
  };
  const install = () => {
    if (!document.head) return;
    apply();
    new MutationObserver(apply).observe(document.head, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ['name', 'content']
    });
  };
  if (document.head) install();
  else document.addEventListener('DOMContentLoaded', install, {once: true});
  window.addEventListener('hashchange', apply);
  window.addEventListener('popstate', apply);
})();''';

UserScript desktopLoginUserScript() => UserScript(
  source: desktopLoginViewportScript,
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  forMainFrameOnly: true,
);
