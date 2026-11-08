import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/guangya_login.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const _verification = 'fixture-verification-id-0123456789';
const _proof = 'fixture-verification-token-0123456789';
const _captcha = 'fixture-captcha-token-0123456789';
HttpResult _response(
  RecordedRequest r, {
  bool? isUser = true,
  String verificationId = _verification,
}) => switch (r.uri.path) {
  '/v1/shield/captcha/init' => jsonResponse({'captcha_token': _captcha}),
  '/v1/auth/verification' => jsonResponse({
    'verification_id': verificationId,
    'is_user': ?isUser,
    'expires_in': 600,
  }),
  '/v1/auth/verification/verify' => jsonResponse({
    'verification_token': _proof,
  }),
  '/v1/auth/signin' || '/v1/auth/signup' => jsonResponse({
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_in': 3600,
  }),
  '/assets/v1/get_assets' => guangyaAssetsResponse(),
  _ => throw StateError('Unexpected SMS endpoint'),
};

void main() {
  test(
    'SMS login validates the account with GET before saving its credentials',
    () async {
      final vault = Vault(StateStore.memory());
      final http = LoginHttp((r) {
        if (r.uri.path != '/v1/user/me') return _response(r);
        if (r.method != 'GET') {
          return jsonResponse({'error': 'unimplemented'}, 501);
        }
        expect(r.body, isNull);
        expect(r.headers['Authorization'], 'Bearer $accessToken');
        return jsonResponse({'sub': 'sms-account', 'name': '短信登录账号'});
      });
      final sms = GuangyaSmsLogin(http, now: () => tokenClock);
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      final login = AccountLoginService(vault, (_, c) => connector.account(c));
      final challenge = await sms.sendSms('13800000000');
      await login.submit(
        CloudPlatform.guangya,
        (_) async => connector.authenticate(await sms.sms(challenge, '123456')),
      );
      expect(
        vault.credential(CloudPlatform.guangya)?.field('userId'),
        'sms-account',
      );
      expect(
        vault.credential(CloudPlatform.guangya)?.field('refreshToken'),
        refreshToken,
      );
      expect(
        http.calls.where((r) => r.uri.path == '/v1/user/me').single.method,
        'GET',
      );
      expect(http.calls.last.uri.path, '/assets/v1/get_assets');
    },
  );

  test(
    'SMS follows the official verification and sign-in sequence with one device',
    () async {
      final http = LoginHttp(_response),
          login = GuangyaSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms('13800000000');
      final credential = await login.sms(challenge, '123456');
      expect(http.calls.map((r) => r.uri.path), [
        '/v1/shield/captcha/init',
        '/v1/auth/verification',
        '/v1/auth/verification/verify',
        '/v1/shield/captcha/init',
        '/v1/auth/signin',
      ]);
      expect(http.calls.first.json['action'], 'POST:/v1/auth/verification');
      expect(http.calls[1].json['phone_number'], '+86 13800000000');
      expect(http.calls[1].json['target'], 'ANY');
      expect(http.calls[2].json['verification_id'], _verification);
      expect(http.calls.last.json, {
        'client_id': GuangyaLoginProtocol.clientId,
        'username': '+86 13800000000',
        'verification_token': _proof,
        'verification_code': '123456',
      });
      expect(
        http.calls.map((r) => r.headers['X-Device-Id']).toSet(),
        hasLength(1),
      );
      expect(http.redirects, everyElement(isFalse));
      expect(credential.field('refreshToken'), refreshToken);
      expect(credential.field('expiresAt'), '${tokenClock + 3600000}');
      expect(credential.field('username'), '13800000000');
      expect(credential.fields.values, isNot(contains('123456')));
      expect(credential.fields.keys, isNot(contains('password')));
    },
  );

  test('a new phone uses signup only after verifying its SMS proof', () async {
    final http = LoginHttp((r) => _response(r, isUser: false)),
        login = GuangyaSmsLogin(http, now: () => tokenClock);
    final challenge = await login.sendSms('13800000000');
    expect(challenge.isUser, isFalse);
    await login.sms(challenge, '123456');
    expect(http.calls.last.uri.path, '/v1/auth/signup');
    expect(http.calls.last.json['phone_number'], '+86 13800000000');
    expect(http.calls.last.json['verification_token'], _proof);
    expect(http.calls.last.json['username'], isNull);
    expect(http.calls.last.json['name'], '138****0000');
  });

  test(
    'verification JWT without is_user is forwarded unchanged to signin',
    () async {
      // Synthetic opaque JWT fixture, not a credential or a decoded identity.
      final jwt = '${'a' * 80}.${'b' * 420}.${'c' * 89}';
      final http = LoginHttp(
        (r) => _response(r, isUser: null, verificationId: jwt),
      );
      final login = GuangyaSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms('13800000000');
      expect(jwt.length, 591);
      expect(challenge.isUser, isNull);
      final credential = await login.sms(challenge, '123456');
      expect(http.calls[2].json['verification_id'], jwt);
      expect(http.calls.last.uri.path, '/v1/auth/signin');
      expect(http.calls.where((r) => r.uri.path.endsWith('/signup')), isEmpty);
      expect(credential.field('refreshToken'), refreshToken);
      expect(credential.fields.values, isNot(contains('123456')));
    },
  );

  test(
    'unknown account registers once only after explicit user_not_found',
    () async {
      final http = LoginHttp(
        (r) => r.uri.path == '/v1/auth/signin'
            ? jsonResponse({'error': 'user_not_found'}, 400)
            : _response(r, isUser: null),
      );
      final login = GuangyaSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms('13800000000');
      final credential = await login.sms(challenge, '123456');
      expect(http.calls.map((r) => r.uri.path), [
        '/v1/shield/captcha/init',
        '/v1/auth/verification',
        '/v1/auth/verification/verify',
        '/v1/shield/captcha/init',
        '/v1/auth/signin',
        '/v1/auth/signup',
      ]);
      final signup = http.calls.last;
      expect(signup.json['verification_token'], _proof);
      expect(signup.json['verification_code'], '123456');
      expect(signup.json['phone_number'], '+86 13800000000');
      expect(signup.json['name'], '138****0000');
      expect(signup.json['username'], isNull);
      expect(
        http.calls.map((r) => r.headers['X-Device-Id']).toSet(),
        hasLength(1),
      );
      expect(
        http.calls.map((r) => r.headers['X-Device-Sign']).toSet(),
        hasLength(1),
      );
      expect(credential.field('refreshToken'), refreshToken);
      expect(credential.fields.values, isNot(contains('123456')));
    },
  );

  for (final (status, error) in [
    (429, 'too_many_requests'),
    (429, 'user_not_found'),
    (400, 'invalid_verification_code'),
    (400, 'verification_expired'),
    (400, 'invalid_verification_token'),
    (403, 'captcha_required'),
    (403, 'captcha_invalid'),
    (403, ''),
    (400, 'invalid_credentials'),
    (500, 'user_not_found'),
  ]) {
    test(
      'unknown account does not register on signin $status $error',
      () async {
        final http = LoginHttp(
          (r) => r.uri.path == '/v1/auth/signin'
              ? jsonResponse({
                  'error': error,
                  'error_description': 'private: 123456',
                }, status)
              : _response(r, isUser: null),
        );
        final login = GuangyaSmsLogin(http, now: () => tokenClock);
        final challenge = await login.sendSms('13800000000');
        await expectLater(
          login.sms(challenge, '123456'),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              isNot(contains('123456')),
            ),
          ),
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/signup')),
          isEmpty,
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/signin')),
          hasLength(1),
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/verify')),
          hasLength(1),
        );
      },
    );
  }

  test('a known account never falls back to registration', () async {
    final http = LoginHttp(
      (r) => r.uri.path == '/v1/auth/signin'
          ? jsonResponse({'error': 'user_not_found'}, 400)
          : _response(r),
    );
    final login = GuangyaSmsLogin(http, now: () => tokenClock);
    final challenge = await login.sendSms('13800000000');
    await expectLater(
      login.sms(challenge, '123456'),
      throwsA(isA<AppException>()),
    );
    expect(http.calls.where((r) => r.uri.path.endsWith('/signup')), isEmpty);
  });

  test('captcha initialization error cannot trigger registration', () async {
    final http = LoginHttp(
      (r) =>
          r.uri.path == '/v1/shield/captcha/init' &&
              r.json['action'] == 'POST:/v1/auth/signin'
          ? jsonResponse({'error': 'user_not_found'}, 400)
          : _response(r, isUser: null),
    );
    final login = GuangyaSmsLogin(http, now: () => tokenClock);
    final challenge = await login.sendSms('13800000000');
    await expectLater(
      login.sms(challenge, '123456'),
      throwsA(isA<AppException>()),
    );
    expect(http.calls.where((r) => r.uri.path.endsWith('/signup')), isEmpty);
    expect(http.calls.where((r) => r.uri.path.endsWith('/signin')), isEmpty);
  });

  test(
    'cancelled signin captcha does not register an unknown account',
    () async {
      final http = LoginHttp(
        (r) =>
            r.uri.path == '/v1/shield/captcha/init' &&
                r.json['action'] == 'POST:/v1/auth/signin'
            ? jsonResponse({'url': 'https://captcha.guangyapan.com/verify'})
            : _response(r, isUser: null),
      );
      final login = GuangyaSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms('13800000000');
      await expectLater(
        login.sms(challenge, '123456', verifyCaptcha: (_) async => null),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.where((r) => r.uri.path.endsWith('/signup')), isEmpty);
      expect(http.calls.where((r) => r.uri.path.endsWith('/signin')), isEmpty);
    },
  );

  test('signin timeout cannot register an unknown account', () async {
    final http = LoginHttp((r) {
      if (r.uri.path == '/v1/auth/signin') {
        throw TimeoutException('fixture timeout');
      }
      return _response(r, isUser: null);
    });
    final login = GuangyaSmsLogin(http, now: () => tokenClock);
    final challenge = await login.sendSms('13800000000');
    await expectLater(
      login.sms(challenge, '123456'),
      throwsA(isA<TimeoutException>()),
    );
    expect(http.calls.where((r) => r.uri.path.endsWith('/signup')), isEmpty);
  });

  test('leaving during signin prevents a late user_not_found signup', () async {
    final delayed = Completer<HttpResult>();
    final http = LoginHttp(
      (r) => r.uri.path == '/v1/auth/signin'
          ? delayed.future
          : _response(r, isUser: null),
    );
    final login = GuangyaSmsLogin(http, now: () => tokenClock);
    final challenge = await login.sendSms('13800000000');
    final scope = RequestScope();
    final pending = scope.run(() => login.sms(challenge, '123456'));
    final failure = expectLater(pending, throwsA(isA<AppException>()));
    await Future<void>.delayed(Duration.zero);
    expect(http.calls.last.uri.path, '/v1/auth/signin');
    scope.cancel();
    delayed.complete(jsonResponse({'error': 'user_not_found'}, 400));
    await failure;
    expect(http.calls.where((r) => r.uri.path.endsWith('/signup')), isEmpty);
  });

  test(
    'signup fallback failure is returned without another verification or retry',
    () async {
      final http = LoginHttp(
        (r) => switch (r.uri.path) {
          '/v1/auth/signin' => jsonResponse({'error': 'user_not_found'}, 400),
          '/v1/auth/signup' => jsonResponse({
            'error': 'too_many_requests',
          }, 429),
          _ => _response(r, isUser: null),
        },
      );
      final login = GuangyaSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms('13800000000');
      await expectLater(
        login.sms(challenge, '123456'),
        throwsA(isA<AppException>()),
      );
      expect(
        http.calls.where((r) => r.uri.path.endsWith('/signup')),
        hasLength(1),
      );
      expect(
        http.calls.where((r) => r.uri.path.endsWith('/verify')),
        hasLength(1),
      );
    },
  );

  test(
    'expired challenge and malformed input never send login requests',
    () async {
      var now = tokenClock;
      final http = LoginHttp(_response),
          login = GuangyaSmsLogin(http, now: () => now);
      await expectLater(login.sendSms('123'), throwsA(isA<AppException>()));
      expect(http.calls, isEmpty);
      final challenge = await login.sendSms('13800000000');
      final count = http.calls.length;
      await expectLater(
        login.sms(challenge, '12ab'),
        throwsA(isA<AppException>()),
      );
      now += 600001;
      await expectLater(
        login.sms(challenge, '123456'),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(count));
    },
  );

  test(
    'cancelling the security challenge cannot send a text message',
    () async {
      final http = LoginHttp(
        (_) => jsonResponse({'url': 'https://captcha.guangyapan.com/verify'}),
      );
      await expectLater(
        GuangyaSmsLogin(
          http,
        ).sendSms('13800000000', verifyCaptcha: (_) async => null),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
      expect(http.calls.single.uri.path, '/v1/shield/captcha/init');
    },
  );

  test(
    'leaving during code verification cannot complete a late sign-in',
    () async {
      final delayed = Completer<HttpResult>();
      final http = LoginHttp(
        (r) => r.uri.path.endsWith('/verify') ? delayed.future : _response(r),
      );
      final login = GuangyaSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms('13800000000');
      final scope = RequestScope();
      final pending = scope.run(() => login.sms(challenge, '123456'));
      final failure = expectLater(pending, throwsA(isA<AppException>()));
      await Future<void>.delayed(Duration.zero);
      scope.cancel();
      delayed.complete(jsonResponse({'verification_token': _proof}));
      await failure;
      expect(http.calls.where((r) => r.uri.path.endsWith('/signin')), isEmpty);
    },
  );

  test(
    'verification errors do not expose the server response or retry a code',
    () async {
      final http = LoginHttp(
        (r) => r.uri.path.endsWith('/verify')
            ? jsonResponse({
                'error': 'invalid_verification_code',
                'error_description': 'private: 123456',
              }, 400)
            : _response(r),
      );
      final login = GuangyaSmsLogin(http, now: () => tokenClock);
      final challenge = await login.sendSms('13800000000');
      await expectLater(
        login.sms(challenge, '123456'),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            isNot(contains('123456')),
          ),
        ),
      );
      expect(
        http.calls.where((r) => r.uri.path.endsWith('/verify')),
        hasLength(1),
      );
      expect(http.calls.where((r) => r.uri.path.endsWith('/signin')), isEmpty);
    },
  );
}
