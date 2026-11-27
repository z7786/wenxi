import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/baidu_download_prompt.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final active = <AppServices>[];
  final answers = <bool>[];
  void noticeTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final services in active) {
          await services.close();
        }
        active.clear();
        answers.clear();
      }
    });
  }

  Future<AppServices> render(
    WidgetTester tester, {
    StateStore? store,
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) async {
    final services = AppServices(
      store: store ?? StateStore.memory(),
      dataDirectory: Directory('test-fixture'),
      cacheDirectory: Directory('test-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture/saved')),
      http: FakeHttp(),
      platformFeatures: false,
      controlEnabled: false,
    );
    active.add(services);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(brightness).copyWith(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answers.add(
                await confirmBaiduDownload(
                  context,
                  services,
                  CloudPlatform.baidu,
                ),
              ),
              child: const Text('测试下载'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return services;
  }

  Future<void> showNotice(WidgetTester tester) async {
    await tester.tap(find.text('测试下载'));
    await tester.pumpAndSettle();
  }

  for (final action in ['取消', '继续下载', '不再显示', '返回']) {
    noticeTest(
      'First Baidu notice blocks $action for ten seconds and remembers reading',
      (tester) async {
        final services = await render(tester);
        await showNotice(tester);
        expect(find.textContaining('300MB'), findsOneWidget);
        expect(find.text('继续下载（10秒）'), findsOneWidget);
        for (final button in tester.widgetList<ButtonStyleButton>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        )) {
          expect(button.onPressed, isNull);
        }
        await tester.tap(find.text('取消'));
        await tester.tap(find.text('不再显示'));
        await tester.tap(find.text('继续下载（10秒）'));
        await tester.binding.handlePopRoute();
        await tester.tapAt(const Offset(2, 2));
        await tester.pump();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(answers, isEmpty);
        expect(services.settings.baiduDownloadNoticeRead, isFalse);

        await tester.pump(const Duration(seconds: 8));
        expect(find.textContaining('秒）'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('继续下载'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNotNull,
        );
        if (action == '返回') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.text(action));
        }
        await tester.pumpAndSettle();
        expect(answers, [action == '继续下载' || action == '不再显示']);
        expect(services.settings.baiduDownloadNoticeRead, isTrue);
        expect(services.settings.hideBaiduDownloadNotice, action == '不再显示');
        await services.updateSettings({'threads': 32});
        await render(tester, store: StateStore.memory(services.store.data));
        await showNotice(tester);
        if (action == '不再显示') {
          expect(find.byType(AlertDialog), findsNothing);
          expect(answers.last, isTrue);
        } else {
          expect(find.text('继续下载'), findsOneWidget);
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNotNull,
          );
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(answers.last, isFalse);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  noticeTest(
    'Unmounting an unread notice releases its countdown and does not mark it read',
    (tester) async {
      final services = await render(tester);
      await showNotice(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 12));
      expect(services.settings.baiduDownloadNoticeRead, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  noticeTest(
    'Legacy opt-out still shows the updated size notice once and keeps the preference',
    (tester) async {
      final services = await render(
        tester,
        store: StateStore.memory({
          'settings': {'hideBaiduDownloadNotice': true, 'threads': 32},
        }),
      );
      await showNotice(tester);
      expect(answers, isEmpty);
      expect(find.textContaining('大文件恢复下载时间待定'), findsOneWidget);
      expect(find.text('继续下载（10秒）'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(services.settings.baiduDownloadNoticeRead, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(answers, [false]);
      expect(services.settings.hideBaiduDownloadNotice, isTrue);
      expect(services.settings.baiduDownloadNoticeRead, isTrue);
      expect(services.settings.threads, 32);
      await render(tester, store: StateStore.memory(services.store.data));
      await showNotice(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(answers, [false, true]);
    },
  );

  noticeTest(
    'Leaving the updated notice early retains the old opt-out and asks again later',
    (tester) async {
      final services = await render(
        tester,
        store: StateStore.memory({
          'settings': {'hideBaiduDownloadNotice': true},
        }),
      );
      await showNotice(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 12));
      expect(services.settings.hideBaiduDownloadNotice, isTrue);
      expect(services.settings.baiduDownloadNoticeRead, isFalse);
      await render(tester, store: StateStore.memory(services.store.data));
      await showNotice(tester);
      expect(find.text('继续下载（10秒）'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    noticeTest(
      'Baidu notice fits a narrow $brightness screen with large text',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await render(tester, brightness: brightness, textScale: 1.8);
        await showNotice(tester);
        await tester.pump(const Duration(seconds: 10));
        final cancel = find.text('取消');
        await tester.ensureVisible(cancel);
        await tester.pumpAndSettle();
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(answers, [false]);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'remembered Baidu notice survives unrelated settings and app reconstruction',
    (tester) async {
      final active = <AppServices>[];
      var confirmed = 0;
      Future<AppServices> render(
        StateStore store,
        CloudPlatform platform,
      ) async {
        final services = AppServices(
          store: store,
          dataDirectory: Directory('test-fixture'),
          cacheDirectory: Directory('test-fixture/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('test-fixture/saved')),
          http: FakeHttp(),
          platformFeatures: false,
          controlEnabled: false,
        );
        active.add(services);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    if (await confirmBaiduDownload(
                      context,
                      services,
                      platform,
                    )) {
                      confirmed++;
                    }
                  },
                  child: const Text('下载文件'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return services;
      }

      try {
        final services = await render(StateStore.memory(), CloudPlatform.baidu);
        await tester.tap(find.text('下载文件'));
        await tester.pumpAndSettle();
        expect(confirmed, 0);
        expect(
          find.text(
            '百度网盘风控严重，下载存在一定风险可能导致账号被限制，请自行权衡，另外尽量不要一次性下载太多文件易导致下载失败。'
            '\n\n因不可抗力因素，视频以外，下载 300MB 以上的普通文件会限速。大文件恢复下载时间待定',
          ),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
        await tester.tap(find.text('不再显示'));
        await tester.pumpAndSettle();
        expect(confirmed, 1);
        expect(services.settings.hideBaiduDownloadNotice, isTrue);
        expect(services.settings.baiduDownloadNoticeRead, isTrue);
        await services.updateSettings({'threads': 32});
        await render(
          StateStore.memory(services.store.data),
          CloudPlatform.baidu,
        );
        await tester.tap(find.text('下载文件'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(confirmed, 2);
        await render(StateStore.memory(), CloudPlatform.quark);
        await tester.tap(find.text('下载文件'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(confirmed, 3);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final services in active) {
          await services.close();
        }
      }
    },
  );

  test('Baidu notice preference survives encrypted state reopening', () async {
    final directory = await Directory.systemTemp.createTemp('baidu-notice-');
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    StateStore? first, reopened;
    try {
      expect(const AppSettings().hideBaiduDownloadNotice, isFalse);
      expect(const AppSettings().baiduDownloadNoticeRead, isFalse);
      first = await StateStore.open(directory, testKey: key);
      await first.put(
        'settings',
        const AppSettings(
          hideBaiduDownloadNotice: true,
          baiduDownloadNoticeRead: true,
        ).toJson(),
      );
      reopened = await StateStore.open(directory, testKey: key);
      final settings = AppSettings.fromJson(
        Map<String, dynamic>.from(reopened.data['settings'] as Map),
      );
      expect(settings.hideBaiduDownloadNotice, isTrue);
      expect(settings.baiduDownloadNoticeRead, isTrue);
      expect(settings.hideGuestDownloadNotice, isFalse);
    } finally {
      first?.dispose();
      reopened?.dispose();
      await directory.delete(recursive: true);
    }
  });
}
