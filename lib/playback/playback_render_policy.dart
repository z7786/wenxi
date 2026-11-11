import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// Physical render dimensions, bounded by the source and preserving its shape.
Size? playbackRenderSize({
  required Size source,
  required Size viewport,
  required double pixelRatio,
  required BoxFit fit,
  double scale = 1,
  double quality = 1,
}) {
  if (!source.isFinite ||
      source.isEmpty ||
      !viewport.isFinite ||
      viewport.isEmpty ||
      !pixelRatio.isFinite ||
      pixelRatio <= 0) {
    return null;
  }
  final x = viewport.width * pixelRatio / source.width;
  final y = viewport.height * pixelRatio / source.height;
  final factor =
      math.min(
        1.0,
        (fit == BoxFit.contain ? math.min(x, y) : math.max(x, y)) *
            scale.clamp(.1, 4),
      ) *
      quality.clamp(.5, 1);
  return Size(
    math.max(2, (source.width * factor / 2).ceil() * 2).toDouble(),
    math.max(2, (source.height * factor / 2).ceil() * 2).toDouble(),
  );
}

/// Require two bad, advancing windows before reducing rendering work once.
/// Counter resets, seeks, buffering and pauses never trigger a downgrade.
class PlaybackDropPolicy {
  Duration? _at;
  int? _drops;
  int _badWindows = 0;
  bool downgraded = false;
  void resetWindow() {
    _at = null;
    _drops = null;
    _badWindows = 0;
  }

  bool observe({
    required Duration elapsed,
    required int drops,
    required double? fps,
    required bool eligible,
  }) {
    final at = _at, previous = _drops;
    _at = elapsed;
    _drops = drops;
    if (!eligible ||
        fps == null ||
        !fps.isFinite ||
        fps < 1 ||
        at == null ||
        previous == null ||
        drops < previous ||
        elapsed <= at) {
      _badWindows = 0;
      return false;
    }
    final seconds = (elapsed - at).inMicroseconds / 1000000;
    if (seconds < 5 || seconds > 20) {
      _badWindows = 0;
      return false;
    }
    final delta = drops - previous;
    _badWindows = delta >= 10 && delta / (fps * seconds) >= .05
        ? _badWindows + 1
        : 0;
    if (downgraded || _badWindows < 2) return false;
    return downgraded = true;
  }
}
