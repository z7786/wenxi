import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/login_webview.dart';

class _Cookies extends PlatformCookieManager {
  _Cookies()
    : super.implementation(const PlatformCookieManagerCreationParams());
  final values = <Cookie>[];
  final removed = <({String name, String? domain, String path, String url})>[];
  int clearedAll = 0;
  @override
  Future<List<Cookie>> getAllCookies() async => List.of(values);
  @override
  Future<bool> deleteAllCookies() async {
    clearedAll++;
    values.clear();
    return true;
  }

  @override
  Future<bool> deleteCookie({
    required WebUri url,
    required String name,
    String path = '/',
    String? domain,
    PlatformInAppWebViewController? iosBelow11WebViewController,
    PlatformInAppWebViewController? webViewController,
  }) async {
    removed.add((name: name, domain: domain, path: path, url: url.toString()));
    values.removeWhere(
      (c) => c.name == name && c.domain == domain && (c.path ?? '/') == path,
    );
    return true;
  }
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    test(
      '$platform main login and SSO popup share the cookie manager store',
      () {
        for (final popup in [false, true]) {
          final settings = webSettings(platform: platform, isPopup: popup);
          expect(settings.incognito, isFalse);
          expect(settings.cacheEnabled, isTrue);
          expect(settings.javaScriptEnabled, isTrue);
        }
      },
    );
    test('$platform login cleanup keeps unrelated search cookies', () async {
      final cookies = _Cookies();
      cookies.values.addAll([
        Cookie(
          name: 'USERSESSIONID',
          value: 'old',
          domain: '.189.cn',
          path: '/',
        ),
        Cookie(
          name: 'SSO',
          value: 'old',
          domain: 'open.e.189.cn',
          path: '/api',
        ),
        Cookie(
          name: '__cf_bm',
          value: 'challenge',
          domain: '.search.example',
          path: '/',
        ),
        Cookie(
          name: 'unrelated',
          value: 'keep',
          domain: '189.cn.example',
          path: '/',
        ),
      ]);
      await forgetWebLoginCookies(
        CookieManager.fromPlatform(cookies),
        WebLoginTarget.targets[CloudPlatform.tianyi]!,
        platform: platform,
      );
      expect(cookies.clearedAll, 0);
      expect(cookies.values.map((c) => c.name), ['__cf_bm', 'unrelated']);
      expect(cookies.removed.map((c) => c.name), ['USERSESSIONID', 'SSO']);
      expect(cookies.removed.last.path, '/api');
      expect(cookies.removed.last.url, 'https://open.e.189.cn/api');
    });
  }
  test(
    'Android and Windows keep their existing cookie cleanup and popup profile',
    () async {
      expect(webSettings(platform: TargetPlatform.android).incognito, isTrue);
      expect(
        webSettings(platform: TargetPlatform.android, isPopup: true).incognito,
        isFalse,
      );
      expect(
        webSettings(platform: TargetPlatform.windows, isPopup: true).incognito,
        isTrue,
      );
      for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
        final cookies = _Cookies();
        await forgetWebLoginCookies(
          CookieManager.fromPlatform(cookies),
          WebLoginTarget.targets[CloudPlatform.quark]!,
          platform: platform,
        );
        expect(cookies.clearedAll, 1);
        expect(cookies.removed, isEmpty);
      }
    },
  );
  test(
    'login cleanup covers provider account hosts and rejects lookalike domains',
    () {
      final lanzou = WebLoginTarget.targets[CloudPlatform.lanzou]!;
      expect(loginCookieDomain(lanzou, '.woozooo.com'), isTrue);
      expect(loginCookieDomain(lanzou, 'accounts.woozooo.com'), isTrue);
      expect(loginCookieDomain(lanzou, 'woozooo.com.invalid'), isFalse);
      expect(loginCookieDomain(lanzou, null), isFalse);
    },
  );
}
