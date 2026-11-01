import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/quark_login_page.dart';
import 'quark_login_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  late AppServices services;
  late QuarkLoginFixture f;
  var closed = false;
  var systemFont = false;
  setUpAll(() async {
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('QuarkLoginFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  Future<void> render(
    WidgetTester tester, {
    bool nativeOnly = false,
    Size size = const Size(393, 852),
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    f = QuarkLoginFixture();
    late Directory directory;
    late Zone ioZone;
    services = (await tester.runAsync(() async {
      ioZone = Zone.current;
      directory = await Directory.systemTemp.createTemp(
        'asterlink-quark-login-',
      );
      return AppServices(
        controlEnabled: false,
        store: StateStore.memory(),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${directory.path}/saved')),
        http: f.http,
        platformFeatures: false,
      );
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await services.close();
        await directory.delete(recursive: true);
      });
    });
    closed = false;
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: appTheme(
            Brightness.light,
            fontFamily: systemFont ? 'QuarkLoginFixture' : null,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  await ioZone.run(() async {
                    if (nativeOnly) {
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => QuarkLoginPage(
                            services,
                            onUseWeb: () => Navigator.pop(context),
                            onUseManual: () {},
                            verifyCaptcha: ({required useSlider}) async =>
                                quarkProof(slider: useSlider),
                          ),
                        ),
                      );
                    } else {
                      await openLogin(context, services, CloudPlatform.quark);
                    }
                  });
                  closed = true;
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
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> fillSms(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('quark-sms-mobile')),
      '13800000000',
    );
    await tap(tester, 'quark-sms-agreement');
    await tester.runAsync(() async {
      await tap(tester, 'quark-sms-send');
      await until(
        () => f.http.calls.any((r) => r.uri.path.endsWith('/sendSmsCode')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('QUARK_LOGIN_SCREENSHOTS')) return;
    await tester.pumpAndSettle();
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.local/quark-login-20261021/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final (size, scale, name) in [
    (const Size(393, 852), 1.0, 'phone'),
    (const Size(1280, 800), 1.0, 'desktop'),
    (const Size(360, 800), 1.5, 'phone-large-text'),
  ]) {
    testWidgets(
      'native phone login layout without QR at $size with text scale $scale',
      (tester) async {
        await render(tester, size: size, scale: scale);
        expect(find.byType(QuarkLoginPage), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
        expect(find.byKey(const ValueKey('quark-sms-mobile')), findsOneWidget);
        expect(f.http.calls, isEmpty);
        await screenshot(tester, '$name-sms');
        expect(find.text('扫码登录'), findsNothing);
        expect(find.byKey(const ValueKey('quark-login-method')), findsNothing);
        expect(find.byKey(const ValueKey('quark-login-qr')), findsNothing);
        await tester.pump(const Duration(seconds: 6));
        expect(f.http.calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('web and manual login stay within the awaited account route', (
    tester,
  ) async {
    await render(tester);
    final owner = services.vault.activeAccountId(CloudPlatform.quark);
    await tap(tester, 'native-login-web');
    await tester.pumpAndSettle();
    expect(find.byType(WebLoginPage), findsOneWidget);
    expect(find.text('切换手机号登录'), findsOneWidget);
    expect(closed, isFalse);
    await tap(tester, 'web-login-password');
    await tester.pumpAndSettle();
    expect(find.byType(QuarkLoginPage), findsOneWidget);
    await tap(tester, 'native-login-manual');
    await tester.pumpAndSettle();
    expect(find.byType(ManualLoginPage), findsOneWidget);
    expect(closed, isFalse);
    expect(services.vault.activeAccountId(CloudPlatform.quark), owner);
    await tap(tester, 'manual-login-password');
    await tester.pumpAndSettle();
    expect(find.byType(QuarkLoginPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(QuarkLoginPage))).pop();
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    expect(closed, isTrue);
    expect(services.vault.credential(CloudPlatform.quark), isNull);
  });

  testWidgets(
    'phone and agreement validation happen before security verification',
    (tester) async {
      await render(tester);
      await tap(tester, 'quark-sms-send');
      expect(find.text('请输入正确的手机号'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('quark-sms-mobile')),
        '13800000000',
      );
      await tap(tester, 'quark-sms-send');
      expect(find.text('请先阅读并同意夸克用户协议和隐私政策'), findsOneWidget);
      expect(f.http.calls, isEmpty);
    },
  );

  testWidgets(
    'changing phone invalidates its code and keeps the send cooldown',
    (tester) async {
      await render(tester, nativeOnly: true);
      await fillSms(tester);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('quark-sms-send')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('quark-sms-code')),
        '1234',
      );
      await tester.enterText(
        find.byKey(const ValueKey('quark-sms-mobile')),
        '13900000000',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('quark-sms-code')))
            .controller!
            .text,
        isEmpty,
      );
      await tap(tester, 'quark-sms-submit');
      expect(find.text('请先获取当前手机号的验证码'), findsOneWidget);
      expect(f.http.calls, hasLength(1));
    },
  );

  testWidgets('successful SMS login saves the account and closes its route', (
    tester,
  ) async {
    await render(tester, nativeOnly: true);
    await fillSms(tester);
    await tester.enterText(
      find.byKey(const ValueKey('quark-sms-code')),
      '1234',
    );
    await tester.runAsync(() async {
      await tap(tester, 'quark-sms-submit');
      await until(() => services.vault.credential(CloudPlatform.quark) != null);
    });
    await tester.pumpAndSettle();
    expect(
      services.vault.credential(CloudPlatform.quark)!.field('username'),
      '13800000000',
    );
    expect(find.byType(QuarkLoginPage), findsNothing);
    expect(closed, isTrue);
  });

  for (final action in ['switch', 'back']) {
    testWidgets('$action cancels pending SMS login before it can save', (
      tester,
    ) async {
      await render(tester, nativeOnly: true);
      await fillSms(tester);
      await tester.enterText(
        find.byKey(const ValueKey('quark-sms-code')),
        '1234',
      );
      final answer = Completer<HttpResult>();
      var cancelled = false;
      f.override = (r) {
        if (r.uri.path.endsWith('/commit')) {
          RequestScope.current!.whenCancel.then((_) => cancelled = true);
          return answer.future;
        }
        return null;
      };
      await tester.runAsync(() async {
        await tap(tester, 'quark-sms-submit');
        await until(
          () => f.http.calls.any((r) => r.uri.path.endsWith('/commit')),
        );
      });
      if (action == 'switch') {
        await tap(tester, 'native-login-web');
      } else {
        Navigator.of(tester.element(find.byType(QuarkLoginPage))).pop();
        await tester.pump();
      }
      await tester.runAsync(() => until(() => cancelled));
      f.override = null;
      answer.complete(
        jsonResponse({'status': 20000, 'data': 'late-fixture-ticket'}),
      );
      await tester.pumpAndSettle();
      expect(services.vault.credential(CloudPlatform.quark), isNull);
      expect(f.http.calls.where((r) => r.uri.path == '/account/info'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
