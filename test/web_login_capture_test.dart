import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/xunlei_web_login.dart';

void main() {
  test(
    'Ctfile detects the website session and prefers account API cookies',
    () {
      final target = WebLoginTarget.targets[CloudPlatform.ctfile]!;
      expect(target.url, 'https://my.ctfile.com/login');
      expect(target.localStorageKey, isNull);
      final urls = target.cookieUrls(
        'https://my.ctfile.com/login?ticket=private',
      );
      expect(urls.first, 'https://api.ctfile.com/v4/user/auth/exchange-token');
      expect(urls.join(), isNot(contains('private')));
      expect(
        target.cookieUrls('https://my.ctfile.com.attacker.invalid/'),
        isNot(contains('https://my.ctfile.com.attacker.invalid/')),
      );
      for (final cookies in [
        <String>[],
        ['tracking=optional'],
        ['ctfile_session=; ct_uid=12'],
      ]) {
        expect(
          LoginCredentials.fromBrowser(CloudPlatform.ctfile, cookies: cookies),
          isEmpty,
        );
      }
      final raw = LoginCredentials.fromBrowser(
        CloudPlatform.ctfile,
        cookies: [
          'ctfile_session=current-web-session; ct_uid=12',
          'ctfile_session=stale-page-session',
        ],
      );
      final credential = LoginCredentials.candidate(
        CloudPlatform.ctfile,
        raw,
        Credential('old', {'primary': 'old-session-token', 'userId': '99'}),
      );
      expect(
        credential.primary,
        contains('ctfile_session=current-web-session'),
      );
      expect(credential.primary, isNot(contains('stale')));
      expect(credential.field('userId'), isEmpty);
    },
  );
  test(
    'Xunlei captures web tokens without inheriting another login password',
    () {
      const data = {
        'access_token': 'fixture-access-token-0123456789',
        'refresh_token': 'fixture-refresh-token-0123456789',
        'sub': 'new-user',
        'device_id': 'web-device-0123456789',
        'captcha_token': 'fixture-captcha-token-0123456789',
      };
      for (final storage in [data, jsonEncode(data)]) {
        final raw = LoginCredentials.fromBrowser(
          CloudPlatform.xunlei,
          storage: storage,
        );
        final candidate = LoginCredentials.candidate(
          CloudPlatform.xunlei,
          raw,
          Credential('old-user', {
            'username': 'old-user',
            'password': 'old-secret',
          }),
        );
        expect(candidate.field('accessToken'), data['access_token']);
        expect(candidate.field('refreshToken'), data['refresh_token']);
        expect(candidate.field('clientId'), XunleiWebLogin.clientId);
        expect(candidate.field('captchaToken'), data['captcha_token']);
        expect(candidate.field('deviceId'), data['device_id']);
        expect(candidate.field('userId'), 'new-user');
        expect(candidate.field('password'), isEmpty);
        expect(candidate.field('username'), isEmpty);
      }
      expect(
        LoginCredentials.fromBrowser(
          CloudPlatform.xunlei,
          cookies: ['sessionid=unvalidated-cookie'],
        ),
        isEmpty,
      );
    },
  );

  test('Xunlei web storage is restricted to its official HTTPS origin', () {
    final target = WebLoginTarget.targets[CloudPlatform.xunlei]!;
    expect(target.localStorageKey, XunleiWebLogin.storageKey);
    expect(target.canReadLocalStorage('https://pan.xunlei.com/'), isTrue);
    for (final url in [
      'http://pan.xunlei.com/',
      'https://pan.xunlei.com:444/',
      'https://pan.xunlei.com.invalid/',
      'https://i.xunlei.com/',
      'https://account.xiaomi.com/fe/service/login/password',
      'https://open-api-auth.xunlei.com/platform',
      'https://user@pan.xunlei.com/',
    ]) {
      expect(target.canReadLocalStorage(url), isFalse);
    }
  });

  test(
    'ILanzou uses a native HttpOnly appToken and retains its stored device',
    () {
      final raw = LoginCredentials.fromBrowser(
        CloudPlatform.ilanzou,
        storage: jsonEncode({
          'uuid': 'official-browser-device',
          'appToken': '',
        }),
        cookies: [
          'appToken=fixture%3Atoken%2Bwith%2Freserved%3D; unrelated=ignore',
        ],
      );
      final credential = LoginCredentials.candidate(
        CloudPlatform.ilanzou,
        raw,
        null,
      );
      expect(credential.field('accessToken'), 'fixture:token+with/reserved=');
      expect(credential.field('uuid'), 'official-browser-device');
      expect(raw, isNot(contains('unrelated')));
    },
  );

  test(
    'native WebView map results and JSON string results are both accepted',
    () {
      const data = {
        'appToken': 'fixture-app-token-0123456789',
        'uuid': 'browser-device',
      };
      for (final stored in [data, jsonEncode(data)]) {
        final raw = LoginCredentials.fromBrowser(
          CloudPlatform.ilanzou,
          storage: stored,
        );
        expect(LoginCredentials.plausible(CloudPlatform.ilanzou, raw), isTrue);
      }
    },
  );

  test('Wopan accepts native token cookies when page storage is unavailable', () {
    final raw = LoginCredentials.fromBrowser(
      CloudPlatform.wopan,
      cookies: [
        'access_token=fixture-access-token-0123456789; refresh_token=fixture-refresh-token-0123456789',
      ],
    );
    final credential = LoginCredentials.candidate(
      CloudPlatform.wopan,
      raw,
      null,
    );
    expect(credential.field('accessToken'), 'fixture-access-token-0123456789');
    expect(
      credential.field('refreshToken'),
      'fixture-refresh-token-0123456789',
    );
  });

  test(
    'Weiyun merges native cookies from the disk and its login callback path',
    () {
      final raw = LoginCredentials.fromBrowser(
        CloudPlatform.weiyun,
        cookies: [
          'wy_uf=0; uin=o1234567',
          'p_skey=fixture-weiyun-session; wyctoken=fixture-csrf',
        ],
      );
      expect(LoginCredentials.plausible(CloudPlatform.weiyun, raw), isTrue);
      final target = WebLoginTarget.targets[CloudPlatform.weiyun]!;
      expect(
        target.cookieUrls('https://www.weiyun.com/disk').first,
        'https://www.weiyun.com/webapp/json/weiyunQdiskClient/DiskUserInfoGet',
      );
      expect(
        target.cookieUrls(
          'https://www.weiyun.com/web/callback/login?ticket=private',
        ),
        contains('https://www.weiyun.com/webapp/'),
      );
      expect(
        target.cookieUrls('https://unrelated.invalid/'),
        isNot(contains('https://unrelated.invalid/')),
      );
      expect(
        target
            .cookieUrls(
              'https://www.weiyun.com/web/callback/login?ticket=private',
            )
            .join(),
        isNot(contains('private')),
      );
    },
  );

  test(
    'Wopan accepts both official origins without allowing sibling or spoofed sites',
    () {
      final target = WebLoginTarget.targets[CloudPlatform.wopan]!;
      for (final url in [
        'https://panservice.mail.wo.cn/h5/wocloud_ai/',
        'https://pan.wo.cn/web',
      ]) {
        expect(target.canReadLocalStorage(url), isTrue);
      }
      for (final url in [
        'http://pan.wo.cn/',
        'https://pan.wo.cn:444/',
        'https://pan.wo.cn.attacker.invalid/',
        'https://mail.wo.cn/',
        'https://user@pan.wo.cn/',
      ]) {
        expect(target.canReadLocalStorage(url), isFalse);
      }
    },
  );

  test('123 authorToken remains a storage credential', () {
    expect(
      LoginCredentials.fromBrowser(
        CloudPlatform.pan123,
        storage: 'fixture-author-token',
      ),
      'fixture-author-token',
    );
  });
}
