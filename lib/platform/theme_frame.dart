import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

typedef ThemeFrameCapture =
    Future<ui.Image?> Function(
      ui.Rect bounds,
      double devicePixelRatio,
      double pixelRatio,
    );

/// Copies the displayed Android surface instead of replaying its clip layers.
/// The frame stays in memory and is used only by the theme transition.
Future<ui.Image?> captureAndroidThemeFrame(
  ui.Rect bounds,
  double devicePixelRatio,
  double pixelRatio,
) async {
  const channel = MethodChannel('com.asterlink.app/native');
  try {
    final frame = await channel
        .invokeMapMethod<String, Object?>('captureThemeFrame', {
          'left': (bounds.left * devicePixelRatio).round(),
          'top': (bounds.top * devicePixelRatio).round(),
          'right': (bounds.right * devicePixelRatio).round(),
          'bottom': (bounds.bottom * devicePixelRatio).round(),
          'width': (bounds.width * pixelRatio).ceil(),
          'height': (bounds.height * pixelRatio).ceil(),
        })
        .timeout(const Duration(milliseconds: 800));
    final bytes = frame?['bytes'];
    final width = frame?['width'], height = frame?['height'];
    if (bytes is! Uint8List ||
        bytes.isEmpty ||
        bytes.length > 16 * 1024 * 1024 ||
        width is! int ||
        height is! int ||
        width <= 0 ||
        height <= 0 ||
        width * height > 3000000 ||
        (width / height - bounds.width / bounds.height).abs() > 2 / height) {
      return null;
    }
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final image = (await codec.getNextFrame()).image;
      if (image.width == width && image.height == height) return image;
      image.dispose();
      return null;
    } finally {
      codec.dispose();
    }
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  }
}
