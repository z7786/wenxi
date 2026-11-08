import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/login_webview.dart';

void main() {
  test(
    'Android Aliyun uses mobile layout with unchanged credential capture',
    () {
      final original = WebLoginTarget.targets[CloudPlatform.aliyun]!;
      final target = webLoginTarget(
        CloudPlatform.aliyun,
        platform: TargetPlatform.android,
      );
      expect(target.userAgent, WebLoginTarget.mobileUserAgent);
      expect(target.desktopMode, isFalse);
      expect(target.url, original.url);
      expect(target.cookieDomains, original.cookieDomains);
      expect(target.clearCookieDomains, original.clearCookieDomains);
      expect(target.storageOrigins, original.storageOrigins);
      expect(target.localStorageKey, 'token');
      expect(target.readStorageScript, original.readStorageScript);
      expect(target.clearStorageScript, original.clearStorageScript);
      expect(
        target.prepareStorageScript('fixture-session'),
        original.prepareStorageScript('fixture-session'),
      );
      expect(target.storageOriginRules, original.storageOriginRules);
      expect(target.cookieUrls(target.url), original.cookieUrls(original.url));
      expect(
        target.canReadLocalStorage('https://www.alipan.com/drive'),
        isTrue,
      );
      for (final url in [
        'http://www.alipan.com/drive',
        'https://www.alipan.com:444/drive',
        'https://www.alipan.com.invalid/drive',
        'https://auth.aliyundrive.com/',
        'https://user@www.alipan.com/drive',
      ]) {
        expect(target.canReadLocalStorage(url), isFalse, reason: url);
      }
      for (final popup in [false, true]) {
        final settings = webSettings(
          userAgent: target.userAgent,
          desktopMode: target.desktopMode,
          isPopup: popup,
          platform: TargetPlatform.android,
        );
        expect(settings.userAgent, WebLoginTarget.mobileUserAgent);
        expect(settings.preferredContentMode, UserPreferredContentMode.MOBILE);
        expect(settings.loadWithOverviewMode, isFalse);
        expect(settings.javaScriptEnabled, isTrue);
        expect(settings.domStorageEnabled, isTrue);
        expect(settings.incognito, !popup);
      }
      expect(original.desktopMode, isTrue);
      expect(original.userAgent, WebLoginTarget.desktopUserAgent);
    },
  );

  for (final platform in TargetPlatform.values) {
    test('$platform retains existing settings outside Android Aliyun', () {
      for (final cloud in WebLoginTarget.targets.keys) {
        if (platform == TargetPlatform.android &&
            cloud == CloudPlatform.aliyun) {
          continue;
        }
        expect(
          webLoginTarget(cloud, platform: platform),
          same(WebLoginTarget.targets[cloud]),
        );
      }
    });
  }
}
