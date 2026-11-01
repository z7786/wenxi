import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/tianyi_captcha.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/login_page.dart';
import 'native_login_support.dart';
import 'support.dart';
import 'token_cloud_support.dart';
import 'xunlei_login_support.dart';
import 'lanzou_password_support.dart';
import 'wopan_login_support.dart';

class GestureCaptcha extends TianyiCaptchaClient {
  GestureCaptcha(int type, {required super.cancel})
    : super(
        appId: 'cloud',
        referer: tianyiFixtureSso,
        checkpoint: () {},
        request: (_) async => throw StateError(
          'The gesture fixture never makes network requests',
        ),
      ) {
    image = TianyiCaptchaImage(
      type: type,
      token: 'test-image',
      background: base64Decode(loginTestPng(310, 155).split(',').last),
      piece: type == 1
          ? base64Decode(loginTestPng(47, 155).split(',').last)
          : null,
      instruction: type == 1 ? '拖动滑块完成拼图' : '山、水、月',
    );
  }
  late final TianyiCaptchaImage image;
  TianyiCaptchaGesture? submitted;
  @override
  Future<TianyiCaptchaImage> load() async => image;
  @override
  Future<TianyiCaptchaProof> verify(
    TianyiCaptchaImage image,
    TianyiCaptchaGesture gesture,
  ) async {
    submitted = gesture;
    return TianyiCaptchaProof(image.type, 'verified-test', 'verified-proof');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LoginTestKey key;
  setUpAll(() => key = LoginTestKey());

  Future<AppServices> render(
    WidgetTester tester,
    CloudPlatform platform,
    JsonHttp http, {
    Size size = const Size(393, 852),
    double scale = 1,
    VoidCallback? onClosed,
    Json? initialData,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    late Directory directory;
    late Zone ioZone;
    final services = (await tester.runAsync(() async {
      ioZone = Zone.current;
      directory = await Directory.systemTemp.createTemp(
        'asterlink-native-login-test-',
      );
      return AppServices(
        controlEnabled: false,
        store: StateStore.memory(initialData),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${directory.path}/saved')),
        http: http,
        platformFeatures: false,
      );
    }))!;
    addTearDown(() async {
      await tester.runAsync(() async {
        await services.close();
        await directory.delete(recursive: true);
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  // Login submission and teardown use real IO below. Keep the
                  // account-slot reservation on that same event loop.
                  await ioZone.run(
                    () => openLogin(context, services, platform),
                  );
                  onClosed?.call();
                },
                child: const Text('打开登录'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开登录'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    return services;
  }

  Future<void> fill(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('native-login-username')),
      'fixture-user',
    );
    await tester.enterText(
      find.byKey(const ValueKey('native-login-password')),
      ' SamplePassword! ',
    );
  }

  for (final size in [const Size(393, 852), const Size(1280, 800)]) {
    testWidgets(
      'Lanzou opens password login and remembers the account at $size',
      (tester) async {
        final fixture = LanzouPasswordFixture();
        final services = await render(
          tester,
          CloudPlatform.lanzou,
          fixture.http,
          size: size,
        );
        expect(find.text('账号密码登录'), findsOneWidget);
        expect(find.byKey(const ValueKey('native-login-web')), findsOneWidget);
        final manual = find.byKey(const ValueKey('native-login-manual'));
        await tester.ensureVisible(manual);
        await tester.tap(manual);
        await tester.pumpAndSettle();
        expect(find.byType(ManualLoginPage), findsOneWidget);
        final back = find.byKey(const ValueKey('manual-login-password'));
        await tester.ensureVisible(back);
        await tester.tap(back);
        await tester.pumpAndSettle();
        await fill(tester);
        final submit = find.byKey(const ValueKey('native-login-submit'));
        await tester.ensureVisible(submit);
        await tester.runAsync(() async {
          await tester.tap(submit);
          await until(
            () => services.vault.credential(CloudPlatform.lanzou) != null,
          );
        });
        await tester.pumpAndSettle();
        final accountId = services.vault.activeAccountId(CloudPlatform.lanzou);
        final saved = services.vault.credential(CloudPlatform.lanzou)!;
        expect(saved.field('username'), 'fixture-user');
        expect(saved.field('password'), ' SamplePassword! ');
        expect(find.byType(PasswordLoginFlow), findsNothing);
        await tester.runAsync(() async {
          await tester.tap(find.text('打开登录'));
        });
        await tester.pumpAndSettle();
        final username = tester.widget<TextFormField>(
          find.byKey(const ValueKey('native-login-username')),
        );
        expect(username.controller!.text, 'fixture-user');
        fixture.cookie = 'renewed-cookie';
        await tester.ensureVisible(submit);
        await tester.runAsync(() async {
          await tester.tap(submit);
          await until(
            () => services.vault
                .credential(CloudPlatform.lanzou)!
                .primary
                .contains('renewed-cookie'),
          );
        });
        await tester.pumpAndSettle();
        expect(services.vault.activeAccountId(CloudPlatform.lanzou), accountId);
        expect(services.vault.profiles(CloudPlatform.lanzou), hasLength(1));
        ScaffoldMessenger.of(
          tester.element(find.text('打开登录')),
        ).clearSnackBars();
        await tester.pumpAndSettle();
        // The login callback runs in the real IO zone. Drain its snackbar
        // animation completion before the test tears down the messenger.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Ctfile password and manual login work at $size', (
      tester,
    ) async {
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/captcha/type')) {
          return jsonResponse({
            'code': 200,
            'captcha_type': 'image',
            'always_required': false,
          });
        }
        if (r.uri.path.endsWith('/login')) {
          expect(r.json['email'], 'test@example.com');
          return jsonResponse({'code': 200, 'token': 'fixture-session-token'});
        }
        if (r.uri.path.endsWith('/profile')) {
          return jsonResponse({'code': 200, 'userid': 42, 'nick_name': '城通测试'});
        }
        return jsonResponse({
          'code': 200,
          'space_used': 100,
          'max_storage': 1000,
        });
      });
      final services = await render(
        tester,
        CloudPlatform.ctfile,
        http,
        size: size,
      );
      expect(find.byKey(const ValueKey('native-login-web')), findsOneWidget);
      final manual = find.byKey(const ValueKey('native-login-manual'));
      await tester.ensureVisible(manual);
      await tester.tap(manual);
      await tester.pumpAndSettle();
      expect(find.text('Session Token'), findsOneWidget);
      final back = find.byKey(const ValueKey('manual-login-password'));
      await tester.ensureVisible(back);
      await tester.tap(back);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('native-login-username')),
        'test@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('native-login-password')),
        'password',
      );
      final submit = find.byKey(const ValueKey('native-login-submit'));
      await tester.ensureVisible(submit);
      await tester.runAsync(() async {
        await tester.tap(submit);
        await until(
          () => services.vault.credential(CloudPlatform.ctfile) != null,
        );
      });
      await tester.pumpAndSettle();
      expect(
        services.vault.credential(CloudPlatform.ctfile)!.field('userId'),
        '42',
      );
      expect(find.byType(PasswordLoginFlow), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Xunlei password login always remembers credentials without a switch',
    (tester) async {
      final fixture = XunleiLoginFixture();
      final services = await render(tester, CloudPlatform.xunlei, fixture.http);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('记住账号密码并自动登录'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('xunlei-login-username')),
        '  $xunleiTestUsername  ',
      );
      await tester.enterText(
        find.byKey(const ValueKey('xunlei-login-password')),
        xunleiTestPassword,
      );
      final button = find.byKey(const ValueKey('xunlei-login-submit'));
      await tester.ensureVisible(button);
      await tester.runAsync(() async {
        await tester.tap(button);
        await until(
          () => services.vault.credential(CloudPlatform.xunlei) != null,
        );
      });
      await tester.pumpAndSettle();
      final saved = services.vault.credential(CloudPlatform.xunlei)!;
      expect(saved.field('username'), xunleiTestUsername);
      expect(saved.field('password'), xunleiTestPassword);
      expect(saved.field('authType'), 'passwordToken');
      expect(find.byType(PasswordLoginFlow), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Xunlei switching to web cancels a pending password login', (
    tester,
  ) async {
    late Completer<HttpResult> pending;
    await tester.runAsync(() async => pending = Completer<HttpResult>());
    var cancelled = false;
    final fixture = XunleiLoginFixture();
    fixture.intercept = (r) {
      if (r.uri.path == '/xluser.core.login/v3/login') {
        RequestScope.current!.whenCancel.then((_) => cancelled = true);
        return pending.future;
      }
      return null;
    };
    final services = await render(tester, CloudPlatform.xunlei, fixture.http);
    await tester.enterText(
      find.byKey(const ValueKey('xunlei-login-username')),
      xunleiTestUsername,
    );
    await tester.enterText(
      find.byKey(const ValueKey('xunlei-login-password')),
      xunleiTestPassword,
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('xunlei-login-submit')));
      await until(() => fixture.passwordCalls == 1);
    });
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('xunlei-login-web')));
      await until(() => cancelled);
      pending.complete(jsonResponse(fixture.signIn));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.byType(WebLoginPage), findsOneWidget);
    expect(services.vault.credential(CloudPlatform.xunlei), isNull);
    expect(
      fixture.http.calls.where((r) => r.uri.path == '/v1/auth/signin/token'),
      isEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('web-login-password')));
    await tester.pumpAndSettle();
    fixture.intercept = null;
    await tester.enterText(
      find.byKey(const ValueKey('xunlei-login-username')),
      xunleiTestUsername,
    );
    await tester.enterText(
      find.byKey(const ValueKey('xunlei-login-password')),
      xunleiTestPassword,
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('xunlei-login-submit')));
      await until(
        () => services.vault.credential(CloudPlatform.xunlei) != null,
      );
    });
    await tester.pumpAndSettle();
    expect(find.byType(PasswordLoginFlow), findsNothing);
    expect(
      services.vault.credential(CloudPlatform.xunlei)!.field('password'),
      xunleiTestPassword,
    );
    expect(tester.takeException(), isNull);
  });

  for (final desktop in [false, true]) {
    testWidgets(
      'Remembered Xunlei credentials refill the ${desktop ? 'desktop' : 'phone'} form with the password masked',
      (tester) async {
        final fixture = XunleiLoginFixture();
        await render(
          tester,
          CloudPlatform.xunlei,
          fixture.http,
          size: desktop ? const Size(1100, 800) : const Size(393, 852),
          scale: desktop ? 1 : 1.4,
          initialData: {
            'credentials': {CloudPlatform.xunlei.key: fixture.initial.toJson()},
          },
        );
        final account = tester.widget<TextField>(
          find.byKey(const ValueKey('xunlei-login-username')),
        );
        final secret = tester.widget<TextField>(
          find.byKey(const ValueKey('xunlei-login-password')),
        );
        expect(account.controller!.text, xunleiTestUsername);
        expect(secret.controller!.text, xunleiTestPassword);
        expect(secret.obscureText, isTrue);
        expect(find.text('手动'), findsNothing);
        expect(find.text('网页登录'), findsOneWidget);
        await tester.tap(find.text('短信登录'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('xunlei-login-remember')),
          findsNothing,
        );
        expect(find.text('发送验证码'), findsOneWidget);
        expect(fixture.http.calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  HttpResult smsResponse(RecordedRequest r) => switch (r.uri.path) {
    '/v1/shield/captcha/init' => jsonResponse({
      'captcha_token': 'fixture-captcha-token-0123456789',
    }),
    '/v1/auth/verification' => jsonResponse({
      'verification_id': 'fixture-verification-id-0123456789',
      'is_user': true,
      'expires_in': 600,
    }),
    '/v1/auth/verification/verify' => jsonResponse({
      'verification_token': 'fixture-verification-token-0123456789',
    }),
    '/v1/auth/signin' => jsonResponse({
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_in': 3600,
    }),
    '/v1/user/me' => jsonResponse({'sub': 'user-1', 'nickname': '短信测试'}),
    '/assets/v1/get_assets' => guangyaAssetsResponse(),
    _ => throw StateError('Unexpected SMS request: ${r.uri.path}'),
  };

  Future<void> sendSms(WidgetTester tester, LoginHttp http) async {
    await tester.enterText(
      find.byKey(const ValueKey('guangya-sms-mobile')),
      '13800000000',
    );
    await tester.tap(find.byKey(const ValueKey('guangya-sms-agreement')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('guangya-sms-send')));
      await until(
        () => http.calls.any((r) => r.uri.path == '/v1/auth/verification'),
      );
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('验证码已发送，请查看手机短信'), findsOneWidget);
  }

  testWidgets(
    'Guangya defaults to SMS and validates the phone and agreement before sending',
    (tester) async {
      final http = LoginHttp(smsResponse);
      await render(tester, CloudPlatform.guangya, http);
      expect(find.text('手机号验证码登录'), findsOneWidget);
      expect(find.byKey(const ValueKey('native-login-password')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('guangya-sms-send')));
      await tester.pump();
      expect(find.text('请输入正确的手机号'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('guangya-sms-mobile')),
        '13800000000',
      );
      await tester.tap(find.byKey(const ValueKey('guangya-sms-send')));
      await tester.pump();
      expect(find.text('请先阅读并同意光鸭用户协议和隐私政策'), findsOneWidget);
      expect(http.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SMS resend is disabled and a changed phone cannot reuse the previous challenge',
    (tester) async {
      final http = LoginHttp(smsResponse);
      await render(tester, CloudPlatform.guangya, http);
      await sendSms(tester, http);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('guangya-sms-send')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('s 后重发'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('guangya-sms-send')));
      await tester.enterText(
        find.byKey(const ValueKey('guangya-sms-code')),
        '123456',
      );
      await tester.enterText(
        find.byKey(const ValueKey('guangya-sms-mobile')),
        '13900000000',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('guangya-sms-code')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.enterText(
        find.byKey(const ValueKey('guangya-sms-code')),
        '123456',
      );
      await tester.tap(find.byKey(const ValueKey('guangya-sms-submit')));
      await tester.pumpAndSettle();
      expect(find.text('请先获取当前手机号的验证码'), findsOneWidget);
      expect(
        http.calls.where((r) => r.uri.path == '/v1/auth/verification'),
        hasLength(1),
      );
      expect(
        http.calls.where(
          (r) =>
              r.uri.path.endsWith('/verify') || r.uri.path.endsWith('/signin'),
        ),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SMS login validates the account then saves the tokens without the SMS code',
    (tester) async {
      final http = LoginHttp(smsResponse);
      final services = await render(tester, CloudPlatform.guangya, http);
      final owner = tester
          .widget<PasswordLoginFlow>(find.byType(PasswordLoginFlow))
          .accountId;
      expect(owner, isNotNull);
      await sendSms(tester, http);
      await tester.enterText(
        find.byKey(const ValueKey('guangya-sms-code')),
        '123456',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('guangya-sms-submit')));
        await until(
          () => services.vault.credential(CloudPlatform.guangya) != null,
        );
      });
      await tester.pumpAndSettle();
      final saved = services.vault.credentialFor(CloudPlatform.guangya, owner)!;
      expect(saved.field('username'), '13800000000');
      expect(saved.field('refreshToken'), refreshToken);
      expect(saved.field('password'), isEmpty);
      expect(saved.fields.values, isNot(contains('123456')));
      expect(find.byType(PasswordLoginFlow), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final phase in ['sending', 'verifying']) {
    testWidgets(
      'Leaving while SMS is $phase discards the late result and keeps the saved account',
      (tester) async {
        final delayed = Completer<HttpResult>();
        RecordedRequest? held;
        final http = LoginHttp((r) {
          if (r.uri.path ==
              (phase == 'sending'
                  ? '/v1/auth/verification'
                  : '/v1/auth/verification/verify')) {
            held = r;
            return delayed.future;
          }
          return smsResponse(r);
        });
        final before = tokenCredential(CloudPlatform.guangya);
        final services = await render(
          tester,
          CloudPlatform.guangya,
          http,
          initialData: {
            'credentials': {CloudPlatform.guangya.key: before.toJson()},
          },
        );
        if (phase == 'verifying') {
          await sendSms(tester, http);
          await tester.enterText(
            find.byKey(const ValueKey('guangya-sms-code')),
            '123456',
          );
        } else {
          await tester.enterText(
            find.byKey(const ValueKey('guangya-sms-mobile')),
            '13800000000',
          );
          await tester.tap(find.byKey(const ValueKey('guangya-sms-agreement')));
        }
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(
              ValueKey(
                phase == 'sending' ? 'guangya-sms-send' : 'guangya-sms-submit',
              ),
            ),
          );
          await until(() => held != null);
        });
        await tester.pageBack();
        await tester.pumpAndSettle();
        delayed.complete(smsResponse(held!));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
        expect(
          services.vault.credential(CloudPlatform.guangya)!.sameAs(before),
          isTrue,
        );
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/signin')),
          isEmpty,
        );
        expect(find.byType(PasswordLoginFlow), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<void> sendWopanSms(WidgetTester tester, LoginHttp http) async {
    await tester.enterText(
      find.byKey(const ValueKey('wopan-sms-mobile')),
      '13800000000',
    );
    await tester.tap(find.byKey(const ValueKey('wopan-sms-agreement')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('wopan-sms-send')));
      await until(
        () =>
            http.calls.any((r) => r.uri.path.endsWith('/sendMessageCodeBase')),
      );
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.text('验证码已发送，请查看手机短信'), findsOneWidget);
  }

  testWidgets(
    'Wopan defaults to SMS and requires a valid phone and agreement',
    (tester) async {
      final http = LoginHttp(wopanLoginResponse);
      await render(tester, CloudPlatform.wopan, http);
      expect(find.text('手机号验证码登录'), findsOneWidget);
      expect(find.byType(WebLoginPage), findsNothing);
      expect(find.byKey(const ValueKey('native-login-password')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('wopan-sms-send')));
      await tester.pump();
      expect(find.text('请输入正确的手机号'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('wopan-sms-mobile')),
        '13800000000',
      );
      await tester.tap(find.byKey(const ValueKey('wopan-sms-send')));
      await tester.pump();
      expect(find.text('请先阅读并同意联通用户协议和隐私政策'), findsOneWidget);
      expect(http.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Wopan disables resend and changing phones discards its code', (
    tester,
  ) async {
    final http = LoginHttp(wopanLoginResponse);
    await render(tester, CloudPlatform.wopan, http);
    await sendWopanSms(tester, http);
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('wopan-sms-send')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const ValueKey('wopan-sms-code')),
      '123456',
    );
    await tester.enterText(
      find.byKey(const ValueKey('wopan-sms-mobile')),
      '13900000000',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('wopan-sms-code')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('wopan-sms-submit')));
    await tester.pumpAndSettle();
    expect(find.text('请先获取当前手机号的验证码'), findsOneWidget);
    expect(http.calls, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('wopan-sms-send')));
    expect(http.calls, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(393, 852), const Size(1280, 800)]) {
    testWidgets('Wopan SMS saves verified tokens without its code at $size', (
      tester,
    ) async {
      final http = LoginHttp(wopanLoginResponse);
      final services = await render(
        tester,
        CloudPlatform.wopan,
        http,
        size: size,
      );
      final owner = tester
          .widget<PasswordLoginFlow>(find.byType(PasswordLoginFlow))
          .accountId;
      await sendWopanSms(tester, http);
      await tester.enterText(
        find.byKey(const ValueKey('wopan-sms-code')),
        '123456',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('wopan-sms-submit')));
        await until(
          () => services.vault.credential(CloudPlatform.wopan) != null,
        );
      });
      await tester.pumpAndSettle();
      final saved = services.vault.credentialFor(CloudPlatform.wopan, owner)!;
      expect(saved.field('username'), '13800000000');
      expect(saved.field('userId'), 'wopan-user');
      expect(saved.field('clientId'), '1001000035');
      expect(saved.field('refreshToken'), refreshToken);
      expect(saved.fields.values, isNot(contains('123456')));
      expect(find.byType(PasswordLoginFlow), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final phase in ['sending', 'verifying']) {
    testWidgets('Leaving Wopan SMS while $phase ignores the late result', (
      tester,
    ) async {
      final delayed = Completer<HttpResult>();
      RecordedRequest? held;
      final http = LoginHttp((r) {
        if (phase == 'sending' && r.uri.path.endsWith('/sendMessageCodeBase') ||
            phase == 'verifying' &&
                r.json.obj('header').str('key') == 'LoginByMobileV2') {
          held = r;
          return delayed.future;
        }
        return wopanLoginResponse(r);
      });
      final before = tokenCredential(CloudPlatform.wopan);
      final services = await render(
        tester,
        CloudPlatform.wopan,
        http,
        initialData: {
          'credentials': {CloudPlatform.wopan.key: before.toJson()},
        },
      );
      if (phase == 'verifying') {
        await sendWopanSms(tester, http);
        await tester.enterText(
          find.byKey(const ValueKey('wopan-sms-code')),
          '123456',
        );
      } else {
        await tester.enterText(
          find.byKey(const ValueKey('wopan-sms-mobile')),
          '13800000000',
        );
        await tester.tap(find.byKey(const ValueKey('wopan-sms-agreement')));
      }
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(
            ValueKey(
              phase == 'sending' ? 'wopan-sms-send' : 'wopan-sms-submit',
            ),
          ),
        );
        await until(() => held != null);
      });
      await tester.pageBack();
      await tester.pumpAndSettle();
      delayed.complete(wopanLoginResponse(held!));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(
        services.vault.credential(CloudPlatform.wopan)!.sameAs(before),
        isTrue,
      );
      expect(
        http.calls.where(
          (r) => r.json.obj('header').str('key') == 'AppQueryUser',
        ),
        isEmpty,
      );
      expect(find.byType(PasswordLoginFlow), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Tianyi restores the remembered username and masked password for re-login',
    (tester) async {
      final credential = Credential('天翼', {
        'primary': 'COOKIE_LOGIN_USER=fixture',
        'authType': 'passwordCookie',
        'username': 'fixture-user',
        'password': ' private-password ',
        'autoLoginBlocked': '1',
      });
      await render(
        tester,
        CloudPlatform.tianyi,
        LoginHttp((_) => jsonResponse({})),
        initialData: {
          'credentials': {CloudPlatform.tianyi.key: credential.toJson()},
        },
      );
      final username = tester.widget<TextFormField>(
        find.byKey(const ValueKey('native-login-username')),
      );
      final password = tester.widget<TextFormField>(
        find.byKey(const ValueKey('native-login-password')),
      );
      expect(username.controller!.text, 'fixture-user');
      expect(password.controller!.text, ' private-password ');
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const ValueKey('native-login-password')),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isTrue,
      );
      expect(find.text('账号密码加密保存在本机，登录失效时自动重登'), findsOneWidget);
      expect(find.byKey(const ValueKey('native-login-web')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Feijipan password login keeps the verified account and remembers the form',
    (tester) async {
      final http = LoginHttp(
        (r) => switch (r.uri.path) {
          '/ws/getUuid' => jsonResponse({
            'code': 200,
            'uuid': 'fixture-device-12345678',
          }),
          '/ws/login' => jsonResponse({
            'code': 200,
            'data': {'appToken': accessToken},
          }),
          '/app/user/account/map' => jsonResponse({
            'code': 200,
            'map': {'userId': 123, 'account': 'fixture123', 'totalSize': 1000},
          }),
          '/app/user/info/map' => jsonResponse({
            'code': 200,
            'map': {'userId': 123, 'userName': '小飞机测试账号'},
          }),
          _ => throw StateError('Unexpected Feijipan password request'),
        },
      );
      final services = await render(tester, CloudPlatform.feijipan, http);
      expect(find.text('小飞机登录'), findsOneWidget);
      expect(find.byType(NativePasswordLoginPage), findsOneWidget);
      await fill(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('native-login-submit')));
        await until(
          () => services.vault.credential(CloudPlatform.feijipan) != null,
        );
      });
      await tester.pumpAndSettle();
      final saved = services.vault.credential(CloudPlatform.feijipan)!;
      expect(saved.field('userId'), '123');
      expect(saved.field('nickname'), '小飞机测试账号');
      expect(saved.field('password'), ' SamplePassword! ');
      await tester.tap(find.text('打开登录'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('native-login-username')),
            )
            .controller!
            .text,
        saved.field('username'),
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('native-login-password')),
            )
            .controller!
            .text,
        saved.field('password'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final platform in [
    CloudPlatform.pan123,
    CloudPlatform.tianyi,
    CloudPlatform.guangya,
  ]) {
    testWidgets(
      '${platform.key} submits the native form and retains only the required credentials',
      (tester) async {
        final http = platform == CloudPlatform.guangya
            ? LoginHttp(
                (r) => switch (r.uri.path) {
                  '/v1/shield/captcha/init' => jsonResponse({
                    'captcha_token': 'fixture-captcha-0123456789',
                  }),
                  '/v1/auth/signin' => jsonResponse({
                    'access_token': accessToken,
                    'refresh_token': refreshToken,
                    'expires_in': 3600,
                  }),
                  '/v1/user/me' => jsonResponse({
                    'sub': 'fixture-user',
                    'nickname': '测试账号',
                  }),
                  '/assets/v1/get_assets' => guangyaAssetsResponse(),
                  _ => throw StateError('Unexpected password request'),
                },
              )
            : platform == CloudPlatform.tianyi
            ? TianyiLoginFixture(key).http
            : LoginHttp(
                (r) => r.uri.path.endsWith('/sign_in')
                    ? jsonResponse({
                        'code': 200,
                        'data': {'token': 'native-token'},
                      })
                    : jsonResponse({
                        'code': 0,
                        'data': {
                          'Nickname': '测试账号',
                          'SpaceUsed': 1,
                          'SpacePermanent': 100,
                          'SpaceTemp': 0,
                        },
                      }),
              );
        final services = await render(tester, platform, http);
        if (platform == CloudPlatform.guangya) {
          expect(find.text('手机号验证码登录'), findsOneWidget);
          await tester.ensureVisible(
            find.byKey(const ValueKey('guangya-sms-password')),
          );
          await tester.tap(find.byKey(const ValueKey('guangya-sms-password')));
          await tester.pumpAndSettle();
        }
        expect(find.byType(NativePasswordLoginPage), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
        await fill(tester);
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('native-login-submit')));
          await until(() => services.vault.credential(platform) != null);
        });
        await tester.pumpAndSettle();
        expect(find.byType(NativePasswordLoginPage), findsNothing);
        if (platform == CloudPlatform.pan123) {
          expect(
            services.vault.credential(platform)!.field('secondary'),
            ' SamplePassword! ',
          );
        } else if (platform == CloudPlatform.tianyi) {
          expect(
            services.vault.credential(platform)!.field('password'),
            ' SamplePassword! ',
          );
          expect(services.vault.credential(platform)!.secondary, isEmpty);
        } else {
          final saved = services.vault.credential(platform)!;
          expect(saved.field('accessToken'), accessToken);
          expect(saved.field('refreshToken'), refreshToken);
          expect(saved.field('password'), ' SamplePassword! ');
          expect(saved.secondary, isEmpty);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Empty inputs, password visibility and large-text narrow layout stay usable',
    (tester) async {
      final http = LoginHttp((_) => jsonResponse({}));
      await render(
        tester,
        CloudPlatform.pan123,
        http,
        size: const Size(320, 740),
        scale: 1.5,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('native-login-submit')),
      );
      await tester.tap(find.byKey(const ValueKey('native-login-submit')));
      await tester.pump();
      expect(find.text('请输入账号'), findsOneWidget);
      expect(find.text('请输入密码'), findsOneWidget);
      expect(http.calls, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('native-login-password')),
        'secret',
      );
      final editable = find.descendant(
        of: find.byKey(const ValueKey('native-login-password')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(editable).obscureText, isTrue);
      await tester.ensureVisible(find.byTooltip('显示密码'));
      await tester.tap(find.byTooltip('显示密码'));
      await tester.pump();
      expect(tester.widget<EditableText>(editable).obscureText, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'A rejected password leaves the form open and preserves the old account',
    (tester) async {
      final services = await render(
        tester,
        CloudPlatform.pan123,
        LoginHttp(
          (_) => jsonResponse({'code': 401, 'message': 'password rejected'}),
        ),
      );
      final previous = Credential('existing', {
        'accessToken': 'old-token',
      }, updatedAt: 1);
      await tester.runAsync(
        () => services.vault.putCredential(CloudPlatform.pan123, previous),
      );
      await fill(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('native-login-submit')));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(find.byType(NativePasswordLoginPage), findsOneWidget);
      expect(find.text('123 登录失败，请检查账号和密码后重试'), findsOneWidget);
      expect(
        services.vault.credential(CloudPlatform.pan123)!.sameAs(previous),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Back immediately cancels an in-flight form before the route animation ends',
    (tester) async {
      late Completer<void> entered;
      late Completer<HttpResult> answer;
      await tester.runAsync(() async {
        entered = Completer<void>();
        answer = Completer<HttpResult>();
      });
      bool cancelled = false;
      final http = LoginHttp((_) {
        RequestScope.current!.whenCancel.then((_) => cancelled = true);
        entered.complete();
        return answer.future;
      });
      final services = await render(tester, CloudPlatform.pan123, http);
      await fill(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('native-login-submit')));
        await entered.future;
      });
      await tester.runAsync(() async {
        Navigator.of(
          tester.element(find.byType(NativePasswordLoginPage)),
        ).pop();
        await until(() => cancelled);
        answer.complete(
          jsonResponse({
            'code': 200,
            'data': {'token': 'late-token'},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(services.vault.credential(CloudPlatform.pan123), isNull);
      expect(find.byType(NativePasswordLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final platform in [
    CloudPlatform.pan123,
    CloudPlatform.lanzou,
    CloudPlatform.feijipan,
    CloudPlatform.pikpak,
    CloudPlatform.tianyi,
    CloudPlatform.xunlei,
  ]) {
    testWidgets(
      '${platform.key} switches both login methods within the same awaited route',
      (tester) async {
        var closed = false;
        final services = await render(
          tester,
          platform,
          LoginHttp((_) => jsonResponse({})),
          onClosed: () => closed = true,
        );
        final nativeType = platform == CloudPlatform.xunlei
            ? XunleiLoginPage
            : NativePasswordLoginPage;
        final webKey = platform == CloudPlatform.xunlei
            ? 'xunlei-login-web'
            : 'native-login-web';
        final owner = services.vault.activeAccountId(platform);
        await tester.ensureVisible(find.byKey(ValueKey(webKey)));
        await tester.tap(find.byKey(ValueKey(webKey)));
        await tester.pumpAndSettle();
        expect(find.byType(WebLoginPage), findsOneWidget);
        expect(find.byType(nativeType), findsNothing);
        expect(closed, isFalse);
        expect(services.vault.activeAccountId(platform), owner);
        await tester.tap(find.byKey(const ValueKey('web-login-password')));
        await tester.pumpAndSettle();
        expect(find.byType(nativeType), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
        expect(closed, isFalse);
        expect(services.vault.credential(platform), isNull);
        Navigator.of(tester.element(find.byType(nativeType))).pop();
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
        expect(closed, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'Switching a pending password login cancels it and a new method can log in before its late result',
    (tester) async {
      late Completer<HttpResult> firstAnswer;
      await tester.runAsync(() async {
        firstAnswer = Completer<HttpResult>();
      });
      var signIns = 0, cancelled = false;
      final http = LoginHttp((r) {
        if (r.uri.path.endsWith('/sign_in')) {
          signIns++;
          if (signIns == 1) {
            RequestScope.current!.whenCancel.then((_) => cancelled = true);
            return firstAnswer.future;
          }
          return jsonResponse({
            'code': 200,
            'data': {'token': 'second-token'},
          });
        }
        return jsonResponse({
          'code': 0,
          'data': {
            'Nickname': 'second account',
            'SpaceUsed': 1,
            'SpacePermanent': 100,
          },
        });
      });
      final services = await render(tester, CloudPlatform.pan123, http);
      await fill(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('native-login-submit')));
        await until(() => signIns == 1);
      });
      await tester.ensureVisible(
        find.byKey(const ValueKey('native-login-web')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('native-login-web')));
        await until(() => cancelled);
      });
      await tester.pumpAndSettle();
      expect(find.byType(WebLoginPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('web-login-password')));
      await tester.pumpAndSettle();
      await fill(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('native-login-submit')));
        await until(
          () => services.vault.credential(CloudPlatform.pan123) != null,
        );
        firstAnswer.complete(
          jsonResponse({
            'code': 200,
            'data': {'token': 'late-token'},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(
        services.vault.credential(CloudPlatform.pan123)!.field('accessToken'),
        'second-token',
      );
      expect(signIns, 2);
      expect(find.byType(PasswordLoginFlow), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  Future<void> captchaDialog(WidgetTester tester, GestureCaptcha client) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(300, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<TianyiCaptchaProof>(
                context: context,
                builder: (_) => TianyiCaptchaDialog(client),
              ),
              child: const Text('验证'),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('验证'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tianyi-captcha-image')), findsOneWidget);
  }

  testWidgets(
    'Native ordered taps preserve captcha coordinates on a scaled screen',
    (tester) async {
      var cancelled = false;
      final client = GestureCaptcha(2, cancel: () => cancelled = true);
      await captchaDialog(tester, client);
      final image = find.byKey(const ValueKey('tianyi-captcha-image'));
      final origin = tester.getTopLeft(image),
          scale = tester.getSize(image).width / 310;
      for (final point in [
        const Offset(30, 30),
        const Offset(80, 70),
        const Offset(140, 100),
      ]) {
        await tester.tapAt(origin + point * scale);
        await tester.pump(const Duration(milliseconds: 100));
        if (client.submitted == null) expect(tester.getTopLeft(image), origin);
      }
      await tester.pumpAndSettle();
      final gesture = client.submitted!;
      expect(gesture.points, hasLength(3));
      expect(gesture.points[0]['x'], closeTo(30, 0.01));
      expect(gesture.points[1]['y'], closeTo(70, 0.01));
      expect(gesture.points[2]['x'], closeTo(140, 0.01));
      expect(cancelled, isFalse);
      expect(find.byType(TianyiCaptchaDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Native slider submits bounded positions and real movement samples',
    (tester) async {
      final client = GestureCaptcha(1, cancel: () {});
      await captchaDialog(tester, client);
      await tester.drag(
        find.byKey(const ValueKey('tianyi-captcha-slider')),
        const Offset(90, 0),
      );
      await tester.pumpAndSettle();
      final gesture = client.submitted!;
      expect(gesture.points.single['x'], inInclusiveRange(20, 263));
      expect(gesture.points.single['y'], 0);
      expect(gesture.rates, isNotEmpty);
      expect(gesture.rates.length, lessThanOrEqualTo(50));
      expect(gesture.rates.every((r) => r['timeDiff']! >= 0), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Captcha cancellation closes the native verification without a proof',
    (tester) async {
      var cancelled = false;
      final client = GestureCaptcha(2, cancel: () => cancelled = true);
      await captchaDialog(tester, client);
      await tester.tap(find.text('取消登录'));
      await tester.pumpAndSettle();
      expect(cancelled, isTrue);
      expect(client.submitted, isNull);
      expect(find.byType(TianyiCaptchaDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
