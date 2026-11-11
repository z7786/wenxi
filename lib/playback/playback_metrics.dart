/// Monotonic timings exclude user pauses and initial buffering from rebuffering.
class PlaybackMetrics {
  Duration? firstFrame, _bufferingAt, _seekAt, _seekTarget;
  Duration bufferingTime = Duration.zero;
  Duration? lastSeekTime;
  int bufferingCount = 0, seekCount = 0, seekTimeoutCount = 0;
  bool _started = false;
  bool _underrun = false;
  bool _awaitingProgress = true, _seekLanded = false;
  Duration? _lastPosition;

  /// Keep the small reserve until playback actually advances after open/seek.
  /// A rendered preview or a jump to the seek target is not resumed playback.
  bool get awaitingProgress => _awaitingProgress;

  void seek(Duration target, Duration elapsed) {
    _seekAt = elapsed;
    _seekTarget = target;
    _seekLanded = false;
    _started = false;
    _underrun = false;
    _awaitingProgress = true;
    _lastPosition = null;
    seekCount++;
    _finishBuffering(elapsed);
  }

  void pause(Duration elapsed) {
    _finishBuffering(elapsed);
    _underrun = false;
  }

  void observe({
    required Duration elapsed,
    required bool playing,
    required bool buffering,
    required Duration position,
  }) {
    final previousPosition = _lastPosition;
    _lastPosition = position;
    final advancing =
        playing &&
        !buffering &&
        previousPosition != null &&
        position > previousPosition &&
        position - previousPosition < const Duration(seconds: 2);
    if (_seekAt != null && _seekTarget != null) {
      if (_seekLanded && advancing) {
        lastSeekTime = elapsed - _seekAt!;
        _seekAt = _seekTarget = null;
        _started = true;
        _awaitingProgress = false;
      } else if (elapsed - _seekAt! > const Duration(seconds: 30)) {
        seekTimeoutCount++;
        _seekAt = _seekTarget = null;
      } else if ((position - _seekTarget!).abs() <
          const Duration(milliseconds: 500)) {
        _seekLanded = true;
      }
      return;
    }
    if (!playing) {
      _finishBuffering(elapsed);
      return;
    }
    if (!buffering) {
      if (advancing) {
        _started = true;
        _underrun = false;
        _awaitingProgress = false;
      }
      _finishBuffering(elapsed);
    } else if ((_started || _underrun) && _bufferingAt == null) {
      _bufferingAt = elapsed;
      if (!_underrun) bufferingCount++;
      _underrun = true;
      // Buffering can flicker before any new frame advances. Count that as
      // one underrun rather than escalating the reserve on every toggle.
      _started = false;
    }
  }

  void _finishBuffering(Duration elapsed) {
    final start = _bufferingAt;
    if (start != null) bufferingTime += elapsed - start;
    _bufferingAt = null;
  }

  Map<String, Object?> fields(Duration elapsed) => {
    'firstFrameMs': ?firstFrame?.inMilliseconds,
    'rebufferCount': bufferingCount,
    'awaitingPlaybackProgress': _awaitingProgress,
    'rebufferMs':
        (bufferingTime +
                (_bufferingAt == null
                    ? Duration.zero
                    : elapsed - _bufferingAt!))
            .inMilliseconds,
    'seekCount': seekCount,
    'seekTimeoutCount': seekTimeoutCount,
    if (_seekAt != null) 'seekWaitMs': (elapsed - _seekAt!).inMilliseconds,
    'seekReadyMs': ?lastSeekTime?.inMilliseconds,
  };
}
