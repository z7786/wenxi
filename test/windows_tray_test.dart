import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _ProbeHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(
        RemoteIdentity(4, '"tray-fixture"', null),
        false,
        rangeSupported: true,
      );
}

class _Services extends AppServices {
  _Services(Directory root, FakeNative native)
    : super(
        store: StateStore.memory(),
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: native,
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        http: FakeHttp(),
        transferHttp: _ProbeHttp(),
        clipboardReader: () async => null,
        controlEnabled: false,
        announcementsUrl: '',
      );

  int closeCalls = 0;
  Completer<void>? holdClose;

  @override
  void refreshEntryData() {}

  @override
  Future<void> close() async {
    closeCalls++;
    await holdClose?.future;
  }

  Future<void> cleanup() => super.close();
}

class _Desktop {
  bool visible = true, minimized = false, focused = true;
  bool maximized = false, maximizedBeforeMinimize = false;
  bool trayVisible = false, destroyed = false;
  bool failTray = false, failHide = false, failShow = false;
  Completer<void>? holdTray, holdHide;
  final calls = <String>[];

  void minimize() {
    maximizedBeforeMinimize = maximized;
    minimized = true;
    focused = false;
  }

  Future<Object?> window(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'isMinimized':
        return minimized;
      case 'hide':
        await holdHide?.future;
        if (failHide) throw PlatformException(code: 'hide-failed');
        visible = false;
        focused = false;
      case 'restore':
        minimized = false;
        maximized = maximizedBeforeMinimize;
      case 'show':
        if (failShow) throw PlatformException(code: 'show-failed');
        visible = true;
      case 'focus':
        focused = true;
      case 'destroy':
        visible = false;
        destroyed = true;
    }
    return null;
  }

  Future<Object?> tray(MethodCall call) async {
    calls.add('tray.${call.method}');
    switch (call.method) {
      case 'setIcon':
        if (failTray) throw PlatformException(code: 'tray-unavailable');
        trayVisible = true;
      case 'setContextMenu':
        await holdTray?.future;
      case 'destroy':
        trayVisible = false;
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const windowChannel = MethodChannel('window_manager');
  const trayChannel = MethodChannel('tray_manager');

  group('Windows minimize to tray', () {
    late Directory root;
    late FakeNative native;
    late _Desktop desktop;
    late _Services services;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('wenxi-tray-test-');
      native = FakeNative()..finish = false;
      desktop = _Desktop();
      services = _Services(root, native);
      messenger.setMockMethodCallHandler(windowChannel, desktop.window);
      messenger.setMockMethodCallHandler(trayChannel, desktop.tray);
      messenger.setMockMethodCallHandler(nativeChannel, (_) async => null);
    });

    tearDown(() async {
      await services.cleanup();
      services.store.dispose();
      messenger.setMockMethodCallHandler(windowChannel, null);
      messenger.setMockMethodCallHandler(trayChannel, null);
      messenger.setMockMethodCallHandler(nativeChannel, null);
      await root.delete(recursive: true);
    });

    Future<(WindowListener, TrayListener)> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1100, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: MainShell(services),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(MainShell));
      return (state as WindowListener, state as TrayListener);
    }

    for (final maximized in [false, true]) {
      testWidgets('restores repeatedly with maximized=$maximized', (
        tester,
      ) async {
        final (window, tray) = await open(tester);
        desktop.maximized = maximized;
        for (var i = 0; i < 3; i++) {
          desktop.minimize();
          window.onWindowMinimize();
          await tester.pumpAndSettle();
          expect(desktop.visible, isFalse);
          expect(desktop.trayVisible, isTrue);
          expect(services.closeCalls, 0);
          if (i.isEven) {
            tray.onTrayIconMouseDown();
          } else {
            tray.onTrayMenuItemClick(MenuItem(key: 'show', label: '打开'));
          }
          await tester.pumpAndSettle();
          expect(desktop.visible, isTrue);
          expect(desktop.minimized, isFalse);
          expect(desktop.focused, isTrue);
          expect(desktop.maximized, maximized);
        }
        expect(desktop.calls, isNot(contains('setBounds')));
        expect(desktop.calls, isNot(contains('unmaximize')));
        expect(native.calls, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(services.cleanup);
      });
    }

    testWidgets('a restore cannot be overtaken by a pending hide', (
      tester,
    ) async {
      final (window, tray) = await open(tester);
      desktop.holdHide = Completer<void>();
      desktop.minimize();
      window.onWindowMinimize();
      await tester.pump();
      tray.onTrayIconMouseDown();
      await tester.pump();
      expect(desktop.calls, isNot(contains('show')));
      desktop.holdHide!.complete();
      await tester.pumpAndSettle();
      expect(desktop.visible, isTrue);
      expect(desktop.focused, isTrue);
      expect(desktop.minimized, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.cleanup);
    });

    testWidgets('unavailable tray keeps ordinary minimization accessible', (
      tester,
    ) async {
      desktop.failTray = true;
      final (window, _) = await open(tester);
      desktop.minimize();
      window.onWindowMinimize();
      await tester.pumpAndSettle();
      expect(desktop.visible, isTrue);
      expect(desktop.minimized, isTrue);
      expect(desktop.calls, isNot(contains('hide')));
      expect(services.closeCalls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.cleanup);
    });

    testWidgets('minimizing during tray initialization waits for its menu', (
      tester,
    ) async {
      desktop.holdTray = Completer<void>();
      final (window, _) = await open(tester);
      desktop.minimize();
      window.onWindowMinimize();
      await tester.pump();
      expect(desktop.visible, isTrue);
      desktop.holdTray!.complete();
      await tester.pumpAndSettle();
      expect(desktop.visible, isFalse);
      expect(desktop.trayVisible, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.cleanup);
    });

    testWidgets('a stale minimize event does not hide a restored window', (
      tester,
    ) async {
      final (window, _) = await open(tester);
      window.onWindowMinimize();
      await tester.pumpAndSettle();
      expect(desktop.visible, isTrue);
      expect(desktop.calls, isNot(contains('hide')));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.cleanup);
    });

    testWidgets('native failures do not break subsequent tray actions', (
      tester,
    ) async {
      final (window, tray) = await open(tester);
      desktop.failHide = true;
      desktop.minimize();
      window.onWindowMinimize();
      await tester.pumpAndSettle();
      expect(desktop.visible, isTrue);
      desktop.failHide = false;
      window.onWindowMinimize();
      await tester.pumpAndSettle();
      expect(desktop.visible, isFalse);
      desktop.failShow = true;
      tray.onTrayIconMouseDown();
      await tester.pumpAndSettle();
      expect(desktop.visible, isFalse);
      desktop.failShow = false;
      tray.onTrayIconMouseDown();
      await tester.pumpAndSettle();
      expect(desktop.visible, isTrue);
      expect(desktop.focused, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.cleanup);
    });

    testWidgets('tray exit cleans up once and ignores late window actions', (
      tester,
    ) async {
      final (window, tray) = await open(tester);
      desktop.minimize();
      window.onWindowMinimize();
      await tester.pumpAndSettle();
      services.holdClose = Completer<void>();
      tray.onTrayMenuItemClick(MenuItem(key: 'exit', label: '退出'));
      await tester.pump();
      expect(services.closeCalls, 1);
      tray.onTrayIconMouseDown();
      window.onWindowClose();
      services.holdClose!.complete();
      await tester.pumpAndSettle();
      expect(services.closeCalls, 1);
      expect(desktop.destroyed, isTrue);
      expect(desktop.trayVisible, isFalse);
      expect(desktop.visible, isFalse);
      expect(desktop.calls, isNot(contains('show')));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.cleanup);
    });

    testWidgets(
      'downloads complete in tray and exit still needs confirmation',
      (tester) async {
        await tester.runAsync(() => services.downloads.initialize());
        final (window, tray) = await open(tester);
        final id = (await tester.runAsync(
          () => services.downloads.enqueue(
            const DownloadSpec(
              url: 'https://example.invalid/tray-fixture',
              fileName: 'tray-fixture.bin',
              expectedSize: 4,
            ),
          ),
        ))!;
        await tester.runAsync(
          () => until(
            () =>
                native.writer ||
                services.downloads.task(id)?.status == DownloadStatus.failed,
          ),
        );
        expect(services.downloads.task(id)!.error, isEmpty);
        desktop.minimize();
        window.onWindowMinimize();
        await tester.pumpAndSettle();
        expect(desktop.visible, isFalse);
        expect(services.downloads.task(id)!.active, isTrue);
        expect(native.calls, isNot(contains('pause')));
        tray.onTrayMenuItemClick(MenuItem(key: 'exit', label: '退出'));
        await tester.pumpAndSettle();
        expect(desktop.visible, isTrue);
        expect(find.text('还有传输任务'), findsOneWidget);
        expect(find.text('后台传输'), findsNothing);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(services.closeCalls, 0);
        window.onWindowClose();
        await tester.pumpAndSettle();
        await tester.tap(find.text('后台传输'));
        await tester.pumpAndSettle();
        expect(desktop.visible, isFalse);
        expect(native.calls, isNot(contains('pause')));
        native.finish = true;
        await tester.runAsync(
          () => until(
            () =>
                services.downloads.task(id)?.status == DownloadStatus.completed,
          ),
        );
        final path = services.downloads.task(id)!.savedPath!;
        final bytes = await tester.runAsync(() => File(path).readAsBytes());
        expect(bytes, native.content);
        expect(desktop.visible, isFalse);
        expect(services.closeCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(services.cleanup);
      },
    );
  }, skip: !Platform.isWindows);
}
