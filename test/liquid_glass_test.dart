import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/appearance.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/liquid_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'glass follows intrinsic child size and opaque modes disable filters',
    (tester) async {
      for (final style in GlassStyle.values) {
        for (final highContrast in [false, true]) {
          await tester.pumpWidget(
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
          );
          await tester.pumpAndSettle();
          expect(
            tester.getSize(find.byKey(const Key('surface'))),
            const Size(144, 64),
          );
          final filter = tester.widget<BackdropFilter>(
            find.byType(BackdropFilter),
          );
          expect(filter.enabled, !highContrast && style != GlassStyle.solid);
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
              theme: appTheme(Brightness.light, glassStyle: style),
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
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isFalse,
      );
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
}
