import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/cloud_favorites_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'app_context_menu_test.dart' show rightClick;
import 'browser_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  const names = [
    '旅行影像',
    '工作资料',
    '使用说明',
    '音乐收藏',
    '家人相册',
    '学习笔记',
    '阅读书单',
    'GitHub',
    '电影合集',
    '开源软件',
    '摄影素材',
    '每周备份',
    '系统镜像',
    '设计参考',
  ];
  late BrowserUiFixture fixture;
  late List<CloudFavorite> favorites;
  String? copiedText;
  Future<void> prepare(
    WidgetTester tester, {
    List<String> titles = names,
    int? count,
  }) async {
    copiedText = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    fixture = await BrowserUiFixture.create();
    final session = fixture.services.cloud.bindSession(
      fixture.connector.personalSession(),
    );
    favorites = [
      for (var i = 0; i < (count ?? titles.length); i++)
        CloudFavorite(
          id: 'favorite-$i',
          session: session,
          file: CloudFile(id: 'folder-$i', name: '原始目录 $i', isDirectory: true),
          directoryId: 'folder-$i',
          trail: [('personal-root', '全部文件')],
          createdAt: 10000 - i,
          customName: titles[i % titles.length],
        ),
    ];
    await fixture.services.store.put(
      'cloudFavorites',
      favorites.map((f) => f.toJson()).toList(),
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      final closing = fixture.close().then((_) => closed = true);
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue);
      await closing;
    });
  }

  Future<void> render(
    WidgetTester tester, {
    Size size = const Size(393, 780),
    bool dark = false,
    bool desktop = false,
    double scale = 1,
    bool enabled = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    await tester.pumpWidget(
      MaterialApp(
        theme:
            appTheme(
              dark ? Brightness.dark : Brightness.light,
              fontFamily: systemFont ? 'FixtureUI' : null,
            ).copyWith(
              platform: desktop
                  ? TargetPlatform.windows
                  : TargetPlatform.android,
            ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: RepaintBoundary(
                key: const Key('favorite-grid-capture'),
                child: Material(
                  borderRadius: BorderRadius.circular(18),
                  child: CloudFavoritesSummary(
                    fixture.services,
                    desktop: desktop,
                    enabled: enabled,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder tile(int index) =>
      find.byKey(Key('home-favorite-${favorites[index].id}'));
  Finder avatar(int index) =>
      find.byKey(Key('favorite-avatar-${favorites[index].id}'));
  Finder caption(int index) =>
      find.byKey(Key('favorite-caption-${favorites[index].id}'));
  final grid = find.byKey(const Key('home-favorites-grid'));

  testWidgets(
    'Android home previews three rows of four favorites and All retains copying',
    (tester) async {
      await prepare(tester);
      await render(tester);
      final layout =
          tester.widget<GridView>(grid).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount;
      expect(layout.crossAxisCount, 4);
      expect(find.byType(CircleAvatar), findsNWidgets(12));
      expect(tester.getSize(avatar(0)), const Size(40, 40));
      expect(tester.getCenter(avatar(0)).dy, tester.getCenter(avatar(3)).dy);
      expect(
        tester.getCenter(avatar(4)).dy,
        greaterThan(tester.getCenter(avatar(0)).dy),
      );
      expect(
        find.descendant(of: avatar(0), matching: find.text('旅')),
        findsOneWidget,
      );
      expect(tester.widget<Text>(caption(0)).data, '旅行影像');
      expect(tester.widget<Text>(caption(0)).maxLines, 1);
      expect(tester.widget<Text>(caption(0)).style?.fontSize, 11);
      expect(
        tester.getTopLeft(caption(0)).dy,
        greaterThan(tester.getBottomLeft(avatar(0)).dy),
      );
      expect(
        tester
            .widgetList<CircleAvatar>(find.byType(CircleAvatar))
            .map((a) => a.backgroundColor)
            .toSet()
            .length,
        greaterThan(4),
      );
      expect(tester.getCenter(avatar(8)).dy, tester.getCenter(avatar(11)).dy);
      expect(tile(11).hitTestable(), findsOneWidget);
      expect(tile(12), findsNothing);
      expect(tile(13), findsNothing);
      expect(find.byTooltip('复制名称'), findsNothing);
      expect(find.text('全部 14'), findsOneWidget);

      await tester.tap(find.byKey(const Key('parse-favorites')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), names[13]);
      await tester.pumpAndSettle();
      final copy = find.byKey(const Key('favorite-copy-favorite-13'));
      expect(copy.hitTestable(), findsOneWidget);
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copiedText, names[13]);
      expect(fixture.services.favorites.all, hasLength(14));
      expect(fixture.connector.reads, isEmpty);
      expect(find.byType(CloudFavoritesPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows favorites remain reachable with lazy scrolling past the visible rows',
    (tester) async {
      await prepare(tester, count: 200);
      await render(tester, desktop: true);
      expect(find.byType(CircleAvatar).evaluate().length, lessThan(40));
      final scrollable = find.descendant(
        of: grid,
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        tile(199),
        340,
        scrollable: scrollable,
        maxScrolls: 60,
      );
      await tester.pumpAndSettle();
      expect(tile(199).hitTestable(), findsOneWidget);
      final scrollbar = tester.widget<Scrollbar>(
        find.ancestor(of: grid, matching: find.byType(Scrollbar)).first,
      );
      expect(scrollbar.thumbVisibility, isTrue);
      // Removing items after scrolling must not leave the grid on a blank page.
      await fixture.services.store.put('cloudFavorites', [
        favorites.first.toJson(),
      ]);
      await tester.pumpAndSettle();
      expect(tile(0).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'initials preserve Unicode characters and stable colors after renaming',
    (tester) async {
      await prepare(
        tester,
        titles: ['  旅行', 'github', '👨‍👩‍👧‍👦 家人', '', '👩🏽‍💻这个收藏名称很长'],
      );
      await render(tester);
      expect(
        find.descendant(of: avatar(0), matching: find.text('旅')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: avatar(1), matching: find.text('G')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: avatar(2), matching: find.text('👨‍👩‍👧‍👦')),
        findsOneWidget,
      );
      expect(tester.widget<Text>(caption(3)).data, '原始目录 3');
      expect(tester.widget<Text>(caption(4)).data, '👩🏽‍💻这个收藏…');
      expect(tester.widget<Text>(caption(4)).semanticsLabel, favorites[4].name);
      expect(fixture.services.favorites.all[4].name, '👩🏽‍💻这个收藏名称很长');
      final color = tester.widget<CircleAvatar>(avatar(0)).backgroundColor;
      await fixture.services.favorites.rename(favorites.first.id, '新的名字');
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(caption(0)).data, '新的名字');
      expect(
        find.descendant(of: avatar(0), matching: find.text('新')),
        findsOneWidget,
      );
      expect(tester.widget<CircleAvatar>(avatar(0)).backgroundColor, color);
    },
  );

  for (final (size, desktop, scale, columns) in [
    (const Size(320, 780), false, 1.8, 4),
    (const Size(780, 393), false, 1.0, 4),
    (const Size(286, 780), true, 1.0, 3),
    (const Size(288, 780), true, 2.0, 1),
    (const Size(1000, 800), true, 1.0, 8),
  ]) {
    testWidgets('favorites adapt to $size at $scale text scale', (
      tester,
    ) async {
      await prepare(
        tester,
        titles: ['这是一个超过一行的收藏名称', 'OneLongEnglishBookmarkName', '旅行'],
        count: 6,
      );
      await render(tester, size: size, desktop: desktop, scale: scale);
      final layout =
          tester.widget<GridView>(grid).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount;
      expect(layout.crossAxisCount, columns);
      expect(
        tester.getRect(avatar(0)).right,
        lessThanOrEqualTo(tester.getRect(tile(0)).right),
      );
      expect(
        tester.getRect(caption(0)).bottom,
        lessThanOrEqualTo(tester.getRect(tile(0)).bottom),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'long press renames a home shortcut and a click opens its original folder',
    (tester) async {
      await prepare(tester, count: 2);
      await render(tester);
      await tester.longPress(tile(0));
      await tester.pumpAndSettle();
      expect(find.text('复制名称'), findsNothing);
      expect(find.text('复制分享链接'), findsNothing);
      await tester.tap(find.text('编辑收藏'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '我的照片');
      await tester.tap(find.byKey(const Key('favorite-details-save')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(caption(0)).data, '我的照片');
      await tester.tap(tile(0));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(fixture.connector.reads.last.$2, 'folder-0');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Windows shortcut right click retains rename and remove commands',
    (tester) async {
      await prepare(tester, count: 2);
      await render(tester, desktop: true);
      await rightClick(tester, tester.getCenter(tile(0)));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('编辑收藏'), findsOneWidget);
      expect(find.text('复制名称'), findsNothing);
      expect(find.text('复制分享链接'), findsNothing);
      await tester.tap(find.text('取消收藏'));
      await tester.pumpAndSettle();
      expect(fixture.services.favorites.all, hasLength(1));
      expect(tile(0), findsNothing);
      expect(tile(1), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('disabled favorites cannot open or edit while parsing is busy', (
    tester,
  ) async {
    await prepare(tester, count: 2);
    await render(tester, enabled: false);
    await tester.tap(tile(0));
    await tester.longPress(tile(0));
    await tester.pumpAndSettle();
    expect(find.byType(BrowserPage), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(fixture.connector.reads, isEmpty);
    expect(
      find.byKey(const Key('home-favorite-copy-favorite-0')),
      findsNothing,
    );
    await render(tester, desktop: true, enabled: false);
    expect(
      find.byKey(const Key('home-favorite-copy-favorite-0')),
      findsNothing,
    );
  });

  testWidgets(
    'Windows favorite copying is available only after opening the full list',
    (tester) async {
      await prepare(tester, count: 2);
      await render(tester, desktop: true);
      final copy = find.byKey(const Key('home-favorite-copy-favorite-0'));
      expect(copy, findsNothing);
      expect(find.byTooltip('复制名称'), findsNothing);
      await tester.longPress(tile(0));
      await tester.pumpAndSettle();
      expect(find.text('复制名称'), findsNothing);
      expect(find.text('复制分享链接'), findsNothing);
      expect(copiedText, isNull);
      Navigator.pop(tester.element(find.byType(BottomSheet)));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsNothing);
      expect(fixture.connector.reads, isEmpty);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.byKey(const Key('parse-favorites')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('favorite-copy-favorite-1')));
      await tester.pumpAndSettle();
      expect(copiedText, names[1]);
      expect(fixture.connector.reads, isEmpty);
      expect(find.byType(CloudFavoritesPage), findsOneWidget);
    },
  );

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? 'Windows' : 'Android'} share favorites copy the original link and extraction code only in the full list',
      (tester) async {
        await prepare(tester, count: 0);
        final link = ParsedLink(
          source: 'https://cloud.189.cn/t/fixture',
          url: 'https://cloud.189.cn/t/fixture',
          platform: CloudPlatform.tianyi,
          kind: LinkKind.cloudShare,
          shareId: 'fixture',
          passcode: 'A%2B+B',
        );
        final session = BrowseSession(
          platform: CloudPlatform.tianyi,
          mode: BrowseMode.share,
          title: '收藏分享',
          rootId: 'share-root',
          sourceLink: link,
        );
        await fixture.services.favorites.toggleShare(session);
        await fixture.services.favorites.toggle(
          session,
          const CloudFile(id: 'file', name: '收藏分享里的文件.pdf'),
          [('share-root', '分享文件')],
        );
        await render(tester, desktop: desktop);
        for (final favorite in fixture.services.favorites.all) {
          final copy = find.byKey(Key('home-favorite-copy-${favorite.id}'));
          expect(copy, findsNothing);
          expect(find.byType(BrowserPage), findsNothing);
        }
        expect(fixture.connector.reads, isEmpty);
        tester.view.physicalSize = const Size(320, 700);
        tester.platformDispatcher.textScaleFactorTestValue = 1.8;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('parse-favorites')));
        await tester.pumpAndSettle();
        for (final favorite in fixture.services.favorites.all) {
          copiedText = null;
          final copy = find.byKey(Key('favorite-copy-${favorite.id}'));
          await tester.ensureVisible(copy);
          await tester.pumpAndSettle();
          await tester.tap(copy);
          await tester.pumpAndSettle();
          expect(copiedText, '${link.url} 提取码：A%2B+B');
        }
        expect(fixture.connector.reads, isEmpty);
        expect(find.byType(CloudFavoritesPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Windows home mouse drag saves the same order shown in the full list',
    (tester) async {
      await prepare(tester, count: 4);
      await render(tester, desktop: true, size: const Size(900, 780));
      final start = tester.getCenter(avatar(0));
      final end = tester.getCenter(avatar(2));
      final mouse = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveTo(Offset.lerp(start, end, .5)!);
      await tester.pump(const Duration(milliseconds: 80));
      await mouse.moveTo(end);
      await tester.pump(const Duration(milliseconds: 80));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(fixture.services.favorites.sort, CloudFavoriteSort.manual);
      expect(fixture.services.favorites.all.map((favorite) => favorite.id), [
        'favorite-1',
        'favorite-2',
        'favorite-0',
        'favorite-3',
      ]);
      expect(find.byType(BrowserPage), findsNothing);
      expect(fixture.connector.reads, isEmpty);
      expect(
        tester.getCenter(avatar(1)).dx,
        lessThan(tester.getCenter(avatar(0)).dx),
      );
      await tester.tap(find.byKey(const Key('parse-favorites')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('favorite-favorite-1'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('favorite-favorite-0'))).dy,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android organize mode drags by its handle without opening a favorite',
    (tester) async {
      await prepare(tester, count: 4);
      await render(tester);
      await tester.tap(find.byKey(const Key('parse-favorites')));
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      await tester.tap(find.byKey(const Key('favorites-organize')));
      await tester.pumpAndSettle();
      expect(find.text('完成'), findsOneWidget);
      expect(find.byType(ReorderableDragStartListener), findsNWidgets(4));
      await tester.tap(find.byKey(const Key('favorite-favorite-0')));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsNothing);
      final start = tester.getCenter(
        find.byKey(const Key('favorite-drag-favorite-0')),
      );
      final end = tester.getCenter(
        find.byKey(const Key('favorite-drag-favorite-2')),
      );
      await tester.timedDragFrom(
        start,
        end - start + const Offset(0, 35),
        const Duration(milliseconds: 650),
      );
      await tester.pumpAndSettle();
      expect(fixture.services.favorites.all.map((favorite) => favorite.id), [
        'favorite-1',
        'favorite-2',
        'favorite-0',
        'favorite-3',
      ]);
      expect(fixture.connector.reads, isEmpty);
      await tester.tap(find.byKey(const Key('favorites-organize')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('favorite-copy-favorite-0')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(avatar(1)).dx,
        lessThan(tester.getCenter(avatar(0)).dx),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Home sorting and pin actions also update the collection list', (
    tester,
  ) async {
    await prepare(tester, titles: ['Zulu', 'Alpha', 'Beta']);
    await render(tester);
    await tester.tap(find.byTooltip('收藏排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名称排序'));
    await tester.pumpAndSettle();
    expect(fixture.services.favorites.sort, CloudFavoriteSort.name);
    expect(
      tester.getCenter(avatar(1)).dx,
      lessThan(tester.getCenter(avatar(0)).dx),
    );
    await tester.longPress(tile(0));
    await tester.pumpAndSettle();
    expect(find.text('复制名称'), findsNothing);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(fixture.services.favorites.all.first.id, 'favorite-0');
    expect(
      find.byKey(const Key('home-favorite-pin-favorite-0')),
      findsOneWidget,
    );
    await tester.longPress(tile(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
    expect(fixture.services.favorites.all.first.id, 'favorite-1');
    await tester.tap(find.byKey(const Key('parse-favorites')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Zulu的收藏操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('favorite-pin-favorite-0')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(fixture.services.favorites.all.first.id, 'favorite-0');
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'favorites icon grid ${dark ? 'dark' : 'light'} visual snapshot',
      (tester) async {
        await prepare(tester);
        await render(tester, dark: dark);
        if (systemFont) {
          await expectLater(
            find.byKey(const Key('favorite-grid-capture')),
            matchesGoldenFile(
              'goldens/favorites-grid-${dark ? 'dark' : 'light'}.png',
            ),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
