import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/skeleton_loading.dart';
import 'browser_test_support.dart';
import 'cloud_accounts_favorites_test.dart' show addFixtureAccount;
import 'support.dart';

class _SearchConnector extends BrowserTestConnector {
  _SearchConnector() : super(CloudPlatform.tianyi);
  final pending = <String, Completer<List<CloudFile>>>{};
  final failures = <String, AppException>{};
  final downloaded = <(BrowseSession, CloudFile, Credential?)>[];
  final renamed = <(String, String)>[];
  final tree = <String, List<CloudFile>>{
    'personal-root': [
      const CloudFile(id: 'work', name: '工作资料', isDirectory: true),
      const CloudFile(id: 'photos', name: '假期相册', isDirectory: true),
      const CloudFile(
        id: 'root-report',
        name: '当前报告.txt',
        parentId: 'personal-root',
      ),
    ],
    'work': [
      const CloudFile(
        id: 'work-report',
        name: '季度报告.pdf',
        parentId: 'work',
        token: 'work-token',
        modifiedAt: '2026-10-09 10:00',
      ),
      const CloudFile(
        id: 'archive',
        name: '往年',
        parentId: 'work',
        isDirectory: true,
      ),
    ],
    'archive': [
      const CloudFile(
        id: 'archive-report',
        name: '年度报告.txt',
        parentId: 'archive',
        token: 'archive-token',
      ),
    ],
    'photos': [
      const CloudFile(
        id: 'photo-report',
        name: '报告.png',
        parentId: 'photos',
        token: 'photo-token',
      ),
    ],
  };

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    reads.add((session.familyId, parentId));
    if (credential?.label == '第二账号') {
      return [
        const CloudFile(
          id: 'second',
          name: '第二账号报告.txt',
          parentId: 'personal-root',
        ),
      ];
    }
    if (failures[parentId] case final failure?) throw failure;
    if (pending[parentId] case final wait?) return wait.future;
    return List.of(tree[parentId] ?? []);
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    downloaded.add((session, file, credential));
    await RequestScope.wait(const Duration(hours: 1));
    throw const AppException('Test download remains pending until teardown');
  }

  @override
  Future<void> rename(
    BrowseSession session,
    CloudFile file,
    String name,
    Credential? credential,
  ) async {
    renamed.add((file.parentId, file.id));
    tree[file.parentId] = [
      for (final entry in tree[file.parentId]!)
        if (entry.id == file.id)
          CloudFile.fromJson({...entry.toJson(), 'name': name})
        else
          entry,
    ];
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late BrowserUiFixture fixture;
  late _SearchConnector connector;

  void browserTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      fixture = await BrowserUiFixture.create();
      connector = _SearchConnector();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = connector;
      binding.imageCache.clear();
      binding.imageCache.clearLiveImages();
      debugNetworkImageHttpClientProvider = () => ThumbnailHttpClient();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
        debugNetworkImageHttpClientProvider = null;
      }
    });
  }

  Future<void> recursive(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('browser-search-entry')));
    await tester.pumpAndSettle();
  }

  Future<void> search(
    WidgetTester tester,
    String query, {
    bool wait = true,
  }) async {
    await tester.enterText(
      find.byKey(const Key('browser-search-input')),
      query,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('browser-search-submit')));
    if (wait) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> menu(WidgetTester tester, String file, String action) async {
    await tester.tap(find.byTooltip('$file操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await tester.pumpAndSettle();
  }

  browserTest(
    'Search opens a separate page, waits for submission and remembers history',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      expect(find.byKey(const Key('cloud-search-page')), findsOneWidget);
      expect(find.text('搜索历史'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('browser-search-input')),
        '报告',
      );
      await tester.pumpAndSettle();
      expect(find.text('当前报告.txt'), findsNothing);
      expect(find.text('季度报告.pdf'), findsNothing);
      expect(connector.reads.map((entry) => entry.$2), ['personal-root']);
      expect(connector.reads, hasLength(1));
      await tester.tap(find.byKey(const Key('browser-search-submit')));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
      expect(find.text('全部文件 / 工作资料 / 往年'), findsOneWidget);
      expect(find.text('季度报告.pdf'), findsOneWidget);
      expect(find.text('年度报告.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('返回文件列表'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cloud-search-page')), findsNothing);
      expect(find.text('当前报告.txt'), findsOneWidget);
      await recursive(tester);
      expect(find.text('搜索历史'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cloud-search-history-报告')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('browser-search-submit')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('cloud-search-history-报告')));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Empty pending search uses the skeleton then displays the first batch',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      await search(tester, '报告');
      final pending = connector.pending['personal-root'] =
          Completer<List<CloudFile>>();
      await tester.tap(find.byTooltip('重新搜索'));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byKey(const Key('cloud-search-skeleton')), findsOneWidget);
      pending.complete(connector.tree['personal-root']);
      await tester.pumpAndSettle();
      expect(find.byType(AppSkeleton), findsNothing);
      expect(find.text('当前报告.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'File type tabs search without a keyword and keep folder traversal enabled',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      await tester.tap(
        find.byKey(const ValueKey('cloud-search-type-document')),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 3 项'), findsOneWidget);
      expect(find.text('年度报告.txt'), findsOneWidget);
      expect(find.text('报告.png'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cloud-search-type-image')));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 1 项'), findsOneWidget);
      expect(find.text('报告.png'), findsOneWidget);
      await search(tester, '报告');
      await tester.tap(find.byKey(const ValueKey('cloud-search-type-all')));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Searching all files from a subfolder can be limited to that subfolder',
    (tester) async {
      await fixture.render(tester);
      await tester.tap(find.widgetWithText(ListTile, '工作资料'));
      await tester.pumpAndSettle();
      await recursive(tester);
      await search(tester, '报告');
      expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('browser-search-scope-folder')),
      );
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 2 项'), findsOneWidget);
      expect(find.text('全部文件 / 工作资料 / 往年'), findsOneWidget);
      expect(find.text('当前报告.txt'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('browser-search-scope-all')));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
      expect(find.text('报告.png'), findsOneWidget);
      await tester.tap(find.byTooltip('返回文件列表'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cloud-search-page')), findsNothing);
      expect(find.text('季度报告.pdf'), findsOneWidget);
      expect(find.text('工作资料'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest('Search history can be cleared from the dedicated page', (
    tester,
  ) async {
    await fixture.render(tester);
    await recursive(tester);
    await search(tester, '报告');
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('cloud-search-history-报告')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('清空搜索历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-search-history-报告')), findsNothing);
    expect(find.text('搜索过的关键词会保存在这里'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  browserTest(
    'A nested result keeps its download account, metadata and favorite location',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      await search(tester, '报告');
      await menu(tester, '年度报告.txt', '收藏');
      final favorite = fixture.services.favorites.all.single;
      expect(favorite.directoryId, 'archive');
      expect(favorite.trail, [
        ('personal-root', '全部文件'),
        ('work', '工作资料'),
        ('archive', '往年'),
      ]);
      expect(
        favorite.session.accountId,
        fixture.services.vault.activeAccountId(CloudPlatform.tianyi),
      );
      await menu(tester, '年度报告.txt', '下载');
      await tester.runAsync(() => until(() => connector.downloaded.isNotEmpty));
      final download = connector.downloaded.single;
      expect(download.$1.accountId, favorite.session.accountId);
      expect(download.$2.parentId, 'archive');
      expect(download.$2.token, 'archive-token');
      expect(download.$3!.label, '测试账号');
      await menu(tester, '年度报告.txt', '打开所在文件夹');
      expect(connector.reads.last.$2, 'archive');
      expect(find.text('工作资料'), findsOneWidget);
      expect(find.text('往年'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('browser-search-input')))
            .controller!
            .text,
        '年度报告.txt',
      );
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Opening a matching folder restores its actual breadcrumb trail',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      await search(tester, '往年');
      expect(find.text('全部文件 / 工作资料'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '往年'));
      await tester.pumpAndSettle();
      expect(connector.reads.last.$2, 'archive');
      expect(find.text('工作资料'), findsOneWidget);
      expect(find.text('年度报告.txt'), findsOneWidget);
      expect(find.byKey(const Key('browser-search-status')), findsNothing);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cloud-search-page')), findsOneWidget);
      expect(find.text('搜索完成 · 共 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'A missing located file restores the search entry and returns to results',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      await search(tester, '报告');
      connector.tree['archive'] = [];
      await menu(tester, '年度报告.txt', '打开所在文件夹');
      expect(find.text('文件夹为空'), findsOneWidget);
      expect(find.byKey(const Key('browser-search-entry')), findsOneWidget);
      expect(find.byKey(const Key('browser-search-input')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cloud-search-page')), findsOneWidget);
      expect(find.text('搜索完成 · 共 3 项'), findsOneWidget);
      expect(find.text('年度报告.txt'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Stopping preserves streamed results and rejects late directory responses',
    (tester) async {
      await fixture.render(tester);
      connector.pending['work'] = Completer();
      connector.pending['photos'] = Completer();
      await recursive(tester);
      await search(tester, '报告', wait: false);
      expect(find.text('正在搜索 · 已找到 1 项'), findsOneWidget);
      await tester.tap(find.byTooltip('停止搜索'));
      await tester.pumpAndSettle();
      expect(find.text('已停止搜索 · 保留 1 项'), findsOneWidget);
      for (final entry in connector.pending.entries) {
        entry.value.complete(connector.tree[entry.key]);
      }
      await tester.pumpAndSettle();
      expect(find.text('季度报告.pdf'), findsNothing);
      await tester.tap(find.byTooltip('重新搜索'));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Editing a pending query cancels old results until the next explicit search',
    (tester) async {
      await fixture.render(tester);
      connector.pending['work'] = Completer();
      connector.pending['photos'] = Completer();
      await recursive(tester);
      await search(tester, '报告', wait: false);
      await tester.enterText(
        find.byKey(const Key('browser-search-input')),
        '年度',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('browser-search-status')), findsNothing);
      for (final entry in connector.pending.entries) {
        entry.value.complete(connector.tree[entry.key]);
      }
      await tester.pumpAndSettle();
      expect(find.text('年度报告.txt'), findsNothing);
      await tester.tap(find.byKey(const Key('browser-search-submit')));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 1 项'), findsOneWidget);
      expect(find.text('年度报告.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Account switching clears pending search data and keeps the new account bound',
    (tester) async {
      final second = await addFixtureAccount(
        fixture.services.vault,
        CloudPlatform.tianyi,
        '第二账号',
        10,
      );
      await fixture.render(tester);
      connector.pending['work'] = Completer();
      connector.pending['photos'] = Completer();
      await recursive(tester);
      await search(tester, '报告', wait: false);
      await tester.tap(find.byTooltip('返回文件列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('切换或更新账号'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('第二账号'));
      await tester.pumpAndSettle();
      expect(
        fixture.services.vault.activeAccountId(CloudPlatform.tianyi),
        second,
      );
      for (final entry in connector.pending.entries) {
        entry.value.complete(connector.tree[entry.key]);
      }
      await tester.pumpAndSettle();
      expect(find.text('第二账号报告.txt'), findsOneWidget);
      expect(find.text('当前报告.txt'), findsNothing);
      expect(find.text('季度报告.pdf'), findsNothing);
      await recursive(tester);
      await search(tester, '报告');
      expect(find.text('搜索完成 · 共 1 项'), findsOneWidget);
      expect(find.text('第二账号报告.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'A changed login cannot reveal the cached list of an idle search page',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      await fixture.services.vault.putCredential(
        CloudPlatform.tianyi,
        Credential('更新的登录', {
          'primary': 'COOKIE_LOGIN_USER=new-fixture',
        }, updatedAt: 2),
      );
      await search(tester, '报告');
      expect(find.text('账号已变化，请重新打开文件列表'), findsOneWidget);
      expect(find.text('当前报告.txt'), findsNothing);
      expect(find.text('季度报告.pdf'), findsNothing);
      expect(connector.reads, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Identical names and IDs in different directories can be selected separately',
    (tester) async {
      connector.tree['work'] = [
        const CloudFile(id: 'repeated', name: '重复.txt', parentId: 'work'),
      ];
      connector.tree['photos'] = [
        const CloudFile(id: 'repeated', name: '重复.txt', parentId: 'photos'),
      ];
      await fixture.render(tester);
      await recursive(tester);
      await search(tester, '重复');
      await tester.tap(find.text('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重复.txt').first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(find.text('重复.txt').last);
      await tester.pumpAndSettle();
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '删除'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Renaming a nested result updates the correct parent and refreshes the search',
    (tester) async {
      await fixture.render(tester);
      await recursive(tester);
      await search(tester, '报告');
      await tester.tap(find.byTooltip('季度报告.pdf操作'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '设计.pdf',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(connector.renamed, [('work', 'work-report')]);
      expect(find.text('季度报告.pdf'), findsNothing);
      expect(find.text('搜索完成 · 共 3 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest(
    'Failed folders are explained and toolbar refresh retries the same search',
    (tester) async {
      connector.failures['photos'] = const AppException('网络暂时不可用');
      await fixture.render(tester);
      await recursive(tester);
      await search(tester, '报告');
      expect(find.text('部分文件夹未能读取 · 找到 3 项'), findsOneWidget);
      await tester.tap(find.byTooltip('查看搜索问题'));
      await tester.pumpAndSettle();
      expect(find.text('全部文件 / 假期相册'), findsOneWidget);
      expect(find.text('网络暂时不可用'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      connector.failures.clear();
      await tester.tap(find.byTooltip('重新搜索'));
      await tester.pumpAndSettle();
      expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  browserTest('Closing the page cancels pending search callbacks', (
    tester,
  ) async {
    await fixture.render(tester);
    connector.pending['work'] = Completer();
    connector.pending['photos'] = Completer();
    await recursive(tester);
    await search(tester, '报告', wait: false);
    await tester.pumpWidget(const SizedBox.shrink());
    for (final entry in connector.pending.entries) {
      entry.value.complete(connector.tree[entry.key]);
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 640), const Size(1100, 780)]) {
    for (final view in ['list', 'grid']) {
      browserTest('Recursive search fits $view at $size with large text', (
        tester,
      ) async {
        await fixture.services.updateBrowserDisplay(
          CloudPlatform.tianyi,
          view: view,
        );
        await fixture.render(tester, size: size, scale: 1.6, dark: true);
        await recursive(tester);
        await search(tester, '报告');
        expect(find.text('搜索完成 · 共 4 项'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('多选'));
        await tester.pumpAndSettle();
        expect(find.text('全选'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
