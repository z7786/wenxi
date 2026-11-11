import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import '../diagnostics/app_log.dart';

/// Flutter timings describe UI work, not the count of presented video frames.
class PlaybackUiDiagnostics {
  PlaybackUiDiagnostics({
    required this.eligible,
    required this.refreshRate,
    required this.context,
    Duration Function()? elapsed,
  }) : _elapsedOverride = elapsed;
  final bool Function() eligible;
  final double Function() refreshRate;
  final Map<String, Object?> Function() context;
  final _watch = Stopwatch();
  final Duration Function()? _elapsedOverride;
  Duration get _elapsed => _elapsedOverride?.call() ?? _watch.elapsed;
  Timer? _timer;
  Duration _lastTick = Duration.zero, _lastLog = Duration.zero;
  int _frames = 0, _overBudget = 0, _lateTicks = 0;
  double _maxBuildMs = 0, _maxRasterMs = 0, _maxLoopDelayMs = 0;

  void start() {
    _watch.start();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = _elapsed;
      final delay = math.max(
        0.0,
        (now - _lastTick).inMicroseconds / 1000 - 1000,
      );
      _lastTick = now;
      if (!_enabled) {
        _reset();
        _lastLog = now;
        return;
      }
      _maxLoopDelayMs = math.max(_maxLoopDelayMs, delay);
      if (delay >= 16) _lateTicks++;
      if (now - _lastLog < const Duration(seconds: 30)) return;
      DiagnosticLog.event(
        'player.ui_sample',
        fields: {
          ...context(),
          'uiTimingMode': kReleaseMode
              ? 'release'
              : kProfileMode
              ? 'profile'
              : 'debug',
          'uiSampleMs': (now - _lastLog).inMilliseconds,
          'displayHz': refreshRate(),
          'uiFrames': _frames,
          'uiOverBudgetFrames': _overBudget,
          'uiOverBudgetRatio': _frames == 0 ? 0 : _overBudget / _frames,
          'uiMaxBuildMs': _maxBuildMs,
          'uiMaxRasterMs': _maxRasterMs,
          'eventLoopMaxDelayMs': _maxLoopDelayMs,
          'eventLoopLateTicks': _lateTicks,
        },
      );
      _lastLog = now;
      _reset();
    });
  }

  bool get _enabled => DiagnosticLog.active?.enabled == true && eligible();
  void _timings(List<FrameTiming> timings) {
    if (!_enabled) return;
    final hz = refreshRate();
    final budgetMs = 1000 / (hz.isFinite && hz >= 1 ? hz : 60);
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds / 1000;
      final raster = timing.rasterDuration.inMicroseconds / 1000;
      _frames++;
      if (build > budgetMs || raster > budgetMs) _overBudget++;
      _maxBuildMs = math.max(_maxBuildMs, build);
      _maxRasterMs = math.max(_maxRasterMs, raster);
    }
  }

  void _reset() {
    _frames = _overBudget = _lateTicks = 0;
    _maxBuildMs = _maxRasterMs = _maxLoopDelayMs = 0;
  }

  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_timings);
    _watch.stop();
  }
}
