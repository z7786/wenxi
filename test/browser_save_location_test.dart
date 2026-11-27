import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'browser_test_support.dart';
import 'cloud_accounts_favorites_test.dart' show addFixtureAccount;

class _SaveConnector extends BrowserTestConnector {
  _SaveConnector() : super(CloudPlatform.tianyi);
  final saved = <(String, String)>[];
  final failures = <String, AppException>{};
  final pending = <String, Completer<List<CloudFile>>>{};
  final pages = <(String, String?)>[];
  bool saveFails = false;
  bool paginated = false;

  BrowseSession shareSession() => const BrowseSession(
    platform: CloudPlatform.tianyi,
    mode: BrowseMode.share,
    title: '分享文件',
    rootId: 'share-root',
  );

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    reads.add((session.familyId, parentId));
    if (failures[parentId] case final failure?) throw failure;
    if (pending[parentId] case final wait?) return wait.future;
    return switch (parentId) {
      'share-root' => [
        const CloudFile(id: 'shared', name: '分享资料.txt', size: 100),
      ],
      'personal-root' => [
        const CloudFile(id: 'work', name: '工作资料', isDirectory: true),
        const CloudFile(id: 'photos', name: '假期相册', isDirectory: true),
        const CloudFile(id: 'own-file', name: '我的资料.txt', size: 100),
      ],
      'work' => [const CloudFile(id: 'archive', name: '往年', isDirectory: true)],
      _ => [],
    };
  }

  @override
  Future<CloudFilePage> listPage(
    BrowseSession session,
    String parentId,
    Credential? credential, {
    String? cursor,
  }) async {
    pages.add((parentId, cursor));
    if (paginated && parentId == 'archive') {
      return CloudFilePage([
        for (var i = 0; i < 40; i++)
          CloudFile(id: 'folder-$i', name: '子目录 $i', isDirectory: true),
      ], nextCursor: 'next-page');
    }
    return CloudFilePage(await list(session, parentId, credential));
  }

  @override
  Future<void> saveShare(
    BrowseSession session,
    List<CloudFile> files,
    String target,
    Credential credential,
  ) async {
    if (saveFails) throw const AppException('转存失败');
    saved.add((credential.label, target));
  }

  @override
  Future<void> move(
    BrowseSession session,
    List<CloudFile> files,
    String target,
    Credential credential,
  ) async {}
}

const _archiveTrail = [
  ('personal-root', '全部文件'),
  ('work', '工作资料'),
  ('archive', '往年'),
];

Future<void> _menu(WidgetTester tester, String file, String action) async {
  await tester.tap(find.byTooltip('$file操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
}

BrowserPage _picker(WidgetTester tester) =>
    tester.widget<BrowserPage>(find.byType(BrowserPage).last);

void main() {
  late BrowserUiFixture fixture;
  late _SaveConnector connector;

  void browserTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      fixture = await BrowserUiFixture.create();
      connector = _SaveConnector();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = connector;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await body(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    });
  }

  Future<BrowseSession> personal() async =>
      fixture.services.cloud.personal(CloudPlatform.tianyi);

  browserTest(
    'Successful save opens the remembered nested directory on the next share',
    (tester) async {
      await fixture.render(tester, session: connector.shareSession());
      await _menu(tester, '分享资料.txt', '转存到我的网盘');
      expect(find.text('选择“全部文件”'), findsOneWidget);
      await tester.tap(find.text('工作资料'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('往年'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择“往年”'));
      await tester.pumpAndSettle();
      expect(connector.saved.single.$2, 'archive');
      expect(
        fixture.services.saveLocations.read(await personal()),
        _archiveTrail,
      );

      // Rebuild the share browser so no picker state survives in the UI.
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.render(tester, session: connector.shareSession());
      connector.reads.clear();
      await _menu(tester, '分享资料.txt', '转存到我的网盘');
      expect(_picker(tester).initialTrail, _archiveTrail);
      expect(find.text('选择“往年”'), findsOneWidget);
      expect(connector.reads, [('', 'archive')]);

      // Breadcrumbs still permit changing the target back to the root.
      await tester.tap(find.text('全部文件'));
      await tester.pumpAndSettle();
      expect(find.text('选择“全部文件”'), findsOneWidget);
      await tester.tap(find.text('选择“全部文件”'));
      await tester.pumpAndSettle();
      expect(fixture.services.saveLocations.read(await personal()), [
        ('personal-root', '全部文件'),
      ]);
    },
  );

  for (final fail in [false, true]) {
    browserTest(
      fail
          ? 'Failed save keeps the previous successful location'
          : 'Cancelling a restored picker keeps the previous location',
      (tester) async {
        final session = await personal();
        await fixture.services.saveLocations.remember(session, _archiveTrail);
        await fixture.render(tester, session: connector.shareSession());
        await _menu(tester, '分享资料.txt', '转存到我的网盘');
        if (fail) {
          await tester.tap(find.text('全部文件'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('假期相册'));
          await tester.pumpAndSettle();
          connector.saveFails = true;
          await tester.tap(find.text('选择“假期相册”'));
          await tester.pumpAndSettle();
          expect(find.textContaining('转存失败'), findsOneWidget);
        } else {
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.text('选择目标文件夹'), findsNothing);
        }
        expect(connector.saved, isEmpty);
        expect(fixture.services.saveLocations.read(session), _archiveTrail);
      },
    );
  }

  browserTest(
    'Unreadable remembered folder falls back to the root and preserves memory',
    (tester) async {
      final session = await personal();
      await fixture.services.saveLocations.remember(session, _archiveTrail);
      connector.failures['archive'] = const AppException('目录已删除');
      await fixture.render(tester, session: connector.shareSession());
      connector.reads.clear();
      await _menu(tester, '分享资料.txt', '转存到我的网盘');
      expect(find.text('选择“全部文件”'), findsOneWidget);
      expect(find.text('工作资料'), findsOneWidget);
      expect(connector.reads, [('', 'archive'), ('', 'personal-root')]);
      expect(fixture.services.saveLocations.read(session), _archiveTrail);
    },
  );

  browserTest(
    'Login expiry remains an account error instead of choosing another folder',
    (tester) async {
      await fixture.services.saveLocations.remember(
        await personal(),
        _archiveTrail,
      );
      connector.failures['archive'] = const AccountLoginRequired('登录已过期');
      await fixture.render(tester, session: connector.shareSession());
      connector.reads.clear();
      await _menu(tester, '分享资料.txt', '转存到我的网盘');
      expect(find.text('选择目标文件夹'), findsNothing);
      expect(find.textContaining('登录已过期'), findsOneWidget);
      expect(connector.reads, [('', 'archive')]);
    },
  );

  browserTest(
    'Another account and ordinary move do not reuse a saved destination',
    (tester) async {
      final first = await personal();
      await fixture.services.saveLocations.remember(first, _archiveTrail);
      final vault = fixture.services.vault;
      final second = await addFixtureAccount(
        vault,
        CloudPlatform.tianyi,
        '第二账号',
        2,
      );
      await vault.activate(CloudPlatform.tianyi, second);
      await fixture.render(tester, session: connector.shareSession());
      await _menu(tester, '分享资料.txt', '转存到我的网盘');
      expect(_picker(tester).session.accountId, second);
      expect(_picker(tester).initialTrail, isNull);
      expect(find.text('选择“全部文件”'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());

      await vault.activate(CloudPlatform.tianyi, first.accountId!);
      await fixture.render(tester, session: first);
      await _menu(tester, '我的资料.txt', '移动');
      expect(_picker(tester).initialTrail, isNull);
      expect(find.text('选择“全部文件”'), findsOneWidget);
      expect(fixture.services.saveLocations.read(first), _archiveTrail);
    },
  );

  browserTest('Restoring reads one page and retains the next-page cursor', (
    tester,
  ) async {
    await fixture.services.saveLocations.remember(
      await personal(),
      _archiveTrail,
    );
    connector.paginated = true;
    await fixture.render(tester, session: connector.shareSession());
    connector.pages.clear();
    await _menu(tester, '分享资料.txt', '转存到我的网盘');
    expect(_picker(tester).initialCursor, 'next-page');
    expect(connector.pages, [('archive', null)]);
    expect(find.text('选择“往年”'), findsOneWidget);
  });

  browserTest(
    'Cancelling while restoring does not issue a fallback root request',
    (tester) async {
      final session = await personal();
      await fixture.services.saveLocations.remember(session, _archiveTrail);
      final pending = connector.pending['archive'] = Completer();
      await fixture.render(tester, session: connector.shareSession());
      await tester.tap(find.byTooltip('分享资料.txt操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('转存到我的网盘'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('取消'), findsOneWidget);
      connector.reads.clear();
      await tester.tap(find.text('取消'));
      pending.completeError(const AppException('读取已取消'));
      await tester.pumpAndSettle();
      expect(find.text('选择目标文件夹'), findsNothing);
      expect(connector.reads, isEmpty);
      expect(fixture.services.saveLocations.read(session), _archiveTrail);
    },
  );
}
