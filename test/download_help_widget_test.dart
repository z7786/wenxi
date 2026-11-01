import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'package:asterlink/ui/resource_home_page.dart';
import 'browser_test_support.dart';

void main() {
  for (final (size, brightness, scale) in [
    (const Size(393, 864), Brightness.light, 1.0),
    (const Size(393, 864), Brightness.dark, 1.8),
    (const Size(1100, 780), Brightness.light, 1.8),
  ]) {
    testWidgets('Download help opens announcements and resources at $size '
        '$brightness scale $scale', (tester) async {
      final fixture = await BrowserUiFixture.create();
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      try {
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: appTheme(brightness),
            home: MainShell(fixture.services, initialTab: 3),
          ),
        );
        await tester.pumpAndSettle();

        Future<void> openHelp() async {
          await tester.tap(find.byKey(const Key('download-failure-help')));
          await tester.pumpAndSettle();
          expect(
            find.text('下载失败时，可查看 App 公告寻找解决办法，或使用「查找资源」功能更换网盘资源。'),
            findsOneWidget,
          );
          expect(find.text('查看公告'), findsOneWidget);
          expect(find.text('查找资源'), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        await openHelp();
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(navigator.currentState!.canPop(), isFalse);
        expect(find.byType(DownloadsPage), findsOneWidget);

        await openHelp();
        await tester.tap(find.byKey(const Key('download-help-announcements')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('announcements-page')), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.byType(DownloadsPage), findsOneWidget);

        await openHelp();
        await tester.tap(find.byKey(const Key('download-help-resources')));
        await tester.pumpAndSettle();
        expect(find.byType(ResourceHomePage), findsOneWidget);
        expect(find.byType(TextField), findsWidgets);
        expect(find.byType(DownloadsPage), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(navigator.currentState!.canPop(), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    });
  }
}
