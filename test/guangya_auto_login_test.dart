import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

void main() {
  test(
    'Expired refresh token renews with the remembered password and preserves account identity',
    () async {
      final initial = tokenCredential(
        CloudPlatform.guangya,
        expired: true,
        fields: {
          'authType': 'passwordToken',
          'username': 'fixture-user',
          'password': 'fixture-password',
        },
      );
      final vault = await tokenVault(CloudPlatform.guangya, initial);
      final owner = vault.activeAccountId(CloudPlatform.guangya);
      var signs = 0;
      final http = LoginHttp((r) {
        switch (r.uri.path) {
          case '/v1/auth/token':
            return jsonResponse({'error': 'invalid_grant'}, 400);
          case '/v1/shield/captcha/init':
            return jsonResponse({
              'captcha_token': 'fixture-captcha-token-0123456789',
            });
          case '/v1/auth/signin':
            signs++;
            return jsonResponse({
              'access_token': renewedAccess,
              'refresh_token': renewedRefresh,
              'expires_in': 3600,
            });
          case '/v1/user/me':
            return jsonResponse({'sub': 'user-1', 'nickname': '续登成功'});
          case '/assets/v1/get_assets':
            return guangyaAssetsResponse();
          default:
            throw StateError('Unexpected auto-login request');
        }
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      expect((await connector.account(initial)).nickname, '续登成功');
      final saved = vault.credential(CloudPlatform.guangya)!;
      expect(saved.field('accessToken'), renewedAccess);
      expect(saved.field('password'), 'fixture-password');
      expect(saved.field('authType'), 'passwordToken');
      expect(saved.updatedAt, initial.updatedAt);
      expect(vault.activeAccountId(CloudPlatform.guangya), owner);
      await connector.account(saved);
      expect(signs, 1);
    },
  );

  test(
    'Interactive verification stops renewal without repeated password attempts',
    () async {
      final initial = tokenCredential(
        CloudPlatform.guangya,
        expired: true,
        fields: {
          'authType': 'passwordToken',
          'username': 'fixture-user',
          'password': 'fixture-password',
        },
      );
      final vault = await tokenVault(CloudPlatform.guangya, initial);
      var challenges = 0;
      final http = LoginHttp((r) {
        if (r.uri.path == '/v1/auth/token') {
          return jsonResponse({'error': 'invalid_grant'}, 400);
        }
        if (r.uri.path == '/v1/shield/captcha/init') {
          challenges++;
          return jsonResponse({'url': 'https://captcha.guangyapan.com/verify'});
        }
        throw StateError('Password must not be sent before verification');
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      await expectLater(
        connector.account(initial),
        throwsA(isA<AccountLoginRequired>()),
      );
      await expectLater(
        connector.account(vault.credential(CloudPlatform.guangya)!),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(challenges, 1);
      expect(
        vault.credential(CloudPlatform.guangya)!.field('password'),
        'fixture-password',
      );
    },
  );

  test(
    'Transient network failure during password renewal does not block auto-login',
    () async {
      final initial = tokenCredential(
        CloudPlatform.guangya,
        expired: true,
        fields: {
          'authType': 'passwordToken',
          'username': 'fixture-user',
          'password': 'fixture-password',
        },
      );
      final vault = await tokenVault(CloudPlatform.guangya, initial);
      var failNetwork = true;
      final http = LoginHttp((r) {
        switch (r.uri.path) {
          case '/v1/auth/token':
            return jsonResponse({'error': 'invalid_grant'}, 400);
          case '/v1/shield/captcha/init':
            if (failNetwork) {
              throw const HttpRequestFailure(
                '网络连接失败',
                kind: 'connectionError',
                retryable: true,
              );
            }
            return jsonResponse({
              'captcha_token': 'fixture-captcha-token-0123456789',
            });
          case '/v1/auth/signin':
            return jsonResponse({
              'access_token': renewedAccess,
              'refresh_token': renewedRefresh,
              'expires_in': 3600,
            });
          case '/v1/user/me':
            return jsonResponse({'sub': 'user-1', 'nickname': '网络恢复'});
          case '/assets/v1/get_assets':
            return guangyaAssetsResponse();
          default:
            throw StateError('Unexpected auto-login request');
        }
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      await expectLater(
        connector.account(initial),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(
        vault.credential(CloudPlatform.guangya)!.field('autoLoginBlocked'),
        isNot('1'),
      );
      failNetwork = false;
      expect((await connector.account(initial)).nickname, '网络恢复');
    },
  );
}
