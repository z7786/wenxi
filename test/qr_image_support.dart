import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:qr_flutter/qr_flutter.dart';

/// Independent QR encoder rendered inside screenshots, including a quiet zone.
Future<Uint8List> qrImageFixture(
  List<String> texts, {
  bool inverted = false,
  Set<int> invertedIndices = const {},
  bool transparent = false,
  int rotation = 0,
  double screenshotHeight = 360,
}) async {
  final width = 360 * texts.length, height = screenshotHeight.round();
  final recorder = ui.PictureRecorder();
  // Keep the recording and all native image resources scoped to this fixture.
  final surface = ui.Canvas(recorder);
  if (!transparent) {
    surface.drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()
        ..color = inverted
            ? const ui.Color(0xff101010)
            : const ui.Color(0xfffafafa),
    );
  }
  for (var i = 0; i < texts.length; i++) {
    final inverse = inverted || invertedIndices.contains(i);
    if (inverse && !inverted) {
      surface.drawRect(
        ui.Rect.fromLTWH(i * 360, 0, 360, screenshotHeight),
        ui.Paint()..color = const ui.Color(0xff101010),
      );
    }
    surface.save();
    surface.translate(i * 360 + 180, screenshotHeight / 2);
    surface.rotate(rotation * 3.141592653589793 / 180);
    surface.translate(-140, -140);
    QrPainter(
      data: texts[i],
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      gapless: true,
      eyeStyle: QrEyeStyle(
        color: inverse
            ? const ui.Color(0xfff0f0f0)
            : const ui.Color(0xff131313),
      ),
      dataModuleStyle: QrDataModuleStyle(
        color: inverse
            ? const ui.Color(0xfff0f0f0)
            : const ui.Color(0xff131313),
      ),
    ).paint(surface, const ui.Size(280, 280));
    surface.restore();
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  try {
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}
