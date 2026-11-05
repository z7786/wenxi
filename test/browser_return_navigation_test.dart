import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/browser_return.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/transfers_page.dart';
import 'browser_test_support.dart';

class _ReturnConnector extends BrowserTestConnector {
  _ReturnConnector() : super(CloudPlatform.tianyi);
  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    reads.add((session.familyId, parentId));
    return [
      for (var i = 0; i < 50; i++)
        CloudFile(
          id: 'file-$i',
          name: '文件 ${i.toString().padLeft(2, '0')}.txt',
          parentId: parentId,
          size: 1000,
        ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [const Size(393, 864), const Size(1100, 850)]) {
    testWidgets(
      'Transfer shortcut returns to original directory and scroll without listing again at $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final fixture = (await tester.runAsync(BrowserUiFixture.create))!;
        final connector = _ReturnConnector();
        fixture.services.cloud.connectors[CloudPlatform.tianyi] = connector;
        final session = BrowseSession(
          platform: CloudPlatform.tianyi,
          mode: BrowseMode.share,
          title: '下载来源合集',
          rootId: 'root',
          sourceLink: ParsedLink(
            source: '',
            url: 'https://cloud.189.cn/t/fixture',
            kind: LinkKind.cloudShare,
            platform: CloudPlatform.tianyi,
            shareId: 'fixture',
          ),
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(Brightness.light),
              home: MainShell(fixture.services),
            ),
          );
          await tester.pumpAndSettle();
          final navigator = Navigator.of(
            tester.element(find.byType(MainShell)),
          );
          unawaited(
            navigator.push<void>(
              MaterialPageRoute(
                builder: (_) => BrowserPage(
                  fixture.services,
                  session,
                  initialTrail: const [('root', '全部文件'), ('season-2', '第二季')],
                ),
              ),
            ),
          );
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          expect(connector.reads.single.$2, 'season-2');
          final list = find
              .descendant(
                of: find.byType(BrowserPage),
                matching: find.byType(ListView),
              )
              .last;
          await tester.drag(list, const Offset(0, -400));
          await tester.pumpAndSettle();
          final before = tester.widget<ListView>(list).controller!.offset;
          expect(before, greaterThan(0));
          await tester.tap(find.byKey(const Key('browser-download-manager')));
          await tester.pumpAndSettle();
          expect(find.byType(TransfersPage), findsOneWidget);
          final shortcut = find.byKey(const Key('transfer-return-browser'));
          expect(shortcut.hitTestable(), findsOneWidget);
          expect(find.text('返回解析目录'), findsOneWidget);
          expect(fixture.services.browserReturn.value!.directory, '第二季');
          expect(fixture.services.browserReturn.value!.scrollOffset, before);
          for (var cycle = 0; cycle < 2; cycle++) {
            await tester.tap(shortcut);
            await tester.pumpAndSettle();
            expect(find.byType(BrowserPage), findsOneWidget);
            expect(fixture.services.browserReturn.value, isNull);
            expect(shortcut, findsNothing);
            expect(find.text('第二季'), findsOneWidget);
            expect(connector.reads.length, 1);
            final resumedList = find
                .descendant(
                  of: find.byType(BrowserPage),
                  matching: find.byType(ListView),
                )
                .last;
            expect(
              tester.widget<ListView>(resumedList).controller!.offset,
              closeTo(before, .01),
            );
            await tester.tap(find.byKey(const Key('browser-download-manager')));
            await tester.pumpAndSettle();
            expect(shortcut.hitTestable(), findsOneWidget);
          }
          fixture.services.transferTab.value = 1;
          await tester.pumpAndSettle();
          expect(shortcut, findsNothing);
          fixture.services.transferTab.value = 0;
          await tester.pumpAndSettle();
          expect(shortcut.hitTestable(), findsOneWidget);
          await tester.tap(shortcut);
          await tester.pumpAndSettle();
          Navigator.of(tester.element(find.byType(BrowserPage))).pop();
          await tester.pumpAndSettle();
          fixture.services.requestDownloadManager();
          await tester.pumpAndSettle();
          expect(shortcut, findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(fixture.close);
        }
      },
    );
  }

  test(
    'Return checkpoint copies directory collections without changing the source',
    () {
      final items = <CloudFile>[const CloudFile(id: 'one', name: 'one.txt')];
      final trail = <(String, String)>[('root', '全部文件'), ('folder', '目录')];
      final target = BrowserReturnTarget(
        session: const BrowseSession(
          platform: CloudPlatform.tianyi,
          mode: BrowseMode.share,
          title: 'fixture',
          rootId: 'root',
        ),
        items: items,
        trail: trail,
      );
      items.clear();
      trail.clear();
      expect(target.items.single.id, 'one');
      expect(target.directory, '目录');
    },
  );
}
