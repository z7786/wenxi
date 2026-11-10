import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/transfer/rapid_transfer_task.dart';
import 'package:asterlink/ui/transfers_page.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'browser_test_support.dart';
import 'support.dart';

Future<void> finish(WidgetTester tester, AppServices services) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var done = false;
  services.close().then((_) => done = true);
  final watch = Stopwatch()..start();
  while (!done && watch.elapsed < const Duration(seconds: 15)) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(done, true);
}

void main() {
  for (final (size, scale) in [
    (const Size(320, 640), 1.4),
    (const Size(1100, 780), 1.0),
  ]) {
    testWidgets('transfer results fit $size with scale $scale', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final services = AppServices(
        store: StateStore.memory(),
        dataDirectory: Directory('rapid-ui'),
        cacheDirectory: Directory('rapid-ui/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('rapid-ui/files')),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
      const source = BrowseSession(
        platform: CloudPlatform.baidu,
        mode: BrowseMode.personal,
        title: '百度',
        rootId: '/',
        metadata: {'accountId': 'source'},
      );
      const target = BrowseSession(
        platform: CloudPlatform.pan123,
        mode: BrowseMode.personal,
        title: '123',
        rootId: '0',
        metadata: {'accountId': 'target'},
      );
      const file = CloudFile(
        id: '42',
        name: '旅行视频与资料 · 2026 年夏季合集.mp4',
        size: 1024,
      );
      final task = RapidTransferTask(
        id: 'fixture',
        source: source,
        target: target,
        parent: '0',
        folderName: '全部文件 / 长名称目录',
        selections: [file],
        createdAt: 1,
        scanned: true,
        status: RapidTaskStatus.completed,
        entries: [
          RapidTransferEntry(
            file,
            ['旅行相册'],
            status: RapidEntryStatus.uploaded,
            method: CrossTransferMethod.relay,
            message: '下载后上传完成',
          ),
        ],
      );
      await services.store.put('rapidTransferTasks', [task.toJson()]);
      await tester.runAsync(() => services.rapidTransfers.initialize());
      services.requestRapidTransferManager();
      expect(services.transferTab.value, 1);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TransfersPage(services))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('秒传'), findsNothing);
      expect(find.text('跨盘传输'), findsOneWidget);
      expect(find.textContaining('下载后上传 1'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.tap(find.text('详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('下载后上传完成'), findsOneWidget);
      expect(tester.takeException(), null);
      await finish(tester, services);
    });
  }
  testWidgets(
    'file menu chooses remembered target account and real destination directory',
    (tester) async {
      final fixture = await BrowserUiFixture.create();
      final services = fixture.services;
      await services.vault.putCredential(
        CloudPlatform.pan123,
        Credential('目标账号', {'primary': 'test-token'}, updatedAt: 2),
      );
      final dest = BrowserTestConnector(CloudPlatform.pan123);
      services.cloud.connectors[CloudPlatform.pan123] = dest;
      final session = await services.cloud.personal(CloudPlatform.tianyi);
      await tester.pumpWidget(
        MaterialApp(home: BrowserPage(services, session)),
      );
      await tester.pumpAndSettle();
      // Selecting one file exposes the same action used for multi-file transfers.
      await tester.longPress(find.text('02 旅行视频.mp4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跨盘传输'));
      await tester.pumpAndSettle();
      expect(find.text('跨盘传输 · 选择目标账号'), findsOneWidget);
      await tester.tap(find.text('目标账号'));
      await tester.pumpAndSettle();
      expect(find.text('选择“全部文件”'), findsOneWidget);
      final picker = tester
          .widgetList<BrowserPage>(find.byType(BrowserPage))
          .last;
      expect(picker.picking, true);
      expect(picker.session.platform, CloudPlatform.pan123);
      expect(
        picker.session.accountId,
        services.vault.accountId(CloudPlatform.pan123),
      );
      expect(tester.takeException(), null);
      await finish(tester, services);
      await tester.runAsync(fixture.close);
    },
  );
}
