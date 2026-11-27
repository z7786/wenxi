import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/transfer/rapid_transfer_task.dart';
import 'support.dart';

RapidTransferTask task(String id, RapidTaskStatus status) {
  const source = BrowseSession(
    platform: CloudPlatform.tianyi,
    mode: BrowseMode.personal,
    title: '来源',
    rootId: '0',
    metadata: {'accountId': 'source'},
  );
  const target = BrowseSession(
    platform: CloudPlatform.pan123,
    mode: BrowseMode.personal,
    title: '目标',
    rootId: '0',
    metadata: {'accountId': 'target'},
  );
  final file = CloudFile(id: id, name: '$id.bin', parentId: '0', size: 3);
  return RapidTransferTask(
    id: id,
    source: source,
    target: target,
    parent: '0',
    folderName: '全部文件',
    selections: [file],
    entries: [
      RapidTransferEntry(
        file,
        [],
        status: status == RapidTaskStatus.completed
            ? RapidEntryStatus.uploaded
            : RapidEntryStatus.failed,
      ),
    ],
    status: status,
    scanned: true,
    createdAt: 1,
  );
}

void main() {
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final clock = Stopwatch()..start();
    while (!ready() && clock.elapsed < const Duration(seconds: 15)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(ready(), isTrue, reason: 'Cross transfer cleanup did not settle');
    await tester.pumpAndSettle();
  }

  Future<AppServices> render(
    WidgetTester tester, {
    bool failedTasks = true,
    bool invalidCache = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(393, 864);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    late Directory root;
    late AppServices services;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp(
        'asterlink-cross-cleanup-ui-',
      );
      final tasks = [
        if (failedTasks) ...[
          task('first', RapidTaskStatus.failed),
          task('second', RapidTaskStatus.interrupted),
        ],
        task('completed', RapidTaskStatus.completed),
      ];
      services = AppServices(
        store: StateStore.memory({
          'rapidTransferTasks': tasks.map((t) => t.toJson()).toList(),
        }),
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: FakeNative(),
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
      await services.rapidTransfers.initialize();
      for (final t in tasks) {
        final key = sha256.convert(utf8.encode(t.id)).toString();
        final cachePath = p.join(
          services.cacheDirectory.path,
          'cross-transfers',
          'relay-$key',
        );
        final payload = invalidCache && t.id == 'first'
            ? File(cachePath)
            : File(p.join(cachePath, 'entry', 'payload'));
        await payload.parent.create(recursive: true);
        await payload.writeAsString('abc');
      }
    });
    services.transferTab.value = 1;
    await tester.pumpWidget(AsterLinkApp(services, initialTab: 3));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final close = services.close().whenComplete(() => closed = true);
      await waitFor(tester, () => closed);
      await close;
      await tester.runAsync(() => root.delete(recursive: true));
    });
    return services;
  }

  Future<void> openCleanup(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清理失败跨盘传输'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty cleanup shows feedback without a confirmation dialog', (
    tester,
  ) async {
    final services = await render(tester, failedTasks: false);
    await openCleanup(tester);
    expect(find.text('暂无可清理的失败跨盘传输'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(services.rapidTransfers.task('completed'), isNotNull);
  });

  testWidgets('cleanup confirmation shows count and cancel keeps caches', (
    tester,
  ) async {
    final services = await render(tester);
    await openCleanup(tester);
    expect(find.textContaining('当前 2 个'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(services.rapidTransfers.tasks, hasLength(3));
    final cache = services.rapidTransfers.relay.cache;
    final count = await tester.runAsync(() => cache.list().length);
    expect(count, 3);
  });

  testWidgets('confirmed cleanup removes failed records and shows result', (
    tester,
  ) async {
    final services = await render(tester);
    await openCleanup(tester);
    await tester.tap(find.text('清理'));
    await tester.pump();
    expect(find.text('正在清理失败跨盘传输…'), findsOneWidget);
    await waitFor(
      tester,
      () =>
          services.rapidTransfers.tasks.length == 1 &&
          find.byType(AlertDialog).evaluate().isEmpty,
    );
    expect(find.text('已清理 2 条失败跨盘传输'), findsOneWidget);
    expect(services.rapidTransfers.task('completed'), isNotNull);
    final count = await tester.runAsync(
      () => services.rapidTransfers.relay.cache.list().length,
    );
    expect(count, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalid cache is retained with a visible partial failure', (
    tester,
  ) async {
    final services = await render(tester, invalidCache: true);
    await openCleanup(tester);
    await tester.tap(find.text('清理'));
    await waitFor(
      tester,
      () =>
          services.rapidTransfers.task('second') == null &&
          find.byType(AlertDialog).evaluate().isEmpty,
    );
    expect(services.rapidTransfers.task('first'), isNotNull);
    expect(services.rapidTransfers.task('completed'), isNotNull);
    expect(find.text('已清理 1 条记录，1 条暂未清理：中转缓存位置发生变化'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cleanup protects tasks resumed while confirmation is open', (
    tester,
  ) async {
    final services = await render(tester);
    await openCleanup(tester);
    services.rapidTransfers.task('first')!.status = RapidTaskStatus.pending;
    services.rapidTransfers.task('completed')!.status = RapidTaskStatus.failed;
    await tester.tap(find.text('清理'));
    await waitFor(
      tester,
      () =>
          services.rapidTransfers.task('second') == null &&
          find.byType(AlertDialog).evaluate().isEmpty,
    );
    expect(services.rapidTransfers.task('first')!.active, isTrue);
    expect(services.rapidTransfers.task('completed'), isNotNull);
    expect(find.text('已清理 1 条失败跨盘传输，状态变化的 1 条已跳过'), findsOneWidget);
  });
}
