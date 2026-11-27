import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/app_switch.dart';
import 'package:asterlink/ui/mine_page.dart';
import 'browser_test_support.dart';
import 'support.dart';

class _WaitingConnector extends BrowserTestConnector {
  _WaitingConnector() : super(CloudPlatform.tianyi);
  int preparing = 0;
  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    preparing++;
    await RequestScope.wait(const Duration(hours: 1));
    throw const AppException('cancelled fixture');
  }
}

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    final desktop = platform == TargetPlatform.windows;
    testWidgets('$platform batch location and settings respect device policy', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fixture = await BrowserUiFixture.create();
      final connector = _WaitingConnector();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = connector;
      final original = '${fixture.directory.path}/original';
      final chosen = '${fixture.directory.path}/chosen';
      try {
        await fixture.services.updateSettings({
          'destination': original,
          'askDownloadDestination': true,
        });
        await fixture.services.store.put('recentDownloadDestinations', [
          chosen,
        ]);
        await fixture.render(tester, size: const Size(1100, 780));
        for (final name in ['使用说明.txt', '假期相册']) {
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
        await tester.pumpAndSettle();
        if (desktop) {
          expect(find.text('下载保存位置'), findsOneWidget);
          expect(fixture.services.downloads.tasks, isEmpty);
          expect(connector.preparing, 0);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(fixture.services.downloads.tasks, isEmpty);
          expect(find.text('已选 2 项'), findsOneWidget);
          await tester.tap(find.text('下载'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('download-location-recent')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(chosen));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('download-location-confirm')));
        }
        await tester.runAsync(() => until(() => connector.preparing == 2));
        await tester.pumpAndSettle();
        expect(find.text('下载保存位置'), findsNothing);
        expect(fixture.services.downloads.tasks, hasLength(2));
        expect(
          fixture.services.downloads.tasks.every(
            (task) => task.destination == (desktop ? chosen : original),
          ),
          isTrue,
        );
        expect(
          fixture.services.downloads.tasks.any(
            (task) => task.spec.relativePath == '假期相册',
          ),
          isTrue,
        );
        expect(fixture.services.settings.destination, original);

        // The explicit menu remains available on a computer with prompting off.
        await fixture.services.updateSettings({
          'askDownloadDestination': false,
        });
        await tester.tap(find.byTooltip('使用说明.txt操作'));
        await tester.pumpAndSettle();
        expect(find.text('下载到…'), desktop ? findsOneWidget : findsNothing);
        if (desktop) {
          await tester.tap(find.text('下载到…'));
          await tester.pumpAndSettle();
          expect(find.text('下载保存位置'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
        }
        expect(fixture.services.downloads.tasks, hasLength(2));
        await tester.pumpWidget(MaterialApp(home: MinePage(fixture.services)));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('下载保存目录'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final setting = find.byKey(
          const ValueKey('ask-download-destination-setting'),
        );
        expect(setting, desktop ? findsOneWidget : findsNothing);
        if (desktop) {
          await tester.ensureVisible(setting);
          await tester.tap(setting);
          await tester.pumpAndSettle();
          expect(fixture.services.settings.askDownloadDestination, isTrue);
          expect(tester.widget<AppSwitchListTile>(setting).value, isTrue);
        }
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.close();
      }
    });
  }
}
