import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'browser_test_support.dart';
import 'lanzou_pagination_test.dart' show pagedFixture, rootPages;
import 'lanzou_folder_support.dart';

void main() {
  late BrowserUiFixture app;
  late LanzouFolderFixture fixture;
  late BrowseSession session;
  late CloudFilePage first;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<void> render(WidgetTester tester, {String view = 'list'}) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      app = await BrowserUiFixture.create(
        platform: CloudPlatform.lanzou,
        view: view,
      );
      fixture = pagedFixture();
      app.services.cloud.connectors[CloudPlatform.lanzou] = fixture.connector;
      session = await app.services.cloud.share(fixture.folderLink());
      first = await app.services.cloud.listPage(session, session.rootId);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserPage(
          app.services,
          session,
          initialItems: first.files,
          initialCursor: first.nextCursor,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    app.close().then((_) => closed = true);
    while (!closed) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
  }

  for (final view in ['list', 'grid']) {
    testWidgets(
      'Browser $view fetches subsequent pages on scroll and keeps selection',
      (tester) async {
        await render(tester, view: view);
        try {
          expect(rootPages(fixture), ['1']);
          expect(find.byKey(const Key('browser-page-status')), findsOneWidget);
          expect(find.text('后页目标.zip'), findsNothing);
          await tester.tap(find.text('多选'));
          await settle(tester);
          expect(find.text('全选已加载'), findsOneWidget);
          await tester.tap(find.text('全选已加载'));
          await settle(tester);
          expect(find.text('已选 51 项'), findsOneWidget);
          final list = find
              .descendant(
                of: find.byType(BrowserPage),
                matching: view == 'grid'
                    ? find.byType(GridView)
                    : find.byType(ListView),
              )
              .last;
          final controller = view == 'grid'
              ? tester.widget<GridView>(list).controller!
              : tester.widget<ListView>(list).controller!;
          controller.jumpTo(controller.position.maxScrollExtent);
          await settle(tester);
          expect(rootPages(fixture), ['1']);
          await tester.tap(find.byKey(const Key('browser-load-more')));
          await settle(tester);
          expect(rootPages(fixture), ['1', '2']);
          expect(find.text('已选 51 项'), findsOneWidget);
          expect(find.text('全选已加载'), findsOneWidget);
          await tester.tap(find.text('全选已加载'));
          await settle(tester);
          expect(find.text('已选 52 项'), findsOneWidget);
          await tester.tap(find.text('完成'));
          await settle(tester);
          controller.jumpTo(0);
          controller.jumpTo(controller.position.maxScrollExtent);
          await settle(tester);
          expect(rootPages(fixture), ['1', '2', '3']);
          expect(find.byKey(const Key('browser-page-status')), findsNothing);
          expect(find.byKey(const Key('browser-load-more')), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await finish(tester);
        }
      },
    );
  }

  testWidgets(
    'Returning to the captured directory keeps its next-page cursor',
    (tester) async {
      await render(tester);
      try {
        app.services.requestDownloadManager();
        final target = app.services.browserReturn.value!;
        expect(target.cursor, first.nextCursor);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: BrowserPage(
              app.services,
              target.session,
              initialItems: target.items,
              initialTrail: target.trail,
              initialCursor: target.cursor,
            ),
          ),
        );
        await settle(tester);
        expect(rootPages(fixture), ['1']);
        final list = find
            .descendant(
              of: find.byType(BrowserPage),
              matching: find.byType(ListView),
            )
            .last;
        final controller = tester.widget<ListView>(list).controller!;
        controller.jumpTo(controller.position.maxScrollExtent);
        await settle(tester);
        expect(rootPages(fixture), ['1', '2']);
        expect(find.textContaining('已加载 52 项'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Search from a partial page finds later files and locates their directory',
    (tester) async {
      await render(tester);
      try {
        expect(rootPages(fixture), ['1']);
        await tester.tap(find.byKey(const Key('browser-search-entry')));
        await settle(tester);
        await tester.enterText(
          find.byKey(const Key('browser-search-input')),
          '后页目标',
        );
        await tester.tap(find.byKey(const Key('browser-search-submit')));
        await settle(tester);
        expect(find.text('搜索完成 · 共 1 项'), findsOneWidget);
        expect(find.text('后页目标.zip'), findsOneWidget);
        expect(rootPages(fixture), containsAll(['2', '3']));
        await tester.tap(find.byTooltip('后页目标.zip操作'));
        await settle(tester);
        await tester.tap(find.text('打开所在文件夹'));
        await settle(tester);
        expect(
          find.byKey(const ValueKey('browser-file-iExample123')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'A failed next page leaves existing rows and retries the same cursor',
    (tester) async {
      await render(tester);
      try {
        fixture.pages['321']![2] = {'zt': 1, 'text': 'invalid'};
        final list = find
            .descendant(
              of: find.byType(BrowserPage),
              matching: find.byType(ListView),
            )
            .last;
        final controller = tester.widget<ListView>(list).controller!;
        controller.jumpTo(controller.position.maxScrollExtent);
        await settle(tester);
        expect(find.text('重试加载'), findsOneWidget);
        expect(find.textContaining('列表格式异常'), findsOneWidget);
        fixture.pages['321']![2] = {
          'zt': 1,
          'text': [
            {'id': 'iExample123', 'name_all': '后页目标.zip', 'size': '1.5 M'},
          ],
        };
        await tester.tap(find.byKey(const Key('browser-load-more')));
        await settle(tester);
        expect(rootPages(fixture), ['1', '2', '2']);
        expect(find.textContaining('已加载 52 项'), findsOneWidget);
        expect(find.text('重试加载'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Leaving a folder cancels a pending next page without replacing child rows',
    (tester) async {
      await render(tester);
      final pending = Completer<HttpResult>();
      try {
        fixture.folderOverride = (request) {
          if (request.method == 'POST' &&
              request.uri.path == '/filemoreajax.php' &&
              Uri.splitQueryString(request.body as String)['fid'] == '321' &&
              Uri.splitQueryString(request.body as String)['pg'] == '2') {
            return pending.future;
          }
          return null;
        };
        final list = find
            .descendant(
              of: find.byType(BrowserPage),
              matching: find.byType(ListView),
            )
            .last;
        final controller = tester.widget<ListView>(list).controller!;
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pump();
        controller.jumpTo(0);
        await tester.pump();
        await tester.tap(find.text('子目录'));
        await settle(tester);
        expect(find.text('nested.zip'), findsOneWidget);
        pending.complete(
          const HttpResult(
            200,
            '{"zt":1,"text":[{"id":"iLate123","name_all":"late.zip"}]}',
          ),
        );
        await settle(tester);
        expect(find.text('late.zip'), findsNothing);
        expect(find.text('nested.zip'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) {
          pending.complete(const HttpResult(200, '{"zt":2}'));
        }
        await finish(tester);
      }
    },
  );
}
