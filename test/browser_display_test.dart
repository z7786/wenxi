import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/cloud_thumbnail.dart';
import 'package:asterlink/ui/common.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'browser_test_support.dart';
import 'support.dart';

class _FileListConnector extends BrowserTestConnector {
  _FileListConnector([this.files]) : super(CloudPlatform.tianyi);

  final List<CloudFile>? files;

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async =>
      files ??
      [
        const CloudFile(id: 'folder', name: 'Folder', isDirectory: true),
        const CloudFile(id: 'missing', name: 'A missing.txt'),
        CloudFile(
          id: 'new',
          name: 'B new.txt',
          modifiedAt: DateTime(2026, 9, 17, 10).toUtc().toIso8601String(),
        ),
        const CloudFile(
          id: 'middle',
          name: 'C middle.txt',
          modifiedAt: '20260916150000',
        ),
        CloudFile(
          id: 'old',
          name: 'D old.txt',
          modifiedAt:
              '${DateTime(2026, 9, 16, 10).millisecondsSinceEpoch ~/ 1000}',
        ),
      ];
}

class _EpisodeNameConnector extends BrowserTestConnector {
  _EpisodeNameConnector() : super(CloudPlatform.tianyi);

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async => [
    for (final episode in [19, 1, 10, 11, 2, 9])
      CloudFile(id: 'episode-$episode', name: '第$episode集.mp4'),
    const CloudFile(id: 'season-2', name: '第2季', isDirectory: true),
    const CloudFile(id: 'season-1', name: '第1季', isDirectory: true),
  ];
}

class _WaitingDownloadConnector extends BrowserTestConnector {
  _WaitingDownloadConnector([super.drive = CloudPlatform.tianyi]);
  int preparing = 0;
  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    preparing++;
    await RequestScope.wait(const Duration(hours: 1));
    throw const AppException('fixture did not release its download');
  }
}

class _PagedProgressConnector extends BrowserTestConnector {
  _PagedProgressConnector() : super(CloudPlatform.aliyun);
  final retry = Completer<void>(), complete = Completer<void>();

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    if (parentId != session.rootId) {
      OperationProgress.reportFiles(200);
      await retry.future;
      RequestScope.checkpoint();
      OperationProgress.reportFiles(200, waitingForRetry: true);
      await complete.future;
      RequestScope.checkpoint();
    }
    return super.list(session, parentId, credential);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late ThumbnailHttpClient images;
  final active = <BrowserUiFixture>[];
  void browserTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      debugNetworkImageHttpClientProvider = () => images;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final value in active) {
          await value.close();
        }
        active.clear();
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  setUp(() {
    images = ThumbnailHttpClient();
    binding.imageCache.clear();
    binding.imageCache.clearLiveImages();
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
  });
  Future<BrowserUiFixture> fixture(
    WidgetTester tester, {
    CloudPlatform platform = CloudPlatform.tianyi,
    String view = 'list',
    DateTime Function() clock = DateTime.now,
  }) async {
    final value = await BrowserUiFixture.create(
      platform: platform,
      view: view,
      clock: clock,
    );
    active.add(value);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    return value;
  }

  Future<void> setView(WidgetTester tester, String name) async {
    await tester.tap(find.byTooltip('显示方式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  browserTest(
    'Aliyun folder loading shows file counts and rate limit waiting',
    (tester) async {
      final value = await fixture(tester, platform: CloudPlatform.aliyun);
      final connector = _PagedProgressConnector();
      value.services.cloud.connectors[CloudPlatform.aliyun] = connector;
      await value.render(tester);
      await tester.tap(find.text('假期相册'));
      await tester.pump();
      expect(find.text('正在加载网盘文件…\n已读取 200 项'), findsOneWidget);
      connector.retry.complete();
      await tester.pump();
      expect(find.text('请求较频繁，正在等待重试…\n已读取 200 项'), findsOneWidget);
      connector.complete.complete();
      await tester.pumpAndSettle();
      expect(find.text('旧目录视频.mp4'), findsOneWidget);
      expect(find.textContaining('已读取 200 项'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in [BrowseMode.personal, BrowseMode.share]) {
    browserTest('Baidu $mode download waits for confirmation before enqueue', (
      tester,
    ) async {
      final value = await fixture(tester, platform: CloudPlatform.baidu);
      final connector = _WaitingDownloadConnector(CloudPlatform.baidu);
      value.services.cloud.connectors[CloudPlatform.baidu] = connector;
      await value.render(
        tester,
        session: BrowseSession(
          platform: CloudPlatform.baidu,
          mode: mode,
          title: '百度测试',
          rootId: 'personal-root',
        ),
      );
      Future<void> request() async {
        await tester.tap(find.byTooltip('使用说明.txt操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载'));
        await tester.pumpAndSettle();
      }

      await request();
      expect(find.text('百度网盘下载提示'), findsOneWidget);
      expect(value.services.downloads.tasks, isEmpty);
      expect(connector.preparing, 0);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.text('百度网盘下载提示'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(value.services.downloads.tasks, isEmpty);
      await request();
      await tester.tap(find.text('继续下载'));
      await tester.runAsync(
        () => until(() => value.services.downloads.tasks.isNotEmpty),
      );
      await tester.pumpAndSettle();
      expect(value.services.downloads.tasks, hasLength(1));
      expect(value.services.settings.hideBaiduDownloadNotice, isFalse);
    });
  }

  browserTest('Lanzou share dialog defaults to permanent validity', (
    tester,
  ) async {
    final value = await fixture(tester, platform: CloudPlatform.lanzou);
    await value.render(tester, size: const Size(800, 900));
    await tester.tap(find.byTooltip('使用说明.txt操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建分享'));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    );
    expect(dropdown.initialValue, 0);
    expect(find.text('永久'), findsWidgets);
    expect(find.text('7 天'), findsNothing);
    expect(find.text('提取码（可选）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> chooseFamily(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(const ValueKey('family-space')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(393, 864), const Size(1100, 780)]) {
    browserTest('File times appear in list, menu and grid at $size', (
      tester,
    ) async {
      final value = await fixture(tester);
      await value.render(tester, size: size);
      expect(find.text('2026-09-17 17:32'), findsOneWidget);
      final folder = find.ancestor(
        of: find.text('假期相册'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: folder, matching: find.textContaining('2026-')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('01 海边照片.jpg操作'));
      await tester.pumpAndSettle();
      expect(find.text('2026-09-17 17:32'), findsNWidgets(2));
      Navigator.of(tester.element(find.text('复制下载链接'))).pop();
      await tester.pumpAndSettle();
      await setView(tester, '大图标');
      await tester.ensureVisible(find.text('01 海边照片.jpg'));
      expect(find.text('2026-09-17 17:32'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  browserTest('Date sort compares mixed formats and keeps undated files last', (
    tester,
  ) async {
    final value = await fixture(tester);
    value.services.cloud.connectors[CloudPlatform.tianyi] =
        _FileListConnector();
    await value.render(tester, size: const Size(1100, 900));
    expect(find.text('2026-09-16 10:00'), findsOneWidget);
    expect(find.text('2026-09-16 15:00'), findsOneWidget);
    expect(find.text('2026-09-17 10:00'), findsOneWidget);

    void expectOrder(List<String> names) {
      for (var i = 1; i < names.length; i++) {
        expect(
          tester.getTopLeft(find.text(names[i - 1])).dy,
          lessThan(tester.getTopLeft(find.text(names[i])).dy),
        );
      }
    }

    for (final ascending in [true, false]) {
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('时间'));
      await tester.pumpAndSettle();
      expectOrder([
        'Folder',
        if (ascending) ...[
          'D old.txt',
          'C middle.txt',
          'B new.txt',
        ] else ...[
          'B new.txt',
          'C middle.txt',
          'D old.txt',
        ],
        'A missing.txt',
      ]);
    }
    expect(tester.takeException(), isNull);
  });

  for (final view in ['list', 'grid']) {
    browserTest('Date $view sort includes relative provider times', (
      tester,
    ) async {
      var now = DateTime(2026, 10, 29, 23, 59);
      final value = await fixture(tester, view: view, clock: () => now);
      value.services.cloud.connectors[CloudPlatform
          .tianyi] = _FileListConnector(const [
        CloudFile(id: 'folder', name: 'Folder', isDirectory: true),
        CloudFile(id: 'missing', name: 'A missing.txt'),
        CloudFile(id: 'now', name: 'B now.txt', modifiedAt: '刚刚'),
        CloudFile(
          id: 'yesterday',
          name: 'C yesterday.txt',
          modifiedAt: '昨天 12:30',
        ),
        // Lanzou returns these labels without a space before the clock time.
        CloudFile(
          id: 'day-before-late',
          name: 'C late.txt',
          modifiedAt: '前天06:17',
        ),
        CloudFile(
          id: 'day-before-early',
          name: 'C early.txt',
          modifiedAt: '前天06:16',
        ),
        CloudFile(
          id: 'three-days',
          name: 'D three days.txt',
          modifiedAt: '3 天前',
        ),
        CloudFile(id: 'two-hours', name: 'E two hours.txt', modifiedAt: '2小时前'),
        CloudFile(
          id: 'absolute',
          name: 'F absolute.txt',
          modifiedAt: '2026-10-30 06:00',
        ),
      ]);
      await value.render(tester, size: const Size(1100, 1200));

      void expectOrder({required bool ascending, bool refreshed = false}) {
        final dated = [
          'D three days.txt',
          'C early.txt',
          'C late.txt',
          'C yesterday.txt',
          if (refreshed) 'F absolute.txt',
          'E two hours.txt',
          'B now.txt',
          if (!refreshed) 'F absolute.txt',
        ];
        final names = [
          'Folder',
          ...(ascending ? dated : dated.reversed),
          'A missing.txt',
        ];
        for (var i = 1; i < names.length; i++) {
          final before = tester.getTopLeft(find.text(names[i - 1]));
          final after = tester.getTopLeft(find.text(names[i]));
          expect(
            before.dy < after.dy ||
                before.dy == after.dy && before.dx < after.dx,
            isTrue,
            reason: '${names[i - 1]} should precede ${names[i]} in $view view',
          );
        }
      }

      for (final ascending in [true, false]) {
        await tester.tap(find.byTooltip('排序'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('时间'));
        await tester.pumpAndSettle();
        expectOrder(ascending: ascending);
      }
      expect(find.text('刚刚'), findsOneWidget);
      expect(find.text('昨天 12:30'), findsOneWidget);
      expect(find.text('前天06:17'), findsOneWidget);
      expect(find.text('前天06:16'), findsOneWidget);
      expect(find.text('3 天前'), findsOneWidget);
      now = now.add(const Duration(days: 1));
      await setView(tester, view == 'list' ? '大图标' : '列表');
      expectOrder(ascending: false);
      await tester.tap(find.byTooltip('刷新文件'));
      await tester.pumpAndSettle();
      expectOrder(ascending: false, refreshed: true);
      expect(tester.takeException(), isNull);
    });

    browserTest('Date $view sort orders files modified within one second', (
      tester,
    ) async {
      final value = await fixture(tester, view: view);
      final second = DateTime.utc(2026, 10, 4, 7, 8, 9);
      value.services.cloud.connectors[CloudPlatform.tianyi] =
          _FileListConnector([
            const CloudFile(id: 'folder', name: 'Folder', isDirectory: true),
            CloudFile(
              id: 'late',
              name: 'A late.txt',
              modifiedAt: second
                  .add(const Duration(milliseconds: 900))
                  .toIso8601String(),
            ),
            CloudFile(
              id: 'near',
              name: 'B near.txt',
              modifiedAt: '${second.microsecondsSinceEpoch + 100002}',
            ),
            const CloudFile(id: 'missing', name: 'C missing.txt'),
            CloudFile(
              id: 'early',
              name: 'D early.txt',
              modifiedAt: second
                  .toLocal()
                  .add(const Duration(microseconds: 100001))
                  .toIso8601String(),
            ),
            CloudFile(
              id: 'middle',
              name: 'E middle.txt',
              modifiedAt: '${second.millisecondsSinceEpoch + 500}',
            ),
          ]);
      await value.render(tester, size: const Size(1100, 1000));

      for (final ascending in [true, false]) {
        await tester.tap(find.byTooltip('排序'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('时间'));
        await tester.pumpAndSettle();
        final dated = [
          'D early.txt',
          'B near.txt',
          'E middle.txt',
          'A late.txt',
        ];
        final names = [
          'Folder',
          ...(ascending ? dated : dated.reversed),
          'C missing.txt',
        ];
        for (var i = 1; i < names.length; i++) {
          final before = tester.getTopLeft(find.text(names[i - 1]));
          final after = tester.getTopLeft(find.text(names[i]));
          expect(
            before.dy < after.dy ||
                before.dy == after.dy && before.dx < after.dx,
            isTrue,
            reason: '${names[i - 1]} should precede ${names[i]} in $view view',
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final view in ['list', 'grid']) {
    browserTest('Name $view sort compares episode numbers in both directions', (
      tester,
    ) async {
      final value = await fixture(tester, view: view);
      value.services.cloud.connectors[CloudPlatform.tianyi] =
          _EpisodeNameConnector();
      await value.render(tester, size: const Size(1100, 1200));

      void expectOrder(List<String> names) {
        for (var i = 1; i < names.length; i++) {
          final before = tester.getTopLeft(find.text(names[i - 1]));
          final after = tester.getTopLeft(find.text(names[i]));
          expect(
            before.dy < after.dy ||
                before.dy == after.dy && before.dx < after.dx,
            isTrue,
            reason: '${names[i - 1]} should precede ${names[i]} in $view view',
          );
        }
      }

      expectOrder([
        '第1季',
        '第2季',
        for (final episode in [1, 2, 9, 10, 11, 19]) '第$episode集.mp4',
      ]);
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('名称'));
      await tester.pumpAndSettle();
      expectOrder([
        '第2季',
        '第1季',
        for (final episode in [19, 11, 10, 9, 2, 1]) '第$episode集.mp4',
      ]);
      expect(tester.takeException(), isNull);
    });

    for (final size in [const Size(393, 1200), const Size(1100, 1200)]) {
      browserTest(
        'Name $view sort uses pinyin and keeps folders first at $size',
        (tester) async {
          final value = await fixture(tester, view: view);
          value.services.cloud.connectors[CloudPlatform.tianyi] =
              _FileListConnector(const [
                CloudFile(id: 'folder-z', name: '资料', isDirectory: true),
                CloudFile(id: 'file-z', name: '资料10.txt'),
                CloudFile(id: 'folder-g', name: '工作', isDirectory: true),
                CloudFile(id: 'file-a10', name: '阿里10.txt'),
                CloudFile(id: 'folder-a', name: '阿里', isDirectory: true),
                CloudFile(id: 'file-g', name: '工作.txt'),
                CloudFile(id: 'file-t1', name: '同1.txt'),
                CloudFile(id: 'file-t01', name: '童01.txt'),
                CloudFile(id: 'file-a2', name: '阿里2.txt'),
              ]);
          await value.render(tester, size: size);

          void expectOrder(List<String> names) {
            for (var i = 1; i < names.length; i++) {
              final before = tester.getTopLeft(find.text(names[i - 1]));
              final after = tester.getTopLeft(find.text(names[i]));
              expect(
                before.dy < after.dy ||
                    before.dy == after.dy && before.dx < after.dx,
                isTrue,
                reason:
                    '${names[i - 1]} should precede ${names[i]} in $view view',
              );
            }
          }

          expectOrder([
            '阿里',
            '工作',
            '资料',
            '阿里2.txt',
            '阿里10.txt',
            '工作.txt',
            '同1.txt',
            '童01.txt',
            '资料10.txt',
          ]);
          await tester.tap(find.byTooltip('排序'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('名称'));
          await tester.pumpAndSettle();
          expectOrder([
            '资料',
            '工作',
            '阿里',
            '资料10.txt',
            '同1.txt',
            '童01.txt',
            '工作.txt',
            '阿里10.txt',
            '阿里2.txt',
          ]);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  browserTest(
    'Batch download returns to browsing while links prepare in independent queue rows',
    (tester) async {
      final value = await fixture(tester);
      final connector = _WaitingDownloadConnector();
      value.services.cloud.connectors[CloudPlatform.tianyi] = connector;
      await value.render(tester, size: const Size(1100, 780));
      for (final name in ['使用说明.txt', '02 旅行视频.mp4']) {
        final row = find.ancestor(
          of: find.text(name),
          matching: find.byType(ListTile),
        );
        await tester.tap(
          find.descendant(of: row, matching: find.byType(Checkbox)),
        );
        await tester.pump();
      }
      await tester.tap(find.text('下载'));
      await tester.runAsync(() => until(() => connector.preparing == 2));
      await tester.pumpAndSettle();
      expect(find.text('正在添加下载任务…'), findsNothing);
      expect(find.text('已添加 2 个下载任务'), findsOneWidget);
      expect(value.services.downloads.tasks, hasLength(2));
      expect(
        value.services.downloads.tasks.every(
          (task) => task.spec.needsPreparation,
        ),
        isTrue,
      );
      expect(find.text('已选 2 项'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DownloadsPage(value.services))),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('02 旅行视频.mp4'));
      await tester.pumpAndSettle();
      final copy = find.ancestor(
        of: find.text('复制下载链接'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(copy).enabled, isFalse);
      expect(find.byKey(const Key('download-stream-play')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final view in ['list', 'grid']) {
    browserTest('Visible multi-select supports empty selection in $view', (
      tester,
    ) async {
      final value = await fixture(tester, view: view);
      await value.render(tester);
      expect(find.text('多选'), findsOneWidget);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      final download = find.widgetWithText(TextButton, '下载');
      expect(tester.widget<TextButton>(download).onPressed, isNull);
      final reads = value.connector.reads.length;
      await tester.tap(find.text('假期相册'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(value.connector.reads, hasLength(reads));
      await tester.tap(find.text('假期相册'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 6 项'), findsOneWidget);
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('多选'), findsOneWidget);
      expect(find.text('已选 0 项'), findsNothing);
      await tester.tap(find.text('假期相册'));
      await tester.pumpAndSettle();
      expect(value.connector.reads.last.$2, 'photos');
      expect(tester.takeException(), isNull);
    });
  }

  browserTest(
    'Changing a dedicated search clears selection before selecting the new results',
    (tester) async {
      final value = await fixture(tester);
      await value.render(tester);
      await tester.tap(find.byKey(const Key('browser-search-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('browser-search-input')),
        '旧目录',
      );
      await tester.tap(find.byKey(const Key('browser-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('browser-search-input')),
        '工作',
      );
      await tester.tap(find.byKey(const Key('browser-search-submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.text('全选'), findsOneWidget);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('多选'), findsOneWidget);
      expect(find.text('已选 1 项'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Grid selection and sorting survive display changes and the preference reopens',
    (tester) async {
      final value = await fixture(tester);
      await value.render(tester);
      expect(find.byType(GridView), findsNothing);
      await setView(tester, '大图标');
      expect(find.byType(GridView), findsOneWidget);
      expect(
        value.services.settings.browserDisplayFor(CloudPlatform.tianyi).view,
        'grid',
      );
      expect(
        value.services.settings.browserDisplayFor(CloudPlatform.quark).view,
        'list',
      );
      final folderPosition = tester.getTopLeft(find.text('假期相册'));
      final photoPosition = tester.getTopLeft(find.text('01 海边照片.jpg'));
      expect(folderPosition.dy, lessThan(photoPosition.dy));
      await tester.longPress(find.text('01 海边照片.jpg'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await setView(tester, '列表');
      expect(find.text('已选 1 项'), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      await tester.tap(find.byTooltip('取消选择'));
      await setView(tester, '大图标');
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大小'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('大小'));
      await tester.pumpAndSettle();
      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(grid.semanticChildCount, 6);
      await tester.pumpWidget(const SizedBox.shrink());
      await value.render(tester);
      expect(find.byType(GridView), findsOneWidget);
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      expect(find.text('↓ 降序'), findsOneWidget);
      expect(
        value.services.settings.browserDisplayFor(CloudPlatform.tianyi).sort,
        'size',
      );
      await tester.tap(find.text('大小'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [CloudPlatform.tianyi, CloudPlatform.c139]) {
    browserTest(
      '${platform.name} space switching clears old folder, search and selection',
      (tester) async {
        final value = await fixture(tester, platform: platform, view: 'grid');
        await value.render(tester);
        await tester.tap(find.text('假期相册'));
        await tester.pumpAndSettle();
        await tester.longPress(find.text('旧目录视频.mp4'));
        await tester.pumpAndSettle();
        expect(find.text('已选 1 项'), findsOneWidget);
        await chooseFamily(tester, '家人的云盘');
        expect(value.connector.reads.last, (
          '12002',
          platform == CloudPlatform.tianyi ? '' : 'root-12002',
        ));
        expect(find.text('已选 1 项'), findsNothing);
        expect(find.byKey(const Key('browser-search-entry')), findsOneWidget);
        expect(find.byKey(const Key('cloud-search-page')), findsNothing);
        expect(find.text('旧目录视频.mp4'), findsNothing);
        expect(find.byTooltip('新建文件夹'), findsNothing);
        await tester.tap(find.byTooltip('02 旅行视频.mp4操作'));
        await tester.pumpAndSettle();
        expect(find.text('重命名'), findsNothing);
        expect(find.text('删除'), findsNothing);
        expect(find.text('创建分享'), findsNothing);
        expect(find.text('复制下载链接'), findsOneWidget);
        expect(find.text('预览 / 文件详情'), findsOneWidget);
        Navigator.of(tester.element(find.text('复制下载链接'))).pop();
        await tester.pumpAndSettle();
        await chooseFamily(tester, '周末相册');
        expect(value.connector.reads.last.$1, '12001');
        await tester.tap(find.byKey(const ValueKey('personal-space')));
        await tester.pumpAndSettle();
        expect(value.connector.reads.last, ('', 'personal-root'));
        expect(find.byType(GridView), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  browserTest('No-family and failed discovery keep the current directory', (
    tester,
  ) async {
    final value = await fixture(tester);
    await value.render(tester);
    await tester.tap(find.text('假期相册'));
    await tester.pumpAndSettle();
    value.connector.spaces = [];
    await tester.tap(find.byKey(const ValueKey('family-space')));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前账号还没有家庭云'), findsOneWidget);
    expect(find.text('旧目录视频.mp4'), findsOneWidget);
    value.connector.familyFailure = const AppException('家庭云暂时不可用');
    await tester.tap(find.byKey(const ValueKey('family-space')));
    await tester.pumpAndSettle();
    expect(find.text('旧目录视频.mp4'), findsOneWidget);
    expect(value.connector.reads.last, ('', 'photos'));
    expect(tester.takeException(), isNull);
  });

  browserTest(
    'A late folder response cannot overwrite the newly selected family',
    (tester) async {
      final value = await fixture(tester);
      await value.render(tester);
      final pending = value.connector.pendingFolder =
          Completer<List<CloudFile>>();
      await tester.tap(find.text('假期相册'));
      await tester.pump();
      await chooseFamily(tester, '周末相册');
      pending.complete([const CloudFile(id: 'stale', name: '过期目录结果.txt')]);
      await tester.pumpAndSettle();
      expect(find.text('过期目录结果.txt'), findsNothing);
      expect(find.text('周末相册'), findsOneWidget);
      expect(find.text('01 海边照片.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Folder picking remains in the supplied family and hides view and space switches',
    (tester) async {
      final value = await fixture(tester, view: 'grid');
      final session = value.connector.familySession(
        value.connector.spaces.first,
      );
      await value.render(tester, session: session, picking: true);
      expect(find.byTooltip('显示方式'), findsNothing);
      expect(find.byKey(const ValueKey('personal-space')), findsNothing);
      expect(find.byKey(const ValueKey('family-space')), findsNothing);
      expect(find.byType(GridView), findsNothing);
      expect(find.text('01 海边照片.jpg'), findsNothing);
      expect(find.text('假期相册'), findsOneWidget);
      expect(value.connector.reads.last.$1, '12001');
      expect(find.text('选择“全部文件”'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Thumbnails decode images and video covers without credentials and safely fall back',
    (tester) async {
      const files = [
        CloudFile(
          id: 'image',
          name: '照片.jpg',
          thumbnailUrl: 'https://preview.example.test/photo.png',
        ),
        CloudFile(
          id: 'video',
          name: '视频.mp4',
          thumbnailUrl: 'https://preview.example.test/video.png',
        ),
        CloudFile(
          id: 'broken',
          name: '失败.jpg',
          thumbnailUrl: 'https://preview.example.test/broken.png',
        ),
        CloudFile(
          id: 'document',
          name: '文件.txt',
          thumbnailUrl: 'https://preview.example.test/original.txt',
        ),
        CloudFile(
          id: 'folder',
          name: '目录.jpg',
          isDirectory: true,
          thumbnailUrl: 'https://preview.example.test/folder.png',
        ),
        CloudFile(
          id: 'local',
          name: '本地.jpg',
          thumbnailUrl: 'file:///private/photo.jpg',
        ),
        CloudFile(
          id: 'secret',
          name: '凭据.jpg',
          thumbnailUrl: 'https://user:secret@preview.example.test/photo.png',
        ),
        CloudFile(
          id: 'relative',
          name: '手机.heic',
          thumbnailUrl: '//preview.example.test/mobile.png',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Wrap(
              children: [
                for (final file in files)
                  CloudThumbnail(
                    file,
                    CloudPlatform.tianyi,
                    key: ValueKey(file.id),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(images.requests.map((r) => r.uri.path).toSet(), {
        '/photo.png',
        '/video.png',
        '/broken.png',
        '/mobile.png',
      });
      for (final request in images.requests) {
        expect(request.headers.values.keys.toSet(), {'user-agent', 'referer'});
      }
      for (final id in ['image', 'video', 'relative']) {
        final raw = tester.widget<RawImage>(
          find.descendant(
            of: find.byKey(ValueKey(id)),
            matching: find.byType(RawImage),
          ),
        );
        expect(raw.image, isNotNull, reason: id);
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('broken')),
          matching: find.byType(FileGlyph),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('video')),
          matching: find.byIcon(CupertinoIcons.play_fill),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (size, scale, dark) in [
    (const Size(320, 700), 1.8, false),
    (const Size(393, 864), 1.0, true),
    (const Size(1100, 780), 1.0, false),
    (const Size(700, 360), 1.6, true),
  ]) {
    browserTest('List and grid fit $size with scale $scale', (tester) async {
      final value = await fixture(tester);
      await value.render(tester, size: size, scale: scale, dark: dark);
      expect(tester.takeException(), isNull);
      await setView(tester, '大图标');
      expect(find.byType(GridView), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(GridView), const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
