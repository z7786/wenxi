import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/liquid_glass.dart';
import 'package:asterlink/ui/app_navigation.dart';
import 'package:asterlink/ui/resource_search_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Load before any widget-test fake clock owns the shared program future.
    await ui.FragmentProgram.fromAsset(liquidGlassShaderAsset);
  });

  testWidgets(
    'global controls, low power and hidden pages stop backdrop processing',
    (tester) async {
      var controls = false, lowPower = false, visible = true;
      late StateSetter update;
      await tester.runAsync(
        () => tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MaterialApp(
                theme: appTheme(
                  Brightness.light,
                  glassControls: controls,
                  glassLowPower: lowPower,
                ),
                home: TickerMode(
                  enabled: visible,
                  child: Scaffold(
                    body: ResourceSearchBar(
                      key: const Key('search-control'),
                      field: const Text('输入资源名称'),
                      onPressed: () {},
                      buttonKey: const Key('search-button'),
                    ),
                    bottomNavigationBar: AppNavigation(
                      selectedIndex: 0,
                      onSelected: (_) {},
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder searchFilters() => find.descendant(
        of: find.byKey(const Key('search-control')),
        matching: find.byType(BackdropFilter),
      );
      expect(searchFilters(), findsNothing);
      expect(find.byType(BackdropFilter), findsWidgets);
      update(() => controls = true);
      await tester.pumpAndSettle();
      expect(searchFilters(), findsWidgets);
      update(() => lowPower = true);
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('search-button'))),
      );
      await tester.pump();
      expect(
        tester
            .widget<AnimatedScale>(
              find.descendant(
                of: find.byKey(const Key('search-button')),
                matching: find.byType(AnimatedScale),
              ),
            )
            .scale,
        1,
      );
      await gesture.cancel();
      update(() {
        lowPower = false;
        visible = false;
      });
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);
      update(() => visible = true);
      await tester.pumpAndSettle();
      expect(searchFilters(), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'RGB dispersion covers straight lens edges and leaves the center unchanged',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        for (var y = 0; y < 96; y += 2) {
          canvas.drawRect(
            Rect.fromLTWH(0, y.toDouble(), 256, 2),
            Paint()..color = y % 4 == 0 ? Colors.white : Colors.black,
          );
        }
        final sourcePicture = recorder.endRecording();
        final source = await sourcePicture.toImage(256, 96);
        sourcePicture.dispose();
        final program = await ui.FragmentProgram.fromAsset(
          liquidGlassShaderAsset,
        );
        final shader = program.fragmentShader()
          ..setFloat(0, 256)
          ..setFloat(1, 96)
          ..setFloat(2, .5)
          ..setFloat(3, 24 / 96)
          ..setFloat(4, 24 / 96)
          ..setFloat(5, 0)
          ..setFloat(7, 1)
          ..setImageSampler(0, source);
        final pixels = <List<int>>[];
        try {
          for (final dispersion in [0.0, .24]) {
            shader.setFloat(6, dispersion);
            final output = ui.PictureRecorder();
            Canvas(output).drawRect(
              const Rect.fromLTWH(0, 0, 256, 96),
              Paint()..shader = shader,
            );
            final picture = output.endRecording();
            final image = await picture.toImage(256, 96);
            try {
              pixels.add(
                (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!.buffer.asUint8List().toList(),
              );
              final directory = Platform.environment['APP_GLASS_PREVIEW_DIR'];
              if (directory != null && dispersion > 0) {
                final file = File('$directory/rgb-dispersion.png');
                await file.parent.create(recursive: true);
                await file.writeAsBytes(
                  (await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  ))!.buffer.asUint8List(),
                );
              }
            } finally {
              image.dispose();
              picture.dispose();
            }
          }
          var colored = 0;
          for (var y = 0; y < 24; y++) {
            final index = (y * 256 + 128) * 4;
            if ((pixels.last[index] - pixels.last[index + 2]).abs() > 10) {
              colored++;
            }
            expect(pixels.first[index], closeTo(pixels.first[index + 2], 1));
          }
          expect(colored, greaterThan(4));
          for (var y = 30; y < 66; y++) {
            final index = (y * 256 + 128) * 4;
            expect(
              pixels.last.sublist(index, index + 4),
              pixels.first.sublist(index, index + 4),
            );
          }
        } finally {
          shader.dispose();
          source.dispose();
        }
      });
    },
  );

  testWidgets(
    'glass follows intrinsic child size and opaque modes disable filters',
    (tester) async {
      for (final style in GlassStyle.values) {
        for (final highContrast in [false, true]) {
          // The material shares its loading future across surfaces and tests.
          // Create that future in the real zone so a disposed fake test clock
          // cannot retain its callbacks for the next test.
          await tester.runAsync(
            () => tester.pumpWidget(
              MaterialApp(
                theme: appTheme(Brightness.light, glassStyle: style),
                home: MediaQuery(
                  data: MediaQueryData(highContrast: highContrast),
                  child: const Scaffold(
                    body: Center(
                      child: LiquidGlassSurface(
                        key: Key('surface'),
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 120, height: 40),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byKey(const Key('surface'))),
            const Size(144, 64),
          );
          final filters = tester.widgetList<BackdropFilter>(
            find.byType(BackdropFilter),
          );
          expect(
            filters.any((filter) => filter.enabled),
            !highContrast && style != GlassStyle.solid,
          );
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets(
    'button keeps its label centered, lets taps through and retains disabled state',
    (tester) async {
      var taps = 0;
      var enabled = true;
      var style = GlassStyle.clear;
      var reduce = false;
      late StateSetter update;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MaterialApp(
              theme: appTheme(
                Brightness.light,
                glassStyle: style,
                glassControls: true,
              ),
              home: MediaQuery(
                data: MediaQueryData(disableAnimations: reduce),
                child: Scaffold(
                  body: Center(
                    child: LiquidGlassButton(
                      key: const Key('button'),
                      onPressed: enabled ? () => taps++ : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(200, 60),
                        padding: const EdgeInsets.all(12),
                      ),
                      child: const Text('搜索'),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('button'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getCenter(find.text('搜索')), tester.getCenter(button));
      var gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
        greaterThan(1),
      );
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(taps, 0);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(taps, 1);
      update(() => enabled = false);
      await tester.pumpAndSettle();
      update(() => style = GlassStyle.frosted);
      await tester.pumpAndSettle();
      expect(tester.getCenter(find.text('搜索')), tester.getCenter(button));
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(find.byType(BackdropFilter), findsNothing);
      update(() {
        enabled = true;
        style = GlassStyle.clear;
        reduce = true;
      });
      await tester.pumpAndSettle();
      gesture = await tester.startGesture(tester.getCenter(button));
      await tester.pump();
      expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 2);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rounded lens refracts edge pixels and preserves the center', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final sourceRecorder = ui.PictureRecorder();
      final sourceCanvas = Canvas(sourceRecorder);
      sourceCanvas.drawColor(const Color(0xff0000ff), BlendMode.src);
      sourceCanvas.drawRect(
        const Rect.fromLTWH(0, 0, 12, 64),
        Paint()..color = const Color(0xffff0000),
      );
      sourceCanvas.drawRect(
        const Rect.fromLTWH(12, 0, 16, 64),
        Paint()..color = const Color(0xff00ff00),
      );
      final sourcePicture = sourceRecorder.endRecording();
      final source = await sourcePicture.toImage(256, 64);
      sourcePicture.dispose();
      final program = await ui.FragmentProgram.fromAsset(
        liquidGlassShaderAsset,
      );
      final shader = program.fragmentShader()
        ..setFloat(0, 256)
        ..setFloat(1, 64)
        ..setFloat(2, .5)
        ..setFloat(3, 24 / 64)
        ..setFloat(4, 24 / 64)
        ..setFloat(5, 0)
        ..setFloat(6, 0)
        ..setFloat(7, 1)
        ..setImageSampler(0, source);
      final recorder = ui.PictureRecorder();
      Canvas(
        recorder,
      ).drawRect(const Rect.fromLTWH(0, 0, 256, 64), Paint()..shader = shader);
      final picture = recorder.endRecording();
      final refracted = await picture.toImage(256, 64);
      try {
        final pixels = (await refracted.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final edge = (32 * 256 + 8) * 4;
        final center = (32 * 256 + 128) * 4;
        expect(pixels.getUint8(edge + 1), greaterThan(110));
        expect(pixels.getUint8(edge), lessThan(20));
        expect(pixels.getUint8(center + 2), greaterThan(240));
        expect(pixels.getUint8(center + 3), 255);
      } finally {
        picture.dispose();
        refracted.dispose();
        shader.dispose();
        source.dispose();
      }
    });
  });

  testWidgets('dispersion preserves neutral color across translucent content', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final sourceRecorder = ui.PictureRecorder();
      final canvas = Canvas(sourceRecorder);
      for (var y = 0; y < 64; y++) {
        canvas.drawRect(
          Rect.fromLTWH(0, y.toDouble(), 256, 1),
          Paint()..color = Color.fromARGB(64 + (y % 8) * 25, 255, 255, 255),
        );
      }
      final sourcePicture = sourceRecorder.endRecording();
      final source = await sourcePicture.toImage(256, 64);
      sourcePicture.dispose();
      final program = await ui.FragmentProgram.fromAsset(
        liquidGlassShaderAsset,
      );
      final shader = program.fragmentShader()
        ..setFloat(0, 256)
        ..setFloat(1, 64)
        ..setFloat(2, .5)
        ..setFloat(3, 24 / 64)
        ..setFloat(4, 24 / 64)
        ..setFloat(5, 0)
        ..setFloat(7, 1)
        ..setImageSampler(0, source);
      final results = <List<int>>[];
      try {
        for (final dispersion in [0.0, .3]) {
          shader.setFloat(6, dispersion);
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 256, 64),
            Paint()..shader = shader,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(256, 64);
          try {
            final data = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            results.add(data.buffer.asUint8List().toList());
          } finally {
            image.dispose();
            picture.dispose();
          }
        }
        var changedAlpha = 0;
        for (var offset = 0; offset < results.last.length; offset += 4) {
          final dispersed = results.last;
          expect(dispersed[offset + 3], inInclusiveRange(60, 245));
          for (var channel = 0; channel < 3; channel++) {
            expect(
              dispersed[offset + channel],
              closeTo(dispersed[offset + 3], 2),
              reason: 'White remains neutral in premultiplied RGBA.',
            );
          }
          if ((results.first[offset + 3] - dispersed[offset + 3]).abs() > 1) {
            changedAlpha++;
          }
        }
        expect(
          changedAlpha,
          greaterThan(0),
          reason: 'Exercise RGB separation.',
        );
        final center = (32 * 256 + 128) * 4;
        expect(
          results.last.sublist(center, center + 4),
          results.first.sublist(center, center + 4),
        );
      } finally {
        shader.dispose();
        source.dispose();
      }
    });
  });

  testWidgets(
    'live lens samples its own bounds after translation and scaling',
    (tester) async {
      if (!ui.ImageFilter.isShaderFilterSupported) return;
      for (final sigma in [0.0, 8.0]) {
        for (final offset in [const Offset(20, 20), const Offset(70, 410)]) {
          for (final scale in [1.0, 1.4]) {
            await tester.pumpWidget(
              MaterialApp(
                theme: appTheme(Brightness.light, glassStyle: GlassStyle.clear),
                home: RepaintBoundary(
                  key: const Key('optical-capture'),
                  child: Stack(
                    children: [
                      const Positioned.fill(
                        child: ColoredBox(color: Colors.white),
                      ),
                      Positioned(
                        left: offset.dx,
                        top: offset.dy,
                        child: Transform.scale(
                          scale: scale,
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: 256,
                            height: 64,
                            child: Stack(
                              children: [
                                const Positioned.fill(
                                  child: ColoredBox(color: Color(0xff0000ff)),
                                ),
                                const Positioned(
                                  left: 0,
                                  top: 0,
                                  bottom: 0,
                                  width: 12,
                                  child: ColoredBox(color: Color(0xffff0000)),
                                ),
                                const Positioned(
                                  left: 12,
                                  top: 0,
                                  bottom: 0,
                                  width: 16,
                                  child: ColoredBox(color: Color(0xff00ff00)),
                                ),
                                Positioned.fill(
                                  child: LiquidGlassSurface(
                                    opacity: 0,
                                    blurSigma: sigma,
                                    highlight: 0,
                                    shadow: 0,
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
            // Shader asset loading runs outside the fake widget-test clock.
            // Wait for the live filter rather than capturing its blur fallback.
            for (var attempt = 0; attempt < 100; attempt++) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 10)),
              );
              await tester.pumpAndSettle();
              if (find.byType(BackdropFilter).evaluate().length == 2) break;
            }
            expect(
              find.byType(BackdropFilter),
              findsNWidgets(2),
              reason: 'live filter $sigma $offset $scale',
            );
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('optical-capture')),
            );
            final pixels = (await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              try {
                final output = Platform.environment['APP_GLASS_PREVIEW_DIR'];
                if (output != null) {
                  final file = File(
                    '$output/optics-$sigma-${offset.dy}-$scale.png',
                  );
                  await file.parent.create(recursive: true);
                  final png = (await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  ))!;
                  await file.writeAsBytes(png.buffer.asUint8List());
                }
                final bytes = (await image.toByteData(
                  format: ui.ImageByteFormat.rawRgba,
                ))!;
                Color at(double x) {
                  final index =
                      (((offset.dy + 32 * scale).round()) * image.width +
                          (offset.dx + x * scale).round()) *
                      4;
                  return Color.fromARGB(
                    bytes.getUint8(index + 3),
                    bytes.getUint8(index),
                    bytes.getUint8(index + 1),
                    bytes.getUint8(index + 2),
                  );
                }

                return (at(8), at(128));
              } finally {
                image.dispose();
              }
            }))!;
            expect(
              pixels.$1.g,
              greaterThan(sigma == 0 ? .6 : .2),
              reason: 'edge $sigma $offset $scale',
            );
            expect(pixels.$2.b, greaterThan(.95));
            expect(pixels.$2.r, lessThan(.05));
            expect(pixels.$2.g, lessThan(.05));
          }
        }
      }
    },
  );
}
