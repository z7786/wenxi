import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/quark_login.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/quark_sms_verification.dart';
import 'native_login_support.dart';
import 'quark_login_support.dart';
import 'support.dart';

void main() {
  test(
    'SMS uses official captcha fields and exchanges the ticket for cloud cookies',
    () async {
      final f = QuarkLoginFixture();
      final login = QuarkLoginService(f.http, now: () => quarkClock);
      final challenge = await login.sendSms(
        ' 13800000000 ',
        verifyCaptcha: ({required useSlider}) async => quarkProof(),
      );
      final credential = await login.sms(challenge, ' 1234 ');
      expect(f.http.calls.map((r) => r.uri.path), [
        '/cas/custom/login/sendSmsCode',
        '/cas/custom/login/commit',
        '/account/info',
        '/1/clouddrive/config',
      ]);
      final sending = f.http.calls.first, commit = f.http.calls[1];
      expect(sending.method, 'POST');
      expect(sending.uri.origin, 'https://uop.quark.cn');
      expect(sending.uri.queryParameters, {'custom_login_type': 'mobile'});
      expect(sending.headers['Origin'], 'https://uop.quark.cn');
      expect(sending.headers['Referer'], QuarkLoginService.mobilePage);
      expect(
        sending.headers['Cookie'],
        contains('security_session=fixture-private'),
      );
      expect(
        quarkForm(sending),
        containsPair('captcha_data', 'fixture-captcha-proof'),
      );
      expect(quarkForm(sending), containsPair('scene_v2', '1ml1ondj'));
      expect(quarkForm(sending), containsPair('scene', 'nvc_login'));
      expect(quarkForm(sending), containsPair('login_name', '13800000000'));
      expect(quarkForm(sending), containsPair('client_id', '532'));
      expect(quarkForm(commit), containsPair('sms_code', '1234'));
      expect(quarkForm(commit), containsPair('transmission_mode', 'pm'));
      expect(f.http.calls[2].uri.queryParameters, {'st': 'fixture-sms-ticket'});
      expect(
        f.http.calls[2].headers['Cookie'],
        isNot(contains('security_session')),
      );
      expect(
        f.http.calls.last.headers['Cookie'],
        contains('__pus=fixture-quark-pus'),
      );
      expect(
        f.http.calls.last.headers['Cookie'],
        isNot(contains('security_session')),
      );
      expect(f.http.calls.last.headers['User-Agent'], QuarkConnector.cloudUa);
      expect(f.http.redirects, everyElement(false));
      expect(
        LoginCredentials.cookiePairs(credential.primary),
        containsPair('__puus', 'fixture-quark-puus=='),
      );
      expect(credential.field('username'), '13800000000');
      expect(credential.field('userId'), 'fixture-quark-user');
      expect(credential.field('authType'), 'smsCookie');
      expect(credential.field('quarkSessionRefreshedAt'), '$quarkClock');
      for (final secret in [
        '1234',
        'fixture-captcha-proof',
        'fixture-sms-ticket',
      ]) {
        expect(credential.fields.values, isNot(contains(secret)));
      }
      challenge.close();
    },
  );

  test(
    'QR waits for confirmed service ticket before exchanging account credentials',
    () async {
      final f = QuarkLoginFixture();
      final login = QuarkLoginService(f.http, now: () => quarkClock);
      final qr = await login.createQr();
      final uri = Uri.parse(qr.url);
      expect(uri.origin, 'https://su.quark.cn');
      expect(uri.path, '/4_eMHBJ');
      expect(uri.queryParameters['token'], 'fixture-qr-token');
      expect(uri.queryParameters['client_id'], '532');
      expect(await login.pollQr(qr), isNull);
      expect(f.http.calls.where((r) => r.uri.path == '/account/info'), isEmpty);
      f.scanned = true;
      final ticket = await login.pollQr(qr);
      final credential = await login.finishQr(qr, ticket!);
      expect(credential.field('authType'), 'qrCookie');
      expect(credential.field('username'), isEmpty);
      expect(
        LoginCredentials.plausible(CloudPlatform.quark, credential.primary),
        isTrue,
      );
      expect(credential.primary, isNot(contains('qr_session')));
      final requests = f.http.calls
          .where((r) => r.uri.path.startsWith('/cas/ajax/'))
          .toList();
      expect(
        requests.map((r) => r.uri.queryParameters['request_id']).toSet(),
        hasLength(requests.length),
      );
      expect(
        requests.map((r) => r.uri.queryParameters['v']),
        everyElement('1.2'),
      );
      expect(
        requests.last.headers['Cookie'],
        contains('qr_session=fixture-qr'),
      );
      expect(
        requests.map((r) => r.headers['Cache-Control']),
        everyElement('no-cache, no-store'),
      );
      qr.close();
    },
  );

  test(
    'only explicit captcha rejection requests the official slider fallback',
    () async {
      final f = QuarkLoginFixture();
      var sends = 0;
      f.override = (r) => r.uri.path.endsWith('/sendSmsCode') && sends++ == 0
          ? jsonResponse({'status': 20180001})
          : null;
      final prompts = <bool>[];
      final challenge = await QuarkLoginService(f.http).sendSms(
        '13800000000',
        verifyCaptcha: ({required useSlider}) async {
          prompts.add(useSlider);
          return quarkProof(slider: useSlider);
        },
      );
      expect(prompts, [false, true]);
      expect(f.http.calls, hasLength(2));
      expect(
        quarkForm(f.http.calls.last)['captcha_data'],
        'fixture-slider-proof',
      );
      expect(quarkForm(f.http.calls.last)['scene_v2'], 'y9x7vx0s');
      challenge.close();
    },
  );

  test(
    'invalid phone, missing proof, expired codes and closed challenges do not send requests',
    () async {
      var now = quarkClock;
      final f = QuarkLoginFixture();
      final login = QuarkLoginService(f.http, now: () => now);
      for (final mobile in ['123', '23800000000', '13800000000\nextra']) {
        await expectLater(
          login.sendSms(
            mobile,
            verifyCaptcha: ({required useSlider}) async => quarkProof(),
          ),
          throwsA(isA<AppException>()),
        );
      }
      await expectLater(
        login.sendSms(
          '13800000000',
          verifyCaptcha: ({required useSlider}) async => null,
        ),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        login.sendSms(
          '13800000000',
          verifyCaptcha: ({required useSlider}) async => QuarkCaptchaProof({}),
        ),
        throwsA(isA<AppException>()),
      );
      expect(f.http.calls, isEmpty);
      final challenge = await login.sendSms(
        '13800000000',
        verifyCaptcha: ({required useSlider}) async => quarkProof(),
      );
      for (final code in ['', '123', '123456', 'ab12']) {
        await expectLater(
          login.sms(challenge, code),
          throwsA(isA<AppException>()),
        );
      }
      now += 600000;
      await expectLater(
        login.sms(challenge, '1234'),
        throwsA(isA<AppException>()),
      );
      now = quarkClock;
      challenge.close();
      await expectLater(
        login.sms(challenge, '1234'),
        throwsA(isA<AppException>()),
      );
      expect(f.http.calls, hasLength(1));
    },
  );

  test('local and server QR expiration require a new QR', () async {
    var now = quarkClock;
    final f = QuarkLoginFixture();
    final login = QuarkLoginService(f.http, now: () => now);
    final qr = await login.createQr();
    f.expired = true;
    await expectLater(login.pollQr(qr), throwsA(isA<QuarkQrExpired>()));
    now = qr.expiresAt;
    final before = f.http.calls.length;
    await expectLater(login.pollQr(qr), throwsA(isA<QuarkQrExpired>()));
    expect(f.http.calls, hasLength(before));
    qr.close();
  });

  test('an unconfirmed QR remains usable after two minutes', () async {
    var now = quarkClock;
    final f = QuarkLoginFixture();
    final login = QuarkLoginService(f.http, now: () => now);
    final qr = await login.createQr();
    now += 122000;
    expect(await login.pollQr(qr), isNull);
    f.scanned = true;
    expect(await login.pollQr(qr), 'fixture-qr-ticket');
    qr.close();
  });

  test('slow QR creation counts its lifetime from the token request', () async {
    var now = quarkClock;
    final f = QuarkLoginFixture();
    f.override = (r) {
      if (r.uri.path.endsWith('/getTokenForQrcodeLogin')) now += 15000;
      return null;
    };
    final qr = await QuarkLoginService(f.http, now: () => now).createQr();
    expect(qr.expiresAt, quarkClock + 180000);
    qr.close();
  });

  test(
    'SMS and ticket exchanges cannot be automatically retried, including GETs',
    () async {
      final f = QuarkLoginFixture();
      final flags = <bool>[];
      f.override = (r) {
        flags.add(JsonHttp.isReadRequest(r.method, r.url));
        return null;
      };
      final login = QuarkLoginService(f.http);
      final sms = await login.sendSms(
        '13800000000',
        verifyCaptcha: ({required useSlider}) async => quarkProof(),
      );
      await login.sms(sms, '1234');
      final qr = await login.createQr();
      await login.pollQr(qr);
      expect(flags, everyElement(false));
      sms.close();
      qr.close();
    },
  );

  test(
    'unknown SMS errors and network failures never replay sends or expose response text',
    () async {
      for (final failure in [
        () => jsonResponse({
          'status': 50001,
          'message': 'private 13800000000 1234',
        }),
        () => throw const HttpRequestFailure(
          '连接超时',
          kind: 'timeout',
          retryable: true,
        ),
      ]) {
        final http = LoginHttp((_) => failure());
        await expectLater(
          QuarkLoginService(http).sendSms(
            '13800000000',
            verifyCaptcha: ({required useSlider}) async => quarkProof(),
          ),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              isNot(contains('private')),
            ),
          ),
        );
        expect(http.calls, hasLength(1));
      }
    },
  );

  test(
    'a cancelled late ticket response cannot request cloud cookies',
    () async {
      final f = QuarkLoginFixture();
      final login = QuarkLoginService(f.http);
      final challenge = await login.sendSms(
        '13800000000',
        verifyCaptcha: ({required useSlider}) async => quarkProof(),
      );
      final pending = Completer<HttpResult>(), entered = Completer<void>();
      f.override = (r) {
        if (r.uri.path.endsWith('/commit')) {
          entered.complete();
          return pending.future;
        }
        return null;
      };
      final scope = RequestScope();
      final attempt = scope.run(() => login.sms(challenge, '1234'));
      final check = expectLater(attempt, throwsA(isA<AppException>()));
      await entered.future;
      scope.cancel();
      challenge.close();
      pending.complete(jsonResponse({'status': 20000, 'data': 'late-ticket'}));
      await check;
      expect(f.http.calls.where((r) => r.uri.path == '/account/info'), isEmpty);
    },
  );

  test('parallel attempts never exchange private QR cookies', () async {
    final f = QuarkLoginFixture();
    var counter = 0;
    f.override = (r) => r.uri.path.endsWith('/getTokenForQrcodeLogin')
        ? HttpResult(
            200,
            '{"status":2000000,"data":{"members":{"token":"fixture-${++counter}"}}}',
            {
              'set-cookie': [
                'qr_session=$counter; Domain=uop.quark.cn; Path=/; Secure',
              ],
            },
          )
        : null;
    final login = QuarkLoginService(f.http);
    final first = await login.createQr(), second = await login.createQr();
    await login.pollQr(first);
    await login.pollQr(second);
    final polls = f.http.calls
        .where((r) => r.uri.path.endsWith('/getServiceTicketByQrcodeToken'))
        .toList();
    expect(polls[0].headers['Cookie'], 'qr_session=1');
    expect(polls[1].headers['Cookie'], 'qr_session=2');
    first.close();
    second.close();
  });

  test(
    'successful native login is committed to the requested account with its quota',
    () async {
      final f = QuarkLoginFixture();
      final vault = Vault(StateStore.memory());
      final owner = await vault.createAccount(CloudPlatform.quark);
      final native = QuarkLoginService(f.http, now: () => quarkClock);
      final connector = QuarkConnector(
        f.http,
        store: vault,
        now: () => quarkClock,
      );
      final login = AccountLoginService(vault, (_, c) => connector.account(c));
      final sms = await native.sendSms(
        '13800000000',
        verifyCaptcha: ({required useSlider}) async => quarkProof(),
      );
      final result = await login.submit(
        CloudPlatform.quark,
        (_) async => connector.authenticate(await native.sms(sms, '1234')),
        accountId: owner,
      );
      expect(vault.activeAccountId(CloudPlatform.quark), owner);
      expect(
        vault.credentialFor(CloudPlatform.quark, owner)!.field('userId'),
        'fixture-quark-user',
      );
      expect(result.account.total, 2048);
      expect(result.account.used, 256);
      sms.close();
    },
  );

  test('failed cloud exchange leaves the saved account intact', () async {
    final f = QuarkLoginFixture();
    final vault = Vault(StateStore.memory());
    final before = Credential('original', {
      'primary': '__pus=old; __puus=old',
    }, updatedAt: 7);
    await vault.putCredential(CloudPlatform.quark, before);
    f.override = (r) =>
        r.uri.path == '/account/info' ? jsonResponse({'success': false}) : null;
    final native = QuarkLoginService(f.http);
    final connector = QuarkConnector(f.http, store: vault);
    final login = AccountLoginService(vault, (_, c) => connector.account(c));
    final sms = await native.sendSms(
      '13800000000',
      verifyCaptcha: ({required useSlider}) async => quarkProof(),
    );
    await expectLater(
      login.submit(
        CloudPlatform.quark,
        (_) async => connector.authenticate(await native.sms(sms, '1234')),
      ),
      throwsA(isA<AppException>()),
    );
    expect(vault.credential(CloudPlatform.quark)!.sameAs(before), isTrue);
    sms.close();
  });

  test(
    'captcha capture is limited to the official mobile login page and proof fields',
    () {
      expect(
        QuarkSmsVerification.trustedPage(QuarkLoginService.mobilePage),
        isTrue,
      );
      for (final page in [
        'http://uop.quark.cn/cas/custom/login?custom_login_type=mobile&client_id=532',
        '${QuarkLoginService.mobilePage}&client_id=evil',
        QuarkLoginService.mobilePage.replaceFirst(
          'uop.quark.cn',
          'uop.quark.cn.evil.test',
        ),
        QuarkLoginService.mobilePage.replaceFirst(
          'uop.quark.cn',
          'name@uop.quark.cn',
        ),
        QuarkLoginService.mobilePage.replaceFirst(
          '/cas/custom/login',
          '/other',
        ),
      ]) {
        expect(QuarkSmsVerification.trustedPage(page), isFalse, reason: page);
      }
      expect(
        QuarkCaptchaProof({...quarkProof().fields, 'sms_code': '1234'}).valid,
        isFalse,
      );
      expect(
        QuarkCaptchaProof({
          ...quarkProof().fields,
          'captcha_data': '\r\n',
        }).valid,
        isFalse,
      );
    },
  );
}
