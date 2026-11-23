import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/app_switch.dart';
import 'package:asterlink/ui/cloud_favorites_page.dart';
import 'package:asterlink/ui/cloud_page.dart';
import 'package:asterlink/ui/resource_preferences.dart';
import 'browser_test_support.dart';

void main() {
  final fixtures = <BrowserUiFixture>[];
  void reorderTest(String name, WidgetTesterCallback body) {
    testWidgets(name, (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 864);
      try {
        await body(tester);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final fixture in fixtures) {
          await fixture.close();
        }
        fixtures.clear();
      }
    });
  }

  Future<BrowserUiFixture> fixture(WidgetTester tester) async {
    final fixture = await BrowserUiFixture.create();
    fixtures.add(fixture);
    return fixture;
  }

  Future<void> drag(
    WidgetTester tester,
    Finder from,
    Finder to, {
    Duration hold = Duration.zero,
    PointerDeviceKind kind = PointerDeviceKind.touch,
    bool edge = false,
  }) async {
    final start = edge
        ? tester.getTopLeft(from) + const Offset(5, 5)
        : tester.getCenter(from);
    final end =
        start +
        Offset(0, tester.getCenter(to).dy - tester.getCenter(from).dy + 8);
    final gesture = await tester.startGesture(start, kind: kind);
    await tester.pump(hold);
    for (var step = 1; step <= 6; step++) {
      await gesture.moveTo(Offset.lerp(start, end, step / 6)!);
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  reorderTest(
    'organize creates a folder and moves an existing favorite into it',
    (tester) async {
      final f = await fixture(tester);
      await f.services.store.put('cloudFavorites', [
        CloudFavorite(
          id: 'favorite',
          session: f.connector.personalSession(),
          file: const CloudFile(id: 'a', name: '影片.mp4'),
          directoryId: '0',
          trail: [('0', '全部文件')],
          createdAt: 1,
        ).toJson(),
      ]);
      await tester.pumpWidget(
        MaterialApp(home: CloudFavoritesPage(f.services, organize: true)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('favorite-folder-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '电影');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(f.services.favorites.folders.single.name, '电影');
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('favorite-move-favorite')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SimpleDialogOption, '电影'));
      await tester.pumpAndSettle();
      final id = f.services.favorites.folders.single.id;
      expect(f.services.favorites.all.single.folderId, id);
      await tester.tap(find.text('未分类'));
      await tester.pumpAndSettle();
      expect(find.text('影片.mp4'), findsNothing);
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      expect(find.text('影片.mp4'), findsOneWidget);
    },
  );

  for (final (label, hold, kind, edge) in [
    ('immediate touch', Duration.zero, PointerDeviceKind.touch, false),
    (
      'held touch',
      const Duration(milliseconds: 800),
      PointerDeviceKind.touch,
      false,
    ),
    (
      'long held touch',
      const Duration(seconds: 2),
      PointerDeviceKind.touch,
      false,
    ),
    (
      'handle edge',
      const Duration(milliseconds: 800),
      PointerDeviceKind.touch,
      true,
    ),
    (
      'held mouse',
      const Duration(milliseconds: 800),
      PointerDeviceKind.mouse,
      false,
    ),
  ]) {
    reorderTest(
      'Cloud sort works with $label and persists the resulting order',
      (tester) async {
        final f = await fixture(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CloudListSettingsPage(f.services),
                    ),
                  ),
                  child: const Text('打开排序'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开排序'));
        await tester.pumpAndSettle();
        Finder handle(String name) => find.descendant(
          of: find.byKey(ValueKey('cloud-layout-$name')),
          matching: find.byType(ReorderableDragStartListener),
        );
        await drag(
          tester,
          handle('quark'),
          handle('guangya'),
          hold: hold,
          kind: kind,
          edge: edge,
        );
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        expect(
          (f.services.store.data.obj('cloudListPreferences')['order'] as List)
              .take(3),
          ['pan123', 'guangya', 'quark'],
        );
        expect(
          f.services.store.data.obj('cloudListPreferences')['hidden'],
          isEmpty,
        );
      },
    );
  }

  for (final edge in [false, true]) {
    reorderTest(
      'Search sort can hold and drag the ${edge ? 'edge' : 'center'} of the handle',
      (tester) async {
        final f = await fixture(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showResourcePrioritySheet(
                    context,
                    f.services.resourceSearch,
                  ),
                  child: const Text('打开排序'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开排序'));
        await tester.pumpAndSettle();
        final from = find.byKey(const ValueKey('resource-drag-Quark'));
        final to = find.byKey(const ValueKey('resource-drag-Tianyi'));
        await drag(
          tester,
          from,
          to,
          hold: const Duration(milliseconds: 800),
          edge: edge,
        );
        await tester.tap(find.byKey(const Key('resource-priority-save')));
        await tester.pumpAndSettle();
        expect(f.services.resourceSearch.cloudPriority.take(3), [
          CloudPlatform.uc,
          CloudPlatform.tianyi,
          CloudPlatform.quark,
        ]);
        expect(f.services.resourceSearch.disabledClouds, isEmpty);
      },
    );
  }

  reorderTest('Favorite sort can hold its handle without opening the item', (
    tester,
  ) async {
    final f = await fixture(tester);
    final session = f.services.cloud.bindSession(f.connector.personalSession());
    await f.services.store.put('cloudFavorites', [
      for (var i = 0; i < 4; i++)
        CloudFavorite(
          id: 'favorite-$i',
          session: session,
          file: CloudFile(id: 'folder-$i', name: '收藏 $i', isDirectory: true),
          directoryId: 'folder-$i',
          trail: [('personal-root', '全部文件')],
          createdAt: 100 - i,
        ).toJson(),
    ]);
    await tester.pumpWidget(MaterialApp(home: CloudFavoritesPage(f.services)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('favorites-organize')));
    await tester.pumpAndSettle();
    await drag(
      tester,
      find.byKey(const Key('favorite-drag-favorite-0')),
      find.byKey(const Key('favorite-drag-favorite-2')),
      hold: const Duration(milliseconds: 800),
    );
    expect(f.services.favorites.all.map((favorite) => favorite.id), [
      'favorite-1',
      'favorite-2',
      'favorite-0',
      'favorite-3',
    ]);
    expect(f.connector.reads, isEmpty);
  });

  reorderTest(
    'Scrolling ordinary cloud rows and toggling visibility do not reorder',
    (tester) async {
      final f = await fixture(tester);
      await tester.pumpWidget(
        MaterialApp(home: CloudListSettingsPage(f.services)),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ReorderableListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;
      await tester.drag(find.text('阿里云盘'), const Offset(0, -160));
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(60));
      await tester.drag(find.text('迅雷网盘'), const Offset(0, 200));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('cloud-visible-quark')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<AppSwitch>(
              find.byKey(const ValueKey('cloud-visible-quark')),
            )
            .value,
        isFalse,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('cloud-layout-quark'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('cloud-layout-pan123')))
              .dy,
        ),
      );
    },
  );
}
