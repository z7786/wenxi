import 'dart:async';
import 'dart:ui' as ui;

import 'package:asterlink/platform/theme_frame.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/native');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'native frame maps logical crop to physical surface and decodes pixels',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff2e7d32), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(80, 40);
      final png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'captureThemeFrame');
            expect(call.arguments, {
              'left': 20,
              'top': 60,
              'right': 420,
              'bottom': 260,
              'width': 80,
              'height': 40,
            });
            return {'bytes': png, 'width': 80, 'height': 40};
          });
      final captured = await captureAndroidThemeFrame(
        const ui.Rect.fromLTWH(10, 30, 200, 100),
        2,
        .4,
      );
      expect(captured, isNotNull);
      expect(captured!.width, 80);
      final rgba = (await captured.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      expect(rgba.buffer.asUint8List().take(4), [46, 125, 50, 255]);
      captured.dispose();
    },
  );

  for (final response in [
    null,
    {'bytes': Uint8List(4), 'width': 0, 'height': 1},
    {'bytes': Uint8List(4), 'width': 3000001, 'height': 1},
    {'bytes': Uint8List(4), 'width': 1, 'height': 100},
    {'bytes': Uint8List(4), 'width': 2, 'height': 1},
  ]) {
    test('unavailable or invalid native image is rejected $response', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => response);
      expect(
        await captureAndroidThemeFrame(
          const ui.Rect.fromLTWH(0, 0, 20, 10),
          1,
          1,
        ),
        isNull,
      );
    });
  }

  test('missing native bridge leaves normal theme change available', () async {
    expect(
      await captureAndroidThemeFrame(
        const ui.Rect.fromLTWH(0, 0, 20, 10),
        1,
        1,
      ),
      isNull,
    );
  });

  test('capture timeout does not wait indefinitely for a surface', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => Completer<Object?>().future);
    expect(
      await captureAndroidThemeFrame(
        const ui.Rect.fromLTWH(0, 0, 20, 10),
        1,
        1,
      ),
      isNull,
    );
  });
}
