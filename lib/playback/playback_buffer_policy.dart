import 'dart:math' as math;
import '../domain/playback.dart';

/// Rebalances packet and Range caches within a platform-specific byte budget.
/// Connection choices are ceilings; congestion reduces active concurrency.
class PlaybackBufferPolicy {
  PlaybackBufferPolicy({required int connectionLimit, this.desktop = false})
    : limit = connectionLimit.clamp(
        PlaybackPreferences.minConnections,
        PlaybackPreferences.maxConnections,
      ),
      connections = math.min(
        8,
        connectionLimit.clamp(
          PlaybackPreferences.minConnections,
          PlaybackPreferences.maxConnections,
        ),
      );

  static const mib = 1024 * 1024;
  static const totalBytes = 96 * mib;
  static const desktopTotalBytes = 320 * mib;
  static const backBytes = 4 * mib;
  static const forwardSeconds = 90;
  static const readaheadSeconds = 90;
  final bool desktop;
  int get byteBudget => desktop ? desktopTotalBytes : totalBytes;
  int get maxForwardBytes => (desktop ? 256 : 48) * mib;
  int limit, connections;
  int forwardBytes = 16 * mib;
  double bytesPerSecond = 0;
  Duration? _sampleAt, _holdUntil;
  int _received = 0, _failures = 0;
  int? _lastStatus;
  Duration? _trialAt;
  int _trialConnections = 0;
  double _trialSpeed = 0;

  void setLimit(int value) {
    final previous = limit;
    limit = value.clamp(
      PlaybackPreferences.minConnections,
      PlaybackPreferences.maxConnections,
    );
    connections = math.min(connections, limit);
    if (limit < previous) _trialAt = null;
    if (limit > previous && _holdUntil == null) {
      connections = math.max(connections, math.min(8, limit));
    }
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
        (average * seconds * rate.clamp(.25, 4) / mib).ceil().clamp(
          16,
          maxForwardBytes ~/ mib,
        ) *
        mib;
    // Only grow the packet cache within a session: the decoder may keep old packets
    // briefly after a reduction, so immediately giving those bytes to the
    // proxy would exceed the combined memory budget.
    return math.max(forwardBytes, target);
  }

  int proxyBytesFor(int forward) => desktop
      ? math.min(64 * mib, byteBudget - backBytes - forward)
      : byteBudget - backBytes - forward;

  /// A short initial reserve, then a larger reserve after real underruns.
  /// The caller excludes seeks and user pauses from the rebuffer count. The decoder's
  /// threshold is in media seconds, so preserve the reserve at faster speeds.
  double resumeSeconds({required int rebufferCount, required double rate}) =>
      (6 + 2 * rebufferCount.clamp(0, 3)) * rate.clamp(.25, 4);

  int observe({
    required Duration elapsed,
    required int receivedBytes,
    required int failures,
    required int? status,
    required int activeRequests,
    int? requestCapacity,
    required double bufferedSeconds,
    required bool buffering,
    required bool playing,
    double requiredBytesPerSecond = 0,
  }) {
    final ceiling = math.min(limit, requestCapacity ?? limit).clamp(1, limit);
    connections = math.min(connections, ceiling);
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
    if (!playing) {
      _trialAt = null;
      return connections;
    }
    if (failed || throttled && activeRequests > 0) {
      connections = math.max(1, connections ~/ 2);
      _holdUntil = elapsed + const Duration(seconds: 12);
      _trialAt = null;
    } else if (previous != null &&
        elapsed > previous &&
        (_holdUntil == null || elapsed >= _holdUntil!)) {
      // Judge a concurrency increase over several samples. Account-level
      // throttling may return 206 for every request while total speed falls.
      if (_trialAt != null) {
        if (activeRequests < connections || delta <= 0) {
          _trialAt = null;
        } else if (elapsed - _trialAt! < const Duration(seconds: 6)) {
          return connections;
        } else {
          _trialAt = null;
          if (bytesPerSecond < _trialSpeed * 1.1) {
            connections = math.min(ceiling, _trialConnections);
            _holdUntil = elapsed + const Duration(seconds: 30);
            return connections;
          }
        }
      }
      // Timestamp-based buffer estimates can be very large for m2ts files.
      // A measured bitrate deficit must trigger growth even with that estimate.
      if ((buffering ||
              bufferedSeconds < 30 ||
              requiredBytesPerSecond > 0 &&
                  bytesPerSecond < requiredBytesPerSecond) &&
          (requiredBytesPerSecond <= 0 ||
              bytesPerSecond < requiredBytesPerSecond * 1.5) &&
          activeRequests >= connections &&
          delta > 0 &&
          connections < ceiling) {
        if (requiredBytesPerSecond > 0 && bytesPerSecond > 0) {
          _trialAt = elapsed;
          _trialConnections = connections;
          _trialSpeed = bytesPerSecond;
        }
        connections = math.min(
          ceiling,
          connections + (connections < 16 ? 2 : connections ~/ 2),
        );
      }
    }
    return connections;
  }
}
