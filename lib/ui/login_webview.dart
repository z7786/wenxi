import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../domain/auth.dart';

InAppWebViewSettings webSettings({
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
  incognito:
      !usesAppleWebStore(platform) &&
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
    const content = login
      ? 'width=device-width,initial-scale=1,minimum-scale=0.5,maximum-scale=8,user-scalable=yes'
      : 'width=1280,minimum-scale=0.1,maximum-scale=8,user-scalable=yes';
    document.documentElement?.toggleAttribute('data-aster-guangya-login', login);
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
