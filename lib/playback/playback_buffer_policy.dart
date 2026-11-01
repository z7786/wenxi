import 'dart:math' as math;
import '../domain/playback.dart';

/// Rebalances packet and Range caches without increasing their combined budget.
/// Connection choices are ceilings; congestion reduces active concurrency.
class PlaybackBufferPolicy {
  PlaybackBufferPolicy({required int connectionLimit})
    : limit = connectionLimit.clamp(
        PlaybackPreferences.minConnections,
        PlaybackPreferences.maxConnections,
      ),
      connections = math.min(
        4,
        connectionLimit.clamp(
          PlaybackPreferences.minConnections,
          PlaybackPreferences.maxConnections,
        ),
      );

  static const mib = 1024 * 1024;
  static const totalBytes = 96 * mib;
  static const backBytes = 4 * mib;
  static const forwardSeconds = 90;
  static const readaheadSeconds = 90;
  int limit, connections;
  int forwardBytes = 16 * mib;
  double bytesPerSecond = 0;
  Duration? _sampleAt, _holdUntil;
  int _received = 0, _failures = 0;
  int? _lastStatus;

  void setLimit(int value) {
    limit = value.clamp(
      PlaybackPreferences.minConnections,
      PlaybackPreferences.maxConnections,
    );
    connections = math.min(connections, limit);
  }

  int forwardTarget({
    required int size,
    required Duration duration,
    required double rate,
    int seconds = forwardSeconds,
  }) {
    if (size <= 0 || duration <= Duration.zero) return forwardBytes;
    final average = size / (duration.inMilliseconds / 1000);
    final target =
        (average * seconds * rate.clamp(.25, 4) / mib).ceil().clamp(16, 48) *
        mib;
    // Only grow the packet cache within a session: mpv may keep old packets
    // briefly after a reduction, so immediately giving those bytes to the
    // proxy would exceed the combined memory budget.
    return math.max(forwardBytes, target);
  }

  int proxyBytesFor(int forward) => totalBytes - backBytes - forward;

  /// A short initial reserve, then a larger reserve after real underruns.
  /// The caller excludes seeks and user pauses from the rebuffer count. mpv's
  /// threshold is in media seconds, so preserve the reserve at faster speeds.
  double resumeSeconds({required int rebufferCount, required double rate}) =>
      (6 + 2 * rebufferCount.clamp(0, 3)) * rate.clamp(.25, 4);

  int observe({
    required Duration elapsed,
    required int receivedBytes,
    required int failures,
    required int? status,
    required int activeRequests,
    required double bufferedSeconds,
    required bool buffering,
    required bool playing,
    double requiredBytesPerSecond = 0,
  }) {
    final previous = _sampleAt;
    final delta = receivedBytes - _received;
    final failed = failures > _failures;
    final throttled = {429, 503}.contains(status) && status != _lastStatus;
    _sampleAt = elapsed;
    _received = receivedBytes;
    _failures = failures;
    _lastStatus = status;
    if (previous != null && elapsed > previous) {
      final seconds = (elapsed - previous).inMicroseconds / 1000000;
      final speed = math.max(0, delta) / seconds;
      bytesPerSecond = bytesPerSecond == 0
          ? speed
          : bytesPerSecond * .65 + speed * .35;
    }
    if (!playing) return connections;
    if (failed || throttled && activeRequests > 0) {
      connections = math.max(1, connections ~/ 2);
      _holdUntil = elapsed + const Duration(seconds: 12);
    } else if (previous != null &&
        elapsed > previous &&
        (_holdUntil == null || elapsed >= _holdUntil!)) {
      // Low buffered time during startup/seeking is normal. Add connections
      // only if measured throughput cannot comfortably supply the media rate;
      // otherwise extra requests compete for the same bandwidth. Unknown
      // duration/size retains the existing early growth behavior.
      if ((buffering || bufferedSeconds < 30) &&
          (requiredBytesPerSecond <= 0 ||
              bytesPerSecond < requiredBytesPerSecond * 1.5) &&
          activeRequests >= connections &&
          delta > 0) {
        connections = math.min(limit, connections + 2);
      }
    }
    return connections;
  }
}
