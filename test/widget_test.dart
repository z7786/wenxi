import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/quark_login_page.dart';
import 'package:asterlink/ui/guangya_sms_login_page.dart';
import 'package:asterlink/ui/wopan_sms_login_page.dart';
import 'package:asterlink/ui/cloud_page.dart';
import 'package:asterlink/ui/experimental_features_page.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/ui/preview_page.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/windows_actions.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bool systemFont = false;
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
      final loader = FontLoader('FixtureUI')
        ..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
      await loader.load();
      systemFont = true;
    }
  });
  Future<AppServices> fixture({
    bool dark = false,
    FakeHttp? http,
    bool loggedIn = true,
    bool missingFiles = false,
    bool quotaExamples = false,
    bool windowsDownloads = false,
  }) async {
    final store = StateStore.memory({
      'settings': {'theme': dark ? 'Dark' : 'Light'},
      'credentials': {
        if (quotaExamples) ...{
          'Baidu': Credential('百度', {
            'primary': 'BDUSS=fixture',
          }, updatedAt: 1).toJson(),
          'Pan123': Credential('123', {
            'accessToken': 'fixture',
          }, updatedAt: 1).toJson(),
        },
        if (loggedIn)
          'Quark': Credential('夸克', {
            'primary': '__pus=fixture; __puus=test-only',
          }, updatedAt: 1).toJson(),
      },
      'tasks': [
        for (var i = 0; i < 2; i++)
          DownloadTask(
            id: 'fixture-$i',
            spec: DownloadSpec(
              url: 'https://example.com/fixture',
              fileName: i == 0
                  ? '追忆影视 Ver.5.8.0 fix.apk'
                  : '豆丁视频 Ver.3.3.2.apk',
              source: {'platform': 'Quark'},
            ),
            createdAt: 2 - i,
            status: DownloadStatus.completed,
            total: i == 0 ? 50467962 : 51883540,
            downloaded: i == 0 ? 50467962 : 51883540,
            connections: 512,
            savedPath: 'content://fixture/$i',
          ).toJson(),
      ],
    });
    final native = FakeNative();
    final services = AppServices(
      controlEnabled: false,
      store: store,
      dataDirectory: Directory('test-fixture'),
      cacheDirectory: Directory('test-fixture/cache'),
      transport: native,
      files: FakeFiles(Directory('test-fixture/saved'))
        ..availability.addAll({
          if (missingFiles) 'content://fixture/0': FileAvailability.missing,
          if (missingFiles)
            'content://fixture/1': FileAvailability.inaccessible,
        }),
      http: http ?? FakeHttp(),
      platformFeatures: false,
      windowsActions: WindowsActions(
        supported: windowsDownloads,
        start: (_, _) async => fail('Fixture must not open Explorer'),
        run: (_, _) async => fail('Fixture must not shut down Windows'),
      ),
      clock: () => DateTime(2026, 9, 14, 20),
    );
    await services.downloads.initialize();
    services.accounts[CloudPlatform.quark] = const CloudAccount(
      'fixture',
      used: 811230822,
      total: 10737418240,
    );
    if (quotaExamples) {
      services.accounts[CloudPlatform.pan123] = const CloudAccount(
        'fixture',
        used: 75 * 1024 * 1024 * 1024,
        total: 100 * 1024 * 1024 * 1024,
      );
      services.accounts[CloudPlatform.baidu] = const CloudAccount(
        'fixture',
        used: 95 * 1024 * 1024 * 1024,
        total: 100 * 1024 * 1024 * 1024,
      );
    }
    return services;
  }

  Future<AppServices> render(
    WidgetTester tester,
    Size size,
    int tab, {
    bool dark = false,
    double scale = 1,
    FakeHttp? http,
    bool loggedIn = true,
    bool missingFiles = false,
    bool quotaExamples = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    debugDisableShadows = false;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final services = (await tester.runAsync(
      () => fixture(
        dark: dark,
        http: http,
        loggedIn: loggedIn,
        missingFiles: missingFiles,
        quotaExamples: quotaExamples,
        windowsDownloads: size.width >= 820 && tab == 2,
      ),
    ))!;
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('capture'),
        child: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: AsterLinkApp(
            services,
            initialTab: tab == 0 ? 0 : tab + 1,
            fontFamily: systemFont ? 'FixtureUI' : null,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      final context = tester.element(find.byType(MainShell));
      for (final file in Directory(
        'assets/icons',
      ).listSync().whereType<File>()) {
        if (file.path.endsWith('.png') || file.path.endsWith('.webp')) {
          await precacheImage(
            AssetImage(file.path.replaceAll('\\', '/')),
            context,
          );
        }
      }
    });
    await tester.pumpAndSettle();
    debugDisableShadows = true;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = services.close().whenComplete(() => closed = true);
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(closed, isTrue, reason: 'Fixture cleanup must finish');
      await closing;
    });
    return services;
  }

  Future<void> changeTextScale(WidgetTester tester, double scale) async {
    final app = tester.widget<AsterLinkApp>(find.byType(AsterLinkApp));
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('capture'),
        child: MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: app,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in CloudPlatform.values.where((p) => p.requiresAccount)) {
    testWidgets('${platform.key} cloud card opens its current login flow', (
      tester,
    ) async {
      await render(tester, const Size(1100, 900), 1, loggedIn: false);
      final title = cloudEntries
          .singleWhere((entry) => entry.$3 == platform)
          .$2;
      // Account reservation is persisted before opening the login route. Keep
      // this write on the same real event loop as the fixture's storage.
      await tester.runAsync(() async {
        await tester.tap(find.text(title));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      if (platform == CloudPlatform.baidu) {
        expect(find.text('百度网盘使用提醒'), findsNothing);
        expect(find.text('百度网盘下载提示'), findsNothing);
      }
      if (platform == CloudPlatform.xunlei) {
        expect(find.byType(XunleiLoginPage), findsOneWidget);
        expect(find.text('账号密码'), findsOneWidget);
        expect(find.text('短信登录'), findsOneWidget);
      } else if (platform == CloudPlatform.github) {
        expect(find.text('GitHub 登录'), findsOneWidget);
        expect(find.byKey(const Key('github-token')), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
      } else if (platform == CloudPlatform.pan123 ||
          platform == CloudPlatform.tianyi ||
          platform == CloudPlatform.aliyun ||
          platform == CloudPlatform.ilanzou ||
          platform == CloudPlatform.lanzou ||
          platform == CloudPlatform.ctfile ||
          platform == CloudPlatform.pikpak ||
          platform == CloudPlatform.feijipan) {
        expect(find.byType(NativePasswordLoginPage), findsOneWidget);
        expect(
          tester
              .widget<NativePasswordLoginPage>(
                find.byType(NativePasswordLoginPage),
              )
              .platform,
          platform,
        );
        expect(find.text('账号密码登录'), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
      } else if (platform == CloudPlatform.quark) {
        expect(find.byType(QuarkLoginPage), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
      } else if (platform == CloudPlatform.guangya) {
        expect(find.byType(GuangyaSmsLoginPage), findsOneWidget);
        expect(find.text('手机号验证码登录'), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
      } else if (platform == CloudPlatform.wopan) {
        expect(find.byType(WopanSmsLoginPage), findsOneWidget);
        expect(find.text('手机号验证码登录'), findsOneWidget);
        expect(find.byType(WebLoginPage), findsNothing);
      } else {
        expect(find.byType(WebLoginPage), findsOneWidget);
        expect(
          tester
              .widget<WebLoginPage>(find.byType(WebLoginPage))
              .target
              .platform,
          platform,
        );
      }
      expect(find.byType(ManualLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }

  testWidgets('Baidu account button opens web login without a warning', (
    tester,
  ) async {
    final http = FakeHttp();
    final services = await render(
      tester,
      const Size(1100, 900),
      1,
      loggedIn: false,
      http: http,
    );
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('百度网盘账号操作'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.text('百度网盘使用提醒'), findsNothing);
    expect(find.byType(WebLoginPage), findsOneWidget);
    expect(services.vault.credential(CloudPlatform.baidu), isNull);
    expect(http.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Baidu re-login opens directly and backing out preserves the current account',
    (tester) async {
      final services = await render(
        tester,
        const Size(1100, 900),
        1,
        quotaExamples: true,
      );
      final credential = services.vault.credential(CloudPlatform.baidu);
      await tester.tap(find.byTooltip('百度网盘账号操作'));
      await tester.pumpAndSettle();
      expect(find.text('百度网盘使用提醒'), findsNothing);
      await tester.tap(find.text('重新登录当前账号'));
      await tester.pumpAndSettle();
      expect(find.text('百度网盘使用提醒'), findsNothing);
      expect(find.byType(WebLoginPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(WebLoginPage))).pop();
      await tester.pumpAndSettle();
      expect(
        services.vault.credential(CloudPlatform.baidu)?.toJson(),
        credential?.toJson(),
      );
      expect(find.byType(WebLoginPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Lanzou keeps anonymous parsing beside its personal account entry',
    (tester) async {
      final http = FakeHttp();
      final services = await render(
        tester,
        const Size(393, 864),
        1,
        loggedIn: false,
        http: http,
      );
      await tester.scrollUntilVisible(find.byTooltip('蓝奏云解析'), 300);
      await tester.drag(
        find.byKey(const PageStorageKey('cloud-list')),
        const Offset(0, -180),
      );
      await tester.pumpAndSettle();
      final lanzouCard = find
          .ancestor(of: find.text('蓝奏云'), matching: find.byType(InkWell))
          .first;
      expect(
        find.descendant(of: lanzouCard, matching: find.text('未登录')),
        findsOneWidget,
      );
      expect(find.byTooltip('蓝奏云账号操作'), findsOneWidget);
      await tester.tap(find.byTooltip('蓝奏云解析'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('parse-input')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('parse-input')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(find.byType(WebLoginPage), findsNothing);
      expect(find.byType(NativePasswordLoginPage), findsNothing);
      expect(http.calls, isEmpty);
      expect(services.vault.credential(CloudPlatform.lanzou), isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Desktop cloud list hides unavailable entries and keeps supported drives',
    (tester) async {
      final http = FakeHttp();
      await render(
        tester,
        const Size(1100, 900),
        1,
        loggedIn: false,
        http: http,
      );
      for (final entry in cloudEntries.where((entry) => entry.$3 == null)) {
        expect(find.text(entry.$2), findsNothing);
        expect(find.byTooltip('${entry.$2}账号操作'), findsNothing);
      }
      for (final entry in cloudEntries.where((entry) => entry.$3 != null)) {
        expect(find.text(entry.$2), findsOneWidget);
      }
      expect(find.text('暂未开放'), findsNothing);
      expect(http.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, size, tab, dark, scale)
      in <(String, Size, int, bool, double)>[
        ('phone-cloud', const Size(393, 864), 1, false, 1),
        ('phone-downloads', const Size(393, 864), 2, false, 1),
        ('desktop-cloud', const Size(1100, 780), 1, false, 1),
        ('desktop-downloads', const Size(1100, 780), 2, false, 1),
        ('phone-dark', const Size(393, 864), 1, true, 1),
        ('phone-large-text', const Size(393, 864), 2, false, 1.8),
        ('phone-parse', const Size(393, 864), 0, false, 1),
        ('phone-parse-recognized', const Size(393, 864), 0, false, 1),
        ('phone-parse-dark', const Size(393, 864), 0, true, 1),
        ('phone-parse-favorites', const Size(393, 864), 0, false, 1),
        ('phone-parse-large-text', const Size(320, 700), 0, false, 1.8),
        ('desktop-parse', const Size(1100, 780), 0, false, 1),
        ('desktop-parse-favorites', const Size(1100, 780), 0, false, 1),
        ('phone-mine', const Size(393, 864), 3, false, 1),
        ('desktop-mine', const Size(1100, 780), 3, false, 1),
        ('phone-downloads-missing', const Size(393, 864), 2, false, 1),
        ('phone-cloud-quota', const Size(393, 864), 1, false, 1),
      ]) {
    testWidgets('$name layout and reference snapshot', (tester) async {
      if (name.startsWith('desktop-parse') || name == 'desktop-mine') {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      }
      try {
        final services = await render(
          tester,
          size,
          tab,
          dark: dark,
          scale: scale,
          missingFiles: name == 'phone-downloads-missing',
          quotaExamples: name == 'phone-cloud-quota',
        );
        if (name.endsWith('parse-favorites')) {
          await tester.runAsync(() async {
            final session = services.cloud.bindSession(
              const BrowseSession(
                platform: CloudPlatform.quark,
                mode: BrowseMode.personal,
                title: '夸克网盘',
                rootId: '0',
              ),
            );
            await services.favorites.toggle(
              session,
              const CloudFile(
                id: 'travel',
                name: '旅行影像',
                parentId: '0',
                isDirectory: true,
              ),
              [('0', '全部文件')],
            );
            await services.favorites.toggle(
              session,
              const CloudFile(
                id: 'guide',
                name: '旅行攻略.pdf',
                parentId: 'travel',
              ),
              [('0', '全部文件'), ('travel', '旅行影像')],
            );
            await services.store.put('playbackHistory', {
              'fixture': {
                'name': '海边日落.mp4',
                'position': 120000,
                'duration': 600000,
                'updatedAt': 1234,
                'completed': false,
              },
            });
            // Multiple fixture saves can share one millisecond. Fix their
            // timestamps so screenshots always show the same newest-first order.
            await services.store.put('cloudFavorites', [
              for (final favorite in services.favorites.all)
                {
                  ...favorite.toJson(),
                  'createdAt': favorite.file.id == 'guide' ? 2000 : 1000,
                },
            ]);
          });
          await tester.pumpAndSettle();
          if (name.startsWith('phone')) {
            await tester.drag(
              find.byKey(const PageStorageKey('parse')),
              const Offset(0, -250),
            );
            await tester.pumpAndSettle();
          }
          expect(find.text('网盘收藏').hitTestable(), findsOneWidget);
          expect(find.text('最近播放').hitTestable(), findsOneWidget);
        }
        if (name == 'phone-parse-recognized') {
          debugDisableShadows = false;
          await tester.enterText(
            find.byKey(const Key('parse-input')),
            '我用夸克网盘分享了「旅行影像」\n链接：https://pan.quark.cn/s/Travel2026\n提取码：a1B2\n复制这段内容即可查看分享文件',
          );
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        // Reference images use the Windows Microsoft YaHei font.
        // Other hosts still run all layout and interaction assertions.
        if (systemFont) {
          await expectLater(
            find.byKey(const Key('capture')),
            matchesGoldenFile('goldens/$name.png'),
          );
        }
        debugDisableShadows = true;
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
  testWidgets(
    'Experimental download settings open separately and preserve independent switches',
    (tester) async {
      final services = await render(tester, const Size(393, 864), 3);
      expect(find.byType(ExperimentalFeaturesPage), findsNothing);
      expect(find.text('突破文件大小限制'), findsNothing);
      await tester.tap(find.text('实验性功能'));
      await tester.pumpAndSettle();
      expect(find.byType(ExperimentalFeaturesPage), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNWidgets(3));
      expect(find.text('突破文件大小限制'), findsOneWidget);
      expect(find.text('游客下载'), findsNWidgets(2));
      expect(find.textContaining('修改后自动保存'), findsNothing);
      expect(find.textContaining('50 MB'), findsOneWidget);
      expect(find.textContaining('游客下载不限制文件大小'), findsOneWidget);
      expect(find.textContaining('已登录时优先使用账号解析下载'), findsOneWidget);
      expect(find.textContaining('已登录时也优先尝试游客下载'), findsNothing);
      expect(services.settings.quarkAuthenticatedDirectDownload, isFalse);
      expect(services.settings.quarkGuestDirectDownload, isFalse);
      expect(services.settings.ucGuestDirectDownload, isTrue);

      final quarkSwitch = find.byKey(
        const ValueKey('quarkAuthenticatedDirectDownload'),
      );
      await tester.runAsync(() async {
        await tester.tap(quarkSwitch);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(quarkSwitch).value, isTrue);
      expect(services.settings.ucGuestDirectDownload, isTrue);
      expect(services.settings.quarkGuestDirectDownload, isFalse);
      Navigator.of(tester.element(find.byType(ExperimentalFeaturesPage))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('实验性功能'));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(quarkSwitch).value, isTrue);

      tester.view.physicalSize = const Size(320, 700);
      await changeTextScale(tester, 1.8);
      final ucSwitch = find.byKey(const ValueKey('ucGuestDirectDownload'));
      await tester.scrollUntilVisible(
        ucSwitch,
        200,
        scrollable: find.descendant(
          of: find.byType(ExperimentalFeaturesPage),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(ucSwitch.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Phone settings theme selection persists and remains usable at large text sizes',
    (tester) async {
      final services = await render(tester, const Size(393, 864), 3);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(
        tester.getTopLeft(find.text('外观')).dy,
        lessThan(tester.getTopLeft(find.text('下载设置')).dy),
      );
      await tester.tap(find.text('主题与外观'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('appearance-mode-System')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('appearance-mode-Dark')),
      );
      await tester.tap(find.byKey(const ValueKey('appearance-mode-Dark')));
      await tester.pumpAndSettle();
      expect(services.settings.theme, 'Light');
      await tester.tap(find.byKey(const Key('appearance-apply')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(services.settings.theme, 'Dark');
      expect(find.text('主题与外观'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(320, 700);
      await changeTextScale(tester, 1.8);
      expect(tester.takeException(), isNull);
      for (final title in ['下载保存目录', '导出加密备份', '日志与故障排查']) {
        await tester.scrollUntilVisible(
          find.text(title),
          240,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text(title).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(services.downloads.tasks, hasLength(2));
      // The fixture initialized its storage on the real event loop. Finish
      // writes queued by the sheet's callback before the common IO teardown.
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      services.close().then((_) => closed = true);
      for (var i = 0; i < 10 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'Desktop settings use two columns and collapse for accessible text sizing',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await render(tester, const Size(1100, 780), 3);
        expect(find.text('主题与外观').hitTestable(), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('外观')).dx,
          greaterThan(tester.getTopLeft(find.text('下载设置')).dx),
        );
        expect(
          tester.getTopLeft(find.text('外观')).dy,
          tester.getTopLeft(find.text('下载设置')).dy,
        );
        await changeTextScale(tester, 1.8);
        expect(tester.takeException(), isNull);
        final settingsScroll = find
            .descendant(
              of: find.byKey(const PageStorageKey('mine')),
              matching: find.byType(Scrollable),
            )
            .first;
        final appearance = tester.getTopLeft(find.text('外观'));
        final initialOffset = tester
            .state<ScrollableState>(settingsScroll)
            .position
            .pixels;
        await tester.scrollUntilVisible(
          find.text('下载设置'),
          200,
          scrollable: settingsScroll,
        );
        final downloads = tester.getTopLeft(find.text('下载设置'));
        expect(downloads.dx, appearance.dx);
        expect(
          downloads.dy +
              tester.state<ScrollableState>(settingsScroll).position.pixels,
          greaterThan(appearance.dy + initialOffset),
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'Desktop resizing preserves expanded settings without mixing scroll state',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final services = await render(tester, const Size(1100, 780), 3);
        await tester.tap(find.text('各网盘连接数'));
        await tester.pumpAndSettle();
        final settingsList = find.byKey(const PageStorageKey('mine'));
        await tester.drag(settingsList, const Offset(0, -190));
        await tester.pumpAndSettle();

        tester.view.physicalSize = const Size(740, 600);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('夸克 · 直链'), findsOneWidget);

        await tester.runAsync(() => services.updateSettings({'theme': 'Dark'}));
        await tester.pumpAndSettle();
        tester.view.physicalSize = const Size(1100, 780);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('夸克 · 直链'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'Baidu manual login saves a Cookie without requiring a custom app ID',
    (tester) async {
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/quota')
            ? jsonResponse({'errno': 0, 'used': 25, 'total': 100})
            : r.uri.path.endsWith('/list')
            ? jsonResponse({'errno': 0, 'list': []})
            : jsonResponse({
                'errno': 0,
                'result': {'username': '百度测试用户'},
              }),
      );
      final services = await render(
        tester,
        const Size(393, 864),
        1,
        http: http,
      );
      bool? navigationResult;
      Navigator.of(tester.element(find.byType(MainShell)))
          .push<bool>(
            MaterialPageRoute(
              builder: (_) => ManualLoginPage(services, CloudPlatform.baidu),
            ),
          )
          .then((result) => navigationResult = result);
      await tester.pumpAndSettle();
      expect(find.text('应用 ID（可选，默认 250528）'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        isEmpty,
      );
      await tester.enterText(
        find.byType(TextField).first,
        'BDUSS=widget-fixture',
      );
      await tester.tap(find.text('验证并保存'));
      // StateStore was initialized outside FakeAsync; let its pending writes
      // settle on the real event loop before finishing the route animation.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        if (services.vault.credential(CloudPlatform.baidu) != null) break;
      }
      expect(http.calls.length, greaterThanOrEqualTo(2));
      expect(services.vault.credential(CloudPlatform.baidu), isNotNull);
      await tester.pumpAndSettle();
      expect(navigationResult, isTrue);
      expect(
        services.vault.credential(CloudPlatform.baidu)!.primary,
        'BDUSS=widget-fixture',
      );
      expect(
        http.calls
            .where((r) => r.uri.host.endsWith('baidu.com'))
            .every((r) => r.uri.queryParameters['app_id'] == '250528'),
        isTrue,
      );
      expect(find.byType(ManualLoginPage), findsNothing);
      expect(tester.takeException(), isNull);
      // The UI queued storage futures in FakeAsync, while fixture setup used
      // real IO. Drain both loops before the common teardown awaits close().
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      services.close().then((_) => closed = true);
      for (var i = 0; i < 10 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }
      expect(closed, isTrue);
    },
  );

  testWidgets('UC login page saves cookies renewed during validation', (
    tester,
  ) async {
    final http = FakeHttp(
      (_) => const HttpResult(
        200,
        '{"status":200,"code":0,"data":{"nickname":"UC测试","use_capacity":25,"total_capacity":100}}',
        {
          'set-cookie': ['__puus=after-validation; Path=/; HttpOnly'],
        },
      ),
    );
    final services = await render(tester, const Size(393, 864), 1, http: http);
    bool? saved;
    Navigator.of(tester.element(find.byType(MainShell)))
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => ManualLoginPage(services, CloudPlatform.uc),
          ),
        )
        .then((value) => saved = value);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      '__pus=widget-account; __puus=before-validation',
    );
    await tester.tap(find.text('验证并保存'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      if (services.vault.credential(CloudPlatform.uc) != null) break;
    }
    await tester.pumpAndSettle();
    expect(saved, isTrue);
    expect(
      services.vault.credential(CloudPlatform.uc)!.primary,
      '__pus=widget-account; __puus=after-validation',
    );
    expect(find.byType(ManualLoginPage), findsNothing);
    expect(tester.takeException(), isNull);
    // Finish futures created by both the UI's fake clock and real fixture IO.
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    services.close().then((_) => closed = true);
    for (var i = 0; i < 10 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    expect(closed, isTrue);
  });

  testWidgets(
    'Missing downloads remain visible, can be filtered and recover after rechecking',
    (tester) async {
      final services = await render(
        tester,
        const Size(600, 900),
        2,
        missingFiles: true,
      );
      expect(find.text('文件不存在'), findsOneWidget);
      expect(find.text('无法访问文件'), findsOneWidget);
      await tester.tap(find.text('文件异常 2'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('file-status-fixture-0')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('查看文件异常').first);
      await tester.pumpAndSettle();
      expect(find.text('打开文件'), findsNothing);
      expect(find.text('分享文件'), findsNothing);
      expect(find.textContaining('下载记录仍保留'), findsOneWidget);
      (services.files as FakeFiles).availability['content://fixture/0'] =
          FileAvailability.present;
      await tester.tap(find.text('重新检查文件'));
      await tester.pumpAndSettle();
      expect(find.text('打开文件'), findsOneWidget);
      expect(find.text('分享文件'), findsOneWidget);
      expect(
        services.downloads.task('fixture-0')!.status,
        DownloadStatus.completed,
      );
      expect(
        services.downloads.task('fixture-0')!.savedPath,
        'content://fixture/0',
      );
    },
  );

  testWidgets(
    'Opening rechecks a formerly available file before invoking a player or native app',
    (tester) async {
      final services = await render(tester, const Size(393, 864), 2);
      (services.files as FakeFiles).availability['content://fixture/0'] =
          FileAvailability.missing;
      await tester.tap(find.byTooltip('打开文件').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('文件不存在或已被移动'), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
      expect(
        find.byKey(const ValueKey('file-status-fixture-0')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Quota thresholds update both progress and accessible occupancy',
    (tester) async {
      var used = 69;
      final services = await render(
        tester,
        const Size(393, 864),
        1,
        http: FakeHttp(
          (_) => jsonResponse({
            'status': 200,
            'data': {
              'nickname': 'fixture',
              'total_capacity': 100,
              'use_capacity': used,
            },
          }),
        ),
      );
      for (final (value, color) in [
        (0, const Color(0xff34c759)),
        (69, const Color(0xff34c759)),
        (70, const Color(0xffff9500)),
        (89, const Color(0xffff9500)),
        (90, const Color(0xffff3b30)),
        (110, const Color(0xffff3b30)),
      ]) {
        used = value;
        await tester.runAsync(
          () => services.refreshAccount(CloudPlatform.quark),
        );
        await tester.pumpAndSettle();
        final bar = tester.widget<LinearProgressIndicator>(
          find.byKey(const Key('quota-Quark')),
        );
        expect(bar.color, color);
        expect(bar.value, (value / 100).clamp(0, 1));
        expect(bar.semanticsValue, '${value.clamp(0, 100)}');
      }
    },
  );

  testWidgets(
    'Capacity error action actually retries and replaces stale quota',
    (tester) async {
      var failed = true;
      final http = FakeHttp(
        (_) => failed
            ? jsonResponse({'status': 503}, 503)
            : jsonResponse({
                'status': 200,
                'data': {
                  'nickname': 'ready',
                  'total_capacity': 200,
                  'use_capacity': 50,
                },
              }),
      );
      final services = await render(
        tester,
        const Size(393, 864),
        1,
        http: http,
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.runAsync(() => services.refreshAccount(CloudPlatform.quark));
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('quota-retry-Quark'));
      expect(retry, findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      failed = false;
      await tester.tap(retry);
      for (var i = 0; i < 100 && services.accountErrors.isNotEmpty; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      await tester.pumpAndSettle();
      expect(services.accounts[CloudPlatform.quark]!.total, 200);
      expect(services.accountErrors, isEmpty);
      expect(retry, findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(http.calls.length, 2);
      expect(find.text('网盘列表'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Incomplete mobile cloud account opens login from its capacity message',
    (tester) async {
      final services = await render(tester, const Size(393, 864), 1);
      await tester.runAsync(() async {
        await services.vault.putCredential(
          CloudPlatform.c139,
          Credential('old', {
            'primary': 'Os_SSo_Sid=early; RMKEY=early',
          }, updatedAt: 1),
        );
        await services.refreshAccount(CloudPlatform.c139);
      });
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('quota-retry-C139'));
      await tester.scrollUntilVisible(
        retry,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(retry.hitTestable(), findsOneWidget);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.byType(WebLoginPage), findsOneWidget);
      expect(find.text('139网页登录'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('返回').first);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Overflow actions keep Escape and cleanup confirmation', (
    tester,
  ) async {
    final services = await render(tester, const Size(393, 864), 2);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('清理下载记录'), findsNothing);
    expect(services.downloads.tasks, hasLength(2));

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理下载记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('全部 2 条下载记录'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('downloads-clear-files')),
          )
          .value,
      false,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(services.downloads.tasks, hasLength(2));

    expect(tester.takeException(), isNull);
  });

  testWidgets('Cloud sorting toggles each key while keeping folders first', (
    tester,
  ) async {
    final http = FakeHttp();
    final services = await render(tester, const Size(393, 864), 1, http: http);
    Navigator.of(tester.element(find.byType(MainShell))).push<void>(
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          services,
          const BrowseSession(
            platform: CloudPlatform.quark,
            mode: BrowseMode.personal,
            title: '夸克网盘',
            rootId: '0',
          ),
          initialItems: const [
            CloudFile(
              id: 'b-folder',
              name: 'B-folder',
              isDirectory: true,
              size: 20,
              modifiedAt: '2026-09-02',
            ),
            CloudFile(
              id: 'alpha',
              name: 'Alpha.txt',
              size: 30,
              modifiedAt: '2026-09-01',
            ),
            CloudFile(
              id: 'a-folder',
              name: 'A-folder',
              isDirectory: true,
              size: 10,
              modifiedAt: '2026-09-01',
            ),
            CloudFile(
              id: 'bravo',
              name: 'Bravo.txt',
              size: 10,
              modifiedAt: '2026-09-03',
            ),
            CloudFile(
              id: 'charlie',
              name: 'Charlie.txt',
              size: 20,
              modifiedAt: '2026-09-02',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    void expectOrder(List<String> names) {
      final positions = [
        for (final name in names) tester.getTopLeft(find.text(name)).dy,
      ];
      expect(positions, orderedEquals([...positions]..sort()));
    }

    expectOrder([
      'A-folder',
      'B-folder',
      'Alpha.txt',
      'Bravo.txt',
      'Charlie.txt',
    ]);
    for (final (label, folders, files, direction) in [
      (
        '名称',
        ['B-folder', 'A-folder'],
        ['Charlie.txt', 'Bravo.txt', 'Alpha.txt'],
        '↓ 降序',
      ),
      (
        '大小',
        ['A-folder', 'B-folder'],
        ['Bravo.txt', 'Charlie.txt', 'Alpha.txt'],
        '↑ 升序',
      ),
      (
        '大小',
        ['B-folder', 'A-folder'],
        ['Alpha.txt', 'Charlie.txt', 'Bravo.txt'],
        '↓ 降序',
      ),
      (
        '时间',
        ['A-folder', 'B-folder'],
        ['Alpha.txt', 'Charlie.txt', 'Bravo.txt'],
        '↑ 升序',
      ),
      (
        '时间',
        ['B-folder', 'A-folder'],
        ['Bravo.txt', 'Charlie.txt', 'Alpha.txt'],
        '↓ 降序',
      ),
    ]) {
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      // Settings now persist in the fixture's real event loop. Await the save
      // before checking the rendered order or selecting the next sort key.
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await tester.runAsync(() => services.store.flush());
      await tester.pumpAndSettle();
      expectOrder([...folders, ...files]);
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      expect(find.text(direction), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    expect(http.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('All phone pages extend behind the floating navigation', (
    tester,
  ) async {
    await render(tester, const Size(393, 864), 0);
    for (final (index, pageKey) in [
      (0, 'parse'),
      (1, 'resource-catalog-home'),
      (2, 'cloud-list'),
      (3, 'downloads'),
      (4, 'mine'),
    ]) {
      await tester.tap(find.byKey(ValueKey('navigation-$index')));
      await tester.pumpAndSettle();
      final page = find.byKey(PageStorageKey(pageKey));
      final bar = find.byKey(const Key('floating-navigation'));
      expect(
        tester.getRect(page).bottom,
        greaterThan(tester.getRect(bar).bottom),
      );
      expect(
        MediaQuery.paddingOf(tester.element(page)).bottom,
        greaterThanOrEqualTo(64),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Cloud layout saves reordering and hiding, and can restore defaults',
    (tester) async {
      final services = await render(tester, const Size(393, 864), 1);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排序与隐藏'));
      await tester.pumpAndSettle();
      final handle = tester.getCenter(
        find.byType(ReorderableDragStartListener).first,
      );
      final drag = await tester.startGesture(handle);
      await tester.pump();
      await drag.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 500));
      await drag.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cloud-visible-quark')));
      await tester.tap(find.text('完成'));
      await tester.runAsync(() => services.store.flush());
      await tester.pumpAndSettle();
      final saved = services.store.data['cloudListPreferences'] as Map;
      expect((saved['order'] as List).first, isNot('quark'));
      expect(saved['hidden'], contains('quark'));
      expect(find.text('夸克网盘'), findsNothing);

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('排序与隐藏'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Switch>(find.byKey(const ValueKey('cloud-visible-quark')))
            .value,
        isFalse,
      );
      await tester.tap(find.text('恢复默认'));
      await tester.tap(find.text('完成'));
      await tester.runAsync(() => services.store.flush());
      await tester.pumpAndSettle();
      expect(find.text('夸克网盘'), findsOneWidget);
      expect(
        (services.store.data['cloudListPreferences'] as Map)['hidden'],
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('All hidden clouds retain a way to restore the list', (
    tester,
  ) async {
    final services = await render(tester, const Size(393, 864), 1);
    await tester.runAsync(
      () => services.store.put('cloudListPreferences', {
        'hidden': [for (final entry in cloudEntries) entry.$3!.name],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂未显示任何网盘'), findsOneWidget);
    await tester.tap(find.text('排序与隐藏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复默认'));
    await tester.tap(find.text('完成'));
    await tester.runAsync(() => services.store.flush());
    await tester.pumpAndSettle();
    expect(find.text('夸克网盘'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bottom navigation keeps the four core features reachable', (
    tester,
  ) async {
    final services = await render(tester, const Size(393, 864), 0);
    expect(find.text('分享解析'), findsOneWidget);
    expect(find.byTooltip('更多操作'), findsNothing);
    await tester.tap(find.byKey(const Key('parse-announcements')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('announcements-page')), findsOneWidget);
    expect(find.text('暂无公告'), findsOneWidget);
    expect(find.text('粘贴链接'), findsNothing);
    expect(find.text('新建下载'), findsNothing);
    await tester.tap(find.byTooltip('返回').first);
    await tester.pumpAndSettle();
    expect(find.text('分享解析'), findsOneWidget);
    await tester.tap(find.text('网盘').last);
    await tester.pumpAndSettle();
    expect(find.text('网盘列表'), findsOneWidget);
    expect(find.text('夸克网盘'), findsOneWidget);
    final taskCount = services.downloads.tasks.length;
    Navigator.of(tester.element(find.text('网盘列表'))).push<void>(
      MaterialPageRoute(
        builder: (_) => PreviewPage(
          services,
          const BrowseSession(
            platform: CloudPlatform.quark,
            mode: BrowseMode.personal,
            title: 'fixture',
            rootId: '0',
          ),
          const CloudFile(id: 'archive', name: '压缩包.7z', size: 4096),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('此类型文件可下载后查看'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '下载文件'), findsOneWidget);
    await tester.tap(find.byTooltip('传输管理'));
    await tester.pumpAndSettle();
    expect(find.byType(PreviewPage), findsNothing);
    expect(
      find.byKey(const Key('download-concurrency')).hitTestable(),
      findsOneWidget,
    );
    expect(services.downloads.tasks.length, taskCount);
    expect(services.transferTab.value, 0);
    await tester.tap(find.byKey(const ValueKey('navigation-3')));
    await tester.pumpAndSettle();
    expect(find.text('传输管理'), findsOneWidget);
    await tester.tap(find.text('我的').last);
    await tester.pumpAndSettle();
    expect(find.text('HTTP 下载连接数'), findsOneWidget);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打赏作者'));
    await tester.pumpAndSettle();
    expect(find.text('谢谢你的支持'), findsOneWidget);
    expect(find.text('保存赞赏码'), findsOneWidget);
    expect(find.bySemanticsLabel('微信赞赏码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Download filtering and details expose safe default deletion', (
    tester,
  ) async {
    final services = await render(tester, const Size(393, 864), 2);
    await tester.tap(find.text('失败 0'));
    await tester.pumpAndSettle();
    expect(find.text('暂无失败任务'), findsOneWidget);
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('追忆影视 Ver.5.8.0 fix.apk'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('downloads-remove-record')));
    await tester.pumpAndSettle();
    final checkbox = tester.widget<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(checkbox.value, isFalse);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(services.downloads.tasks.length, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Narrow cloud list keeps every supported drive reachable', (
    tester,
  ) async {
    await render(tester, const Size(320, 700), 1, scale: 1.6);
    expect(find.text('夸克网盘'), findsOneWidget);
    expect(find.text('123网盘'), findsOneWidget);
    for (final (_, title, _) in cloudEntries) {
      await tester.scrollUntilVisible(find.text(title), 250);
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.byTooltip('$title账号操作'), findsOneWidget);
      expect(find.text('暂未开放'), findsNothing);
    }
    expect(find.text('网盘列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
