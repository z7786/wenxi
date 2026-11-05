import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/appearance_page.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/app_navigation.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var systemFont = false;
  setUpAll(() async {
    for (final pair in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(pair.$1)..addFont(rootBundle.load(pair.$2))).load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('AppearanceFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      systemFont = true;
    }
  });

  Future<AppServices> render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double scale = 1,
    AppSettings settings = const AppSettings(theme: 'Light'),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wenxi-theme-page-'),
    ))!;
    final services = (await tester.runAsync(
      () async => AppServices(
        store: StateStore.memory({'settings': settings.toJson()}),
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(directory),
        http: FakeHttp(),
        controlEnabled: false,
        platformFeatures: false,
      ),
    ))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      var closed = false;
      services.close().then((_) => closed = true);
      for (var i = 0; i < 40 && !closed; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(closed, isTrue);
      await tester.runAsync(() => directory.delete(recursive: true));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('appearance-capture'),
        child: AsterLinkApp(
          services,
          initialTab: 4,
          fontFamily: systemFont ? 'AppearanceFixture' : null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();
    return services;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> apply(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('appearance-apply')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    final directory = Platform.environment['APP_THEME_PREVIEW_DIR'];
    if (directory == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('appearance-capture')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$directory/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets(
    'preview is local; apply keeps the page and download service alive',
    (tester) async {
      final services = await render(tester);
      final downloads = services.downloads;
      final shell = tester.state(find.byType(MainShell, skipOffstage: false));
      await tap(tester, 'appearance-palette-mint');
      await tap(tester, 'appearance-mode-Dark');
      await tap(tester, 'appearance-glass-frosted');
      await tap(tester, 'appearance-glass-controls');
      await tap(tester, 'appearance-glass-low-power');
      expect(services.settings.themePalette, AppPalette.blue);
      expect(services.settings.theme, 'Light');
      expect(services.settings.glassStyle, GlassStyle.clear);
      expect(services.settings.glassControls, isFalse);
      expect(services.settings.glassLowPower, isFalse);
      expect(
        Theme.of(tester.element(find.text('项目资料.zip'))).colorScheme.primary,
        Color(AppPalette.mint.darkAccent),
      );
      expect(
        AppAppearance.of(tester.element(find.text('项目资料.zip'))).glassStyle,
        GlassStyle.frosted,
      );
      await apply(tester);
      expect(services.settings.themePalette, AppPalette.mint);
      expect(services.settings.theme, 'Dark');
      expect(services.settings.glassStyle, GlassStyle.frosted);
      expect(services.settings.glassControls, isTrue);
      expect(services.settings.glassLowPower, isTrue);
      expect(services.downloads, same(downloads));
      expect(
        tester.state(find.byType(MainShell, skipOffstage: false)),
        same(shell),
      );
      expect(find.byType(AppearancePage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('薄荷绿 · 磨砂'), findsOneWidget);
      expect(
        AppAppearance.of(
          tester.element(find.byKey(const Key('floating-navigation'))),
        ).glassStyle,
        GlassStyle.frosted,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discarding a preview and restoring defaults only affect appearance',
    (tester) async {
      final services = await render(
        tester,
        settings: const AppSettings(
          theme: 'Dark',
          themePalette: AppPalette.rose,
          glassStyle: GlassStyle.frosted,
          hideResourceNavigation: true,
          threads: 8,
        ),
      );
      await tap(tester, 'appearance-palette-amber');
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(services.settings.themePalette, AppPalette.rose);
      await tester.tap(find.text('主题与外观'));
      await tester.pumpAndSettle();
      await tap(tester, 'appearance-reset');
      expect(services.settings.themePalette, AppPalette.rose);
      await apply(tester);
      expect(services.settings.theme, 'System');
      expect(services.settings.themePalette, AppPalette.blue);
      expect(services.settings.glassStyle, GlassStyle.clear);
      expect(services.settings.hideResourceNavigation, isFalse);
      expect(services.settings.threads, 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('resource navigation can be previewed, saved and restored', (
    tester,
  ) async {
    final services = await render(tester);
    expect(services.settings.hideResourceNavigation, isFalse);
    await tap(tester, 'appearance-hide-resource-navigation');
    expect(services.settings.hideResourceNavigation, isFalse);
    final preview = find.byKey(const Key('appearance-preview'));
    expect(
      tester
          .widget<AppNavigation>(
            find.descendant(of: preview, matching: find.byType(AppNavigation)),
          )
          .hideResources,
      isTrue,
    );
    expect(
      find.byKey(const Key('appearance-preview-resources')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('navigation-1')), findsNothing);
    await apply(tester);
    expect(services.settings.hideResourceNavigation, isTrue);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigation-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('navigation-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('parse-resources')), findsOneWidget);
    expect(find.text('更新来源'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('navigation-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题与外观'));
    await tester.pumpAndSettle();
    await tap(tester, 'appearance-hide-resource-navigation');
    await apply(tester);
    expect(services.settings.hideResourceNavigation, isFalse);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigation-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('navigation-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('parse-resources')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system mode and solid navigation update without changing tabs', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await render(tester, settings: const AppSettings());
    await tap(tester, 'appearance-palette-violet');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.text('项目资料.zip'))).colorScheme.primary,
      Color(AppPalette.violet.darkAccent),
    );
    await tap(tester, 'appearance-glass-solid');
    final filters = tester.widgetList<BackdropFilter>(
      find.descendant(
        of: find.byKey(const Key('appearance-preview')),
        matching: find.byType(BackdropFilter),
      ),
    );
    expect(filters.where((filter) => filter.enabled), isEmpty);
    await tester.ensureVisible(find.byKey(const Key('appearance-preview')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-2')));
    await tester.pumpAndSettle();
    await apply(tester);
    expect(
      tester
          .widget<Semantics>(find.byKey(const ValueKey('navigation-2')))
          .properties
          .selected,
      true,
    );
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    ('phone', const Size(393, 864), 1.0, AppPalette.mint, 'Light'),
    ('phone-dark', const Size(393, 864), 1.0, AppPalette.violet, 'Dark'),
    ('phone-large-text', const Size(320, 700), 1.8, AppPalette.rose, 'Dark'),
    ('desktop', const Size(1100, 820), 1.0, AppPalette.amber, 'Light'),
  ]) {
    testWidgets(
      '${scenario.$1} appearance controls remain visible and usable',
      (tester) async {
        await render(
          tester,
          size: scenario.$2,
          scale: scenario.$3,
          settings: AppSettings(theme: scenario.$5, themePalette: scenario.$4),
        );
        await screenshot(tester, scenario.$1);
        expect(
          find.byKey(const Key('appearance-apply')).hitTestable(),
          findsOneWidget,
        );
        for (final palette in AppPalette.values) {
          await tap(tester, 'appearance-palette-${palette.name}');
          expect(tester.takeException(), isNull);
        }
        for (final style in GlassStyle.values) {
          await tap(tester, 'appearance-glass-${style.name}');
          expect(tester.takeException(), isNull);
        }
        await tap(tester, 'appearance-glass-controls');
        await tap(tester, 'appearance-glass-low-power');
        expect(tester.takeException(), isNull);
        await screenshot(tester, '${scenario.$1}-options');
        expect(
          find.byKey(const Key('appearance-apply')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        scenario.$1 == 'desktop'
            ? TargetPlatform.windows
            : TargetPlatform.android,
      ),
    );
  }
}
