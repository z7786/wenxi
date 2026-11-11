import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/skeleton_loading.dart';
import 'browser_test_support.dart';

class _DirectoryConnector extends BrowserTestConnector {
  _DirectoryConnector() : super(CloudPlatform.tianyi);

  final pages = <(String, String?)>[];
  final pending = <String, Completer<CloudFilePage>>{};
  bool paginated = false;
  int fileCount = 90;

  List<CloudFile> files(String parent, int start, int end) => [
    for (var i = start; i < end; i++)
      CloudFile(
        id: '$parent-folder-$i',
        name: '目录 ${i.toString().padLeft(3, '0')}',
        parentId: parent,
        isDirectory: true,
      ),
  ];

  @override
  Future<CloudFilePage> listPage(
    BrowseSession session,
    String parentId,
    Credential? credential, {
    String? cursor,
  }) async {
    pages.add((parentId, cursor));
    if (pending[parentId] case final reply?) return reply.future;
    final start = int.tryParse(cursor ?? '') ?? 0;
    final end = paginated ? (start + 30).clamp(0, fileCount) : fileCount;
    return CloudFilePage(
      files(parentId, start, end),
      nextCursor: end < fileCount ? '$end' : null,
    );
  }
}

Finder fileList() => find.descendant(
  of: find.byType(BrowserPage),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is ListView && widget.controller != null || widget is GridView,
  ),
);

ScrollController controller(WidgetTester tester) =>
    tester.widget<ScrollView>(fileList()).controller!;

Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pumpAndSettle();
}

Future<void> scrollDown(WidgetTester tester) async {
  controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
  await tester.pumpAndSettle();
}

Finder visibleFolder() => find
    .descendant(of: fileList(), matching: find.textContaining('目录 '))
    .hitTestable()
    .first;

Future<void> back(WidgetTester tester) async {
  await Navigator.of(tester.element(find.byType(BrowserPage))).maybePop();
  await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Windows back mouse returns one directory and restores its position',
    (tester) async {
      final fixture = (await tester.runAsync(BrowserUiFixture.create))!;
      final provider = _DirectoryConnector();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = provider;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await fixture.render(tester);
        await scrollDown(tester);
        final offset = controller(tester).offset;
        await tester.tap(visibleFolder());
        await settle(tester);
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kBackMouseButton,
        );
        await mouse.down(tester.getCenter(fileList()));
        await mouse.up();
        await settle(tester);
        expect(controller(tester).offset, closeTo(offset, .01));
        expect(provider.pages, hasLength(2));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(fixture.close);
      }
    },
    skip: !Platform.isWindows,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  for (final view in ['list', 'grid']) {
    testWidgets(
      'Returning through nested $view folders restores each parent position',
      (tester) async {
        final fixture = (await tester.runAsync(
          () => BrowserUiFixture.create(view: view),
        ))!;
        final provider = _DirectoryConnector();
        fixture.services.cloud.connectors[CloudPlatform.tianyi] = provider;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        try {
          await fixture.render(tester);
          await scrollDown(tester);
          final rootOffset = controller(tester).offset;
          final rootFolder = tester.widget<Text>(visibleFolder()).data!;
          final rootTop = tester.getTopLeft(visibleFolder()).dy;
          await tester.tap(visibleFolder());
          await settle(tester);
          expect(controller(tester).offset, 0);
          await scrollDown(tester);
          final childOffset = controller(tester).offset;
          final childFolder = tester.widget<Text>(visibleFolder()).data!;
          await tester.tap(visibleFolder());
          await settle(tester);
          expect(controller(tester).offset, 0);
          await back(tester);
          expect(controller(tester).offset, closeTo(childOffset, .01));
          expect(
            find
                .descendant(of: fileList(), matching: find.text(childFolder))
                .hitTestable(),
            findsOneWidget,
          );
          await tester.tap(find.widgetWithText(TextButton, '全部文件'));
          await settle(tester);
          expect(controller(tester).offset, closeTo(rootOffset, .01));
          final restored = find.descendant(
            of: fileList(),
            matching: find.text(rootFolder),
          );
          expect(tester.getTopLeft(restored).dy, closeTo(rootTop, .01));
          expect(provider.pages, hasLength(3));
          await tester.tap(restored);
          await settle(tester);
          expect(controller(tester).offset, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(fixture.close);
        }
      },
    );
  }

  testWidgets(
    'Returning restores loaded pages and continues with the saved cursor',
    (tester) async {
      final fixture = (await tester.runAsync(BrowserUiFixture.create))!;
      final provider = _DirectoryConnector()
        ..paginated = true
        ..fileCount = 100;
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = provider;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await fixture.render(tester);
        controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
        await settle(tester);
        expect(provider.pages, [
          ('personal-root', null),
          ('personal-root', '30'),
        ]);
        controller(tester).jumpTo(2400);
        await tester.pumpAndSettle();
        final offset = controller(tester).offset;
        await tester.tap(visibleFolder());
        await settle(tester);
        await back(tester);
        expect(controller(tester).offset, closeTo(offset, .01));
        expect(provider.pages, hasLength(3));
        final list = tester.widget<ListView>(fileList());
        expect(list.childrenDelegate.estimatedChildCount, 61);
        controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
        await settle(tester);
        expect(provider.pages.last, ('personal-root', '60'));
        expect(provider.pages, hasLength(4));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'Returning during a pending child load rejects the late child response',
    (tester) async {
      final fixture = (await tester.runAsync(BrowserUiFixture.create))!;
      final provider = _DirectoryConnector();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = provider;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await fixture.render(tester);
        await scrollDown(tester);
        final offset = controller(tester).offset;
        final folder = tester.widget<Text>(visibleFolder()).data!;
        final index = int.parse(folder.split(' ').last);
        final child = 'personal-root-folder-$index';
        final pending = provider.pending[child] = Completer<CloudFilePage>();
        await tester.tap(visibleFolder());
        await tester.pump();
        await back(tester);
        expect(controller(tester).offset, closeTo(offset, .01));
        pending.complete(
          CloudFilePage([const CloudFile(id: 'stale', name: '过期内容.txt')]),
        );
        await settle(tester);
        expect(find.text('过期内容.txt'), findsNothing);
        expect(controller(tester).offset, closeTo(offset, .01));
        expect(provider.pages, hasLength(2));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'Expired directory snapshots reload previous pages and restore position',
    (tester) async {
      var now = DateTime(2026, 11, 7, 12);
      final fixture = (await tester.runAsync(
        () => BrowserUiFixture.create(clock: () => now),
      ))!;
      final provider = _DirectoryConnector()
        ..paginated = true
        ..fileCount = 100;
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = provider;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await fixture.render(tester);
        controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
        await settle(tester);
        controller(tester).jumpTo(2400);
        await tester.pumpAndSettle();
        final offset = controller(tester).offset;
        await tester.tap(visibleFolder());
        await settle(tester);
        now = now.add(const Duration(minutes: 1));
        await back(tester);
        expect(controller(tester).offset, closeTo(offset, .01));
        expect(provider.pages.skip(3), [
          ('personal-root', null),
          ('personal-root', '30'),
        ]);
        controller(tester).jumpTo(controller(tester).position.maxScrollExtent);
        await settle(tester);
        expect(provider.pages.last, ('personal-root', '60'));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'Refreshing retains visible files while a new directory uses the skeleton',
    (tester) async {
      final fixture = (await tester.runAsync(BrowserUiFixture.create))!;
      final provider = _DirectoryConnector();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = provider;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await fixture.render(tester);
        final refresh = provider.pending['personal-root'] =
            Completer<CloudFilePage>();
        await tester.tap(find.byTooltip('刷新文件'));
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.text('目录 000'), findsOneWidget);
        expect(find.byType(AppSkeleton), findsNothing);
        refresh.complete(CloudFilePage(provider.files('personal-root', 0, 90)));
        provider.pending.remove('personal-root');
        await settle(tester);
        final child = provider.pending['personal-root-folder-0'] =
            Completer<CloudFilePage>();
        await tester.tap(find.text('目录 000'));
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(const Key('browser-files-skeleton')), findsOneWidget);
        child.complete(
          CloudFilePage(provider.files('personal-root-folder-0', 0, 3)),
        );
        await settle(tester);
        expect(find.byType(AppSkeleton), findsNothing);
        expect(find.text('目录 002'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'Refreshing a changed tree drops cached files and clamps restored scroll',
    (tester) async {
      final fixture = (await tester.runAsync(BrowserUiFixture.create))!;
      final provider = _DirectoryConnector();
      fixture.services.cloud.connectors[CloudPlatform.tianyi] = provider;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        await fixture.render(tester);
        await scrollDown(tester);
        await tester.tap(visibleFolder());
        await settle(tester);
        provider.fileCount = 4;
        await tester.tap(find.byTooltip('刷新文件'));
        await settle(tester);
        await back(tester);
        expect(provider.pages.last, ('personal-root', null));
        expect(provider.pages, hasLength(4));
        expect(controller(tester).offset, 0);
        expect(find.text('目录 003'), findsOneWidget);
        expect(find.text('目录 004'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(fixture.close);
      }
    },
  );
}
