import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/cloud_page.dart';
import 'package:asterlink/ui/login_page.dart';
import 'browser_test_support.dart';
import 'token_cloud_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [CloudPlatform.weiyun, CloudPlatform.wopan]) {
    testWidgets(
      '${platform.key} opens the official web login and keeps manual entry in the same account',
      (tester) async {
        final fixture = await BrowserUiFixture.create(platform: platform);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        try {
          await fixture.services.vault.removeCredential(platform);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(393, 864);
          await tester.pumpWidget(
            MaterialApp(home: Scaffold(body: CloudPage(fixture.services))),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(platform.label));
          await tester.tap(find.text(platform.label));
          await tester.pumpAndSettle();
          if (platform == CloudPlatform.wopan) {
            await tester.tap(find.text('切换网页登录'));
            await tester.pumpAndSettle();
          }
          final page = tester.widget<WebLoginPage>(find.byType(WebLoginPage));
          expect(page.target, WebLoginTarget.targets[platform]);
          expect(page.target.userAgent, contains('Windows NT'));
          expect(page.accountId, isNotNull);
          await tester.tap(find.text('手动'));
          await tester.pumpAndSettle();
          final manual = tester.widget<ManualLoginPage>(
            find.byType(ManualLoginPage),
          );
          expect(manual.platform, platform);
          expect(manual.accountId, page.accountId);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(WebLoginPage), findsOneWidget);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(fixture.services.vault.profiles(platform), isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }
      },
    );
  }

  for (final platform in [
    CloudPlatform.ilanzou,
    CloudPlatform.weiyun,
    CloudPlatform.wopan,
  ]) {
    testWidgets(
      '${platform.key} offers file operations and omits unsupported sharing in both menus',
      (tester) async {
        final fixture = await BrowserUiFixture.create(platform: platform);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        try {
          await fixture.services.vault.putCredential(
            platform,
            LoginCredentials.candidate(
              platform,
              platform == CloudPlatform.weiyun
                  ? 'uin=o12345; p_skey=fixture-cookie'
                  : refreshToken,
              null,
            ),
          );
          await fixture.render(tester);
          expect(find.byKey(const Key('browser-add-menu')), findsOneWidget);
          await tester.tap(find.byKey(const Key('browser-add-menu')));
          await tester.pumpAndSettle();
          expect(find.text('上传文件'), findsOneWidget);
          expect(find.text('新建文件夹'), findsOneWidget);
          Navigator.of(tester.element(find.text('新建文件夹'))).pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('02 旅行视频.mp4操作'));
          await tester.pumpAndSettle();
          expect(find.text('下载'), findsOneWidget);
          expect(find.text('重命名'), findsOneWidget);
          expect(find.text('移动'), findsOneWidget);
          expect(find.text('删除'), findsOneWidget);
          expect(find.text('创建分享'), findsNothing);
          Navigator.of(tester.element(find.text('重命名'))).pop();
          await tester.pumpAndSettle();
          await tester.longPress(find.text('02 旅行视频.mp4'));
          await tester.pumpAndSettle();
          expect(find.text('已选 1 项'), findsOneWidget);
          expect(find.text('下载'), findsOneWidget);
          expect(find.text('移动'), findsOneWidget);
          expect(find.text('删除'), findsOneWidget);
          expect(find.text('分享'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await fixture.close();
        }
      },
    );
  }
}
