import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/file_access.dart';
import 'support.dart';

class _SelectionHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"selection-fixture"', null), false);
}

class _SelectionFiles extends FakeFiles {
  _SelectionFiles(super.directory);
  final failPaths = <String>{};
  Completer<FileAvailability>? blocked;
  Completer<void>? deletionBlocked;
  int blockDeletionAt = 1;
  int deletes = 0, inspections = 0, checked = 0;
  @override
  Future<FileAvailability> inspect(String? path) async {
    inspections++;
    try {
      if (blocked != null) return await blocked!.future;
      if (path != null && availability.containsKey(path)) {
        return availability[path]!;
      }
      // The widget fixture observes real external deletion without leaving
      // host file handles open in Flutter's simulated clock. PlatformFileAccess
      // itself is exercised by file_availability_test and file_deletion_test.
      return path != null && File(path).existsSync()
          ? FileAvailability.present
          : FileAvailability.missing;
    } finally {
      checked++;
    }
  }

  @override
  Future<void> delete(String? path) async {
    deletes++;
    if (deletionBlocked != null && deletes == blockDeletionAt) {
      await deletionBlocked!.future;
    }
    if (failPaths.contains(path)) throw const AppException('文件正在使用');
    await super.delete(path);
  }
}

void main() {
  final openVideoLabel = Platform.isWindows ? '播放视频' : '打开文件';
  bool systemFont = false;
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final clock = Stopwatch()..start();
    bool settled() =>
        ready() && find.byType(CircularProgressIndicator).evaluate().isEmpty;
    do {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    } while (!settled() && clock.elapsed < const Duration(seconds: 12));
    expect(
      settled(),
      isTrue,
      reason: 'The asynchronous selection action did not finish',
    );
    await tester.pumpAndSettle();
  }

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

  Future<(AppServices, FakeNative, _SelectionFiles)> render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    bool dark = false,
    double scale = 1,
    bool missingFiles = false,
    bool blockedInspection = false,
    bool unfinishedSavedFile = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    late Directory root;
    late AppServices services;
    final native = FakeNative()..finish = false;
    late _SelectionFiles files;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('aster-download-selection-');
      files = _SelectionFiles(Directory(p.join(root.path, 'saved')));
      final tasks = <Json>[];
      for (final (id, name, status, createdAt) in [
        ('completed-a', '旅行回忆 第一集.mp4', DownloadStatus.completed, 4),
        ('completed-b', '旅行回忆 第二集.mp4', DownloadStatus.completed, 3),
        ('paused', '待续传的资料.zip', DownloadStatus.paused, 2),
        ('failed', '等待重试的文件.zip', DownloadStatus.failed, 1),
      ]) {
        String? savedPath;
        if (status == DownloadStatus.completed ||
            unfinishedSavedFile && status == DownloadStatus.failed) {
          savedPath = p.join(root.path, '$id.mp4');
          await File(savedPath).writeAsBytes([1, 2, 3, 4]);
          if (missingFiles) {
            await File(savedPath).delete();
            files.availability[savedPath] = FileAvailability.missing;
            files.failPaths.add(savedPath);
          }
        }
        tasks.add(
          DownloadTask(
            id: id,
            spec: DownloadSpec(
              url: 'https://example.com/$id',
              fileName: name,
              source: {'platform': 'Quark'},
              expectedSize: 4,
            ),
            createdAt: createdAt,
            status: status,
            total: 4,
            downloaded: status == DownloadStatus.completed ? 4 : 0,
            savedPath: savedPath,
            connections: 512,
            error: status == DownloadStatus.failed ? '网络连接中断' : '',
          ).toJson(),
        );
      }
      services = AppServices(
        controlEnabled: false,
        store: StateStore.memory({
          'settings': {'theme': dark ? 'Dark' : 'Light', 'concurrent': 1},
          'tasks': tasks,
        }),
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: native,
        files: files,
        http: FakeHttp(),
        transferHttp: _SelectionHttp(),
        platformFeatures: false,
        clock: () => DateTime(2026, 9, 14, 20),
      );
      await services.downloads.initialize();
    });
    if (blockedInspection) files.blocked = Completer<FileAvailability>();
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('selection-capture'),
        child: AsterLinkApp(
          services,
          initialTab: 3,
          fontFamily: systemFont ? 'FixtureUI' : null,
        ),
      ),
    );
    if (!blockedInspection) await waitFor(tester, () => files.checked >= 2);
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
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      if (files.deletionBlocked?.isCompleted == false) {
        files.deletionBlocked!.complete();
        await tester.pump();
      }
      if (files.blocked?.isCompleted == false) {
        files.blocked!.complete(FileAvailability.inaccessible);
        await tester.pump();
      }
      await waitFor(tester, () => files.checked == files.inspections);
      var closed = false;
      final close = services.close().whenComplete(() => closed = true);
      await waitFor(tester, () => closed);
      await close;
      await tester.runAsync(() async {
        expect(
          p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path),
          isTrue,
        );
        await root.delete(recursive: true);
      });
    });
    return (services, native, files);
  }

  Finder row(String id) => find.byKey(ValueKey('download-row-$id'));
  Checkbox checkbox(WidgetTester tester, String id) =>
      tester.widget<Checkbox>(find.byKey(ValueKey('download-select-$id')));
  Finder action(String name) => find.byKey(Key('downloads-batch-$name'));
  Finder getCount() => find.byKey(const Key('downloads-selected-count'));
  Future<void> select(WidgetTester tester, String id) async {
    await tester.longPress(row(id));
    await tester.pumpAndSettle();
  }

  void background(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void foreground(WidgetTester tester) {
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  for (final entry in ['single', 'batch', 'clear', 'failed']) {
    testWidgets('Deletion progress is visible through the $entry entry', (
      tester,
    ) async {
      final (services, _, files) = await render(
        tester,
        unfinishedSavedFile: entry == 'failed',
      );
      files.deletionBlocked = Completer<void>();
      files.blockDeletionAt = entry == 'single' || entry == 'failed' ? 1 : 2;
      if (entry == 'single') {
        await tester.tap(row('completed-a'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('downloads-remove-record')));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckboxListTile));
        await tester.tap(
          find.byKey(const Key('downloads-confirm-single-delete')),
        );
      } else if (entry == 'batch') {
        await select(tester, 'completed-a');
        await tester.tap(row('completed-b'));
        await tester.tap(action('delete'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckboxListTile));
        await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      } else {
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry == 'failed' ? '清理失败任务' : '清理下载记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('downloads-clear-files')));
        await tester.tap(find.byKey(const Key('downloads-confirm-clear')));
      }
      final expectedDeletes = files.blockDeletionAt;
      for (
        var tries = 0;
        tries < 100 && files.deletes < expectedDeletes;
        tries++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(files.deletes, expectedDeletes);
      await tester.pump(const Duration(milliseconds: 150));
      final count = entry == 'single' || entry == 'failed'
          ? 1
          : entry == 'batch'
          ? 2
          : 4;
      final processed = entry == 'single' || entry == 'failed' ? 0 : 1;
      expect(find.text('已处理 $processed / $count 项'), findsOneWidget);
      expect(find.text('正在删除本地文件…'), findsOneWidget);
      expect(find.textContaining('已删除 0 项'), findsOneWidget);
      if (processed > 0) {
        expect(find.textContaining('等待保存 1 项'), findsOneWidget);
      }
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('operation-item-progress')),
            )
            .value,
        0,
      );
      expect(services.downloads.tasks, hasLength(4));
      files.deletionBlocked!.complete();
      await waitFor(tester, () => services.downloads.tasks.length == 4 - count);
      expect(find.byKey(const Key('operation-item-progress')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Cancelling visible deletion finishes only the current file', (
    tester,
  ) async {
    final (services, _, files) = await render(tester);
    final keptPath = services.downloads.task('completed-b')!.savedPath!;
    files.deletionBlocked = Completer<void>();
    await select(tester, 'completed-a');
    await tester.tap(row('completed-b'));
    await tester.tap(action('delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
    for (var tries = 0; tries < 100 && files.deletes == 0; tries++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(files.deletes, 1);
    expect(find.text('已处理 0 / 2 项'), findsOneWidget);
    final dialog = find.ancestor(
      of: find.byKey(const Key('operation-item-progress')),
      matching: find.byType(AlertDialog),
    );
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextButton, '取消'),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('operation-item-progress')), findsNothing);
    files.deletionBlocked!.complete();
    await waitFor(tester, () => services.downloads.task('completed-a') == null);
    expect(services.downloads.task('completed-b'), isNotNull);
    expect(files.deletes, 1);
    await tester.runAsync(
      () async => expect(await File(keptPath).exists(), isTrue),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A missing file can be removed from its details without file access',
    (tester) async {
      final (services, _, _) = await render(tester, missingFiles: true);
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.text('移除下载记录'), findsOneWidget);
      expect(find.text('同时删除已下载的文件'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(services.downloads.task('completed-a'), isNotNull);
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(services.downloads.task('completed-b'), isNotNull);
    },
  );

  testWidgets(
    'Missing file filter supports selecting and removing all records',
    (tester) async {
      final (services, _, _) = await render(tester, missingFiles: true);
      await tester.tap(find.text('文件异常 2'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('其中 2 个文件已不存在，将移除对应的下载记录。'), findsOneWidget);
      expect(find.text('同时删除已下载的文件'), findsNothing);
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(tester, () => services.downloads.tasks.length == 2);
      expect(services.downloads.task('completed-a'), isNull);
      expect(services.downloads.task('completed-b'), isNull);
      expect(services.downloads.task('paused'), isNotNull);
      expect(services.downloads.task('failed'), isNotNull);
      expect(find.byKey(const Key('downloads-selection-bar')), findsNothing);
    },
  );

  testWidgets(
    'Opening details rechecks a file deleted externally after list inspection',
    (tester) async {
      final (services, _, files) = await render(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      expect(find.text('文件不存在'), findsNothing);
      await tester.runAsync(() => File(path).delete());
      files.failPaths.add(path);
      await tester.tap(row('completed-a'));
      await waitFor(
        tester,
        () => find.textContaining('文件已被移动或删除，下载记录仍保留').evaluate().isNotEmpty,
      );
      expect(find.text(openVideoLabel), findsNothing);
      expect(find.text('移除下载记录'), findsOneWidget);
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
      expect(
        services.store.data
            .list('tasks')
            .any((task) => task.str('id') == 'completed-a'),
        isFalse,
      );
    },
  );

  testWidgets(
    'Returning from an external file manager refreshes an open details sheet',
    (tester) async {
      final (services, _, files) = await render(tester);
      await tester.tap(row('completed-a'));
      await waitFor(tester, () => files.checked == files.inspections);
      expect(find.text(openVideoLabel), findsOneWidget);
      background(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      foreground(tester);
      await waitFor(
        tester,
        () => find.textContaining('文件已被移动或删除，下载记录仍保留').evaluate().isNotEmpty,
      );
      expect(find.text(openVideoLabel), findsNothing);
      expect(find.text('移除下载记录'), findsOneWidget);
      expect(
        services.downloads.task('completed-a')!.status,
        DownloadStatus.completed,
      );
      await Navigator.of(tester.element(find.text('移除下载记录'))).maybePop();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'A failed open exposes record removal even when the provider cannot identify the file',
    (tester) async {
      final (services, _, files) = await render(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      files.availability[path] = FileAvailability.inaccessible;
      files.failPaths.add(path);
      final open = find.descendant(
        of: row('completed-a'),
        matching: find.byType(IconButton),
      );
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.text('移除下载记录'), findsOneWidget);
      expect(find.text(openVideoLabel), findsNothing);
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前无法访问原文件，仍可直接移除'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
    },
  );

  testWidgets(
    'A blocked file inspection cannot block single or batch history removal',
    (tester) async {
      final (services, _, files) = await render(
        tester,
        blockedInspection: true,
      );
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.textContaining('文件状态尚未确认，仍可直接移除'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      await select(tester, 'completed-b');
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('移除 1 条下载记录'), findsOneWidget);
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-b') == null,
      );
      files.blocked!.complete(FileAvailability.present);
      await tester.pumpAndSettle();
      expect(services.downloads.tasks.map((task) => task.id), [
        'paused',
        'failed',
      ]);
      expect(files.deletes, 0);
    },
  );

  testWidgets(
    'Returning to the download tab discovers an external deletion and permits batch removal',
    (tester) async {
      final (services, _, files) = await render(tester);
      await tester.tap(find.text('网盘').last);
      await tester.pumpAndSettle();
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      files.failPaths.add(path);
      await tester.tap(find.text('传输').last);
      await waitFor(tester, () => find.text('文件不存在').evaluate().isNotEmpty);
      await tester.tap(find.text('文件异常 1'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
      expect(services.downloads.task('completed-b'), isNotNull);
    },
  );

  testWidgets(
    'An inaccessible history record can be removed in a batch without deleting its file',
    (tester) async {
      final (services, _, files) = await render(tester);
      final path = services.downloads.task('completed-a')!.savedPath!;
      await tester.runAsync(() => File(path).delete());
      files.availability[path] = FileAvailability.inaccessible;
      files.failPaths.add(path);
      background(tester);
      foreground(tester);
      await waitFor(tester, () => find.text('无法访问文件').evaluate().isNotEmpty);
      await tester.tap(find.text('文件异常 1'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      expect(files.deletes, 0);
    },
  );

  testWidgets(
    'Long press selects, taps toggle, back and tab change exit selection',
    (tester) async {
      await render(tester);
      await select(tester, 'completed-a');
      expect(checkbox(tester, 'completed-a').value, isTrue);
      expect(tester.widget<Text>(getCount()).data, '已选 1 项');
      expect(tester.widget<TextButton>(action('pause')).onPressed, isNull);
      expect(tester.widget<TextButton>(action('resume')).onPressed, isNull);
      await tester.tap(row('completed-b'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(getCount()).data, '已选 2 项');
      await tester.tap(row('completed-a'));
      await tester.pumpAndSettle();
      expect(checkbox(tester, 'completed-a').value, isFalse);
      expect(find.text('复制下载链接'), findsNothing);
      await Navigator.of(tester.element(row('completed-b'))).maybePop();
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
      await tester.tap(row('completed-b'));
      await tester.pumpAndSettle();
      expect(find.text('复制下载链接'), findsOneWidget);
      Navigator.of(tester.element(find.text('复制下载链接'))).pop();
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(find.text('网盘').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('传输').last);
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
    },
  );

  testWidgets(
    'Select all stays within the filter and vanished rows leave selection',
    (tester) async {
      final (services, _, _) = await render(tester);
      await tester.tap(find.text('已完成 2'));
      await tester.pumpAndSettle();
      await select(tester, 'completed-a');
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(getCount()).data, '已选 2 项');
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(getCount()).data, '已选 0 项');
      expect(tester.widget<TextButton>(action('delete')).onPressed, isNull);
      await tester.tap(find.text('失败 1'));
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
      await select(tester, 'failed');
      await tester.runAsync(() => services.downloads.delete('failed'));
      await tester.pumpAndSettle();
      expect(getCount(), findsNothing);
      expect(services.downloads.task('completed-a'), isNotNull);
    },
  );

  testWidgets(
    'Batch delete can be cancelled and preserves downloaded files by default',
    (tester) async {
      final (services, _, _) = await render(tester);
      final paths = [
        'completed-a',
        'completed-b',
      ].map((id) => services.downloads.task(id)!.savedPath!).toList();
      await select(tester, 'completed-a');
      await tester.tap(row('completed-b'));
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('移除 2 条下载记录'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(services.downloads.tasks.length, 4);
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(tester, () => services.downloads.tasks.length == 2);
      expect(getCount(), findsNothing);
      await tester.runAsync(() async {
        for (final path in paths) {
          expect(await File(path).exists(), isTrue);
        }
      });
      expect(services.downloads.task('paused'), isNotNull);
      expect(services.downloads.task('failed'), isNotNull);
    },
  );

  testWidgets(
    'Opting into file deletion retains a failed file and selects it for retry',
    (tester) async {
      final (services, _, files) = await render(tester);
      final keep = services.downloads.task('completed-a')!.savedPath!;
      final removed = services.downloads.task('completed-b')!.savedPath!;
      files.failPaths.add(keep);
      await select(tester, 'completed-a');
      await tester.tap(row('completed-b'));
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-b') == null,
      );
      expect(tester.widget<Text>(getCount()).data, '已选 1 项');
      expect(checkbox(tester, 'completed-a').value, isTrue);
      expect(services.downloads.task('completed-a')!.error, '文件正在使用');
      expect(services.downloads.tasks.length, 3);
      await tester.runAsync(() async {
        expect(await File(keep).exists(), isTrue);
        expect(await File(removed).exists(), isFalse);
      });
      expect(
        find.byKey(const Key('downloads-selection-notice')),
        findsOneWidget,
      );
      files.failPaths.clear();
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('移除 1 条下载记录'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(
        tester,
        () => services.downloads.task('completed-a') == null,
      );
      await tester.runAsync(() async {
        expect(await File(keep).exists(), isFalse);
      });
    },
  );

  testWidgets(
    'Overflow cleanup removes all download records and keeps saved files by default',
    (tester) async {
      final (services, _, files) = await render(tester);
      final paths = [
        'completed-a',
        'completed-b',
      ].map((id) => services.downloads.task(id)!.savedPath!).toList();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理下载记录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('全部 4 条下载记录'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('downloads-clear-files')),
            )
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('downloads-confirm-clear')));
      await waitFor(tester, () => services.downloads.tasks.isEmpty);
      expect(files.deletes, 0);
      await tester.runAsync(() async {
        for (final path in paths) {
          expect(await File(path).exists(), true);
        }
      });
    },
  );

  for (final label in ['清理下载记录', '清理失败任务']) {
    testWidgets('Cancelling $label preserves every task and file', (
      tester,
    ) async {
      final (services, _, files) = await render(tester);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-clear-files')));
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(services.downloads.tasks.length, 4);
      expect(files.deletes, 0);
    });
  }

  for (final deleteFiles in [false, true]) {
    testWidgets(
      'Failed cleanup only removes failed tasks; delete files=$deleteFiles',
      (tester) async {
        final (services, _, files) = await render(
          tester,
          unfinishedSavedFile: true,
        );
        final residual = services.downloads.task('failed')!.savedPath!;
        final completed = services.downloads.task('completed-a')!.savedPath!;
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清理失败任务'));
        await tester.pumpAndSettle();
        expect(find.textContaining('当前 1 个失败任务'), findsOneWidget);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const Key('downloads-clear-files')),
              )
              .value,
          false,
        );
        if (deleteFiles) {
          await tester.tap(find.byKey(const Key('downloads-clear-files')));
        }
        await tester.tap(find.byKey(const Key('downloads-confirm-clear')));
        await waitFor(tester, () => services.downloads.task('failed') == null);
        expect(
          services.downloads.tasks.map((task) => task.id),
          unorderedEquals(['completed-a', 'completed-b', 'paused']),
        );
        expect(files.deletes, deleteFiles ? 1 : 0);
        await tester.runAsync(() async {
          expect(await File(residual).exists(), !deleteFiles);
          expect(await File(completed).exists(), true);
        });
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('清理失败任务'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('暂无可清理的失败任务'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'Failed cleanup keeps tasks resumed while confirmation was open',
    (tester) async {
      final (services, native, files) = await render(tester);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理失败任务'));
      await tester.pumpAndSettle();
      final resume = services.downloads.resume('failed');
      await waitFor(tester, () => native.begins.isNotEmpty);
      await resume;
      await tester.tap(find.byKey(const Key('downloads-clear-files')));
      await tester.tap(find.byKey(const Key('downloads-confirm-clear')));
      await tester.pumpAndSettle();
      expect(services.downloads.tasks, hasLength(4));
      expect(services.downloads.task('failed')!.active, true);
      expect(files.deletes, 0);
      expect(find.text('暂无可清理的失败任务'), findsOneWidget);
    },
  );

  testWidgets(
    'Failed cleanup retains a task whose residual file cannot be removed',
    (tester) async {
      final (services, _, files) = await render(
        tester,
        unfinishedSavedFile: true,
      );
      final residual = services.downloads.task('failed')!.savedPath!;
      files.failPaths.add(residual);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理失败任务'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-clear-files')));
      await tester.tap(find.byKey(const Key('downloads-confirm-clear')));
      await waitFor(
        tester,
        () => services.downloads.task('failed')!.error == '文件正在使用',
      );
      expect(services.downloads.tasks, hasLength(4));
      expect(files.deletes, 1);
      expect(find.textContaining('1 条暂未清理'), findsOneWidget);
      await tester.runAsync(
        () async => expect(await File(residual).exists(), true),
      );
    },
  );

  testWidgets(
    'Cleanup can delete downloaded and residual files while retaining a deletion failure',
    (tester) async {
      final (services, _, files) = await render(
        tester,
        unfinishedSavedFile: true,
      );
      final retained = services.downloads.task('completed-a')!.savedPath!;
      final removed = [
        'completed-b',
        'failed',
      ].map((id) => services.downloads.task(id)!.savedPath!).toList();
      files.failPaths.add(retained);
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理下载记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-clear-files')));
      await tester.tap(find.byKey(const Key('downloads-confirm-clear')));
      await waitFor(tester, () => services.downloads.tasks.length == 1);
      expect(services.downloads.tasks.single.id, 'completed-a');
      expect(services.downloads.tasks.single.error, '文件正在使用');
      await tester.runAsync(() async {
        expect(await File(retained).exists(), isTrue);
        for (final path in removed) {
          expect(await File(path).exists(), isFalse);
        }
      });
    },
  );

  testWidgets(
    'A failed task without an exported path still offers local file deletion',
    (tester) async {
      final (services, _, _) = await render(tester);
      expect(services.downloads.task('failed')!.savedPath, isNull);
      await tester.tap(row('failed'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      expect(find.text('同时删除本地文件'), findsOneWidget);
      expect(find.textContaining('自动清理未完成缓存'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(tester, () => services.downloads.task('failed') == null);
      expect(services.downloads.task('paused'), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Failed and paused tasks show the batch prompt and remove only selected residual files',
    (tester) async {
      final (services, _, _) = await render(tester, unfinishedSavedFile: true);
      final residual = services.downloads.task('failed')!.savedPath!;
      final kept = services.downloads.task('completed-a')!.savedPath!;
      await select(tester, 'failed');
      await tester.tap(row('paused'));
      await tester.tap(action('delete'));
      await tester.pumpAndSettle();
      expect(find.text('同时删除本地文件'), findsOneWidget);
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await tester.tap(find.byType(CheckboxListTile));
      await tester.tap(find.byKey(const Key('downloads-confirm-delete')));
      await waitFor(tester, () => services.downloads.tasks.length == 2);
      await tester.runAsync(() async {
        expect(await File(residual).exists(), false);
        expect(await File(kept).exists(), true);
      });
    },
  );

  testWidgets(
    'Unchecking file deletion keeps a failed task residual while removing its record',
    (tester) async {
      final (services, _, _) = await render(tester, unfinishedSavedFile: true);
      final residual = services.downloads.task('failed')!.savedPath!;
      await tester.tap(row('failed'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('downloads-remove-record')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('downloads-confirm-single-delete')),
      );
      await waitFor(tester, () => services.downloads.task('failed') == null);
      await tester.runAsync(() async {
        expect(await File(residual).exists(), true);
      });
    },
  );

  testWidgets(
    'Selected paused and failed downloads resume and pause without touching completed files',
    (tester) async {
      final (services, native, _) = await render(tester);
      await select(tester, 'paused');
      await tester.tap(row('failed'));
      await tester.pumpAndSettle();
      await tester.tap(action('resume'));
      await waitFor(
        tester,
        () => native.writer && services.downloads.task('failed')!.active,
      );
      expect(getCount(), findsNothing);
      await select(tester, 'paused');
      await tester.tap(row('failed'));
      await tester.pumpAndSettle();
      await tester.tap(action('pause'));
      await waitFor(
        tester,
        () =>
            services.downloads.activeCount == 0 &&
            services.downloads.task('failed')!.status == DownloadStatus.paused,
      );
      expect(native.begins.length, 1);
      expect(services.downloads.task('paused')!.status, DownloadStatus.paused);
      expect(
        services.downloads.task('completed-a')!.status,
        DownloadStatus.completed,
      );
      expect(
        services.downloads.task('completed-b')!.status,
        DownloadStatus.completed,
      );
    },
  );

  testWidgets(
    'New task and progress reordering do not move the selection to another file',
    (tester) async {
      final (services, native, _) = await render(tester);
      await select(tester, 'completed-a');
      native.finish = true;
      late String id;
      id = (await tester.runAsync(
        () => services.downloads.enqueue(
          const DownloadSpec(
            url: 'https://example.com/new',
            fileName: '新下载的资料.zip',
            expectedSize: 4,
          ),
        ),
      ))!;
      await waitFor(
        tester,
        () =>
            services.downloads.task(id)!.status == DownloadStatus.completed &&
            services.downloads.activeCount == 0,
      );
      expect(tester.widget<Text>(getCount()).data, '已选 1 项');
      expect(checkbox(tester, 'completed-a').value, isTrue);
      expect(checkbox(tester, id).value, isFalse);
    },
  );

  for (final (name, size, dark, scale) in [
    ('phone-downloads-selection', const Size(393, 864), false, 1.0),
    ('phone-downloads-selection-dark', const Size(393, 864), true, 1.0),
    (
      'landscape-downloads-selection-large-text',
      const Size(900, 430),
      false,
      1.5,
    ),
  ]) {
    testWidgets('$name selection layout', (tester) async {
      await render(tester, size: size, dark: dark, scale: scale);
      await select(tester, 'paused');
      await tester.tap(find.byKey(const Key('downloads-select-all')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<Text>(getCount()).data, '已选 4 项');
      await expectLater(
        find.byKey(const Key('selection-capture')),
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
