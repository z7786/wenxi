import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/main.dart' show MainShell;
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/resource_link_checks.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/domain/background.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'package:asterlink/ui/app_navigation.dart';
import 'package:asterlink/ui/app_background.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/preview_page.dart';
import 'package:asterlink/ui/resource_search_page.dart';
import 'package:asterlink/ui/resource_home_page.dart';
import 'package:asterlink/ui/search_security_dialog.dart';
import 'resource_search_test.dart' show SearchApiFixture;
import 'support.dart';
import 'fixtures/resource_search_samples.dart';
import 'resource_link_check_support.dart';
import 'background_support.dart';

List<ResourceSearchHit> results() => [
  ResourceSearchHit.fromRaw({
    'title': 'Python 编程：从入门到实践（第 3 版）',
    'url': 'https://pan.quark.cn/s/books',
    'password': 'aB12',
    'description': '电子书与配套练习代码，适合零基础学习与查阅。',
    'source_name': '学习资料分享',
    'datetime': '2026-10-20 12:00:00',
  }),
  ResourceSearchHit.fromRaw({
    'title': 'Python 自动化办公 · 视频与实战项目',
    'url': 'https://pan.baidu.com/s/1course',
    'password': '1234',
    'description': '从表格处理到文件整理，包含课程与项目资料。',
    'source_name': '课程资源',
  }),
  ResourceSearchHit.fromRaw({
    'title': 'Python 数据分析与可视化资料',
    'url': 'https://www.alipan.com/s/data',
    'description': '数据处理、分析与可视化相关的学习资料。',
    'source_name': '开发者资料库',
  }),
  ResourceSearchHit.fromRaw({
    'title': 'Python 开源工具与参考文档',
    'url': 'https://drive.uc.cn/s/tools',
    'source_name': '软件与文档',
  }),
];

class _SearchShareConnector extends CloudConnector {
  @override
  CloudPlatform get platform => CloudPlatform.quark;
  ParsedLink? opened;
  int downloadCalls = 0;
  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    opened = link;
    return BrowseSession(
      platform: CloudPlatform.quark,
      mode: BrowseMode.share,
      title: 'Python 学习资料',
      rootId: link.shareId!,
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async => [
    CloudFile(
      id: session.rootId == 'poolnew' ? 'newbook' : 'book',
      name: 'Python 学习指南.pdf',
      size: 4096,
      parentId: session.rootId,
    ),
  ];
  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    downloadCalls++;
    throw UnsupportedError('Fixture does not download files');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var loadedChineseFont = false;
  setUpAll(() async {
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      await (FontLoader('ResourceSearchFixture')..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          ))
          .load();
      loadedChineseFont = true;
    }
  });

  Future<(AppServices, SearchApiFixture)> render(
    WidgetTester tester, {
    Size size = const Size(430, 932),
    bool dark = false,
    bool populated = false,
    bool root = false,
    int initialTab = 1,
    bool hideResourceNavigation = false,
    bool home = false,
    double scale = 1,
    double bottomInset = 0,
    AppPalette palette = AppPalette.blue,
    bool wallpaper = false,
    Stream<ResourceSearchBatch> Function(String, dynamic)? response,
    Future<void> Function(ResourceSearchHit)? onOpen,
    ResourceLinkChecks? linkChecks,
    List<ResourceSearchHit>? recommendations,
    ResourceCatalog? catalog,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.padding = FakeViewPadding(bottom: bottomInset);
    tester.view.viewPadding = FakeViewPadding(bottom: bottomInset);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    final directory = Directory.systemTemp.createTempSync(
      'asterlink-search-widget-',
    );
    final wallpaperBytes = wallpaper
        ? await tester.runAsync(() => backgroundFixture(night: dark))
        : null;
    final picture = wallpaperBytes == null
        ? null
        : BackgroundPicture(
            id: '${sha256.convert(wallpaperBytes)}.png',
            width: 960,
            height: 1280,
          );
    final store = StateStore.memory({
      'resourceSearchHistory': ['Python 教程', '设计素材', '电子书'],
      'settings': AppSettings(
        themePalette: palette,
        background: BackgroundSettings(day: picture),
        hideResourceNavigation: hideResourceNavigation,
      ).toJson(),
    });
    final api = SearchApiFixture(
      response ??
          (_, _) =>
              Stream.value(ResourceSearchBatch(results(), complete: true)),
    );
    if (recommendations != null) {
      api.discover = (_, _) async => recommendations;
    }
    if (catalog != null) api.catalogRespond = (_, _) async => catalog;
    final service = ResourceSearch(
      store: store,
      api: api,
      linkChecks: linkChecks,
    );
    final services = AppServices(
      store: store,
      dataDirectory: directory,
      cacheDirectory: Directory('${directory.path}/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('${directory.path}/files')),
      http: FakeHttp(),
      platformFeatures: false,
      controlEnabled: false,
      resourceSearch: service,
    );
    if (picture != null) {
      services.backgrounds.directory.createSync(recursive: true);
      services.backgrounds.file(picture.id).writeAsBytesSync(wallpaperBytes!);
      await tester.runAsync(() async {
        final provider = ResizeImage(
          FileImage(services.backgrounds.file(picture.id)),
          width: 1024,
          height: 1024,
          policy: ResizeImagePolicy.fit,
        );
        final stream = provider.resolve(ImageConfiguration.empty);
        final ready = Completer<void>();
        final listener = ImageStreamListener((image, _) {
          image.dispose();
          if (!ready.isCompleted) ready.complete();
        }, onError: (error, stack) => ready.completeError(error, stack));
        stream.addListener(listener);
        try {
          await ready.future;
        } finally {
          stream.removeListener(listener);
        }
      });
    }
    if (populated) {
      if (linkChecks == null) {
        await tester.runAsync(() => service.search('Python'));
      } else {
        unawaited(service.search('Python'));
      }
    }
    final theme =
        appTheme(
          dark ? Brightness.dark : Brightness.light,
          palette: palette,
          fontFamily: loadedChineseFont ? 'ResourceSearchFixture' : null,
        ).copyWith(
          platform: size.width >= 1000
              ? TargetPlatform.windows
              : TargetPlatform.android,
        );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        locale: const Locale('zh', 'CN'),
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: root
            ? MainShell(services, initialTab: initialTab)
            : home
            ? Scaffold(
                body: ResourceHomePage(
                  services,
                  onOpen: onOpen ?? (_) async {},
                ),
              )
            : ResourceSearchPage(services, onOpen: onOpen ?? (_) async {}),
      ),
    );
    if (linkChecks != null && service.searching) {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    } else {
      await tester.pumpAndSettle();
    }
    if (root && populated) {
      await tester.enterText(
        find.byKey(const Key('resource-home-search-input')),
        'Python',
      );
      await tester.tap(find.byKey(const Key('resource-home-search-submit')));
      await tester.pumpAndSettle();
    }
    final imageContext = tester.element(find.byType(Scaffold).first);
    await tester.runAsync(() async {
      for (final platform in CloudPlatform.values) {
        final icon = platform.icon;
        await precacheImage(
          AssetImage('assets/icons/$icon.${icon == '123' ? 'webp' : 'png'}'),
          imageContext,
        );
      }
    });
    if (linkChecks != null && service.searching) {
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      unawaited(services.close().then((_) => closed = true));
      for (var i = 0; i < 100 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue);
      directory.deleteSync(recursive: true);
    });
    return (services, api);
  }

  testWidgets(
    'recommendations refresh in place and resource cards open without displaying a source',
    (tester) async {
      ResourceSearchHit card(int id) => ResourceSearchHit.fromRaw({
        'title': '学习资源 $id',
        'url': 'https://pan.quark.cn/s/rec$id',
        'recommendation_id': id,
        'category': '学习',
        'description': '公开学习资料，支持在本机查看分享内容。',
        'source_name': '不要显示的来源',
      });
      ResourceSearchHit? opened;
      final (_, api) = await render(
        tester,
        recommendations: [card(1), card(2)],
        onOpen: (hit) async => opened = hit,
      );
      expect(find.text('推荐资源'), findsOneWidget);
      expect(find.text('不要显示的来源'), findsNothing);
      api.discover = (exclude, refresh) async {
        expect(exclude, [1, 2]);
        expect(refresh, isTrue);
        return [card(3), card(4)];
      };
      final refresh = find.byKey(const Key('resource-recommendations-refresh'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text('学习资源 1'), findsNothing);
      final third = find.byKey(
        const ValueKey('resource-recommendation-3-Quark:rec3'),
      );
      await tester.ensureVisible(third);
      await tester.tap(third);
      await tester.pumpAndSettle();
      expect(opened?.recommendationId, 3);
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, size, scale) in [
    ('phone', const Size(430, 932), 1.0),
    ('desktop', const Size(1280, 900), 1.0),
    ('large-text', const Size(320, 700), 1.6),
  ]) {
    testWidgets('resource center $name layout', (tester) async {
      await render(
        tester,
        root: true,
        size: size,
        scale: scale,
        recommendations: List.generate(
          4,
          (i) => ResourceSearchHit.fromRaw({
            'title': ['Python 自动化办公', '手机摄影入门教程', '英语学习与练习', '设计素材与参考文档'][i],
            'url': 'https://pan.quark.cn/s/recommendation$i',
            'recommendation_id': i + 1,
            'category': ['编程', '摄影', '学习', '素材'][i],
            'description': '打开分享查看资源内容，文件预览在你的设备上完成。',
            'source_name': '不显示来源',
          }),
        ),
      );
      expect(find.byKey(const ValueKey('navigation-4')), findsOneWidget);
      expect(find.text('热门推荐'), findsOneWidget);
      expect(find.text('不显示来源'), findsNothing);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MainShell),
        matchesGoldenFile('goldens/resource-center-$name.png'),
      );
    });
  }

  for (final (name, size, scale, inset, categories) in [
    ('phone', const Size(430, 932), 1.0, 0.0, false),
    ('phone-inset', const Size(430, 932), 1.0, 34.0, false),
    ('narrow-large-text', const Size(320, 700), 1.6, 34.0, false),
    ('categories', const Size(393, 864), 1.0, 28.0, true),
  ]) {
    testWidgets('last catalog title clears floating navigation on $name', (
      tester,
    ) async {
      ResourceSearchHit card(int n) => ResourceSearchHit.fromRaw({
        'title': '推荐学习资源 $n',
        'description': '资源说明 $n',
        'url': 'https://pan.quark.cn/s/bottom$n',
        'recommendation_id': n,
      });
      await render(
        tester,
        root: true,
        size: size,
        scale: scale,
        bottomInset: inset,
        catalog: ResourceCatalog(
          popular: List.generate(10, (n) => card(n + 1)),
          categories: [
            if (categories)
              ResourceCategory(
                id: 7,
                name: '学习资料',
                resources: [card(11), card(12), card(13)],
              ),
          ],
        ),
      );
      final scrollView = tester.widget<CustomScrollView>(
        find.descendant(
          of: find.byType(ResourceHomePage),
          matching: find.byType(CustomScrollView),
        ),
      );
      final controller = scrollView.controller!;
      expect(controller.position.maxScrollExtent, greaterThan(0));
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final title = find.text('推荐学习资源 ${categories ? 13 : 10}');
      final navigationTop = tester.getTopLeft(find.byType(AppNavigation)).dy;
      expect(tester.getBottomLeft(title).dy, lessThan(navigationTop - 16));
      expect(title.hitTestable(), findsOneWidget);
      if (!categories) {
        expect(
          tester.getBottomLeft(find.text('资源说明 10')).dy,
          lessThan(navigationTop - 16),
        );
      }
      expect(tester.takeException(), isNull);
      if (name == 'phone-inset' || name == 'narrow-large-text') {
        await expectLater(
          find.byType(MainShell),
          matchesGoldenFile('goldens/resource-center-scrolled-$name.png'),
        );
      }
    });
  }

  testWidgets('resource tab keeps priority settings and omits the more menu', (
    tester,
  ) async {
    await render(tester, root: true);
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(find.byKey(const Key('resource-priority-settings')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('navigation-4')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('更多操作'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'swiping switches all main tabs and preserves the resource input',
    (tester) async {
      await render(tester, root: true);
      final resourceState = tester.state(find.byType(ResourceHomePage));
      await tester.enterText(
        find.byKey(const Key('resource-home-search-input')),
        '学习资料',
      );
      Future<void> swipe(double dx, int expected) async {
        await tester.drag(
          find.byKey(const Key('main-page-swipe-area')),
          Offset(dx, 0),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<AppNavigation>(find.byType(AppNavigation))
              .selectedIndex,
          expected,
        );
        expect(tester.takeException(), isNull);
      }

      for (final index in [2, 3, 4, 4]) {
        await swipe(-220, index);
      }
      for (final index in [3, 2, 1, 0, 0]) {
        await swipe(220, index);
      }
      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ResourceHomePage)), same(resourceState));
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('resource-home-search-input')),
            )
            .controller!
            .text,
        '学习资料',
      );
    },
  );

  testWidgets(
    'starting on parse preloads resource cards and opening the tab reuses them',
    (tester) async {
      final (services, api) = await render(tester, root: true, initialTab: 0);
      expect(find.byKey(const ValueKey('navigation-1')), findsOneWidget);
      expect(find.byKey(const Key('parse-resources')), findsNothing);
      expect(find.text('更新来源'), findsNothing);
      expect(services.resourceSearch.catalogLoaded, isTrue);
      expect(services.resourceSearch.recommendationsLoaded, isTrue);
      expect(api.catalogCalls, hasLength(1));
      final recommendationCount = api.recommendationCalls.length;
      expect(api.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pumpAndSettle();
      expect(api.catalogCalls, hasLength(1));
      expect(api.recommendationCalls, hasLength(recommendationCount));
      expect(api.calls, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hidden resource entry preserves search and parser back navigation',
    (tester) async {
      await render(
        tester,
        root: true,
        initialTab: 0,
        hideResourceNavigation: true,
      );
      final input = find.byKey(const Key('parse-input'));
      await tester.enterText(input, 'https://pan.quark.cn/s/keepinput');
      await tester.pumpAndSettle();
      expect(find.text('更新来源'), findsNothing);
      expect(find.byKey(const ValueKey('navigation-1')), findsNothing);
      await tester.tap(find.byKey(const Key('parse-resources')));
      await tester.pumpAndSettle();
      expect(find.byType(ResourceHomePage), findsOneWidget);
      expect(find.byKey(const Key('resource-back-to-parse')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('resource-home-search-input')),
        'Python',
      );
      await tester.tap(find.byKey(const Key('resource-home-search-submit')));
      await tester.pumpAndSettle();
      expect(find.byType(ResourceSearchPage), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(ResourceHomePage), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'https://pan.quark.cn/s/keepinput',
      );
      await tester.tap(find.byKey(const Key('parse-resources')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('resource-home-search-input')),
            )
            .controller!
            .text,
        'Python',
      );
      await tester.tap(find.byKey(const ValueKey('navigation-0')));
      await tester.pumpAndSettle();
      expect(input, findsOneWidget);
      await tester.tap(find.byKey(const Key('parse-resources')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('resource-back-to-parse')));
      await tester.pumpAndSettle();
      expect(input, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('swiping skips resources after its navigation entry is hidden', (
    tester,
  ) async {
    await render(
      tester,
      root: true,
      initialTab: 0,
      hideResourceNavigation: true,
    );
    for (final (dx, page) in [
      (-220.0, 2),
      (-220.0, 3),
      (-220.0, 4),
      (220.0, 3),
      (220.0, 2),
      (220.0, 0),
    ]) {
      await tester.drag(
        find.byKey(const Key('main-page-swipe-area')),
        Offset(dx, 0),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppNavigation>(find.byType(AppNavigation)).selectedIndex,
        page,
      );
    }
    expect(find.byKey(const ValueKey('navigation-1')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'vertical scrolling and small horizontal drags keep the current tab',
    (tester) async {
      await render(
        tester,
        root: true,
        recommendations: List.generate(
          20,
          (n) => ResourceSearchHit.fromRaw({
            'title': '学习资料 $n',
            'url': 'https://pan.quark.cn/s/scroll$n',
            'recommendation_id': n + 1,
          }),
        ),
      );
      final area = find.byKey(const Key('main-page-swipe-area'));
      await tester.drag(area, const Offset(8, -240));
      await tester.pumpAndSettle();
      final scrollView = tester.widget<CustomScrollView>(
        find.descendant(
          of: find.byType(ResourceHomePage),
          matching: find.byType(CustomScrollView),
        ),
      );
      expect(scrollView.controller!.offset, greaterThan(0));
      await tester.timedDrag(
        area,
        const Offset(30, 0),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<AppNavigation>(find.byType(AppNavigation)).selectedIndex,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, dark, wallpaper) in [
    ('dark', true, false),
    ('wallpaper', false, true),
    ('wallpaper-dark', true, true),
  ]) {
    testWidgets('resource home follows the app theme and $name', (
      tester,
    ) async {
      await render(
        tester,
        root: true,
        dark: dark,
        wallpaper: wallpaper,
        palette: AppPalette.mint,
        recommendations: List.generate(
          4,
          (n) => ResourceSearchHit.fromRaw({
            'title': ['Python 自动化办公', '手机摄影入门教程', '英语学习与练习', '设计素材与参考文档'][n],
            'url': 'https://pan.quark.cn/s/theme$n',
            'recommendation_id': n + 1,
            'description': '学习资料与实用工具',
          }),
        ),
      );
      if (wallpaper) {
        expect(find.byType(BackgroundImageView), findsOneWidget);
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MainShell),
        matchesGoldenFile('goldens/resource-center-$name.png'),
      );
    });
  }

  testWidgets(
    'catalog categories refresh independently and empty categories reserve no space',
    (tester) async {
      ResourceSearchHit card(int n) => ResourceSearchHit.fromRaw({
        'title': '分类课程 $n',
        'url': 'https://pan.quark.cn/s/catalog$n',
        'recommendation_id': n,
        'source_name': '隐藏的来源',
      });
      final (services, api) = await render(
        tester,
        home: true,
        catalog: ResourceCatalog(
          popular: [card(1)],
          categories: [
            ResourceCategory(
              id: 7,
              name: '学习资料',
              resources: [card(2), card(3), card(4)],
            ),
            const ResourceCategory(id: 8, name: '空分类不显示', resources: []),
          ],
        ),
      );
      expect(find.text('热门推荐'), findsOneWidget);
      expect(find.text('学习资料'), findsOneWidget);
      expect(find.text('空分类不显示'), findsNothing);
      expect(find.text('隐藏的来源'), findsNothing);
      await expectLater(
        find.byType(ResourceHomePage),
        matchesGoldenFile('goldens/resource-catalog-categories-phone.png'),
      );
      api.catalogRespond = (section, exclude) async {
        expect(section, '7');
        expect(exclude, [2, 3, 4]);
        return ResourceCatalog(
          popular: [card(99)],
          categories: [
            ResourceCategory(id: 7, name: '学习资料', resources: [card(5)]),
          ],
        );
      };
      final refresh = find.byKey(const ValueKey('resource-section-refresh-7'));
      await tester.ensureVisible(refresh);
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(find.text('分类课程 5'), findsOneWidget);
      expect(find.text('分类课程 99'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('分类课程 1'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('分类课程 1'), findsOneWidget);
      expect(services.resourceSearch.items, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resource home shows reusable recent searches', (tester) async {
    final (services, api) = await render(tester, home: true);
    expect(find.text('最近搜索'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('resource-home-history-电子书')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('resource-home-history-电子书')));
    await tester.pumpAndSettle();
    expect(find.byType(ResourceSearchPage), findsOneWidget);
    expect(services.resourceSearch.keyword, '电子书');
    expect(api.calls, ['电子书']);

    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ResourceHomePage), findsOneWidget);
    expect(services.resourceSearch.history.first, '电子书');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('resource-home-search-input')),
          )
          .controller!
          .text,
      '电子书',
    );

    await tester.tap(find.byKey(const Key('resource-home-clear-history')));
    await tester.pumpAndSettle();
    expect(services.resourceSearch.history, isEmpty);
    expect(find.text('最近搜索'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('resource-home-search-input')),
      '视频素材',
    );
    await tester.tap(find.byKey(const Key('resource-home-search-submit')));
    await tester.pumpAndSettle();
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('resource-home-history-视频素材')),
      findsOneWidget,
    );
    expect(services.resourceSearch.history, ['视频素材']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'priority sheet saves local order and standalone result route hides main navigation',
    (tester) async {
      final (services, _) = await render(tester, root: true);
      await tester.tap(find.byKey(const Key('resource-priority-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下移夸克'));
      await tester.tap(find.byKey(const Key('resource-priority-save')));
      await tester.pumpAndSettle();
      expect(services.resourceSearch.cloudPriority.first, CloudPlatform.uc);
      await tester.enterText(
        find.byKey(const Key('resource-home-search-input')),
        'Python',
      );
      await tester.tap(find.byKey(const Key('resource-home-search-submit')));
      await tester.pumpAndSettle();
      expect(find.byType(ResourceSearchPage), findsOneWidget);
      expect(find.byKey(const ValueKey('navigation-4')), findsNothing);
      expect(services.resourceSearch.items.first.platform, CloudPlatform.uc);
      await tester.drag(
        find.byType(CustomScrollView).last,
        const Offset(-250, 0),
      );
      await tester.pumpAndSettle();
      expect(services.resourceSearch.cloudFilter, CloudPlatform.uc.label);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(ResourceHomePage), findsOneWidget);
      expect(find.byType(ResourceSearchPage), findsNothing);
      expect(find.byKey(const ValueKey('navigation-4')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('resource-home-search-input')),
            )
            .controller!
            .text,
        'Python',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android system back during a streaming search returns home and cancels the request',
    (tester) async {
      final batches = StreamController<ResourceSearchBatch>();
      addTearDown(batches.close);
      final (_, api) = await render(
        tester,
        root: true,
        response: (_, _) => batches.stream,
      );
      await tester.enterText(
        find.byKey(const Key('resource-home-search-input')),
        '学习资料',
      );
      await tester.tap(find.byKey(const Key('resource-home-search-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(ResourceSearchPage), findsOneWidget);
      expect(api.cancellations.single.isCancelled, isFalse);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(ResourceHomePage), findsOneWidget);
      expect(api.cancellations.single.isCancelled, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('resource-home-search-input')),
            )
            .controller!
            .text,
        '学习资料',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'catalog checks only visible recommendation links and stops when inactive',
    (tester) async {
      final probe = LinkCheckApiFixture(
        (_) async => ResourceLinkHealth.checked(
          ResourceLinkState.valid,
          DateTime(2026, 10, 23),
        ),
      );
      await render(
        tester,
        home: true,
        linkChecks: ResourceLinkChecks(probe),
        catalog: ResourceCatalog(
          popular: List.generate(
            20,
            (n) => ResourceSearchHit.fromRaw({
              'title': '本地检测资源 $n',
              'url': 'https://pan.quark.cn/s/local$n',
              'recommendation_id': n + 1,
            }),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(probe.calls, isNotEmpty);
      expect(probe.calls.length, lessThan(20));
      expect(find.text('链接有效'), findsWidgets);
      final home = tester.widget<ResourceHomePage>(
        find.byType(ResourceHomePage),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceHomePage(
            home.services,
            onOpen: home.onOpen,
            active: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final count = probe.calls.length;
      await tester.pump(const Duration(seconds: 1));
      expect(probe.calls.length, count);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'listing uses the original share and pool transfer starts only when opening a file preview',
    (tester) async {
      final (services, api) = await render(tester, root: true);
      api.resolve = (hit, _, selection) async =>
          ResourceSearchOpenResult.fromJson(hit, {
            'mode': 'temp_share',
            'transfer_scope': 'file',
            'source_file_id': selection.fileId,
            'url': 'https://pan.quark.cn/s/poolnew',
            'password': 'nEw2',
          });
      final connector = _SearchShareConnector();
      services.cloud.connectors[CloudPlatform.quark] = connector;
      expect(find.byKey(const Key('parse-resource-search')), findsNothing);
      expect(find.byType(ResourceHomePage), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('resource-home-search-input')),
        'Python',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('resource-home-search-submit')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('resource-result-Quark:books')),
      );
      await tester.tap(find.byKey(const ValueKey('resource-open-Quark:books')));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(api.openCalls, isEmpty);
      expect(connector.opened!.shareId, 'books');
      expect(connector.opened!.passcode, 'aB12');
      expect(find.text('Python 学习指南.pdf'), findsOneWidget);
      await tester.tap(find.text('Python 学习指南.pdf'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(api.openCalls.single.identity, 'Quark:books');
      expect(connector.opened!.shareId, 'poolnew');
      expect(connector.opened!.passcode, 'nEw2');
      Navigator.of(tester.element(find.byType(PreviewPage))).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(BrowserPage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ResourceSearchPage), findsOneWidget);
      expect(services.resourceSearch.items.length, 4);
      expect(services.resourceSearch.allItems.first.password, 'aB12');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('resource-search-input')))
            .controller!
            .text,
        'Python',
      );
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> settlePreview(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pumpAndSettle();
  }

  Future<(SearchApiFixture, _SearchShareConnector)> openOriginalBrowser(
    WidgetTester tester,
  ) async {
    final (services, api) = await render(tester, root: true, populated: true);
    final connector = _SearchShareConnector();
    services.cloud.connectors[CloudPlatform.quark] = connector;
    await tester.tap(find.byKey(const ValueKey('resource-open-Quark:books')));
    await settlePreview(tester);
    expect(find.byType(BrowserPage), findsOneWidget);
    expect(api.openCalls, isEmpty);
    expect(connector.opened!.shareId, 'books');
    return (api, connector);
  }

  testWidgets('preview failure stays on the file and can retry transfer', (
    tester,
  ) async {
    final (api, connector) = await openOriginalBrowser(tester);
    api.resolve = (_, _, _) => Future.error(StateError('转存服务暂时不可用'));
    await tester.tap(find.text('Python 学习指南.pdf'));
    await settlePreview(tester);
    expect(find.text('暂未完成资源准备'), findsOneWidget);
    expect(find.byKey(const Key('pool-preview-original')), findsNothing);
    expect(find.text('使用原链接预览'), findsNothing);
    expect(connector.downloadCalls, 0);
    expect(api.openCalls, hasLength(1));
    expect(connector.opened!.shareId, 'books');
    api.resolve = (hit, _, selection) async =>
        ResourceSearchOpenResult.fromJson(hit, {
          'mode': 'temp_share',
          'transfer_scope': 'file',
          'source_file_id': selection.fileId,
          'url': 'https://pan.quark.cn/s/poolnew',
        });
    await tester.tap(find.byKey(const Key('pool-preview-retry')));
    await settlePreview(tester);
    expect(api.openCalls, hasLength(2));
    expect(connector.opened!.shareId, 'poolnew');
    expect(find.text('暂未完成资源准备'), findsNothing);
    expect(find.text('下载文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed transfer offers retry and return without original preview',
    (tester) async {
      final (api, connector) = await openOriginalBrowser(tester);
      api.resolve = (hit, _, _) async => ResourceSearchOpenResult(
        hit: hit,
        mode: 'original',
        reason: 'transfer_failed',
        message: '暂时未能生成新的分享链接',
      );
      await tester.tap(find.text('Python 学习指南.pdf'));
      await settlePreview(tester);
      expect(find.text('暂时未能生成新的分享链接'), findsOneWidget);
      expect(find.text('暂未完成资源准备'), findsOneWidget);
      expect(find.byKey(const Key('pool-preview-retry')), findsOneWidget);
      expect(find.byKey(const Key('pool-preview-original')), findsNothing);
      expect(find.text('使用原链接预览'), findsNothing);
      expect(find.text('下载文件'), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '下载文件',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(connector.downloadCalls, 0);
      expect(api.openCalls, hasLength(1));
      expect(connector.opened!.shareId, 'books');
      expect(connector.opened!.passcode, 'aB12');
      Navigator.of(tester.element(find.byType(PreviewPage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.text('Python 学习指南.pdf'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing transfer captcha blocks original preview and retry verifies again',
    (tester) async {
      final (api, connector) = await openOriginalBrowser(tester);
      final services = tester
          .widget<BrowserPage>(find.byType(BrowserPage))
          .services;
      final browserContext = tester.element(find.byType(BrowserPage));
      final http = FakeHttp((call) {
        if (call.uri.path.endsWith('/open/file')) {
          return jsonResponse({
            'success': false,
            'code': 'HUMAN_VERIFICATION_REQUIRED',
          }, 403);
        }
        if (call.uri.path.endsWith('/challenge')) {
          return jsonResponse(
            jsonDecode(
                  File('test/fixtures/search_captcha.json').readAsStringSync(),
                )
                as Map<String, dynamic>,
          );
        }
        throw StateError('Unexpected request: ${call.uri.path}');
      });
      final transferApi = HttpResourceSearchApi(
        http,
        endpoint: 'http://search.test',
      );
      transferApi.security.onVerification = (client, cancellation) async =>
          await showDialog<bool>(
            context: browserContext,
            barrierDismissible: false,
            builder: (_) =>
                SearchSecurityDialog(services, client, cancellation),
          ) ??
          false;
      api.resolve = (hit, cancellation, selection) =>
          transferApi.open(hit, cancellation, selection: selection);

      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(
          attempt == 0
              ? find.text('Python 学习指南.pdf')
              : find.byKey(const Key('pool-preview-retry')),
        );
        // The preview progress keeps animating while verification is pending.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(SearchSecurityDialog), findsOneWidget);
        await tester.tap(find.byTooltip('取消验证'));
        await settlePreview(tester);
        expect(find.byType(SearchSecurityDialog), findsNothing);
        expect(find.text('已取消安全验证'), findsOneWidget);
        expect(find.text('暂未完成资源准备'), findsOneWidget);
        expect(find.byKey(const Key('pool-preview-retry')), findsOneWidget);
        expect(find.byKey(const Key('pool-preview-original')), findsNothing);
        expect(find.text('使用原链接预览'), findsNothing);
        expect(find.text('下载文件'), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) => widget is IconButton && widget.tooltip == '下载文件',
                ),
              )
              .onPressed,
          isNull,
        );
        expect(connector.downloadCalls, 0);
        expect(connector.opened!.shareId, 'books');
        expect(api.openCalls, hasLength(attempt + 1));
        expect(
          http.calls.where((call) => call.uri.path.endsWith('/open/file')),
          hasLength(attempt + 1),
        );
        expect(
          http.calls.where((call) => call.uri.path.endsWith('/verify')),
          isEmpty,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final reason in ['insufficient_space', 'no_account']) {
    testWidgets('$reason silently starts preview using the original share', (
      tester,
    ) async {
      final (api, connector) = await openOriginalBrowser(tester);
      api.resolve = (hit, _, _) async => ResourceSearchOpenResult(
        hit: hit,
        mode: 'original',
        reason: reason,
        message: '号池暂不可用，使用原链接预览',
      );
      await tester.tap(find.text('Python 学习指南.pdf'));
      await settlePreview(tester);
      expect(find.byType(PreviewPage), findsOneWidget);
      expect(find.text('号池暂不可用，使用原链接预览'), findsNothing);
      expect(find.byKey(const Key('pool-preview-original')), findsNothing);
      expect(find.text('暂未完成资源准备'), findsNothing);
      expect(find.text('下载文件'), findsOneWidget);
      expect(api.openCalls, hasLength(1));
      expect(connector.opened!.shareId, 'books');
      expect(connector.opened!.passcode, 'aB12');
      Navigator.of(tester.element(find.byType(PreviewPage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserPage), findsOneWidget);
      expect(find.textContaining('删除临时'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('leaving preview cancels the request and ignores late results', (
    tester,
  ) async {
    final (api, connector) = await openOriginalBrowser(tester);
    final waiting = Completer<ResourceSearchOpenResult>();
    api.resolve = (_, _, _) => waiting.future;
    await tester.tap(find.text('Python 学习指南.pdf'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.openCalls, hasLength(1));
    expect(find.byKey(const Key('pool-preview-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pool-preview-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(BrowserPage), findsOneWidget);
    expect(api.openCancellations.single.isCancelled, isTrue);
    waiting.complete(
      ResourceSearchOpenResult.fromJson(api.openCalls.single, {
        'mode': 'temp_share',
        'url': 'https://pan.quark.cn/s/poolnew',
      }),
    );
    await tester.pumpAndSettle();
    expect(connector.opened!.shareId, 'books');
    expect(find.byType(PreviewPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'filter is local, copying includes password, and history can be cleared',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (services, api) = await render(tester, populated: true);
      await tester.tap(find.byKey(const ValueKey('resource-filter-百度网盘')));
      await tester.pumpAndSettle();
      expect(services.resourceSearch.items.single.cloudName, '百度网盘');
      expect(api.calls.length, 1);
      await tester.tap(find.byTooltip('复制分享链接').first);
      await tester.pumpAndSettle();
      expect(copied, contains('提取码：1234'));
      expect(copied, contains('pan.baidu.com'));
      await tester.runAsync(services.resourceSearch.clearHistory);
      expect(services.resourceSearch.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('streaming loading can be stopped while preserving results', (
    tester,
  ) async {
    final stream = StreamController<ResourceSearchBatch>(sync: true);
    final (services, _) = await render(
      tester,
      response: (_, cancellation) {
        unawaited(cancellation.whenCancel.then((_) => stream.close()));
        return stream.stream;
      },
    );
    await tester.enterText(
      find.byKey(const Key('resource-search-input')),
      'Python',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('resource-search-submit')));
    await tester.pump();
    stream.add(ResourceSearchBatch([results().first]));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在搜索'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('resource-search-stop')));
    await tester.tap(find.byKey(const Key('resource-search-stop')));
    await tester.pumpAndSettle();
    expect(services.resourceSearch.items.length, 1);
    expect(find.text('搜索已停止'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone can reopen history from a result page and search again', (
    tester,
  ) async {
    final (services, _) = await render(tester, populated: true);
    await tester.tap(find.byKey(const Key('resource-search-history')));
    await tester.pumpAndSettle();
    expect(find.text('最近搜索'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('resource-history-电子书')));
    await tester.pumpAndSettle();
    expect(services.resourceSearch.keyword, '电子书');
    expect(find.text('最近搜索'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'advanced filters apply locally and details show the full share',
    (tester) async {
      final (services, api) = await render(tester, populated: true);
      await tester.tap(find.byKey(const Key('resource-advanced-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('resource-include-input')),
        'Python 编程',
      );
      await tester.enterText(
        find.byKey(const Key('resource-exclude-input')),
        '自动化',
      );
      await tester.tap(find.byKey(const Key('resource-apply-filters')));
      await tester.pumpAndSettle();
      expect(services.resourceSearch.items.single.identity, 'Quark:books');
      expect(api.calls.length, 1);
      await tester.ensureVisible(
        find.byKey(const ValueKey('resource-result-Quark:books')),
      );
      await tester.tap(find.textContaining('Python 编程：').first);
      await tester.pumpAndSettle();
      expect(find.text('资源详情'), findsOneWidget);
      expect(find.text('提取码：aB12'), findsOneWidget);
      expect(find.text('电子书与配套练习代码，适合零基础学习与查阅。'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scroll loading reaches results beyond sixty without another request',
    (tester) async {
      final (services, api) = await render(
        tester,
        populated: true,
        response: (_, _) => Stream.value(
          ResourceSearchBatch([
            for (var i = 0; i < 80; i++)
              ResourceSearchHit.fromRaw({
                'title': 'Python 资料 $i',
                'url': 'https://pan.quark.cn/s/bulk$i',
              }),
          ], complete: true),
        ),
      );
      expect(services.resourceSearch.allItems.length, 80);
      expect(
        find.byKey(const ValueKey('resource-result-Quark:bulk79')),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('resource-result-Quark:bulk79')),
        600,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('resource-search-results')),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('resource-result-Quark:bulk79')),
        findsOneWidget,
      );
      expect(find.text('已显示全部 80 条结果'), findsOneWidget);
      expect(api.calls.length, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reference cards fit three complete descriptions in the phone viewport',
    (tester) async {
      await render(
        tester,
        populated: true,
        response: (_, _) => Stream.value(
          ResourceSearchBatch(resourceSearchSamples(), complete: true),
        ),
      );
      final fullyVisible = find
          .byType(ResourceSearchResultRow)
          .evaluate()
          .where((element) {
            final rect = tester.getRect(find.byWidget(element.widget));
            return rect.top >= 56 && rect.bottom <= 932;
          });
      expect(fullyVisible.length, greaterThanOrEqualTo(3));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only checked result batches appear and valid/unconfirmed/invalid ordering is preserved',
    (tester) async {
      final checkerApi = LinkCheckApiFixture();
      final checks = ResourceLinkChecks(checkerApi);
      final opened = <String>[];
      final (services, api) = await render(
        tester,
        populated: true,
        linkChecks: checks,
        onOpen: (hit) async {
          opened.add(hit.identity);
        },
      );
      expect(services.resourceSearch.phase, ResourceSearchPhase.checking);
      expect(find.byType(ResourceSearchResultRow), findsNothing);
      expect(checkerApi.calls, hasLength(3));
      expect(find.text('正在检测链接 0/4'), findsOneWidget);
      expect(api.openCalls, isEmpty);
      for (final (index, state) in [
        ResourceLinkState.valid,
        ResourceLinkState.invalid,
        ResourceLinkState.locked,
      ].indexed) {
        checkerApi.calls[index].complete(state);
      }
      await tester.pump();
      expect(checkerApi.calls, hasLength(4));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(ResourceSearchResultRow), findsNWidgets(3));
      expect(find.text('正在检测链接 3/4'), findsOneWidget);
      expect(find.text('待检测'), findsNothing);
      expect(find.text('检测中'), findsNothing);
      checkerApi.calls.last.complete(ResourceLinkState.unknown);
      await tester.pumpAndSettle();
      for (final label in ['链接有效', '链接失效', '提取码待确认', '暂无法确认']) {
        expect(find.text(label), findsOneWidget);
      }
      final invalidIdentity = checkerApi.calls[1].hit.identity;
      final ordered = services.resourceSearch.items
          .map((hit) => hit.identity)
          .toList();
      expect(ordered.last, invalidIdentity);
      expect(ordered.first, checkerApi.calls[0].hit.identity);
      final invalid = checkerApi.calls[1].hit;
      await tester.tap(
        find.byKey(ValueKey('resource-open-${invalid.identity}')),
      );
      await tester.pumpAndSettle();
      expect(opened, [invalid.identity]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all returned search links are checked once and scrolling does not start new probes',
    (tester) async {
      final checkerApi = LinkCheckApiFixture(
        (_) async => ResourceLinkHealth.checked(
          ResourceLinkState.valid,
          DateTime(2026, 10, 22),
        ),
      );
      final checks = ResourceLinkChecks(checkerApi);
      final (services, _) = await render(
        tester,
        populated: true,
        linkChecks: checks,
        response: (_, _) => Stream.value(
          ResourceSearchBatch(
            List.generate(50, (i) => probeHit('viewport$i')),
            complete: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      final viewport = tester.getRect(
        find.byKey(const PageStorageKey('resource-search-results')),
      );
      final builtRows = find
          .byType(ResourceSearchResultRow, skipOffstage: false)
          .evaluate()
          .toList();
      final visible = builtRows
          .where(
            (element) => tester
                .getRect(find.byWidget(element.widget, skipOffstage: false))
                .overlaps(viewport),
          )
          .map(
            (element) =>
                (element.widget as ResourceSearchResultRow).hit.identity,
          )
          .toSet();
      expect(
        checkerApi.calls.map((call) => call.hit.identity).toSet(),
        services.resourceSearch.allItems.map((hit) => hit.identity).toSet(),
      );
      expect(builtRows.length, greaterThan(visible.length));
      final initial = checkerApi.calls.length;
      final scroller = find.byKey(
        const PageStorageKey('resource-search-results'),
      );
      await tester.drag(scroller, const Offset(0, -650));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(checkerApi.calls.length, initial);
      expect(
        checkerApi.calls.map((call) => call.hit.identity),
        contains('Quark:viewport49'),
      );
      await tester.drag(scroller, const Offset(0, 650));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        checkerApi.calls.where(
          (call) => call.hit.identity == 'Quark:viewport0',
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving the page or backgrounding cancels local probes; resuming checks visible rows again',
    (tester) async {
      final checkerApi = LinkCheckApiFixture();
      final checks = ResourceLinkChecks(checkerApi);
      await render(tester, populated: true, linkChecks: checks);
      await tester.pump(const Duration(milliseconds: 200));
      expect(checkerApi.calls, hasLength(3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(
        checkerApi.calls.every((call) => call.cancellation.isCancelled),
        isTrue,
      );
      checkerApi.calls.first.complete(ResourceLinkState.invalid);
      await tester.pump();
      expect(find.text('链接失效'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(checkerApi.calls, hasLength(6));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(
        checkerApi.calls.every((call) => call.cancellation.isCancelled),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stopping a search with pending checks displays retained links without pending badges',
    (tester) async {
      final checkerApi = LinkCheckApiFixture();
      final (services, _) = await render(
        tester,
        populated: true,
        linkChecks: ResourceLinkChecks(checkerApi),
      );
      await tester.tap(find.byKey(const Key('resource-search-stop')));
      await tester.pumpAndSettle();
      expect(services.resourceSearch.phase, ResourceSearchPhase.stopped);
      expect(find.text('搜索已停止'), findsOneWidget);
      expect(find.byType(ResourceSearchResultRow), findsNWidgets(4));
      expect(find.text('待检测'), findsNothing);
      expect(find.text('检测中'), findsNothing);
      expect(
        checkerApi.calls.every((call) => call.cancellation.isCancelled),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resource details show local detection and allow an uncached manual recheck',
    (tester) async {
      final checkerApi = LinkCheckApiFixture((call) async {
        if (call.hit.identity == 'Quark:books') return call.result.future;
        return ResourceLinkHealth.checked(
          ResourceLinkState.valid,
          DateTime(2026, 10, 22),
        );
      });
      final checks = ResourceLinkChecks(checkerApi);
      await render(tester, populated: true, linkChecks: checks);
      await tester.pump(const Duration(milliseconds: 200));
      checkerApi.calls.first.complete(ResourceLinkState.valid);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('resource-result-Quark:books')),
      );
      await tester.pumpAndSettle();
      expect(find.text('本机网络检测'), findsOneWidget);
      final recheck = find.byKey(const Key('resource-health-recheck'));
      await tester.tap(recheck);
      await tester.pump();
      expect(
        checkerApi.calls.where((call) => call.hit.identity == 'Quark:books'),
        hasLength(2),
      );
      expect(tester.widget<TextButton>(recheck).onPressed, isNull);
      checkerApi.calls.last.complete(ResourceLinkState.invalid);
      await tester.pumpAndSettle();
      expect(find.text('链接失效'), findsWidgets);
      expect(tester.widget<TextButton>(recheck).onPressed, isNotNull);
      Navigator.of(tester.element(find.text('资源详情'))).pop();
      await tester.pumpAndSettle();
      expect(checks.health(results().first).state, ResourceLinkState.invalid);
      expect(
        tester
            .widget<ResourceSearchResultRow>(
              find.byType(ResourceSearchResultRow).first,
            )
            .hit
            .identity,
        'Quark:books',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'returning to the top naturally applies waiting checked results',
    (tester) async {
      final checkerApi = LinkCheckApiFixture();
      final hits = List.generate(18, (i) => probeHit('return$i'));
      await render(
        tester,
        populated: true,
        linkChecks: ResourceLinkChecks(checkerApi),
        response: (_, _) =>
            Stream.value(ResourceSearchBatch(hits, complete: true)),
      );
      for (var i = 0; i < 15; i++) {
        checkerApi.calls[i].complete(ResourceLinkState.unknown);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      final scroller = find.byKey(
        const PageStorageKey('resource-search-results'),
      );
      await tester.drag(scroller, const Offset(0, -650));
      await tester.pump(const Duration(milliseconds: 800));
      for (var i = 15; i < 18; i++) {
        checkerApi.calls[i].complete(ResourceLinkState.valid);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const Key('resource-search-new-results')),
        findsOneWidget,
      );
      await tester.drag(scroller, const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('resource-search-new-results')),
        findsNothing,
      );
      expect(
        tester
            .widget<ResourceSearchResultRow>(
              find.byType(ResourceSearchResultRow).first,
            )
            .health!
            .state,
        ResourceLinkState.valid,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'later checked batches keep scrolled rows still until new results are opened',
    (tester) async {
      final checkerApi = LinkCheckApiFixture();
      final hits = List.generate(24, (i) => probeHit('stable$i'));
      final (services, _) = await render(
        tester,
        populated: true,
        linkChecks: ResourceLinkChecks(checkerApi),
        response: (_, _) =>
            Stream.value(ResourceSearchBatch(hits, complete: true)),
      );
      for (var i = 0; i < 15; i++) {
        checkerApi.calls[i].complete(ResourceLinkState.unknown);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 260));
      final scroller = find.byKey(
        const PageStorageKey('resource-search-results'),
      );
      await tester.drag(scroller, const Offset(0, -650));
      await tester.pump(const Duration(milliseconds: 800));
      final state = tester.state<ScrollableState>(
        find.descendant(of: scroller, matching: find.byType(Scrollable)).first,
      );
      final offset = state.position.pixels;
      final viewport = tester.getRect(scroller);
      final visibleRow =
          find
                  .byType(ResourceSearchResultRow)
                  .evaluate()
                  .firstWhere(
                    (element) => tester
                        .getRect(find.byWidget(element.widget))
                        .overlaps(viewport),
                  )
                  .widget
              as ResourceSearchResultRow;
      final key = find.byKey(
        ValueKey('resource-result-${visibleRow.hit.identity}'),
      );
      final before = tester.getRect(key);
      for (var i = 15; i < hits.length; i++) {
        checkerApi.calls[i].complete(ResourceLinkState.valid);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(services.resourceSearch.phase, ResourceSearchPhase.complete);
      expect(state.position.pixels, closeTo(offset, .01));
      expect(tester.getRect(key), before);
      expect(
        find.byKey(const Key('resource-search-new-results')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('resource-search-new-results')));
      await tester.pumpAndSettle();
      expect(state.position.pixels, 0);
      expect(
        find.byKey(const Key('resource-search-new-results')),
        findsNothing,
      );
      final first = tester.widget<ResourceSearchResultRow>(
        find.byType(ResourceSearchResultRow).first,
      );
      expect(first.health!.state, ResourceLinkState.valid);
      expect(checkerApi.calls, hasLength(24));
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, size, scale, dark) in [
    ('narrow phone', const Size(320, 568), 1.0, false),
    ('large text phone', const Size(390, 844), 2.0, false),
    ('dark desktop', const Size(1280, 900), 1.0, true),
    ('landscape phone', const Size(740, 360), 1.0, false),
  ]) {
    testWidgets('local health badges fit the $name layout', (tester) async {
      final checkerApi = LinkCheckApiFixture(
        (call) async => ResourceLinkHealth.checked(
          ResourceLinkState.values[2 + call.hit.identity.length % 5],
          DateTime(2026, 10, 22),
        ),
      );
      await render(
        tester,
        populated: true,
        size: size,
        scale: scale,
        dark: dark,
        linkChecks: ResourceLinkChecks(checkerApi),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(checkerApi.calls, isNotEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final (name, size, dark, populated, scale) in [
    ('phone-welcome', const Size(430, 932), false, false, 1.0),
    ('phone-results', const Size(430, 932), false, true, 1.0),
    ('phone-dark', const Size(430, 932), true, true, 1.0),
    ('desktop-results', const Size(1280, 900), false, true, 1.0),
    ('phone-large-text', const Size(390, 844), false, true, 2.0),
    ('phone-narrow', const Size(320, 568), false, true, 1.0),
    ('phone-landscape', const Size(740, 360), false, true, 1.0),
  ]) {
    testWidgets('$name layout', (tester) async {
      await render(
        tester,
        size: size,
        dark: dark,
        populated: populated,
        scale: scale,
        response: (_, _) => Stream.value(
          ResourceSearchBatch(resourceSearchSamples(), complete: true),
        ),
      );
      if (scale > 1) {
        await tester.ensureVisible(
          find.byKey(const ValueKey('resource-result-Quark:PreviewResource1')),
        );
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(ResourceSearchPage),
        matchesGoldenFile('goldens/resource-search-$name.png'),
      );
    });
  }
}
