import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/download_protection.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/ui/download_protection_page.dart';

class _Platform extends DownloadProtectionPlatform {
  _Platform({super.operatingSystem});
  final opened = <String>[];
  bool allowed = false, failRead = false, failOpen = false;
  bool desktop = false, running = false, keepAlive = false;
  bool? keepAliveNotifications;
  @override
  Future<DownloadProtectionStatus> status() async {
    if (failRead) throw PlatformException(code: 'status');
    return DownloadProtectionStatus(
      batteryUnrestricted: allowed,
      notificationsEnabled: allowed,
      backgroundRestricted: !allowed,
      desktop: desktop,
      serviceRunning: running,
      wakeLockHeld: running,
      keepAliveRunning: keepAlive,
      keepAliveNotificationsEnabled: keepAliveNotifications ?? allowed,
    );
  }

  @override
  Future<void> openSettings(String kind) async {
    if (failOpen) throw const AppException('系统设置不可用');
    opened.add(kind);
  }
}

void main() {
  testWidgets(
    'iOS explains foreground transfers without requesting Android settings',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: DownloadProtectionPage(
            platform: DownloadProtectionPlatform(operatingSystem: 'ios'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('iOS 下载与续传'), findsOneWidget);
      expect(find.textContaining('请保持应用在前台'), findsOneWidget);
      expect(find.text('电池优化'), findsNothing);
      expect(find.text('开启通知'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'macOS displays sleep protection without Windows tray instructions',
    (tester) async {
      final platform = _Platform(operatingSystem: 'macos')
        ..desktop = true
        ..running = true;
      await tester.pumpWidget(
        MaterialApp(home: DownloadProtectionPage(platform: platform)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('最小化窗口后下载和上传会继续'), findsOneWidget);
      expect(find.text('下载保活运行中 · 自动休眠保护已开启'), findsOneWidget);
      expect(find.textContaining('系统托盘，下载和上传'), findsNothing);
      expect(find.textContaining('托盘下载'), findsNothing);
      expect(platform.opened, isEmpty);
    },
  );
  testWidgets(
    'Android reports startup keepalive independently of active downloads and denied notifications',
    (tester) async {
      final platform = _Platform()..keepAlive = true;
      await tester.pumpWidget(
        MaterialApp(home: DownloadProtectionPage(platform: platform)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('后台保活运行中 · 通知未开启'), 250);
      expect(find.text('下载开始后自动启用锁屏保护'), findsOneWidget);
      expect(find.text('下载保护运行中 · 锁屏保护已启用'), findsNothing);
      platform.allowed = true;
      platform.running = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('后台保活运行中'), findsOneWidget);
      expect(find.text('下载保护运行中 · 锁屏保护已启用'), findsOneWidget);
      platform.running = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('后台保活运行中'), findsOneWidget);
      expect(find.text('下载开始后自动启用锁屏保护'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'a disabled keepalive channel is shown even if download notifications are enabled',
    (tester) async {
      final platform = _Platform()
        ..allowed = true
        ..keepAlive = true
        ..keepAliveNotifications = false;
      await tester.pumpWidget(
        MaterialApp(home: DownloadProtectionPage(platform: platform)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('开启通知'));
      expect(find.text('下载通知已开启，保活通知未开启。可在系统设置中开启“后台保活”。'), findsOneWidget);
      await tester.tap(find.text('开启通知'));
      await tester.pumpAndSettle();
      expect(platform.opened, ['notifications']);
      expect(find.text('后台保活运行中 · 通知未开启'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Windows shows live sleep protection without Android permissions',
    (tester) async {
      final platform = _Platform()
        ..desktop = true
        ..running = true;
      await tester.pumpWidget(
        MaterialApp(home: DownloadProtectionPage(platform: platform)),
      );
      await tester.pumpAndSettle();
      expect(find.text('下载保活运行中 · 自动休眠保护已开启'), findsOneWidget);
      expect(find.text('电池优化'), findsNothing);
      expect(find.text('开启下载通知'), findsNothing);
      expect(platform.opened, isEmpty);
      platform.running = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('下载开始后自动启用保护'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'background settings are explicit and refresh after returning from system UI',
    (tester) async {
      final platform = _Platform();
      await tester.pumpWidget(
        MaterialApp(home: DownloadProtectionPage(platform: platform)),
      );
      await tester.pumpAndSettle();
      expect(platform.opened, isEmpty);
      await tester.tap(find.text('允许后台下载'));
      await tester.pumpAndSettle();
      expect(platform.opened, ['battery']);
      expect(find.text('允许后台下载'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      platform.allowed = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('已允许忽略电池优化。'), findsOneWidget);
      await tester.ensureVisible(find.text('查看通知设置'));
      await tester.tap(find.text('查看通知设置'));
      await tester.pumpAndSettle();
      expect(platform.opened, ['battery', 'notifications']);
      await tester.ensureVisible(find.text('打开应用信息'));
      await tester.tap(find.text('打开应用信息'));
      await tester.pumpAndSettle();
      expect(platform.opened.last, 'app');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'read or settings failures do not display a false granted state',
    (tester) async {
      final platform = _Platform()..failRead = true;
      await tester.pumpWidget(
        MaterialApp(home: DownloadProtectionPage(platform: platform)),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂时无法读取后台设置，请重试'), findsOneWidget);
      expect(find.text('已允许忽略电池优化。'), findsNothing);
      platform.failRead = false;
      await tester.tap(find.text('重新检查'));
      await tester.pumpAndSettle();
      platform.failOpen = true;
      await tester.tap(find.text('允许后台下载'));
      await tester.pumpAndSettle();
      expect(find.text('系统设置不可用'), findsOneWidget);
      expect(platform.opened, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'protection page fits a small screen with large text and dark theme',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: DownloadProtectionPage(platform: _Platform()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('打开应用信息'), 250);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
