/// Requires an actual current VO frame, then watches playback progress.
/// mpv uses video time while a normal video track is playing. This detects a
/// stalled core or missing output, but cannot prove Flutter presented the pixels.
class PlaybackVideoMonitor {
  PlaybackVideoMonitor({this.timeout = const Duration(seconds: 15)});

  final Duration timeout;
  Duration? _since, _sampleAt, _position;

  void reset() {
    _since = _sampleAt = _position = null;
  }

  bool observe({
    required Duration elapsed,
    required Duration position,
    required bool outputReady,
    required bool eligible,
    required double rate,
  }) {
    if (!eligible) {
      reset();
      return false;
    }
    final previousAt = _sampleAt, previousPosition = _position;
    final moved = previousPosition == null
        ? Duration.zero
        : position - previousPosition;
    final interval = previousAt == null ? Duration.zero : elapsed - previousAt;
    // A seek or a suspended sampler starts a fresh observation window.
    final discontinuity =
        interval.isNegative ||
        interval > const Duration(seconds: 6) ||
        moved.isNegative ||
        moved.inMilliseconds > interval.inMilliseconds * rate + 2000;
    if (_since == null ||
        discontinuity ||
        (outputReady && moved > Duration.zero)) {
      _since = elapsed;
    }
    _sampleAt = elapsed;
    _position = position;
    return elapsed - _since! >= timeout;
  }
}
