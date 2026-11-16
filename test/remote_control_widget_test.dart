import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/remote_control_dialogs.dart';
import 'package:asterlink/ui/announcement_markdown.dart';
import 'package:asterlink/ui/about_dialog.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/cloud_page.dart';
import 'package:asterlink/ui/login_page.dart';
import 'package:asterlink/ui/mine_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/parse_menu.dart';
import 'package:asterlink/ui/uc_tv_authorization_page.dart';
import 'remote_control_support.dart';
import 'support.dart';

class _MutationConnector extends CloudConnector {
  @override
  final platform = CloudPlatform.quark;
  int deletions = 0;
  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    deletions++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;
  AppServices? services;
  late FakeControlFetcher fetcher;
  late FakeHttp http;
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
      await (FontLoader('ControlFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  void scenario(String name, Future<void> Function(WidgetTester tester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (services case final active?) {
          var closed = false;
          active.close().then((_) => closed = true);
          for (var i = 0; i < 40 && !closed; i++) {
            await tester.pump();
          }
          expect(closed, isTrue);
          active.store.dispose();
          services = null;
        }
      }
    });
  }

  Future<void> render(
    WidgetTester tester,
    Widget Function(AppServices) page, {
    Json? config,
    bool loggedIn = true,
    bool configured = true,
    bool foreground = false,
    bool dark = false,
    double scale = 1,
    Size size = const Size(393, 852),
    GlobalKey<NavigatorState>? navigatorKey,
    DateTime Function()? clock,
    FutureOr<String> Function(Uri)? respond,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final data = config ?? controlJson();
    fetcher = FakeControlFetcher(data)..respond = respond;
    http = FakeHttp();
    final active = services = AppServices(
      store: StateStore.memory({
        ...controlCache(data),
        'credentials': {
          if (loggedIn)
            'Quark': Credential('fixture', {
              'primary': '__pus=a; __puus=b',
            }, updatedAt: 1).toJson(),
        },
      }),
      dataDirectory: Directory('control-widget-fixture'),
      cacheDirectory: Directory('control-widget-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('control-widget-fixture/saved')),
      http: http,
      platformFeatures: false,
      clock: clock ?? () => controlNow,
      controlUrl: controlEndpoint,
      controlEnabled: configured,
      controlFetcher: fetcher,
    );
    if (foreground) active.control.setForeground(true);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('control-capture'),
        child: MaterialApp(
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          theme:
              appTheme(
                dark ? Brightness.dark : Brightness.light,
                fontFamily: systemFont ? 'ControlFixture' : null,
              ).copyWith(
                platform: size.width >= 820
                    ? TargetPlatform.windows
                    : TargetPlatform.android,
              ),
          home: page(active),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget promptHome(AppServices s, {RemoteLinkLauncher? launcher}) => Scaffold(
    appBar: AppBar(
      title: const Text('我的'),
      actions: [
        ParseMenuButton(
          control: s.control,
          onDonate: () {},
          linkLauncher: launcher,
        ),
      ],
    ),
    body: Column(
      children: [
        RemoteControlPrompts(s.control, launcher: launcher),
        Expanded(child: MinePage(s, linkLauncher: launcher)),
      ],
    ),
  );

  Future<void> tapMine(WidgetTester tester, String label) async {
    if (['使用帮助', '项目地址'].contains(label) &&
        find.text(label).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        find.text('帮助与诊断'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('帮助与诊断'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('帮助与诊断'));
      await tester.pumpAndSettle();
    }
    await tester.scrollUntilVisible(
      find.text(label),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(label));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> tapAnnouncement(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件公告'));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('control-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('.local/update-policy-review/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  scenario('About refreshes its plain description without a license button', (
    tester,
  ) async {
    await render(
      tester,
      (services) => Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showWenxiAbout(context, services.control),
            child: const Text('关于文析助手'),
          ),
        ),
      ),
    );
    fetcher.text = jsonEncode(
      controlJson(revision: 2)..['about'] = {'description': '新的文析助手介绍\n第二行说明'},
    );
    await tester.tap(find.text('关于文析助手'));
    await tester.pumpAndSettle();
    expect(find.text('新的文析助手介绍\n第二行说明'), findsOneWidget);
    expect(find.text('查看许可'), findsNothing);
    expect(find.text('VIEW LICENSES'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
    fetcher.text = jsonEncode(
      controlJson(revision: 3)..['about'] = {'description': '弹窗中的介绍也会更新'},
    );
    await services!.control.refresh(force: true);
    await tester.pumpAndSettle();
    expect(find.text('弹窗中的介绍也会更新'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  scenario(
    'Week checkbox resets on content refresh and persists across restart and manual reopening',
    (tester) async {
      var now = controlNow;
      final initial = controlJson(noticeId: 'old');
      (initial['announcement'] as Map).remove('id');
      await render(
        tester,
        promptHome,
        config: initial,
        foreground: true,
        clock: () => now,
      );
      final checkbox = find.byKey(
        const ValueKey('control-hide-announcement-week'),
      );
      expect(find.text('7天不再显示'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      final latest = controlJson(revision: 2, noticeId: 'new');
      (latest['announcement'] as Map)['title'] = '新内容需要重新确认免打扰';
      fetcher.text = jsonEncode(latest);
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(services!.control.announcementMuted, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
      final reopened = RemoteControlService(
        StateStore.memory(jsonDecode(jsonEncode(services!.store.data))),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => now,
      );
      expect(reopened.unreadAnnouncement, isNull);
      reopened.close();
      await tapAnnouncement(tester);
      expect(find.text('新内容需要重新确认免打扰'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      services!.control.setForeground(false);
      now = now.add(const Duration(days: 1));
      services!.control.setForeground(true);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      services!.control.setForeground(false);
      now = now.add(const Duration(days: 6));
      services!.control.setForeground(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  scenario(
    'Changed announcement content automatically opens during a saved week mute',
    (tester) async {
      final initial = controlJson(noticeId: 'a');
      await render(tester, promptHome, config: initial, foreground: true);
      final checkbox = find.byKey(
        const ValueKey('control-hide-announcement-week'),
      );
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      (initial['announcement'] as Map)['content'] = '7天内更新的公告应再次显示';
      fetcher.text = jsonEncode(initial);
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(find.text('7天内更新的公告应再次显示'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      expect(services!.control.announcementMuted, isFalse);
    },
  );

  scenario(
    'Ordinary announcement close is eligible again after a full restart',
    (tester) async {
      await render(
        tester,
        promptHome,
        config: controlJson(noticeId: 'a'),
        foreground: true,
      );
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(services!.control.unreadAnnouncement, isNull);
      final reopened = RemoteControlService(
        StateStore.memory(jsonDecode(jsonEncode(services!.store.data))),
        enabled: true,
        platform: 'android',
        currentBuild: 44,
        configUrl: controlEndpoint,
        clock: () => controlNow,
      );
      expect(reopened.unreadAnnouncement, isNotNull);
      reopened.close();
    },
  );

  scenario(
    'Startup announcement shows pictures and opens its mini-program button',
    (tester) async {
      final opened = <Uri>[];
      final target = Uri.parse('weixin://dl/business/?t=example-ticket');
      final data = controlJson(
        noticeId: 'image-mini-program',
        buttonText: '打开微信小程序',
        buttonUrl: target.toString(),
      );
      (data['announcement'] as Map)['content'] =
          '## 活动说明\n\n![活动图片](https://images.example.test/notice.png)\n\n点击下方按钮进入小程序。';
      await render(
        tester,
        (s) => promptHome(
          s,
          launcher: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
        config: data,
        foreground: true,
      );
      expect(find.byType(AnnouncementMarkdown), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AnnouncementMarkdown),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );
      expect(find.text('活动说明'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.byKey(const ValueKey('control-announcement-link')));
      await tester.pumpAndSettle();
      expect(opened, [target]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(services!.control.unreadAnnouncement, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final action in ['link', 'back', 'outside']) {
    scenario('Week choice is honored when closing the notice by $action', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      final opened = <Uri>[];
      await render(
        tester,
        (s) => promptHome(
          s,
          launcher: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
        navigatorKey: navigator,
        config: controlJson(
          noticeId: 'a',
          buttonText: '打开项目',
          buttonUrl: 'https://example.test/project',
        ),
        foreground: true,
      );
      await tester.tap(
        find.byKey(const ValueKey('control-hide-announcement-week')),
      );
      await tester.pumpAndSettle();
      if (action == 'link') {
        await tester.tap(
          find.byKey(const ValueKey('control-announcement-link')),
        );
      } else if (action == 'back') {
        await navigator.currentState!.maybePop();
      } else {
        await tester.tapAt(const Offset(4, 4));
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(services!.control.announcementMuted, isTrue);
      expect(opened, hasLength(action == 'link' ? 1 : 0));
    });
  }

  scenario(
    'A forced update interrupt does not commit an unconfirmed week checkbox',
    (tester) async {
      await render(
        tester,
        promptHome,
        config: controlJson(noticeId: 'a'),
        foreground: true,
      );
      await tester.tap(
        find.byKey(const ValueKey('control-hide-announcement-week')),
      );
      await tester.pumpAndSettle();
      fetcher.text = jsonEncode(
        controlJson(
          revision: 2,
          noticeId: 'a',
          androidBuild: 1000,
          windowsBuild: 1000,
          force: true,
        ),
      );
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      expect(services!.control.announcementMuted, isFalse);
      expect(services!.control.unreadAnnouncement, isNotNull);
      fetcher.text = jsonEncode(controlJson(revision: 3, noticeId: 'a'));
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const ValueKey('control-hide-announcement-week')),
            )
            .value,
        isFalse,
      );
    },
  );

  scenario(
    'Announcement and update use separate dialogs, wait for dismissal, and can be reopened manually',
    (tester) async {
      await render(
        tester,
        promptHome,
        config: controlJson(
          noticeId: 'a',
          androidBuild: 1000,
          windowsBuild: 1000,
        ),
        foreground: true,
      );
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('control-update-dialog')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byKey(const ValueKey('control-update-dialog')), findsNothing);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('control-update-dialog')),
          matching: find.text('发现新版本 0.4.0'),
        ),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(services!.control.unreadAnnouncement, isNull);
      await tester.tap(find.byKey(const ValueKey('control-update-later')));
      await tester.pumpAndSettle();
      expect(services!.control.unreadUpdate, isNull);
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tapAnnouncement(tester);
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tapMine(tester, '检查更新');
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
    },
  );

  scenario(
    'Mine help opens its remote URL directly and update downloads use the current platform URL',
    (tester) async {
      final opened = <Uri>[];
      await render(
        tester,
        (s) => Scaffold(
          body: MinePage(
            s,
            linkLauncher: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
        config: controlJson(
          noticeId: 'a',
          androidBuild: 1000,
          windowsBuild: 1000,
          help: true,
        ),
      );
      await tapMine(tester, '使用帮助');
      expect(find.byType(AlertDialog), findsNothing);
      expect(opened.map((u) => u.toString()), [
        'https://help.example.test/guide#cloud',
      ]);
      await tapMine(tester, '检查更新');
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('control-download-update')));
      await tester.pumpAndSettle();
      expect(opened.map((u) => u.toString()), [
        'https://help.example.test/guide#cloud',
        'https://download.example.test/${services!.control.platform}',
      ]);
      final next = controlJson(revision: 2, help: true);
      (next['help'] as Map)['url'] = 'https://help.example.test/new-guide';
      fetcher.text = jsonEncode(next);
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      await tapMine(tester, '使用帮助');
      expect(opened.last.toString(), 'https://help.example.test/new-guide');
      expect(find.byType(AlertDialog), findsNothing);
      await tapMine(tester, '项目地址');
      expect(opened.last.toString(), 'https://github.com/z7786/wenxi');
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  for (final method in ['later', 'barrier', 'back', 'escape']) {
    scenario(
      'Ordinary update can close with $method without recording an ignore',
      (tester) async {
        await render(
          tester,
          promptHome,
          config: controlJson(androidBuild: 1000, windowsBuild: 1000),
          foreground: true,
          size: const Size(1100, 780),
        );
        switch (method) {
          case 'later':
            await tester.tap(
              find.byKey(const ValueKey('control-update-later')),
            );
          case 'barrier':
            await tester.tapAt(const Offset(4, 4));
          case 'back':
            await tester.binding.handlePopRoute();
          case 'escape':
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        }
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(services!.control.unreadUpdate, isNull);
        expect(
          services!.store.data.obj(
            RemoteControlService.seenKey,
          )['ignoredUpdates'],
          isNull,
        );
        services!.control.setForeground(false);
        services!.control.setForeground(true);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }

  scenario(
    'Explicit ignore suppresses automatic reminders but manual checks and newer builds remain available',
    (tester) async {
      await render(
        tester,
        promptHome,
        config: controlJson(androidBuild: 1000, windowsBuild: 1000),
        foreground: true,
      );
      await tester.tap(find.byKey(const ValueKey('control-ignore-update')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        services!.store.data
            .obj(RemoteControlService.seenKey)
            .obj('ignoredUpdates')[services!.control.platform],
        1000,
      );
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tapMine(tester, '检查更新');
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('control-update-later')));
      await tester.pumpAndSettle();
      fetcher.text = jsonEncode(
        controlJson(revision: 2, androidBuild: 1001, windowsBuild: 1001),
      );
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      expect(services!.control.unreadUpdate!.build, 1001);
    },
  );

  for (final (name, size, scale) in [
    ('phone', const Size(393, 852), 1.0),
    ('desktop', const Size(1100, 780), 1.0),
    ('narrow-large', const Size(320, 700), 1.8),
  ]) {
    scenario(
      '$name forced update blocks dismissal and stays visible during download until withdrawn',
      (tester) async {
        final opened = <Uri>[];
        final launch = Completer<bool>();
        final navigator = GlobalKey<NavigatorState>();
        final config = controlJson(
          noticeId: 'after-update',
          androidBuild: 1000,
          windowsBuild: 1000,
          force: true,
        );
        if (scale > 1) {
          for (final update in (config['updates'] as Map).values) {
            update['notes'] = '改善网盘体验，修复已知问题。\n' * 80;
          }
        }
        await render(
          tester,
          (s) => promptHome(
            s,
            launcher: (url) {
              opened.add(url);
              return launch.future;
            },
          ),
          config: config,
          foreground: true,
          size: size,
          scale: scale,
          dark: name == 'desktop',
          navigatorKey: navigator,
        );
        expect(find.text('请更新至 0.4.0'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('control-announcement-dialog')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('control-ignore-update')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('control-update-later')),
          findsNothing,
        );
        final route = ModalRoute.of(
          tester.element(find.byKey(const ValueKey('control-update-dialog'))),
        )!;
        expect(route.barrierDismissible, isFalse);
        await tester.tapAt(const Offset(4, 4));
        await tester.binding.handlePopRoute();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        // A login page may finish asynchronously and try to return a bool.
        navigator.currentState!.pop(true);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (scale == 1) await capture(tester, '$name-forced-update');
        await tester.tap(find.byKey(const ValueKey('control-download-update')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('control-download-update')));
        expect(opened.map((u) => u.toString()), [
          'https://download.example.test/${services!.control.platform}',
        ]);
        services!.control.setForeground(false);
        launch.complete(true);
        await tester.pumpAndSettle();
        services!.control.setForeground(true);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsOneWidget,
        );
        expect(services!.control.unreadUpdate, isNotNull);
        fetcher.text = jsonEncode(
          controlJson(revision: 2, noticeId: 'after-update'),
        );
        await tester.tap(find.byKey(const ValueKey('control-recheck-update')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('control-announcement-dialog')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final modal in [false, true]) {
    scenario(
      'Forced update covers an existing ${modal ? 'dialog' : 'page'} and preserves it on withdrawal',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        await render(
          tester,
          promptHome,
          foreground: true,
          navigatorKey: navigator,
        );
        final route = modal
            ? DialogRoute<void>(
                context: tester.element(find.byType(RemoteControlPrompts)),
                builder: (_) => const AlertDialog(title: Text('正在进行账号操作')),
              )
            : MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('正在进行账号操作')),
              );
        unawaited(navigator.currentState!.push(route));
        await tester.pumpAndSettle();
        fetcher.text = jsonEncode(
          controlJson(
            revision: 2,
            androidBuild: 1000,
            windowsBuild: 1000,
            force: true,
          ),
        );
        await services!.control.refresh(force: true);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsOneWidget,
        );
        fetcher.text = jsonEncode(controlJson(revision: 3));
        await services!.control.refresh(force: true);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('control-update-dialog')),
          findsNothing,
        );
        expect(find.text('正在进行账号操作'), findsOneWidget);
        expect(route.isCurrent, isTrue);
      },
    );
  }

  scenario(
    'A new forced update interrupts an announcement without marking it as read',
    (tester) async {
      await render(
        tester,
        promptHome,
        config: controlJson(noticeId: 'a'),
        foreground: true,
      );
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      fetcher.text = jsonEncode(
        controlJson(
          revision: 2,
          noticeId: 'a',
          androidBuild: 1000,
          windowsBuild: 1000,
          force: true,
        ),
      );
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      expect(services!.control.unreadAnnouncement!.id, 'a');
      fetcher.text = jsonEncode(controlJson(revision: 3, noticeId: 'a'));
      await tester.tap(find.byKey(const ValueKey('control-recheck-update')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  scenario('A pending navigation cannot cover the required update', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await render(
      tester,
      promptHome,
      config: controlJson(androidBuild: 1000, windowsBuild: 1000, force: true),
      foreground: true,
      navigatorKey: navigator,
    );
    final page = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('解析完成后的文件列表')),
    );
    unawaited(navigator.currentState!.push(page));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('control-update-dialog'));
    expect(dialog, findsOneWidget);
    expect(ModalRoute.of(tester.element(dialog))!.isCurrent, isTrue);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(page.isActive, isTrue);
    fetcher.text = jsonEncode(controlJson(revision: 2));
    await services!.control.refresh(force: true);
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(page.isCurrent, isTrue);
    expect(find.text('解析完成后的文件列表'), findsOneWidget);
  });

  scenario(
    'Live update policy, notes and download URL changes are applied to the open dialog',
    (tester) async {
      final opened = <Uri>[];
      await render(
        tester,
        (s) => promptHome(
          s,
          launcher: (url) async {
            opened.add(url);
            return true;
          },
        ),
        config: controlJson(androidBuild: 1000, windowsBuild: 1000),
        foreground: true,
      );
      final oldLater = tester
          .widget<TextButton>(
            find.byKey(const ValueKey('control-update-later')),
          )
          .onPressed!;
      final oldIgnore = tester
          .widget<TextButton>(
            find.byKey(const ValueKey('control-ignore-update')),
          )
          .onPressed!;
      final forced = controlJson(
        revision: 2,
        androidBuild: 1000,
        windowsBuild: 1000,
        force: true,
      );
      for (final update in (forced['updates'] as Map).values) {
        update['downloadUrl'] = 'https://new-download.example.test/package';
        update['notes'] = '必须更新的说明';
      }
      fetcher.text = jsonEncode(forced);
      await services!.control.refresh(force: true);
      oldLater();
      oldIgnore();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('control-update-later')), findsNothing);
      expect(find.text('必须更新的说明'), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('control-download-update')));
      await tester.pumpAndSettle();
      expect(
        opened.single.toString(),
        'https://new-download.example.test/package',
      );
      fetcher.text = jsonEncode(
        controlJson(revision: 3, androidBuild: 1001, windowsBuild: 1001),
      );
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-update-later')),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  scenario(
    'Forced update survives browser and refresh failures, and can recover by rechecking',
    (tester) async {
      await render(
        tester,
        (s) => promptHome(s, launcher: (_) async => false),
        config: controlJson(
          androidBuild: 1000,
          windowsBuild: 1000,
          force: true,
        ),
        foreground: true,
      );
      await tester.tap(find.byKey(const ValueKey('control-download-update')));
      await tester.pumpAndSettle();
      expect(find.text('无法打开链接，请检查系统默认浏览器'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      fetcher.respond = (_) => throw const SocketException('offline');
      await tester.tap(find.byKey(const ValueKey('control-recheck-update')));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂时无法获取在线信息'), findsOneWidget);
      expect(find.byKey(const ValueKey('control-update-later')), findsNothing);
      fetcher.respond = null;
      fetcher.text = jsonEncode(controlJson(revision: 2));
      await tester.tap(find.byKey(const ValueKey('control-recheck-update')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('control-update-dialog')), findsNothing);
    },
  );

  scenario('Expired forced-update cache releases the dialog while offline', (
    tester,
  ) async {
    var now = controlNow;
    await render(
      tester,
      promptHome,
      config: controlJson(androidBuild: 1000, windowsBuild: 1000, force: true),
      foreground: true,
      clock: () => now,
    );
    services!.control.setForeground(false);
    now = now.add(RemoteControlService.legacyRestrictionLifetime);
    fetcher.respond = (_) => throw const SocketException('offline');
    services!.control.setForeground(true);
    await tester.pumpAndSettle();
    expect(services!.control.hasFreshConfig, isFalse);
    expect(find.byKey(const ValueKey('control-update-later')), findsOneWidget);
    expect(services!.control.requiredUpdate, isNull);
  });

  scenario(
    'Announcement buttons use remote text and URL only on click, including manual reopening',
    (tester) async {
      final opened = <Uri>[];
      await render(
        tester,
        (s) => promptHome(
          s,
          launcher: (url) async {
            opened.add(url);
            return true;
          },
        ),
        config: controlJson(
          noticeId: 'promo-1',
          buttonText: '了解活动',
          buttonUrl: 'https://notice.example.test/promo?from=app#details',
        ),
        foreground: true,
      );
      expect(find.text('了解活动'), findsOneWidget);
      expect(opened, isEmpty);
      await tester.tap(find.byKey(const ValueKey('control-announcement-link')));
      await tester.pumpAndSettle();
      expect(
        opened.single.toString(),
        'https://notice.example.test/promo?from=app#details',
      );
      expect(services!.control.unreadAnnouncement, isNull);
      expect(find.byType(AlertDialog), findsNothing);
      await tapAnnouncement(tester);
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      fetcher.text = jsonEncode(
        controlJson(
          revision: 2,
          noticeId: 'promo-2',
          buttonText: '立即查看',
          buttonUrl: 'https://notice.example.test/new',
        ),
      );
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(find.text('立即查看'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      await tapAnnouncement(tester);
      await tester.tap(find.byKey(const ValueKey('control-announcement-link')));
      await tester.pumpAndSettle();
      expect(opened.last.toString(), 'https://notice.example.test/new');
    },
  );

  scenario(
    'An announcement link failure reports the problem and leaves manual reopening available',
    (tester) async {
      await render(
        tester,
        (s) => promptHome(s, launcher: (_) async => false),
        config: controlJson(
          noticeId: 'a',
          buttonText: '查看详情',
          buttonUrl: 'https://notice.example.test/event',
        ),
        foreground: true,
      );
      await tester.tap(find.byKey(const ValueKey('control-announcement-link')));
      await tester.pumpAndSettle();
      expect(find.text('无法打开链接，请检查系统默认浏览器'), findsOneWidget);
      await tapAnnouncement(tester);
      expect(
        find.byKey(const ValueKey('control-announcement-link')),
        findsOneWidget,
      );
    },
  );

  scenario(
    'Manual announcement entry refreshes a seen cache and coalesces repeated taps',
    (tester) async {
      await render(
        tester,
        promptHome,
        config: controlJson(noticeId: 'a'),
        foreground: true,
      );
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(services!.control.unreadAnnouncement, isNull);
      final response = Completer<String>();
      fetcher.respond = (_) => response.future;
      await tapAnnouncement(tester);
      expect(find.byType(AlertDialog), findsNothing);
      await tapAnnouncement(tester);
      expect(fetcher.calls, hasLength(2));
      final latest = controlJson(revision: 2, noticeId: 'a');
      (latest['announcement'] as Map)['title'] = '更新后的公告';
      (latest['announcement'] as Map)['content'] = '已取得最新内容';
      response.complete(jsonEncode(latest));
      await tester.pumpAndSettle();
      expect(find.text('更新后的公告'), findsOneWidget);
      expect(find.text('已取得最新内容'), findsOneWidget);
      expect(find.text('维护公告'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(services!.control.unreadAnnouncement, isNull);
    },
  );

  scenario(
    'Startup waits for fresh configuration before showing a cached notice',
    (tester) async {
      final response = Completer<String>();
      await render(
        tester,
        promptHome,
        config: controlJson(noticeId: 'old'),
        foreground: true,
        respond: (_) => response.future,
      );
      expect(find.byType(AlertDialog), findsNothing);
      final latest = controlJson(revision: 2, noticeId: 'new');
      (latest['announcement'] as Map)['title'] = '启动时的新公告';
      response.complete(jsonEncode(latest));
      await tester.pumpAndSettle();
      expect(find.text('启动时的新公告'), findsOneWidget);
      expect(find.text('维护公告'), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  scenario('Open announcement follows changed content, links and withdrawal', (
    tester,
  ) async {
    final opened = <Uri>[];
    await render(
      tester,
      (s) => promptHome(
        s,
        launcher: (url) async {
          opened.add(url);
          return true;
        },
      ),
      config: controlJson(noticeId: 'old'),
      foreground: true,
    );
    final latest = controlJson(
      revision: 2,
      noticeId: 'new',
      buttonText: '打开新链接',
      buttonUrl: 'https://notice.example.test/new',
    );
    (latest['announcement'] as Map)['title'] = '替换后的公告';
    fetcher.text = jsonEncode(latest);
    await services!.control.refresh(force: true);
    await tester.pumpAndSettle();
    expect(find.text('替换后的公告'), findsOneWidget);
    expect(find.text('维护公告'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('control-announcement-link')));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), 'https://notice.example.test/new');
    expect(services!.control.unreadAnnouncement, isNull);
    expect(find.byType(AlertDialog), findsNothing);
    await tapAnnouncement(tester);
    fetcher.text = jsonEncode(controlJson(revision: 3));
    await services!.control.refresh(force: true);
    await tester.pumpAndSettle();
    expect(find.text('暂无公告'), findsOneWidget);
    expect(find.text('替换后的公告'), findsNothing);
    expect(
      find.byKey(const ValueKey('control-announcement-link')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  scenario(
    'Announcement refresh retains malformed JSON and applies same-revision repairs',
    (tester) async {
      await render(tester, promptHome, config: controlJson(noticeId: 'a'));
      for (final (body, error) in [
        (
          '{"schema":1,"revision":2,"announcement":{"content":"first" "content":"second"}}',
          '在线配置格式有误，请联系维护者修正',
        ),
      ]) {
        fetcher.text = body;
        await tapAnnouncement(tester);
        expect(find.text(error), findsOneWidget);
        expect(find.text('当前显示上次成功获取的公告。'), findsOneWidget);
        expect(find.text('维护公告'), findsOneWidget);
        expect(services!.control.config.announcement!.id, 'a');
        await tester.tap(
          find.byKey(const ValueKey('control-read-announcement')),
        );
        await tester.pumpAndSettle();
      }
      final latest = controlJson(noticeId: 'a');
      (latest['announcement'] as Map)['title'] = '已修正的公告';
      fetcher.text = jsonEncode(latest);
      await tapAnnouncement(tester);
      expect(find.text('已修正的公告'), findsOneWidget);
      expect(find.text('当前显示上次成功获取的公告。'), findsNothing);
      expect(services!.control.lastError, isNull);
    },
  );

  scenario(
    'Manual refresh failure keeps the cached notice and does not claim the app is current',
    (tester) async {
      await render(tester, promptHome, config: controlJson(noticeId: 'a'));
      fetcher.respond = (_) => throw const SocketException('offline');
      await tapMine(tester, '检查更新');
      expect(find.textContaining('暂时无法获取在线信息'), findsOneWidget);
      await tapAnnouncement(tester);
      expect(find.text('维护公告'), findsOneWidget);
      expect(find.text('当前显示上次成功获取的公告。'), findsOneWidget);
      expect(fetcher.calls, hasLength(2));
      expect(find.text('当前已是最新版本'), findsNothing);
      expect(services!.control.config.announcement!.id, 'a');
    },
  );

  scenario(
    'Settings keeps help and updates while announcements move to the parse menu',
    (tester) async {
      await render(tester, promptHome, config: controlJson());
      await tapMine(tester, '使用帮助');
      expect(find.text('软件公告'), findsNothing);
      expect(find.text('检查更新'), findsOneWidget);
      expect(find.text('暂未提供帮助链接'), findsNWidgets(2));
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tapAnnouncement(tester);
      expect(find.text('暂无公告'), findsOneWidget);
    },
  );

  scenario(
    'An installation without an endpoint never reports an unverified latest version',
    (tester) async {
      await render(tester, promptHome, configured: false, foreground: true);
      await tapMine(tester, '检查更新');
      expect(find.text('此版本暂未提供在线更新信息'), findsOneWidget);
      expect(find.text('当前已是最新版本'), findsNothing);
      expect(fetcher.calls, isEmpty);
    },
  );

  scenario(
    'Automatic prompts wait in the background, including between dialogs',
    (tester) async {
      await render(
        tester,
        promptHome,
        config: controlJson(
          noticeId: 'a',
          androidBuild: 1000,
          windowsBuild: 1000,
        ),
      );
      expect(find.byType(AlertDialog), findsNothing);
      services!.control.setForeground(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      services!.control.setForeground(false);
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      services!.control.setForeground(true);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
    },
  );

  scenario('New prompts wait until the main route returns from another page', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await render(tester, promptHome, foreground: true, navigatorKey: navigator);
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Center(child: Text('正在播放'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    fetcher.text = jsonEncode(
      controlJson(revision: 2, noticeId: 'after-playback'),
    );
    await services!.control.refresh(force: true);
    await tester.pumpAndSettle();
    expect(find.text('正在播放'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('control-announcement-dialog')),
      findsOneWidget,
    );
  });

  scenario('A modal removed without popping also releases waiting prompts', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await render(tester, promptHome, foreground: true, navigatorKey: navigator);
    final route = DialogRoute<void>(
      context: tester.element(find.byType(RemoteControlPrompts)),
      builder: (_) => const AlertDialog(title: Text('等待账号操作')),
    );
    unawaited(navigator.currentState!.push(route));
    await tester.pumpAndSettle();
    fetcher.text = jsonEncode(
      controlJson(revision: 2, noticeId: 'after-modal'),
    );
    await services!.control.refresh(force: true);
    await tester.pumpAndSettle();
    expect(find.text('等待账号操作'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('control-announcement-dialog')),
      findsNothing,
    );
    navigator.currentState!.removeRoute(route);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('control-announcement-dialog')),
      findsOneWidget,
    );
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  scenario(
    'Repeated manual checks and automatic refresh share one dialog slot',
    (tester) async {
      await render(tester, promptHome, foreground: true);
      final response = Completer<String>();
      fetcher.respond = (_) => response.future;
      await tapMine(tester, '检查更新');
      await tapMine(tester, '检查更新');
      expect(fetcher.calls, hasLength(2));
      response.complete(
        jsonEncode(
          controlJson(
            revision: 2,
            noticeId: 'manual-refresh',
            androidBuild: 1000,
            windowsBuild: 1000,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsNothing,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('control-update-later')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('control-update-dialog')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  scenario(
    'Disabled cloud card shows its reason, prevents login and preserves logout',
    (tester) async {
      await render(
        tester,
        (s) => Scaffold(body: CloudPage(s)),
        config: controlJson(disabled: ['quark']),
      );
      expect(
        find.byKey(const ValueKey('cloud-disabled-quark')),
        findsOneWidget,
      );
      await tester.tap(find.text('夸克网盘'));
      await tester.pumpAndSettle();
      expect(find.byType(WebLoginPage), findsNothing);
      await tester.tap(find.byTooltip('夸克网盘账号操作'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('退出账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出账号'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(services!.vault.credential(CloudPlatform.quark), isNull);
      expect(http.calls, isEmpty);
    },
  );

  scenario(
    'A provider switched off during deletion confirmation cannot execute the pending mutation',
    (tester) async {
      const session = BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: '文件列表',
        rootId: '0',
      );
      const file = CloudFile(id: 'file', name: 'fixture.txt', parentId: '0');
      final connector = _MutationConnector();
      await render(tester, (s) {
        s.cloud.connectors[CloudPlatform.quark] = connector;
        return BrowserPage(s, session, initialItems: const [file]);
      });
      await tester.tap(find.byTooltip('fixture.txt操作'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('删除'));
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除网盘文件'), findsOneWidget);
      fetcher.text = jsonEncode(controlJson(revision: 2, disabled: ['quark']));
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(connector.deletions, 0);
      expect(find.text('网盘暂时停用'), findsOneWidget);
      expect(http.calls, isEmpty);
      final next = controlJson(revision: 3, disabled: ['quark']);
      (next['clouds'] as Map)['quark']['message'] = '维护进度已更新，预计稍后恢复';
      fetcher.text = jsonEncode(next);
      await services!.control.refresh(force: true);
      await tester.pumpAndSettle();
      expect(find.text('维护进度已更新，预计稍后恢复'), findsOneWidget);
    },
  );

  scenario('Share parsing checks the switch before asking the user to log in', (
    tester,
  ) async {
    await render(
      tester,
      (s) => Scaffold(body: ParsePage(s)),
      loggedIn: false,
      config: controlJson(disabled: ['quark']),
    );
    await tester.enterText(
      find.byKey(const Key('parse-input')),
      'https://pan.quark.cn/s/Abcd',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('parse-start')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('网盘维护中'), findsOneWidget);
    expect(http.calls, isEmpty);
  });

  scenario(
    'Directly opened UC TV page respects maintenance before obtaining a QR code',
    (tester) async {
      await render(
        tester,
        (s) => UcTvAuthorizationPage(s),
        config: controlJson(disabled: ['uc']),
      );
      expect(find.textContaining('网盘维护中'), findsOneWidget);
      expect(http.calls, isEmpty);
    },
  );

  for (final (name, size, scale, dark) in [
    ('phone-control', const Size(393, 852), 1.0, false),
    ('desktop-control', const Size(1100, 780), 1.0, true),
    ('narrow-large-control', const Size(320, 700), 1.8, false),
  ]) {
    scenario('$name independent dialogs remain readable and dismissible', (
      tester,
    ) async {
      final config = controlJson(
        noticeId: 'a',
        androidBuild: 1000,
        windowsBuild: 1000,
        help: true,
        buttonText: scale > 1 ? '查看本次维护服务进度与详细帮助说明' : '查看详情',
        buttonUrl: 'https://notice.example.test/details',
      );
      if (scale > 1) {
        (config['announcement'] as Map)['title'] = '关于网盘近期维护与恢复服务的通知';
        (config['announcement'] as Map)['content'] =
            '网盘接口正在维护，已有任务可以继续使用。\n' * 80;
        for (final update in (config['updates'] as Map).values) {
          update['notes'] = '改善网盘体验，修复已知问题。\n' * 80;
        }
      }
      await render(
        tester,
        promptHome,
        config: config,
        foreground: true,
        size: size,
        scale: scale,
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('control-announcement-dialog')),
        findsOneWidget,
      );
      if (scale == 1) {
        await capture(tester, '$name-announcement');
      }
      await tester.tap(find.byKey(const ValueKey('control-read-announcement')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('control-update-dialog')),
        findsOneWidget,
      );
      if (scale == 1) {
        await capture(tester, '$name-update');
      }
      await tester.tap(find.byKey(const ValueKey('control-update-later')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  scenario('Long maintenance reasons fit desktop large text', (tester) async {
    final config = controlJson(disabled: ['quark']);
    (config['clouds'] as Map)['quark']['message'] =
        '正在维护网盘接口，暂停新的解析与下载。已有下载会继续，请稍后重试或查看最新公告。';
    await render(
      tester,
      (s) => Scaffold(body: CloudPage(s)),
      config: config,
      size: const Size(1100, 780),
      scale: 1.8,
    );
    expect(find.byKey(const ValueKey('cloud-disabled-quark')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  scenario(
    'Help launch failure is reported without opening an intermediate page',
    (tester) async {
      await render(
        tester,
        (s) => Scaffold(body: MinePage(s, linkLauncher: (_) async => false)),
        config: controlJson(help: true),
      );
      await tapMine(tester, '使用帮助');
      expect(find.text('无法打开链接，请检查系统默认浏览器'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
