import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/remote_control_service.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/remote_control_dialogs.dart';
import 'app_update_support.dart';
import 'remote_control_support.dart';

void main() {
  late UpdateFixture f;
  late RemoteControlService control;
  late StateStore state;
  late FakeControlFetcher fetcher;
  final opened = <Uri>[];
  final inApp = find.byKey(const ValueKey('control-in-app-update'));
  final dialog = find.byKey(const ValueKey('control-update-dialog'));

  Future<void> render(
    WidgetTester tester, {
    String platform = 'android',
    bool force = false,
    Size size = const Size(393, 852),
    double scale = 1,
    String notes = '更新说明',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    f = UpdateFixture(platform: platform);
    final update = f.current!;
    final data = RemoteControlConfig(
      updates: {
        platform: RemoteUpdate(
          update.version,
          update.build,
          update.downloadUrl,
          notes,
          force: force,
          inAppDownloadUrl: update.inAppDownloadUrl,
          inAppPasscode: update.inAppPasscode,
        ),
      },
    ).toJson();
    state = StateStore.memory(controlCache(data));
    fetcher = FakeControlFetcher(data);
    control = RemoteControlService(
      state,
      platform: platform,
      currentBuild: 110,
      configUrl: controlEndpoint,
      enabled: true,
      fetcher: fetcher,
      clock: () => controlNow,
    );
    control.addListener(() {
      f.current = control.availableUpdate;
      f.foreground = control.inForeground;
    });
    control.setForeground(true);
    opened.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRemoteUpdate(
                context,
                control,
                control.availableUpdate!,
                updater: f.service,
                launcher: (uri) async {
                  opened.add(uri);
                  return true;
                },
              ),
              child: const Text('检查更新'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
  }

  void scenario(String name, Future<void> Function(WidgetTester) run) {
    testWidgets(name, (tester) async {
      try {
        await run(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        control.close();
        state.dispose();
        f.close();
      }
    });
  }

  scenario(
    'Dismissing during manual installation validation does not launch later',
    (tester) async {
      await render(tester);
      await f.service.start(f.current!);
      f.complete();
      await tester.pumpAndSettle();
      f.installer.pending = Completer<void>();
      await tester.tap(inApp);
      await tester.pump();
      expect(f.installer.preparations, 1);
      Navigator.of(tester.element(dialog)).pop();
      await tester.pumpAndSettle();
      f.installer.pending!.complete();
      await tester.pumpAndSettle();
      expect(f.installer.opens, 0);
    },
  );

  scenario('App download shows progress and Android launches installer once', (
    tester,
  ) async {
    await render(tester);
    expect(find.text('App 内更新'), findsOneWidget);
    expect(find.text('浏览器更新'), findsOneWidget);
    await tester.tap(inApp);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    expect(opened, isEmpty);
    f.downloads.change(f.downloads.tasks.single.id, {
      'status': 'running',
      'downloaded': 512,
      'speed': 128,
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('50.0%'), findsOneWidget);
    await tester.tap(find.text('暂停下载'));
    await tester.pumpAndSettle();
    expect(find.text('继续下载'), findsOneWidget);
    await tester.tap(inApp);
    await tester.pumpAndSettle();
    f.complete();
    await tester.pumpAndSettle();
    expect(f.installer.opens, 1);
    control.setForeground(false);
    control.setForeground(true);
    await tester.pumpAndSettle();
    expect(f.installer.opens, 1);
    expect(find.text('立即安装'), findsOneWidget);
    expect(control.unreadUpdate, isNotNull);
  });

  scenario('Failed updates offer both resume and a fresh share download', (
    tester,
  ) async {
    await render(tester);
    await tester.tap(inApp);
    await tester.pumpAndSettle();
    final oldId = f.downloads.tasks.single.id;
    f.downloads.change(oldId, {'status': 'failed', 'error': '文件已更新，请重新下载'});
    await tester.pumpAndSettle();
    expect(find.text('重试下载'), findsOneWidget);
    expect(find.text('重新下载'), findsOneWidget);
    f.connector.entries = [
      const CloudFile(id: 'fresh', name: 'fresh.apk', size: 2048),
    ];
    await tester.tap(find.byKey(const ValueKey('control-update-redownload')));
    await tester.pumpAndSettle();
    expect(f.downloads.created, 2);
    expect(f.downloads.resumed, 0);
    expect(f.downloads.task(oldId), isNull);
    expect(find.text('fresh.apk'), findsOneWidget);
    expect(find.text('文件已更新，请重新下载'), findsNothing);
    f.complete();
    await tester.pumpAndSettle();
    expect(f.installer.opens, 1);
  });

  scenario(
    'Closing download dialog preserves task; reopened dialog offers installation',
    (tester) async {
      await render(tester);
      await tester.tap(inApp);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('control-update-later')));
      await tester.pumpAndSettle();
      f.complete();
      await tester.pumpAndSettle();
      expect(f.installer.opens, 0);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('立即安装'), findsOneWidget);
      await tester.tap(inApp);
      await tester.pumpAndSettle();
      expect(f.installer.opens, 1);
      expect(f.downloads.created, 1);
    },
  );

  scenario(
    'Background completion waits for explicit install after foregrounding',
    (tester) async {
      await render(tester);
      await tester.tap(inApp);
      await tester.pumpAndSettle();
      control.setForeground(false);
      f.complete();
      await tester.pumpAndSettle();
      control.setForeground(true);
      await tester.pumpAndSettle();
      expect(f.installer.opens, 0);
      expect(find.text('立即安装'), findsOneWidget);
    },
  );

  scenario(
    'Closing the dialog during automatic validation does not open an installer later',
    (tester) async {
      await render(tester);
      f.installer.pending = Completer<void>();
      await tester.tap(inApp);
      await tester.pumpAndSettle();
      f.complete();
      await tester.pumpAndSettle();
      expect(f.installer.preparations, 1);
      await tester.tap(find.byKey(const ValueKey('control-update-later')));
      await tester.pumpAndSettle();
      f.installer.pending!.complete();
      await tester.pumpAndSettle();
      expect(f.installer.opens, 0);
    },
  );

  scenario('Parsing failure stays visible with an explicit browser fallback', (
    tester,
  ) async {
    await render(tester);
    f.connector.entries = [];
    await tester.tap(inApp);
    await tester.pumpAndSettle();
    expect(find.textContaining('必须只包含一个安装包'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.text('浏览器更新'));
    await tester.pumpAndSettle();
    expect(opened.single.host, 'share.feijipan.com');
    expect(dialog, findsNothing);
  });

  for (final platform in ['android', 'windows']) {
    scenario(
      '$platform forced update keeps its gate after downloading and opening installer',
      (tester) async {
        await render(tester, platform: platform, force: true);
        if (platform == 'windows') {
          f.current = control.availableUpdate;
          f.connector.entries = [
            const CloudFile(id: 'file', name: 'app.exe', size: 1024),
          ];
        }
        await tester.tap(inApp);
        await tester.pumpAndSettle();
        expect(find.text('下载管理'), findsNothing);
        f.complete();
        await tester.pumpAndSettle();
        if (platform == 'windows') {
          expect(f.installer.opens, 0);
          await tester.tap(inApp);
          await tester.pumpAndSettle();
        }
        expect(f.installer.opens, 1);
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(dialog, findsOneWidget);
        expect(control.requiredUpdate, isNotNull);
        fetcher.text = jsonEncode({
          'updates': {
            platform: {'enabled': false},
          },
        });
        await control.refresh(force: true);
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
      },
    );
  }

  for (final view in [const Size(320, 740), const Size(1080, 800)]) {
    scenario('Update controls fit ${view.width}px with large text', (
      tester,
    ) async {
      await render(tester, size: view, scale: 1.6, force: true);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(inApp);
      await tester.tap(inApp);
      await tester.pumpAndSettle();
      f.downloads.change(f.downloads.tasks.single.id, {
        'status': 'failed',
        'error': '网络错误，请重试或选择浏览器更新',
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  for (final force in [false, true]) {
    scenario('Long release notes keep update controls visible (force=$force)', (
      tester,
    ) async {
      final notes = List.generate(
        80,
        (i) => '第 ${i + 1} 项：修复问题并优化使用体验。',
      ).join('\n');
      await render(
        tester,
        size: const Size(320, 740),
        scale: 1.6,
        force: force,
        notes: notes,
      );
      expect(tester.takeException(), isNull);
      expect(inApp.hitTestable(), findsOneWidget);
      expect(
        find.byKey(const ValueKey('control-download-update')).hitTestable(),
        findsOneWidget,
      );
      final scroll = find.ancestor(
        of: find.text(notes),
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(scroll, const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(inApp.hitTestable(), findsOneWidget);
      await tester.tap(inApp);
      await tester.pumpAndSettle();
      expect(f.downloads.tasks, hasLength(1));
      f.downloads.change(f.downloads.tasks.single.id, {
        'status': 'failed',
        'error': List.filled(20, '网络错误，请重试或选择浏览器更新。').join('\n'),
      });
      await tester.pumpAndSettle();
      expect(inApp.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
