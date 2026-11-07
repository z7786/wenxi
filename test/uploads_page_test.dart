import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/uploads_page.dart';
import 'package:asterlink/ui/transfers_page.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'package:asterlink/upload/upload_folder.dart';
import 'upload_manager_test.dart' show QueueConnector, uploadSession;
import 'support.dart';

void main() {
  late AppServices services;
  late QueueConnector provider;
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
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });
  Future<void> setup(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    bool browser = false,
    bool shell = false,
    bool dark = false,
    bool preview = false,
    bool folderPreview = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    services = AppServices(
      store: StateStore.memory(),
      dataDirectory: Directory('upload-ui-fixture'),
      cacheDirectory: Directory('upload-ui-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('upload-ui-fixture/files')),
      http: FakeHttp(),
      platformFeatures: false,
      controlEnabled: false,
    );
    await services.vault.putCredential(
      CloudPlatform.quark,
      Credential('测试账号', {'primary': 'fixture'}, updatedAt: 1),
    );
    provider = QueueConnector();
    services.cloud.connectors[CloudPlatform.quark] = provider;
    if (preview) {
      final fixtures = [
        for (final (id, name, status, phase, size, sent) in [
          (
            'preview-video',
            '周末旅行 · 精选片段.mp4',
            UploadStatus.running,
            UploadPhase.uploading,
            200 * 1024 * 1024,
            84 * 1024 * 1024,
          ),
          (
            'preview-pending',
            '项目资料备份.zip',
            UploadStatus.pending,
            UploadPhase.preparing,
            72 * 1024 * 1024,
            0,
          ),
          (
            'preview-failed',
            '相机原图合集.zip',
            UploadStatus.failed,
            UploadPhase.uploading,
            128 * 1024 * 1024,
            32 * 1024 * 1024,
          ),
          (
            'preview-completed',
            '使用说明.pdf',
            UploadStatus.completed,
            UploadPhase.finishing,
            12 * 1024 * 1024,
            12 * 1024 * 1024,
          ),
        ])
          UploadTask(
            id: id,
            name: name,
            session: services.cloud.bindSession(uploadSession),
            parent: '0',
            folderName: '我的文件 / 旅行记录',
            accountName: '日常备份',
            path: 'fixture/$id',
            size: size,
            sent: sent,
            status: status,
            phase: phase,
            createdAt: 1,
            modifiedAt: 1,
            error: status == UploadStatus.failed ? '网络连接中断，重新上传会从头开始' : '',
          ),
        if (folderPreview)
          UploadTask(
            id: 'preview-folder',
            session: services.cloud.bindSession(uploadSession),
            parent: '0',
            folderName: '全部文件',
            accountName: '测试账号',
            path: 'fixture/资料',
            name: '资料',
            size: 100,
            modifiedAt: 0,
            createdAt: 1,
            sent: 40,
            status: UploadStatus.failed,
            folder: UploadFolder(
              location: 'fixture/资料',
              name: '资料',
              files: [
                UploadFolderFile(
                  location: 'fixture/资料/one.txt',
                  relativePath: 'one.txt',
                  size: 40,
                  modifiedAt: 1,
                  fileId: 'completed',
                ),
                UploadFolderFile(
                  location: 'fixture/资料/sub/two.mp4',
                  relativePath: 'sub/two.mp4',
                  size: 60,
                  modifiedAt: 1,
                ),
              ],
              directories: ['', 'sub', 'empty'],
            ),
          ),
      ];
      await services.store.put(
        'uploadTasks',
        fixtures.map((t) => t.toJson()).toList(),
      );
      await services.uploads.initialize();
      for (final t in fixtures) {
        services.uploads.task(t.id)!
          ..status = t.status
          ..phase = t.phase
          ..error = t.error
          ..speed = t.status == UploadStatus.running ? 3 * 1024 * 1024 : 0;
      }
    }
    services.transferTab.value = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(
          dark ? Brightness.dark : Brightness.light,
          fontFamily: systemFont ? 'FixtureUI' : null,
        ),
        home: RepaintBoundary(
          key: const Key('uploads-capture'),
          child: shell
              ? MainShell(services, initialTab: 3)
              : browser
              ? BrowserPage(services, uploadSession)
              : Scaffold(body: TransfersPage(services)),
        ),
      ),
    );
    if (preview) {
      await tester.runAsync(() async {
        final context = tester.element(find.byType(UploadsPage));
        for (final asset in [
          'assets/icons/app.png',
          'assets/icons/quark.png',
        ]) {
          await precacheImage(AssetImage(asset), context);
        }
      });
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<String> enqueue() async =>
      (await services.uploads.enqueue(uploadSession, '0', '全部文件', [
        XFile.fromData(
          Uint8List.fromList([1, 2, 3]),
          path: 'new.txt',
          name: 'new.txt',
          lastModified: DateTime.utc(2026, 10, 8),
        ),
      ])).single;
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var done = false;
    services.close().then((_) => done = true);
    final cleanupClock = Stopwatch()..start();
    while (!done && cleanupClock.elapsed < const Duration(seconds: 15)) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(done, isTrue, reason: 'Upload page cleanup did not finish');
  }

  testWidgets(
    'folder uploads show counts, current file and a continuation action',
    (tester) async {
      await setup(
        tester,
        preview: true,
        folderPreview: true,
        size: const Size(320, 700),
        scale: 1.8,
      );
      try {
        final task = services.uploads.task('preview-folder')!;
        task.folder!.currentItem = '资料/sub/two.mp4';
        final row = find.byKey(const ValueKey('upload-row-preview-folder'));
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        expect(find.textContaining('1/2 个文件 · 3 个目录'), findsOneWidget);
        expect(find.byTooltip('继续上传'), findsOneWidget);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text('当前文件'), findsOneWidget);
        expect(find.text('资料/sub/two.mp4'), findsOneWidget);
        expect(find.text('继续上传'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'leaving upload management does not cancel an upload; returning shows completion',
    (tester) async {
      await setup(tester);
      try {
        provider.hold = Completer<void>();
        final id = await enqueue();
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.textContaining('正在上传'), findsOneWidget);
        services.transferTab.value = 0;
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byType(UploadsPage), findsNothing);
        expect(services.uploads.task(id)!.active, isTrue);
        provider.hold!.complete();
        await tester.pumpAndSettle();
        services.transferTab.value = 1;
        await tester.pumpAndSettle();
        expect(find.textContaining('上传完成'), findsOneWidget);
        expect(find.byTooltip('打开目标目录：全部文件'), findsOneWidget);
      } finally {
        await finish(tester);
      }
    },
  );
  testWidgets(
    'successful background upload refreshes the matching browser directory',
    (tester) async {
      await setup(tester, browser: true);
      try {
        expect(find.text('new.txt'), findsNothing);
        await enqueue();
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(find.text('new.txt'), findsOneWidget);
      } finally {
        await finish(tester);
      }
    },
  );
  testWidgets(
    'upload and download navigation select the intended transfer tab',
    (tester) async {
      await setup(tester, shell: true);
      try {
        expect(find.text('传输管理'), findsOneWidget);
        services.requestDownloadManager();
        await tester.pumpAndSettle();
        expect(services.transferTab.value, 0);
        services.requestUploadManager();
        await tester.pumpAndSettle();
        expect(find.textContaining('暂无上传任务'), findsOneWidget);
        expect(find.text('传输'), findsOneWidget);
      } finally {
        await finish(tester);
      }
    },
  );
  for (final (size, scale) in [
    (const Size(320, 700), 1.8),
    (const Size(844, 390), 1.0),
    (const Size(1280, 800), 1.0),
  ]) {
    testWidgets('upload task controls fit $size at scale $scale', (
      tester,
    ) async {
      await setup(tester, size: size, scale: scale);
      try {
        await enqueue();
        await tester.pumpAndSettle();
        expect(find.textContaining('上传完成'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    });
  }
  testWidgets(
    'failed uploads retry in their original directory and records can be removed',
    (tester) async {
      await setup(tester);
      try {
        provider.fail = true;
        final id = await enqueue();
        await tester.pumpAndSettle();
        expect(find.textContaining('上传失败'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('upload-filter-3')));
        await tester.pumpAndSettle();
        provider.fail = false;
        await tester.tap(find.byTooltip('重新上传'));
        await tester.pumpAndSettle();
        expect(services.uploads.task(id)!.status, UploadStatus.completed);
        expect(provider.parents, ['0', '0']);
        await tester.tap(find.byKey(const ValueKey('upload-filter-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('upload-row-$id')));
        await tester.pumpAndSettle();
        expect(find.text('上传账号'), findsOneWidget);
        expect(find.text('目标目录'), findsOneWidget);
        await tester.tap(find.text('删除记录'));
        await tester.pumpAndSettle();
        expect(services.uploads.task(id), isNull);
        expect(provider.files, hasLength(1));
      } finally {
        await finish(tester);
      }
    },
  );
  testWidgets('upload details update when an active task completes', (
    tester,
  ) async {
    await setup(tester);
    try {
      provider.hold = Completer<void>();
      final id = await enqueue();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(ValueKey('upload-row-$id')));
      await tester.pumpAndSettle();
      expect(find.text('取消上传'), findsOneWidget);
      expect(find.byKey(const Key('uploads-remove-record')), findsNothing);
      provider.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.text('取消上传'), findsNothing);
      expect(find.byKey(const Key('uploads-remove-record')), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });
  for (final (name, size, dark, scale) in [
    ('phone-uploads', const Size(393, 864), false, 1.0),
    ('phone-uploads-dark', const Size(393, 864), true, 1.0),
    ('phone-uploads-large-text', const Size(320, 700), false, 1.8),
    ('desktop-uploads', const Size(1280, 800), false, 1.0),
  ]) {
    testWidgets('$name upload layout', (tester) async {
      await setup(
        tester,
        size: size,
        dark: dark,
        scale: scale,
        shell: true,
        preview: true,
      );
      try {
        expect(tester.takeException(), isNull);
        if (scale == 1) {
          for (final id in [
            'preview-video',
            'preview-pending',
            'preview-failed',
            'preview-completed',
          ]) {
            expect(
              tester.getSize(find.byKey(ValueKey('upload-row-$id'))).height,
              lessThanOrEqualTo(76),
              reason: 'Each file must keep a compact list row',
            );
          }
        }
        if (systemFont) {
          await expectLater(
            find.byKey(const Key('uploads-capture')),
            matchesGoldenFile('goldens/$name.png'),
          );
        }
      } finally {
        await finish(tester);
      }
    });
  }
}
