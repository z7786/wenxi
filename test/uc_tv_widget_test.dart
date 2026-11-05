import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/uc_tv.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/ui/uc_tv_authorization_page.dart';
import 'player_support.dart';
import 'support.dart';
import 'uc_tv_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late UcTvFixture f;

  void scenario(String title, Future<void> Function(WidgetTester) body) {
    testWidgets(title, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        services.close().then((_) => closed = true);
        for (var i = 0; i < 40 && !closed; i++) {
          await tester.pump();
        }
        expect(closed, isTrue);
        services.store.dispose();
      }
    });
  }

  Future<void> render(
    WidgetTester tester, {
    bool authorized = false,
    bool player = false,
    bool menu = false,
    Size size = const Size(393, 852),
    double scale = 1,
    bool dark = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    f = UcTvFixture(credential: ucTvCredential(authorized: authorized));
    services = AppServices(
      controlEnabled: false,
      store: f.store,
      dataDirectory: Directory('test-fixture'),
      cacheDirectory: Directory('test-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture/saved')),
      http: f.http,
      platformFeatures: false,
    );
    services.cloud.connectors[CloudPlatform.uc] = f.connector;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final controller = player
        ? cloudPlayback(
            services,
            ucTvPersonal,
            ucTvVideo,
            [ucTvVideo],
            backendFactory: (entry, _) => FakePlaybackBackend(entry.id, []),
          )
        : null;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(dark ? Brightness.dark : Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  if (menu) {
                    await accountMenu(context, services, CloudPlatform.uc);
                  } else if (player) {
                    await Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlayerPage(
                          controller!,
                          subtitleDirectory: Directory(
                            'test-fixture/subtitles',
                          ),
                          device: FakePlaybackDevice(),
                          onAuthorizeUcTv: (_) =>
                              openUcTvAuthorization(context, services),
                        ),
                      ),
                    );
                  } else {
                    await openUcTvAuthorization(context, services);
                  }
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  }

  scenario(
    'QR page pauses polling in background and saves after foreground confirmation',
    (tester) async {
      await render(tester);
      expect(find.byType(UcTvAuthorizationPage), findsOneWidget);
      expect(find.byType(Image), findsWidgets);
      expect(find.textContaining('Extscreen'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(f.calls('/oauth/code'), hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 12));
      expect(f.calls('/oauth/code'), hasLength(1));
      f.scanned = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(UcTvService.authorized(f.credential), isTrue);
      expect(find.byType(UcTvAuthorizationPage), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      expect(f.credential.updatedAt, 7);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Back navigation invalidates a pending poll before the route animation finishes',
    (tester) async {
      await render(tester);
      final pending = Completer<HttpResult>();
      f.respond = (r) => r.uri.path == '/oauth/code' ? pending.future : null;
      await tester.pump(const Duration(seconds: 2));
      expect(f.calls('/oauth/code'), hasLength(1));
      await tester.pageBack();
      pending.complete(ucTvOk({'code': 'late-cancelled-code'}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(f.calls('/ucdrive/token'), isEmpty);
      expect(UcTvService.authorized(f.credential), isFalse);
      expect(f.credential.primary, contains('web-session'));
      expect(tester.takeException(), isNull);
    },
  );

  scenario('Expired QR can be regenerated without changing the web login', (
    tester,
  ) async {
    await render(tester);
    f.now += 301000;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('二维码已超时，请重新获取'), findsOneWidget);
    await tester.ensureVisible(find.text('重新获取二维码'));
    await tester.tap(find.text('重新获取二维码'));
    await tester.pump();
    expect(f.calls('/oauth/authorize'), hasLength(2));
    expect(f.credential.updatedAt, 7);
    expect(tester.takeException(), isNull);
  });

  scenario(
    'Account menu exposes the TV grant and revocation preserves web login',
    (tester) async {
      await render(tester, authorized: true, menu: true);
      await tester.ensureVisible(find.text('TV 播放授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('TV 播放授权'));
      await tester.pumpAndSettle();
      expect(find.text('TV 播放已就绪'), findsOneWidget);
      expect(f.calls('/oauth/authorize'), isEmpty);
      await tester.ensureVisible(find.text('解除 TV 播放授权'));
      await tester.tap(find.text('解除 TV 播放授权'));
      await tester.pump();
      expect(UcTvService.authorized(f.credential), isFalse);
      expect(f.credential.primary, contains('web-session'));
      expect(f.credential.updatedAt, 7);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'An unconfigured video opens QR authorization once and resumes after confirmation',
    (tester) async {
      await render(tester, player: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(UcTvAuthorizationPage), findsOneWidget);
      f.scanned = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byType(UcTvAuthorizationPage), findsNothing);
      final page = tester.widget<PlayerPage>(find.byType(PlayerPage));
      expect(page.controller.ready, isTrue);
      expect(page.controller.sourceError, isNull);
      expect(f.calls('/file'), hasLength(1));
      expect(f.calls('/oauth/authorize'), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Cancelling the player authorization leaves a retry action without reopening QR',
    (tester) async {
      await render(tester, player: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(UcTvAuthorizationPage), findsNothing);
      expect(find.text('扫码授权播放'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(f.calls('/oauth/authorize'), hasLength(1));
      await tester.tap(find.text('扫码授权播放'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(UcTvAuthorizationPage), findsOneWidget);
      expect(f.calls('/oauth/authorize'), hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in [
    ('small enlarged-text phone', const Size(320, 700), 1.6, false),
    ('dark desktop', const Size(1100, 780), 1.0, true),
  ]) {
    scenario('QR controls remain reachable on ${entry.$1}', (tester) async {
      await render(tester, size: entry.$2, scale: entry.$3, dark: entry.$4);
      await tester.ensureVisible(find.text('重新获取二维码'));
      await tester.pump();
      expect(find.text('重新获取二维码').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
