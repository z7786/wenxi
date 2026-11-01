import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/ctfile.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/ctfile_captcha.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  HttpResult ok(Json data) => jsonResponse({'code': 200, ...data});
  CtfileCaptchaProof widgetProof(
    CtfileCaptchaChallenge challenge,
    String token,
  ) => challenge.proofFromMessage({
    'source': challenge.type == 'turnstile'
        ? 'ctfile-turnstile'
        : 'ctfile-captcha',
    'type': challenge.type,
    'event': 'success',
    'token': token,
  })!;
  HttpResult legacyProfile(RecordedRequest r) => r.uri.path.endsWith('/profile')
      ? ok({'userid': 12, 'nick_name': '测试账号'})
      : ok({'space_used': 100, 'max_storage': 1000});

  test('Required official widgets run before password submission', () async {
    for (final type in ['altcha', 'cap', 'turnstile']) {
      var prompts = 0, signIns = 0;
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/captcha/type')) {
          expect(r.method, 'GET');
          expect(r.headers['Accept-Language'], 'zh-CN');
          return ok({'captcha_type': type, 'always_required': true});
        }
        if (r.uri.path.endsWith('/login/login')) {
          signIns++;
          expect(prompts, 1);
          expect(r.uri.queryParameters['lang'], 'zh-hans');
          expect(r.json['email'], 'test@example.com');
          expect(r.json['password'], ' Password + 文 ');
          expect(r.json['${type}_token'], 'verified-widget-proof-0123456789');
          expect(r.json.containsKey('captcha'), isFalse);
          expect(r.json.containsKey('captcha_id'), isFalse);
          return HttpResult(200, jsonEncode({'code': 200}), {
            'set-cookie': [
              'ctfile_session=web-login; Domain=.ctfile.com; Path=/; Secure',
              'ua_checkmutilogin=attempt-only; Path=/; Secure',
            ],
          });
        }
        if (r.uri.path.endsWith('/exchange-token')) {
          expect(r.headers['Cookie'], 'ctfile_session=web-login');
          expect(r.json['rotate_token'], isFalse);
          return ok({
            'data': {'userid': 12, 'token': 'access', 'expires_in': 900},
          });
        }
        expect(r.headers['Authorization'], 'Bearer access');
        expect(r.headers.containsKey('Cookie'), isFalse);
        if (r.uri.path.endsWith('/profile/info')) {
          return ok({
            'data': {'userid': 12, 'username': '本次账号'},
          });
        }
        return ok({
          'data': {
            'workspaces': [
              {
                'id': 45,
                'owner_id': 12,
                'space_used': 100,
                'space_quota': 1000,
              },
            ],
            'has_more': false,
          },
        });
      });
      final login = await CtfileConnector(http).password(
        ' test@example.com ',
        ' Password + 文 ',
        verifyCaptcha: (challenge) async {
          prompts++;
          expect(signIns, 0);
          expect(challenge.type, type);
          expect(challenge.url.host, 'h5.ctfile.com');
          expect(challenge.url.queryParameters['source'], 'p8');
          expect(challenge.url.queryParameters['action'], 'login');
          return widgetProof(challenge, 'verified-widget-proof-0123456789');
        },
      );
      expect(signIns, 1);
      expect(login.credential.field('userId'), '12');
      expect(login.credential.field('authType'), 'webCookie');
      expect(login.credential.field('password'), isEmpty);
      expect(
        login.credential.fields.values.join(' '),
        isNot(contains('verified-widget-proof')),
      );
      expect(login.account.used, 100);
    }
  });

  test(
    'Expired widget proof is refreshed and tracking cookies stay in the attempt',
    () async {
      var signIns = 0, prompts = 0;
      final states = <String>[];
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/captcha/type')) {
          return ok({'captcha_type': 'altcha', 'always_required': true});
        }
        if (r.uri.path.endsWith('/login/login')) {
          signIns++;
          expect(
            r.json['altcha_token'],
            'verified-widget-proof-$signIns-0123456789',
          );
          if (signIns == 1) {
            return HttpResult(
              200,
              jsonEncode({
                'code': 400,
                'error_code': 'LOGIN_CAPTCHA_TIMEOUT',
                'captcha_type': 'altcha',
                'require_captcha': true,
                'message': 'Login failed',
              }),
              {
                'set-cookie': [
                  'ua_checkmutilogin=attempt-cookie; Path=/; Secure',
                ],
              },
            );
          }
          expect(r.headers['Cookie'], 'ua_checkmutilogin=attempt-cookie');
          return HttpResult(
            200,
            jsonEncode({'code': 200, 'token': 'fixture-session-token'}),
            {
              'set-cookie': ['tracking=optional; Path=/; Secure'],
            },
          );
        }
        expect(r.headers.containsKey('Cookie'), isFalse);
        expect(r.json['session'], 'fixture-session-token');
        return legacyProfile(r);
      });
      final login = await CtfileConnector(http).password(
        'test@example.com',
        'fixture-password',
        verifyCaptcha: (challenge) async {
          prompts++;
          states.add(challenge.state);
          if (prompts == 2) expect(challenge.message, contains('过期'));
          return widgetProof(
            challenge,
            'verified-widget-proof-$prompts-0123456789',
          );
        },
      );
      expect(prompts, 2);
      expect(states.toSet(), hasLength(2));
      expect(login.credential.primary, 'fixture-session-token');
      expect(login.credential.field('authType'), isEmpty);
      expect(login.credential.primary, isNot(contains('tracking')));
    },
  );

  test(
    'Captcha can be requested by login when an older server has no preflight',
    () async {
      var signIns = 0;
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/captcha/type')) {
          return jsonResponse({'code': 404}, 404);
        }
        if (r.uri.path.endsWith('/login/login')) {
          if (++signIns == 1) {
            return jsonResponse({
              'code': 400,
              'error_code': 'LOGIN_CAPTCHA_REQUIRED',
              'captcha_type': 'image',
              'message': 'Login failed',
            });
          }
          expect(r.json['captcha_id'], 'a' * 32);
          expect(r.json['captcha'], 'Ab123');
          return ok({'token': 'fixture-session-token'});
        }
        return legacyProfile(r);
      });
      await CtfileConnector(http).password(
        'test@example.com',
        'fixture-password',
        verifyCaptcha: (challenge) async {
          expect(challenge.isImage, isTrue);
          expect(challenge.imageUrl('a' * 32).queryParameters['act'], 'login');
          return challenge.imageProof('a' * 32, ' Ab123 ');
        },
      );
      expect(signIns, 2);
    },
  );

  test(
    'Wrong password stops even when the server keeps require_captcha enabled',
    () async {
      var prompts = 0;
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/captcha/type')
            ? ok({'captcha_type': 'altcha', 'always_required': true})
            : jsonResponse({
                'code': 400,
                'error_code': 'LOGIN_PASSWORD_WRONG',
                'require_captcha': true,
                'message': 'Login failed',
              }),
      );
      await expectLater(
        CtfileConnector(http).password(
          'test@example.com',
          'wrong-fixture-password',
          verifyCaptcha: (challenge) async {
            prompts++;
            return widgetProof(challenge, 'verified-widget-proof-0123456789');
          },
        ),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('邮箱或密码错误'),
          ),
        ),
      );
      expect(prompts, 1);
      expect(http.calls, hasLength(2));
    },
  );

  test(
    'Cancellation before proof cannot send a password or replace an account',
    () async {
      final vault = Vault(StateStore.memory());
      final old = Credential('旧账号', {
        'primary': 'old-session-token',
        'userId': '12',
      });
      await vault.putCredential(CloudPlatform.ctfile, old);
      final entered = Completer<void>();
      final answer = Completer<CtfileCaptchaProof?>();
      final http = FakeHttp(
        (_) => ok({'captcha_type': 'altcha', 'always_required': true}),
      );
      final connector = CtfileConnector(http);
      final service = AccountLoginService(
        vault,
        (_, c) => connector.account(c),
      );
      final pending = service.submit(
        CloudPlatform.ctfile,
        (_) => connector.password(
          'test@example.com',
          'fixture-password',
          verifyCaptcha: (_) {
            entered.complete();
            return answer.future;
          },
        ),
      );
      final rejected = expectLater(pending, throwsA(isA<AppException>()));
      await entered.future;
      service.invalidate(CloudPlatform.ctfile);
      await rejected;
      answer.complete(null);
      expect(http.calls, hasLength(1));
      expect(vault.credential(CloudPlatform.ctfile)!.primary, old.primary);
    },
  );

  test('Only proofs belonging to the current challenge are accepted', () async {
    final stale = CtfileCaptchaChallenge('altcha');
    final http = FakeHttp(
      (_) => ok({'captcha_type': 'altcha', 'always_required': true}),
    );
    await expectLater(
      CtfileConnector(http).password(
        'test@example.com',
        'fixture-password',
        verifyCaptcha: (_) async =>
            widgetProof(stale, 'verified-widget-proof-0123456789'),
      ),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('验证码已变化'),
        ),
      ),
    );
    expect(http.calls, hasLength(1));
  });

  test('Repeated rejected captcha proofs are bounded', () async {
    var prompts = 0;
    final http = FakeHttp(
      (r) => r.uri.path.endsWith('/captcha/type')
          ? ok({'captcha_type': 'altcha', 'always_required': true})
          : jsonResponse({
              'code': 400,
              'error_code': 'LOGIN_CAPTCHA_WRONG',
              'captcha_type': 'altcha',
            }),
    );
    await expectLater(
      CtfileConnector(http).password(
        'test@example.com',
        'fixture-password',
        verifyCaptcha: (challenge) async {
          prompts++;
          return widgetProof(
            challenge,
            'verified-widget-proof-$prompts-0123456789',
          );
        },
      ),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('验证码错误'),
        ),
      ),
    );
    expect(prompts, 3);
    expect(
      http.calls.where((r) => r.uri.path.endsWith('/login/login')),
      hasLength(3),
    );
  });

  test('Missing proof UI reports the real verification requirement', () async {
    final http = FakeHttp(
      (_) => jsonResponse({
        'code': 400,
        'error_code': 'LOGIN_CAPTCHA_REQUIRED',
        'captcha_type': 'altcha',
        'message': 'Login failed',
      }),
    );
    await expectLater(
      CtfileConnector(http).password('test@example.com', 'fixture-password'),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('安全验证'),
        ),
      ),
    );
    expect(http.calls, hasLength(1));
  });

  test(
    'Widget message types, official page scope and image ids are checked',
    () {
      final challenge = CtfileCaptchaChallenge('altcha');
      final url = challenge.url;
      expect(challenge.trustedPage(url.toString()), isTrue);
      for (final bad in [
        url.replace(scheme: 'http').toString(),
        url.replace(host: 'h5.ctfile.com.untrusted.test').toString(),
        url.replace(userInfo: 'user').toString(),
        url.replace(port: 8443).toString(),
        url.replace(path: '/captcha/turnstile.html').toString(),
        '${url.toString()}&source=v4',
        url
            .replace(
              queryParameters: {...url.queryParameters, 'action': 'register'},
            )
            .toString(),
        url
            .replace(
              queryParameters: {
                ...url.queryParameters,
                'api': 'https://api.ctfile.com',
              },
            )
            .toString(),
      ]) {
        expect(challenge.trustedPage(bad), isFalse);
      }
      final valid = {
        'source': 'ctfile-captcha',
        'type': 'altcha',
        'event': 'success',
        'token': 'verified-widget-proof-0123456789',
      };
      for (final changed in [
        {'source': 'untrusted'},
        {'type': 'turnstile'},
        {'event': 'expired'},
        {'token': ''},
        {
          'token': ['verified-widget-proof-0123456789'],
        },
        {'token': 'token-with\nnewline'},
      ]) {
        expect(challenge.proofFromMessage({...valid, ...changed}), isNull);
      }
      expect(challenge.proofFromMessage(valid)!.fields.keys, ['altcha_token']);
      final image = CtfileCaptchaChallenge('image');
      expect(
        () => image.imageProof('../bad', 'Ab123'),
        throwsA(isA<AppException>()),
      );
      expect(
        () => image.imageProof('a' * 32, '12'),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Capture scripts execute and preserve a fast widget proof in memory',
    () async {
      final challenge = CtfileCaptchaChallenge('altcha');
      final script =
          '''
global.window = global;
window.top = window;
global.location = {origin: 'https://h5.ctfile.com', pathname: '/captcha/altcha.html'};
global.document = {readyState:'loading', addEventListener: () => {}};
${challenge.installScript}
window.ReactNativeWebView.postMessage(JSON.stringify({
  source:'ctfile-captcha', type:'altcha', event:'success', token:'verified-widget-proof-0123456789'
}));
const first = ${challenge.captureScript.replaceFirst(RegExp(r';\s*$'), '')};
const second = ${challenge.captureScript.replaceFirst(RegExp(r';\s*$'), '')};
process.stdout.write(JSON.stringify({first:JSON.parse(first), second}));
''';
      final result = await Process.run('node', ['-e', script]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final data = asJson(jsonDecode(result.stdout as String));
      expect(challenge.proofFromMessage(data['first']), isNotNull);
      expect(data['second'], '');
    },
  );
}
