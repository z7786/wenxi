import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/app_popup_menu.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/cloud_accounts_page.dart';
import 'package:asterlink/ui/cloud_favorites_page.dart';
import 'package:asterlink/ui/common.dart';
import 'package:asterlink/ui/loading_indicator.dart';
import 'package:asterlink/ui/native_password_login_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/recent_playback_page.dart';
import 'browser_test_support.dart';
import 'cloud_accounts_favorites_test.dart' show addFixtureAccount;

class _SwitchConnector extends BrowserTestConnector {
  _SwitchConnector() : super(CloudPlatform.tianyi);
  String? failOwner;
  final pendingRoots = <String, Completer<List<CloudFile>>>{};
  final accountReads = <(String, String, String)>[];
  final shares = <(String, ParsedLink)>[];

  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    shares.add((credential!.label, link));
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '分享文件',
      rootId: 'share-root',
      metadata: {'token': 'fixture-${credential.updatedAt}'},
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    final account = credential!;
    accountReads.add((account.label, session.familyId, parentId));
    if (account.label == failOwner) throw const AppException('测试账号暂时无法读取');
    if (parentId == session.rootId && pendingRoots[account.label] != null) {
      return pendingRoots[account.label]!.future;
    }
    return [
      ...await super.list(session, parentId, credential),
      CloudFile(
        id: 'owner-file',
        name: '${account.label}-${account.updatedAt}.mp4',
        parentId: parentId,
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const platform = CloudPlatform.tianyi;

  Future<void> tap(
    WidgetTester tester,
    Finder finder, {
    bool settle = true,
  }) async {
    await tester.tap(finder);
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> account(
    WidgetTester tester,
    String value, {
    bool settle = true,
  }) async {
    await tap(
      tester,
      find.byKey(const Key('browser-account-menu')),
      settle: settle,
    );
    final item = find.byWidgetPredicate(
      (widget) => widget is PopupMenuItem<String> && widget.value == value,
    );
    await tap(tester, item, settle: settle);
  }

  Future<void> scenario(
    WidgetTester tester,
    Future<void> Function(BrowserUiFixture fixture, _SwitchConnector connector)
    body,
  ) async {
    final fixture = await BrowserUiFixture.create();
    final connector = _SwitchConnector();
    fixture.services.cloud.connectors[platform] = connector;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    try {
      await body(fixture, connector);
    } finally {
      for (final pending in connector.pendingRoots.values) {
        if (!pending.isCompleted) pending.complete([]);
      }
      if (connector.pendingFolder case final pending?
          when !pending.isCompleted) {
        pending.complete([]);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.close();
    }
  }

  for (final mode in ['personal', 'family', 'share']) {
    testWidgets(
      'Quick account switch reloads the $mode session for its owner',
      (tester) => scenario(tester, (fixture, connector) async {
        final vault = fixture.services.vault;
        final second = await addFixtureAccount(vault, platform, '家庭账号', 10);
        final session = switch (mode) {
          'family' => connector.familySession(connector.spaces.first),
          'share' => BrowseSession(
            platform: platform,
            mode: BrowseMode.share,
            title: '分享文件',
            rootId: 'share-root',
            sourceLink: ParsedLink(
              source: 'https://cloud.189.cn/t/fixture',
              url: 'https://cloud.189.cn/t/fixture',
              kind: LinkKind.cloudShare,
              platform: platform,
              shareId: 'fixture',
              passcode: '1234',
            ),
          ),
          _ => connector.personalSession(),
        };
        await fixture.render(tester, session: session);
        await account(tester, 'account:$second');
        expect(vault.activeAccountId(platform), second);
        expect(find.text('家庭账号-10.mp4'), findsOneWidget);
        expect(connector.accountReads.last, (
          '家庭账号',
          '',
          mode == 'share' ? 'share-root' : 'personal-root',
        ));
        if (mode == 'share') {
          expect(connector.shares.single.$1, '家庭账号');
          expect(connector.shares.single.$2.passcode, '1234');
        }
        await tap(tester, find.byKey(const Key('browser-account-menu')));
        final menu = tester.widget<AppPopupMenuButton<String>>(
          find.byKey(const Key('browser-account-menu')),
        );
        expect(
          menu.actions.singleWhere((a) => a.selected).value,
          'account:$second',
        );
      }),
    );
  }

  testWidgets(
    'An old folder response cannot replace the newly selected account',
    (tester) => scenario(tester, (fixture, connector) async {
      final second = await addFixtureAccount(
        fixture.services.vault,
        platform,
        '家庭账号',
        10,
      );
      await fixture.render(tester);
      final old = connector.pendingFolder = Completer<List<CloudFile>>();
      await tap(tester, find.text('假期相册'), settle: false);
      expect(find.text('正在加载网盘文件…'), findsOneWidget);
      expect(find.byType(AppLoadingIndicator), findsAtLeastNWidgets(1));
      expect(
        tester.getCenter(find.byType(AppLoadingIndicator)).dx,
        tester.view.physicalSize.width / 2,
      );
      expect(
        tester.getCenter(find.text('正在加载网盘文件…')).dx,
        tester.view.physicalSize.width / 2,
      );
      await account(tester, 'account:$second', settle: false);
      await tester.pumpAndSettle();
      expect(find.text('家庭账号-10.mp4'), findsOneWidget);
      old.complete([const CloudFile(id: 'stale', name: '不应显示的旧文件.mp4')]);
      await tester.pumpAndSettle();
      expect(find.text('不应显示的旧文件.mp4'), findsNothing);
      expect(find.text('家庭账号-10.mp4'), findsOneWidget);
      expect(fixture.services.vault.activeAccountId(platform), second);
    }),
  );

  testWidgets(
    'Failed and cancelled account switches preserve the current login and folder',
    (tester) => scenario(tester, (fixture, connector) async {
      final vault = fixture.services.vault,
          first = vault.activeAccountId(platform);
      final second = await addFixtureAccount(vault, platform, '家庭账号', 10);
      await fixture.render(tester);
      await tap(tester, find.text('假期相册'));
      connector.failOwner = '家庭账号';
      await account(tester, 'account:$second');
      expect(vault.activeAccountId(platform), first);
      expect(find.text('旧目录视频.mp4'), findsOneWidget);
      connector.failOwner = null;
      final pending = connector.pendingRoots['家庭账号'] =
          Completer<List<CloudFile>>();
      await account(tester, 'account:$second', settle: false);
      expect(find.text('正在读取文件列表…'), findsOneWidget);
      expect(find.byType(AppLoadingIndicator), findsAtLeastNWidgets(1));
      await tap(tester, find.text('取消'));
      pending.complete([const CloudFile(id: 'late', name: '已取消的账号文件.mp4')]);
      await tester.pumpAndSettle();
      expect(vault.activeAccountId(platform), first);
      expect(find.text('旧目录视频.mp4'), findsOneWidget);
      expect(find.text('已取消的账号文件.mp4'), findsNothing);
    }),
  );

  testWidgets(
    'Current account can reload changed credentials while keeping its family space',
    (tester) => scenario(tester, (fixture, connector) async {
      final vault = fixture.services.vault,
          owner = vault.activeAccountId(platform)!;
      await fixture.render(
        tester,
        session: connector.familySession(connector.spaces.first),
      );
      await vault.putCredential(
        platform,
        Credential('更新账号', {'primary': 'fixture-new'}, updatedAt: 20),
      );
      await tester.pumpAndSettle();
      await account(tester, 'account:$owner');
      expect(find.text('更新账号-20.mp4'), findsOneWidget);
      expect(connector.accountReads.last.$2, connector.spaces.first.id);
      await tap(tester, find.byTooltip('刷新文件'));
      expect(find.textContaining('账号已变化'), findsNothing);
    }),
  );

  for (final size in [const Size(393, 864), const Size(1100, 780)]) {
    testWidgets(
      'Quick login update and add account preserve cancelled changes at $size',
      (tester) => scenario(tester, (fixture, connector) async {
        final vault = fixture.services.vault,
            owner = vault.activeAccountId(platform)!;
        await fixture.render(tester, size: size);
        await tap(tester, find.text('假期相册'));
        final beforeReads = connector.accountReads.length;
        await account(tester, 'login');
        expect(
          tester
              .widget<NativePasswordLoginPage>(
                find.byType(NativePasswordLoginPage),
              )
              .accountId,
          owner,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('旧目录视频.mp4'), findsOneWidget);
        expect(connector.accountReads.length, beforeReads);
        await account(tester, 'add');
        final added = tester
            .widget<NativePasswordLoginPage>(
              find.byType(NativePasswordLoginPage),
            )
            .accountId;
        expect(added, isNot(owner));
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(vault.profiles(platform), hasLength(1));
        expect(vault.activeAccountId(platform), owner);
        expect(find.text('旧目录视频.mp4'), findsOneWidget);
        await account(tester, 'login');
        // Simulate the existing login service saving a successful replacement.
        await vault.putCredential(
          platform,
          Credential('已更新', {'primary': 'fixture-updated'}, updatedAt: 30),
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('已更新-30.mp4'), findsOneWidget);
        tester.view.physicalSize = const Size(320, 700);
        tester.platformDispatcher.textScaleFactorTestValue = 1.8;
        await tester.pumpAndSettle();
        await tap(tester, find.byKey(const Key('browser-account-menu')));
        expect(find.text('更新当前账号').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }),
    );
  }

  testWidgets(
    'Home favorites open their stored directory and stay separate from recent playback',
    (tester) => scenario(tester, (fixture, connector) async {
      final services = fixture.services;
      final session = services.cloud.bindSession(connector.personalSession());
      await services.favorites.toggle(
        session,
        const CloudFile(
          id: 'nested-video',
          name: '旧目录视频.mp4',
          parentId: 'photos',
        ),
        [('personal-root', '全部文件'), ('photos', '假期相册')],
      );
      final favorite = services.favorites.all.single;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 864);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: ParsePage(services)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(ValueKey('home-favorite-${favorite.id}')),
      );
      expect(find.byIcon(CupertinoIcons.star_fill), findsOneWidget);
      await tap(tester, find.byKey(ValueKey('home-favorite-${favorite.id}')));
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(connector.accountReads.last.$3, 'photos');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '旧目录视频.mp4',
      );
      // The first back leaves the restored folder; the second leaves the browser.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('parse-favorites')));
      await tap(tester, find.byKey(const Key('parse-favorites')));
      expect(find.byType(CloudFavoritesPage), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('parse-recent')));
      await tap(tester, find.byKey(const Key('parse-recent')));
      expect(find.byType(RecentPlaybackPage), findsOneWidget);
      expect(find.byType(CloudFavoritesPage), findsNothing);
    }),
  );

  for (final size in [const Size(393, 864), const Size(1100, 780)]) {
    testWidgets(
      'Share link can be starred and reopened from home at $size',
      (tester) => scenario(tester, (fixture, connector) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        final services = fixture.services;
        final link = ParsedLink(
          source: 'fixture share',
          url: 'https://cloud.189.cn/t/fixture',
          kind: LinkKind.cloudShare,
          platform: platform,
          shareId: 'fixture',
          passcode: '1234',
        );
        final session = await services.cloud.share(link);
        await fixture.render(tester, session: session);
        await tap(tester, find.byTooltip('收藏分享链接'));
        expect(find.byTooltip('取消收藏分享链接'), findsOneWidget);
        final saved = services.favorites.all.single;
        expect(saved.isShareLink, isTrue);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(body: ParsePage(services)),
          ),
        );
        await tester.pumpAndSettle();
        final row = find.byKey(ValueKey('home-favorite-${saved.id}'));
        await tester.ensureVisible(row);
        await tap(tester, row);
        expect(find.byType(BrowserPage), findsOneWidget);
        expect(connector.shares, hasLength(2));
        expect(connector.shares.last.$2.passcode, '1234');
        expect(connector.accountReads.last.$3, 'share-root');
        await tap(tester, find.byTooltip('取消收藏分享链接'));
        expect(services.favorites.all, isEmpty);
      }),
    );
  }

  testWidgets(
    'Cloud account management opens from the top right menu',
    (tester) => scenario(tester, (fixture, _) async {
      await tester.pumpWidget(AsterLinkApp(fixture.services, initialTab: 2));
      await tester.pumpAndSettle();
      expect(find.text('账号管理'), findsNothing);
      expect(find.text('网盘收藏'), findsNothing);
      await tap(tester, find.byTooltip('更多操作'));
      await tap(tester, find.text('账号管理'));
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      final vault = fixture.services.vault;
      final previous = vault.activeAccountId(platform);
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('account-add-${platform.key}')),
        180,
        scrollable: find.descendant(
          of: find.byType(CloudAccountsPage),
          matching: find.byType(Scrollable),
        ),
      );
      await tap(tester, find.byKey(ValueKey('account-add-${platform.key}')));
      expect(find.byType(NativePasswordLoginPage), findsOneWidget);
      final owner = tester
          .widget<NativePasswordLoginPage>(find.byType(NativePasswordLoginPage))
          .accountId;
      expect(owner, isNotNull);
      expect(owner, isNot(previous));
      expect(vault.activeAccountId(platform), previous);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(CloudAccountsPage), findsOneWidget);
      expect(vault.credentialFor(platform, previous), isNotNull);
      expect(
        vault.store.data
            .obj('cloudAccounts')
            .obj(platform.key)
            .containsKey(owner),
        isFalse,
      );
    }),
  );

  testWidgets(
    'Busy progress survives cancellation, late work and a new small-screen dialog',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 420);
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final old = Completer<void>(), current = Completer<void>();
      final results = <int?>[];
      var runs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                child: const Text('执行'),
                onPressed: () async {
                  final run = ++runs;
                  final result = await busy(context, () async {
                    await OperationProgress.step(
                      OperationStage.verifyShare,
                      () async {},
                    );
                    await OperationProgress.step(
                      OperationStage.createTemporary,
                      () async {},
                    );
                    await OperationProgress.step(
                      run == 1
                          ? OperationStage.transfer
                          : OperationStage.downloadLink,
                      () => (run == 1 ? old : current).future,
                    );
                    return run;
                  }, label: '正在加载网盘文件…');
                  results.add(result);
                },
              ),
            ),
          ),
        ),
      );
      await tap(tester, find.text('执行'), settle: false);
      expect(find.text('正在转存文件…'), findsOneWidget);
      await tap(tester, find.text('取消'));
      await tap(tester, find.text('执行'), settle: false);
      old.complete();
      await tester.pump();
      expect(find.text('正在获取下载链接…'), findsOneWidget);
      expect(find.text('正在转存文件…'), findsNothing);
      current.complete();
      await tester.pumpAndSettle();
      expect(results, [null, 2]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
