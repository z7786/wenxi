import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/search_announcement.dart';

const longNotice = SearchAnnouncement(
  title: '搜索首页的新资源已经更新，欢迎查看电影、学习资料与软件推荐，点击公告查看完整说明。',
  content: '**公告说明**\n\n支持复制与查看全文。',
);

Future<void> render(
  WidgetTester tester, {
  SearchAnnouncement notice = longNotice,
  bool active = true,
  bool reduced = false,
  bool dark = false,
  double scale = 1,
  Size size = const Size(390, 844),
  TargetPlatform platform = TargetPlatform.android,
  Future<void> Function(String)? copy,
  Future<bool> Function(Uri)? launch,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(
        dark ? Brightness.dark : Brightness.light,
      ).copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              SearchAnnouncementBar(
                notice: notice,
                active: active,
                copyText: copy ?? (_) async {},
                linkLauncher: launch,
              ),
              Builder(
                builder: (context) => TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const Scaffold(body: Text('下一页')),
                    ),
                  ),
                  child: const Text('其他页面'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

double offset(WidgetTester tester) => tester
    .widget<Transform>(
      find.byKey(const Key('search-announcement-motion'), skipOffstage: false),
    )
    .transform
    .storage[12];

void main() {
  testWidgets(
    'Long text waits, scrolls, pauses on hover, page inactivity and background',
    (tester) async {
      await render(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(offset(tester), 0);
      await tester.pump(const Duration(seconds: 2));
      expect(offset(tester), lessThan(0));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(0, 0));
      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('search-announcement-bar'))),
      );
      await tester.pump();
      final hovered = offset(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(offset(tester), hovered);
      await mouse.moveTo(const Offset(0, 0));
      await mouse.removePointer();
      await tester.pump();
      await render(tester, active: false);
      final inactive = offset(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(offset(tester), inactive);
      await render(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      final background = offset(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(offset(tester), background);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(offset(tester), lessThan(background));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Short text and reduced motion do not animate; resizing remeasures text',
    (tester) async {
      await render(tester, notice: const SearchAnnouncement(title: '欢迎使用'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-announcement-motion')), findsNothing);
      await render(tester, reduced: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-announcement-motion')), findsNothing);
      await render(tester);
      expect(
        find.byKey(const Key('search-announcement-motion')),
        findsOneWidget,
      );
      await render(tester, size: const Size(2000, 900));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('search-announcement-motion')), findsNothing);
    },
  );

  testWidgets('Another route pauses scrolling and returning resumes it', (
    tester,
  ) async {
    await render(tester);
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('其他页面'));
    await tester.pumpAndSettle();
    final paused = offset(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(offset(tester), paused);
    Navigator.of(tester.element(find.text('下一页'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 3));
    expect(offset(tester), lessThan(paused));
    await tester.pumpWidget(const SizedBox());
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      '$platform detail is responsive, selectable, copies and opens only on action',
      (tester) async {
        String? copied;
        final launched = <Uri>[];
        final notice = SearchAnnouncement(
          title: '本周资源更新',
          content: '## 使用说明\n\n支持复制完整公告。',
          buttonText: '查看活动',
          buttonUrl: Uri.parse('https://example.test/news'),
        );
        await render(
          tester,
          notice: notice,
          platform: platform,
          size: platform == TargetPlatform.windows
              ? const Size(1280, 900)
              : const Size(320, 640),
          scale: platform == TargetPlatform.android ? 2 : 1,
          dark: platform == TargetPlatform.windows,
          copy: (text) async => copied = text,
          launch: (url) async {
            launched.add(url);
            return true;
          },
        );
        await tester.tap(find.byKey(const Key('search-announcement-bar')));
        await tester.pumpAndSettle();
        expect(
          find.byType(
            platform == TargetPlatform.windows ? Dialog : BottomSheet,
          ),
          findsOneWidget,
        );
        expect(find.byType(SelectableText), findsWidgets);
        expect(launched, isEmpty);
        await tester.tap(find.text('复制公告'));
        await tester.pumpAndSettle();
        expect(copied, '${notice.title}\n\n${notice.content}');
        expect(find.text('公告已复制'), findsOneWidget);
        await tester.tap(find.text('查看活动'));
        await tester.pumpAndSettle();
        expect(launched, [notice.buttonUrl]);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('search-announcement-details')),
          findsNothing,
        );
      },
    );
  }

  testWidgets(
    'Long details pause animation; clipboard failure leaves readable content',
    (tester) async {
      await render(
        tester,
        copy: (_) async => throw StateError('clipboard unavailable'),
      );
      await tester.tap(find.byKey(const Key('search-announcement-bar')));
      await tester.pumpAndSettle();
      final paused = offset(tester);
      await tester.pump(const Duration(seconds: 4));
      expect(offset(tester), paused);
      await tester.tap(find.text('复制公告'));
      await tester.pumpAndSettle();
      expect(find.text('复制失败，请长按文本手动复制'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
