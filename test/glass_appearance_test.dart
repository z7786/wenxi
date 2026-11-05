import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/backgrounds.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/domain/background.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/ui/app_background.dart';
import 'package:asterlink/ui/app_navigation.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/appearance_preview.dart';

// Sample empty space between navigation items, including the painted backdrop.
// Checking theme values alone misses opaque ancestors and opacity overrides.
Future<Color> navigationPixel(
  WidgetTester tester, {
  required bool rail,
  required String name,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('glass-capture')),
  );
  final navigation = tester.getRect(
    rail
        ? find.byType(AppNavigation)
        : find.byKey(const Key('floating-navigation')),
  );
  final sample = boundary.globalToLocal(
    rail ? navigation.topLeft + const Offset(8, 300) : navigation.center,
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final output = Platform.environment['APP_GLASS_PREVIEW_DIR'];
      if (output != null) {
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final file = File('$output/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
      }
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      var red = 0, green = 0, blue = 0;
      for (var y = sample.dy.round() - 2; y <= sample.dy.round() + 2; y++) {
        for (var x = sample.dx.round() - 2; x <= sample.dx.round() + 2; x++) {
          final offset = (y * image.width + x) * 4;
          red += data.getUint8(offset);
          green += data.getUint8(offset + 1);
          blue += data.getUint8(offset + 2);
        }
      }
      return Color.fromARGB(
        255,
        (red / 25).round(),
        (green / 25).round(),
        (blue / 25).round(),
      );
    } finally {
      image.dispose();
    }
  }))!;
}

double colorDistance(Color a, Color b) =>
    ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255 / 3;

Future<(int, int)> selectedNavigationPixels(
  WidgetTester tester,
  int selectedIndex,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('glass-capture')),
  );
  final tab = find.byKey(ValueKey('navigation-$selectedIndex'));
  final accent = Theme.of(tester.element(tab)).colorScheme.primary;
  final regions =
      [
        find.descendant(of: tab, matching: find.byType(SvgPicture)),
        find.descendant(of: tab, matching: find.byType(Text)),
      ].map((finder) {
        final rect = tester.getRect(finder);
        return Rect.fromPoints(
          boundary.globalToLocal(rect.topLeft),
          boundary.globalToLocal(rect.bottomRight),
        );
      }).toList();
  return (await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      int count(Rect region) {
        var pixels = 0;
        for (var y = region.top.ceil(); y < region.bottom.floor(); y++) {
          for (var x = region.left.ceil(); x < region.right.floor(); x++) {
            final offset = (y * image.width + x) * 4;
            final color = Color.fromARGB(
              255,
              data.getUint8(offset),
              data.getUint8(offset + 1),
              data.getUint8(offset + 2),
            );
            if (colorDistance(color, accent) < 12) pixels++;
          }
        }
        return pixels;
      }

      return (count(regions[0]), count(regions[1]));
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? fontFamily;
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
      fontFamily = 'GlassFixture';
      await (FontLoader(fontFamily!)..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
    }
  });

  Future<void> renderNavigation(
    WidgetTester tester, {
    required GlassStyle style,
    required Brightness brightness,
    bool rail = false,
    bool highContrast = false,
    int selectedIndex = 0,
    Color backdrop = const Color(0xff1e88e5),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(brightness, glassStyle: style, fontFamily: fontFamily),
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 640),
            highContrast: highContrast,
            disableAnimations: true,
          ),
          child: Material(
            color: Colors.transparent,
            child: RepaintBoundary(
              key: const Key('glass-capture'),
              child: BackgroundScope(
                active: true,
                settings: const BackgroundSettings(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: backdrop),
                    Align(
                      alignment: rail
                          ? Alignment.centerLeft
                          : Alignment.bottomCenter,
                      child: AppNavigation(
                        rail: rail,
                        selectedIndex: selectedIndex,
                        onSelected: (_) {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'opaque navigation keeps selected icons and labels visible (${brightness.name})',
      (tester) async {
        for (final style in GlassStyle.values) {
          for (final selectedIndex in [0, 3]) {
            await renderNavigation(
              tester,
              style: style,
              brightness: brightness,
              highContrast: style != GlassStyle.solid,
              selectedIndex: selectedIndex,
            );
            final (icon, label) = await selectedNavigationPixels(
              tester,
              selectedIndex,
            );
            expect(icon, greaterThan(10), reason: '$style selected icon');
            expect(label, greaterThan(10), reason: '$style selected label');
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final rail in [false, true]) {
    final layout = rail ? 'rail' : 'phone';
    for (final brightness in Brightness.values) {
      testWidgets(
        '$layout ${brightness.name} glass styles remain distinct over wallpaper',
        (tester) async {
          final pixels = <GlassStyle, Color>{};
          for (final style in GlassStyle.values) {
            await renderNavigation(
              tester,
              style: style,
              brightness: brightness,
              rail: rail,
            );
            pixels[style] = await navigationPixel(
              tester,
              rail: rail,
              name: '$layout-${brightness.name}-${style.name}',
            );
          }
          expect(
            colorDistance(
              pixels[GlassStyle.clear]!,
              pixels[GlassStyle.frosted]!,
            ),
            greaterThan(10),
            reason:
                'Wallpaper must not flatten clear and frosted to the same tint',
          );
          expect(
            colorDistance(
              pixels[GlassStyle.frosted]!,
              pixels[GlassStyle.solid]!,
            ),
            greaterThan(3),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('$layout solid and high contrast hide the backdrop', (
      tester,
    ) async {
      for (final style in GlassStyle.values) {
        final pixels = <Color>[];
        for (final backdrop in [Colors.blue, Colors.orange]) {
          await renderNavigation(
            tester,
            style: style,
            brightness: Brightness.light,
            rail: rail,
            highContrast: style != GlassStyle.solid,
            backdrop: backdrop,
          );
          pixels.add(
            await navigationPixel(
              tester,
              rail: rail,
              name: '$layout-opaque-${style.name}-${backdrop.toARGB32()}',
            ),
          );
        }
        expect(pixels[0], pixels[1]);
        final filters = tester.widgetList<BackdropFilter>(
          find.byType(BackdropFilter),
        );
        expect(filters.every((filter) => !filter.enabled), isTrue);
      }
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name} preview demonstrates glass without a custom wallpaper',
      (tester) async {
        final repository = BackgroundRepository(
          Directory.systemTemp,
          current: () => const BackgroundSettings(),
        );
        final pixels = <GlassStyle, Color>{};
        for (final style in GlassStyle.values) {
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness, fontFamily: fontFamily),
              home: Scaffold(
                body: Center(
                  child: RepaintBoundary(
                    key: const Key('glass-capture'),
                    child: SizedBox(
                      width: 360,
                      child: AppearancePreview(
                        settings: AppSettings(
                          theme: brightness == Brightness.dark
                              ? 'Dark'
                              : 'Light',
                          glassStyle: style,
                        ),
                        repository: repository,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          pixels[style] = await navigationPixel(
            tester,
            rail: false,
            name: 'preview-${brightness.name}-${style.name}',
          );
        }
        expect(
          colorDistance(pixels[GlassStyle.clear]!, pixels[GlassStyle.frosted]!),
          greaterThan(8),
          reason: 'A flat preview makes the glass selection look ineffective',
        );
        expect(
          colorDistance(pixels[GlassStyle.frosted]!, pixels[GlassStyle.solid]!),
          greaterThan(3),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
