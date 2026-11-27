import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/cloud_accounts_page.dart';
import 'package:asterlink/ui/cloud_favorites_page.dart';
import 'package:asterlink/ui/native_password_login_page.dart';
import 'browser_test_support.dart';
import 'cloud_accounts_favorites_test.dart' show addFixtureAccount;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Custom account name is saved and re-login targets the existing account',
    (tester) async {
      final fixture = await BrowserUiFixture.create();
      const platform = CloudPlatform.tianyi;
      final vault = fixture.services.vault;
      final id = vault.activeAccountId(platform)!;
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: CloudAccountsPage(fixture.services, platform: platform),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('测试账号的账号操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('自定义名称'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        await tester.enterText(find.byType(TextField), '我的工作网盘');
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(vault.profiles(platform).single.customName, '我的工作网盘');
        expect(find.text('我的工作网盘'), findsOneWidget);
        await tester.tap(find.byTooltip('我的工作网盘的账号操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新登录'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<NativePasswordLoginPage>(
                find.byType(NativePasswordLoginPage),
              )
              .accountId,
          id,
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(vault.profiles(platform).single.id, id);
        expect(vault.profiles(platform).single.name, '我的工作网盘');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    },
  );

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'Favorites menu saves folders and files, then opens the saved directory and highlights the file',
    (tester) async {
      final fixture = await BrowserUiFixture.create();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        await fixture.render(tester);
        await tap(tester, find.byTooltip('假期相册操作'));
        await tap(tester, find.text('收藏'));
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(fixture.services.favorites.all, hasLength(1));
        await tap(tester, find.text('假期相册'));
        await tap(tester, find.byTooltip('旧目录视频.mp4操作'));
        await tap(tester, find.text('收藏'));
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(fixture.services.favorites.all, hasLength(2));
        await tap(tester, find.byTooltip('网盘收藏'));
        await tap(tester, find.text('旧目录视频.mp4'));
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, '旧目录视频.mp4');
        expect(fixture.connector.reads.last.$2, 'photos');
        expect(find.text('假期相册'), findsOneWidget);
        await tap(tester, find.byTooltip('清除搜索，显示全部文件'));
        expect(field.controller!.text, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    },
  );

  for (final size in [const Size(393, 864), const Size(1100, 780)]) {
    testWidgets('Favorite custom names display, search and clear at $size', (
      tester,
    ) async {
      final fixture = await BrowserUiFixture.create();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        final services = fixture.services;
        final session = await services.cloud.personal(CloudPlatform.tianyi);
        await services.favorites.toggle(
          session,
          const CloudFile(id: 'photos', name: '假期相册', isDirectory: true),
          [(session.rootId, '全部文件')],
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: CloudFavoritesPage(services),
          ),
        );
        await tester.pumpAndSettle();
        await tap(tester, find.byTooltip('假期相册的收藏操作'));
        await tap(tester, find.text('编辑收藏'));
        final input = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(input, '工作照片');
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(find.text('工作照片'), findsOneWidget);
        expect(services.favorites.all.single.file.name, '假期相册');
        for (final query in ['假期相册', '工作照片']) {
          await tester.enterText(find.byType(TextField), query);
          await tester.pumpAndSettle();
          expect(
            find.byKey(
              ValueKey('favorite-${services.favorites.all.single.id}'),
            ),
            findsOneWidget,
          );
        }
        await tester.enterText(find.byType(TextField), '');
        await tester.pumpAndSettle();
        await tap(tester, find.text('工作照片'));
        expect(fixture.connector.reads.last.$2, 'photos');
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tap(tester, find.byTooltip('工作照片的收藏操作'));
        await tap(tester, find.text('编辑收藏'));
        expect(tester.widget<TextField>(input).controller!.text, '工作照片');
        await tester.enterText(input, '');
        await tap(tester, find.byKey(const Key('favorite-details-save')));
        expect(find.text('假期相册'), findsOneWidget);
        await services.favorites.rename(
          services.favorites.all.single.id,
          '工作照片',
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: CloudFavoritesSummary(services, desktop: size.width >= 900),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('工作照片'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    });

    testWidgets(
      'Account manager switches without discarding another login and cancels adding at $size',
      (tester) async {
        final fixture = await BrowserUiFixture.create();
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        try {
          final vault = fixture.services.vault, p = CloudPlatform.tianyi;
          final first = vault.activeAccountId(p)!;
          final second = await addFixtureAccount(vault, p, '家庭账号', 10);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(Brightness.light),
              home: CloudAccountsPage(fixture.services, platform: p),
            ),
          );
          await tester.pumpAndSettle();
          await tap(tester, find.byKey(ValueKey('account-$second')));
          expect(vault.activeAccountId(p), second);
          expect(vault.credentialFor(p, first), isNotNull);
          await tap(tester, find.byKey(ValueKey('account-add-${p.key}')));
          final login = tester.widget<NativePasswordLoginPage>(
            find.byType(NativePasswordLoginPage),
          );
          expect(login.accountId, isNot(second));
          expect(vault.credentialFor(p, login.accountId), isNull);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(vault.profiles(p), hasLength(2));
          expect(
            vault.store.data.obj('cloudAccounts').obj(p.key),
            hasLength(2),
          );
          tester.platformDispatcher.textScaleFactorTestValue = 1.8;
          await tester.pumpAndSettle();
          expect(
            find.byIcon(CupertinoIcons.checkmark_circle_fill),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }
      },
    );
  }
}
