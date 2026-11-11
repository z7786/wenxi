import 'dart:io';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/transfer/rapid_transfer_task.dart';
import 'package:asterlink/ui/transfers_page.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/download_progress.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'package:asterlink/domain/rapid_transfer.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/ui/app_context_menu.dart';
import 'rapid_transfer_manager_test.dart' show Drive, file;
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

class HeldTransferDrive extends Drive {
  HeldTransferDrive(super.platform);
  @override
  Future<RapidTransferResult> rapidTransfer(
    BrowseSession session,
    String parent,
    RapidTransferFile source,
    Credential credential,
  ) async {
    await RequestScope.cancellable(Completer<void>().future);
    return const RapidTransferResult.reused('completed');
  }
}

void main() {
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
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });
  testWidgets(
    'cross progress covers scanning, both relay phases and partial failure',
    (tester) async {
      const session = BrowseSession(
        platform: CloudPlatform.pan123,
        mode: BrowseMode.personal,
        title: '123',
        rootId: '0',
      );
      final entry = RapidTransferEntry(
        const CloudFile(id: 'movie', name: 'movie.mp4', size: 100),
        [],
        method: CrossTransferMethod.relay,
      );
      final task = RapidTransferTask(
        id: 'progress',
        source: session,
        target: session,
        parent: '0',
        folderName: '全部文件',
        selections: [entry.file],
        createdAt: 1,
        status: RapidTaskStatus.running,
        entries: [entry],
      );
      Future<void> render() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TransferProgress.cross(task, enabled: false)),
          ),
        );
        await tester.pump();
      }

      dynamic painter() => tester
          .widget<CustomPaint>(
            find.byKey(
              const ValueKey('cross-transfer-progress-paint-progress'),
            ),
          )
          .painter;
      await render();
      expect(find.text('扫描中'), findsOneWidget);
      task.scanned = true;
      entry.status = RapidEntryStatus.processing;
      await render();
      expect(find.text('匹配中'), findsOneWidget);
      task.speed = 100;
      entry.status = RapidEntryStatus.downloading;
      entry.downloaded = 50;
      await render();
      expect(painter().fill.value, .25);
      entry.status = RapidEntryStatus.uploading;
      entry.sent = 50;
      await render();
      expect(painter().fill.value, .75);
      task.status = RapidTaskStatus.completed;
      entry.status = RapidEntryStatus.failed;
      await render();
      expect(painter().fill.value, 1);
      expect(find.byType(TransferProgress), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      entry.status = RapidEntryStatus.uploaded;
      await render();
      expect(
        find.byKey(const ValueKey('cross-transfer-progress-paint-progress')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'relay shows independent download and upload percentages after failure',
    (tester) async {
      const s = BrowseSession(
        platform: CloudPlatform.pan123,
        mode: BrowseMode.personal,
        title: '123',
        rootId: '0',
      );
      final entry = RapidTransferEntry(
        const CloudFile(id: 'a', name: 'a.bin', size: 100),
        [],
        method: CrossTransferMethod.relay,
        status: RapidEntryStatus.downloading,
        downloaded: 50,
      );
      final task = RapidTransferTask(
        id: 'phases',
        source: s,
        target: s,
        parent: '0',
        folderName: 'root',
        selections: [entry.file],
        createdAt: 1,
        status: RapidTaskStatus.running,
        scanned: true,
        entries: [entry],
      );
      Future<void> render() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CrossTransferProgress(task, enabled: false)),
          ),
        );
        await tester.pump();
      }

      await render();
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('上传'), findsOneWidget);
      final downloaded = find.byKey(
        const ValueKey('cross-download-progress-paint-phases'),
      );
      final uploaded = find.byKey(
        const ValueKey('cross-upload-progress-paint-phases'),
      );
      dynamic painter(Finder f) => tester.widget<CustomPaint>(f).painter;
      expect(painter(downloaded).fill.value, .5);
      expect(painter(uploaded).fill.value, 0);
      entry
        ..status = RapidEntryStatus.uploading
        ..payloadReady = true
        ..downloaded = 100
        ..sent = 25;
      await render();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('已完成'), findsOneWidget);
      expect(painter(uploaded).fill.value, .25);
      entry.status = RapidEntryStatus.failed;
      task.status = RapidTaskStatus.completed;
      await render();
      expect(find.text('已完成'), findsOneWidget);
      expect(painter(uploaded).fill.value, .25);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  for (final (size, scale, dark, name) in [
    (const Size(393, 864), 1.0, false, 'cross-transfer-phone-standard'),
    (const Size(320, 640), 1.8, false, 'cross-transfer-phone'),
    (const Size(1100, 780), 1.0, false, 'cross-transfer-desktop'),
    (const Size(844, 390), 1.4, true, 'cross-transfer-landscape-dark'),
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
      final upload = UploadTask(
        id: 'local-upload',
        session: target,
        parent: '0',
        folderName: '全部文件',
        accountName: '目标账号',
        path: 'fixture/notes.pdf',
        name: '普通上传 · 使用说明.pdf',
        size: 1024,
        modifiedAt: 1,
        createdAt: 2,
        status: UploadStatus.completed,
      );
      await services.store.put('uploadTasks', [upload.toJson()]);
      await services.uploads.initialize();
      services.requestRapidTransferManager();
      expect(services.transferTab.value, 1);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            dark ? Brightness.dark : Brightness.light,
            fontFamily: systemFont ? 'FixtureUI' : null,
          ),
          home: RepaintBoundary(
            key: const Key('cross-transfer-capture'),
            child: Scaffold(body: TransfersPage(services)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('秒传'), findsNothing);
      expect(find.text('跨盘传输'), findsOneWidget);
      expect(find.textContaining('下载后上传 1'), findsNothing);
      final row = find.byKey(const ValueKey('cross-transfer-row-fixture'));
      final normalRow = find.byKey(const ValueKey('upload-row-local-upload'));
      expect(tester.getSize(row).height, tester.getSize(normalRow).height);
      expect(tester.takeException(), null);
      await tester.runAsync(() async {
        final context = tester.element(row);
        await precacheImage(const AssetImage('assets/icons/123.webp'), context);
      });
      await tester.pump();
      if (systemFont) {
        await expectLater(
          find.byKey(const Key('cross-transfer-capture')),
          matchesGoldenFile('goldens/$name.png'),
        );
      }
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('下载后上传 1'), findsOneWidget);
      expect(find.text('目标目录'), findsOneWidget);
      final entry = find.widgetWithText(ListTile, '下载后上传完成');
      await tester.scrollUntilVisible(
        entry,
        150,
        scrollable: find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pump();
      expect(entry.hitTestable(), findsOneWidget);
      expect(tester.takeException(), null);
      await finish(tester, services);
    });
  }
  testWidgets(
    'cross transfer actions preserve cancel, retry, folder and remove',
    (tester) async {
      final fixture = await BrowserUiFixture.create();
      final services = fixture.services;
      final sourceDrive = Drive(CloudPlatform.tianyi);
      final targetDrive = HeldTransferDrive(CloudPlatform.pan123);
      services.cloud.connectors[CloudPlatform.tianyi] = sourceDrive;
      services.cloud.connectors[CloudPlatform.pan123] = targetDrive;
      await services.vault.putCredential(
        CloudPlatform.pan123,
        Credential('目标账号', {'primary': 'fixture'}, updatedAt: 2),
      );
      final source = await services.cloud.personal(CloudPlatform.tianyi);
      final target = await services.cloud.personal(CloudPlatform.pan123);
      final video = file('video', 'movie.mp4', '0');
      sourceDrive.directories['0'] = [video];
      late String id;
      await tester.runAsync(() async {
        id = await services.rapidTransfers.enqueue(
          source,
          [video],
          target,
          '0',
          '全部文件',
        );
      });
      final task = services.rapidTransfers.task(id)!;
      // The provider keeps the task running until the user's cancellation.
      services.requestRapidTransferManager();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TransfersPage(services))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(task.active, isTrue);
      final row = find.byKey(ValueKey('cross-transfer-row-$id'));
      final action = find.byKey(ValueKey('cross-transfer-action-$id'));
      await tester.tap(find.byKey(const ValueKey('upload-filter-1')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(row, findsOneWidget);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(task.status, RapidTaskStatus.cancelled);
      expect(row, findsNothing);
      await tester.tap(find.byKey(const ValueKey('upload-filter-3')));
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      await tester.tap(action);
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(task.active, isTrue);
      expect(row, findsNothing);
      await tester.tap(find.byKey(const ValueKey('upload-filter-1')));
      await tester.pump(const Duration(milliseconds: 200));
      final menu = tester.widget<AppContextMenu<String>>(
        find
            .ancestor(of: row, matching: find.byType(AppContextMenu<String>))
            .first,
      );
      expect(menu.actions().any((a) => a.value == 'cancel'), isTrue);
      expect(menu.actions().any((a) => a.value == 'remove'), isFalse);
      await tester.tap(action);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('upload-filter-3')));
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      final folder = find.byKey(const ValueKey('cross-transfer-folder'));
      await tester.ensureVisible(folder);
      await tester.pump();
      await tester.tap(folder);
      await tester.pumpAndSettle();
      final browser = tester.widget<BrowserPage>(find.byType(BrowserPage));
      expect(browser.session.platform, target.platform);
      expect(browser.session.accountId, target.accountId);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      final remove = find.byKey(const ValueKey('cross-transfer-remove'));
      await tester.ensureVisible(remove);
      await tester.pump();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      for (
        var i = 0;
        services.rapidTransfers.task(id) != null && i < 100;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
      expect(services.rapidTransfers.task(id), isNull);
      expect(tester.takeException(), isNull);
      await finish(tester, services);
      await tester.runAsync(fixture.close);
    },
  );
  for (final view in ['list', 'grid']) {
    for (final fileName in ['02 旅行视频.mp4', '工作资料']) {
      testWidgets(
        '$view three-dot menu transfers $fileName to selected account and directory',
        (tester) async {
          final fixture = await BrowserUiFixture.create(view: view);
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
          await tester.tap(find.byTooltip('$fileName操作'));
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
          await tester.tap(find.text('工作资料'));
          await tester.pumpAndSettle();
          expect(find.text('选择“工作资料”'), findsOneWidget);
          await tester.tap(find.text('选择“工作资料”'));
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
          final task = services.rapidTransfers.tasks.single;
          expect(task.selections.single.name, fileName);
          expect(task.parent, 'work');
          expect(
            task.target.accountId,
            services.vault.accountId(CloudPlatform.pan123),
          );
          expect(tester.takeException(), null);
          await finish(tester, services);
          await tester.runAsync(fixture.close);
        },
      );
    }
  }
}
