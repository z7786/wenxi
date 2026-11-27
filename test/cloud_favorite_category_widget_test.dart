import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/cloud_favorites_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'browser_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> selectFolder(WidgetTester tester, String name) async {
    await tap(tester, find.byType(DropdownButtonFormField<String>));
    await tap(tester, find.text(name).last);
  }

  for (final (size, brightness, scale) in [
    (const Size(393, 864), Brightness.light, 1.0),
    (const Size(1100, 780), Brightness.dark, 1.0),
    (const Size(320, 780), Brightness.dark, 1.8),
  ]) {
    testWidgets('editing a favorite saves its name and category at $size', (
      tester,
    ) async {
      final fixture = await BrowserUiFixture.create();
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        final favorites = fixture.services.favorites;
        final session = fixture.services.cloud.bindSession(
          fixture.connector.personalSession(),
        );
        final file = (await fixture.connector.list(
          session,
          session.rootId,
          null,
        )).first;
        final folderId = await favorites.createFolder('相册');
        await favorites.toggle(session, file, [(session.rootId, '全部文件')]);
        await favorites.setPinned(favorites.all.single.id, true);
        final original = favorites.all.single;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(brightness),
            home: CloudFavoritesPage(fixture.services),
          ),
        );
        await tester.pumpAndSettle();
        await tap(tester, find.byTooltip('${original.name}的收藏操作'));
        await tap(tester, find.text('编辑收藏'));
        if (size.width == 320) {
          await tester.tap(find.byKey(const Key('favorite-edit-name')));
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pumpAndSettle();
        }
        await selectFolder(tester, '相册');
        await tester.enterText(
          find.byKey(const Key('favorite-edit-name')),
          '家庭照片',
        );
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        final edited = favorites.all.single;
        expect(edited.customName, '家庭照片');
        expect(edited.folderId, folderId);
        expect(edited.pinned, isTrue);
        expect(edited.file.toJson(), original.file.toJson());
        expect(edited.session.accountId, original.session.accountId);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        await tap(tester, find.byTooltip('家庭照片的收藏操作'));
        await tap(tester, find.text('编辑收藏'));
        await selectFolder(tester, '未分类');
        await tester.enterText(
          find.byKey(const Key('favorite-edit-name')),
          '取消的修改',
        );
        await tap(tester, find.text('取消'));
        expect(favorites.all.single.toJson(), edited.toJson());
        await tap(tester, find.byTooltip('家庭照片的收藏操作'));
        await tap(tester, find.text('编辑收藏'));
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('favorite-edit-name')))
              .controller!
              .text,
          '家庭照片',
        );
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>),
              )
              .initialValue,
          folderId,
        );
        await selectFolder(tester, '未分类');
        await tester.enterText(find.byKey(const Key('favorite-edit-name')), '');
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(favorites.all.single.folderId, isEmpty);
        expect(favorites.all.single.name, file.displayName);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    });
  }

  testWidgets(
    'adding favorites selects or creates a category and cancellation saves no favorite',
    (tester) async {
      final fixture = await BrowserUiFixture.create();
      addTearDown(tester.view.reset);
      try {
        final favorites = fixture.services.favorites;
        final album = await favorites.createFolder('相册');
        await fixture.render(tester);
        await tap(tester, find.byTooltip('假期相册操作'));
        await tap(tester, find.text('收藏'));
        await selectFolder(tester, '相册');
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        final folderFavorite = favorites.all.single;
        expect(folderFavorite.file.isDirectory, isTrue);
        expect(folderFavorite.folderId, album);
        await tap(tester, find.byTooltip('使用说明.txt操作'));
        await tap(tester, find.text('收藏'));
        await tap(tester, find.byKey(const Key('favorite-category-create')));
        await tester.enterText(find.byType(TextField).last, '阅读');
        await tap(tester, find.text('确定'));
        final reading = favorites.folders.singleWhere((f) => f.name == '阅读').id;
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byType(DropdownButtonFormField<String>),
              )
              .initialValue,
          reading,
        );
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(
          favorites.all.singleWhere((f) => f.file.id == 'notes').folderId,
          reading,
        );
        await tap(tester, find.byTooltip('工作资料操作'));
        await tap(tester, find.text('收藏'));
        await selectFolder(tester, '阅读');
        await tap(tester, find.text('取消'));
        expect(favorites.all, hasLength(2));
        await tap(tester, find.byTooltip('使用说明.txt操作'));
        await tap(tester, find.text('取消收藏'));
        expect(find.byKey(const Key('favorite-details-dialog')), findsNothing);
        expect(favorites.all.single.id, folderFavorite.id);
        final reopened = CloudFavorites(
          fixture.services.store,
          fixture.services.cloud,
        );
        expect(reopened.all.single.folderId, album);
        expect(reopened.folders.map((f) => f.name), ['相册', '阅读']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    },
  );

  testWidgets(
    'editing can create a category, reject duplicates and recover a deleted selection',
    (tester) async {
      final fixture = await BrowserUiFixture.create();
      addTearDown(tester.view.reset);
      try {
        final favorites = fixture.services.favorites;
        await fixture.render(tester);
        await tap(tester, find.byTooltip('假期相册操作'));
        await tap(tester, find.text('收藏'));
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        final original = favorites.all.single;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: CloudFavoritesPage(fixture.services),
          ),
        );
        await tester.pumpAndSettle();
        await tap(tester, find.byTooltip('${original.name}的收藏操作'));
        await tap(tester, find.text('编辑收藏'));
        await tester.enterText(
          find.byKey(const Key('favorite-edit-name')),
          '新相册',
        );
        await tap(tester, find.byKey(const Key('favorite-category-create')));
        await tester.enterText(find.byType(TextField).last, '照片');
        await tap(tester, find.text('确定'));
        final folderId = favorites.folders.single.id;
        await tap(tester, find.byKey(const Key('favorite-category-create')));
        await tester.enterText(find.byType(TextField).last, '照片');
        await tap(tester, find.text('确定'));
        expect(find.text('已存在同名文件夹'), findsOneWidget);
        expect(favorites.folders, hasLength(1));
        expect(favorites.all.single.customName, isEmpty);
        await favorites.deleteFolder(folderId);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const Key('favorite-details-save')),
              )
              .onPressed,
          isNull,
        );
        await selectFolder(tester, '未分类');
        await tester.enterText(
          find.byKey(const Key('favorite-edit-name')),
          List.filled(81, '名').join(),
        );
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(find.text('收藏名称最多 80 个字符'), findsOneWidget);
        expect(favorites.all.single.customName, isEmpty);
        await tester.enterText(
          find.byKey(const Key('favorite-edit-name')),
          '新相册',
        );
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(favorites.all.single.customName, '新相册');
        expect(favorites.all.single.folderId, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    },
  );
}
