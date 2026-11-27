import 'dart:async';

import '../core/json.dart';
import '../diagnostics/app_log.dart';
import 'windows_player_components.dart';

class PlaybackRuntimeUnavailable extends AppException {
  const PlaybackRuntimeUnavailable() : super('内置播放器加载失败，请重试或选择外部播放器；解析和下载不受影响');
}

/// Optional playback initialization never owns application startup or data.
class PlaybackRuntime {
  PlaybackRuntime({required Future<void> Function() initialize})
    : _initialize = initialize;

  static final shared = PlaybackRuntime(initialize: initializeMediaRuntime);
  final Future<void> Function() _initialize;
  Future<void>? _pending;
  bool ready = false;
  PlaybackRuntimeUnavailable? failure;
  int _attempts = 0;

  /// Warm once; failures are retried only by an explicit playback request.
  void preload() {
    if (_attempts != 0) return;
    unawaited(ensureInitialized().catchError((Object _) {}));
  }

  Future<void> ensureInitialized() {
    if (ready) return Future.value();
    if (_pending case final pending?) return pending;
    final attempt = ++_attempts;
    final watch = Stopwatch()..start();
    return _pending = Future<void>.sync(_initialize)
        .then((_) {
          ready = true;
          failure = null;
          DiagnosticLog.event(
            'player.runtime_ready',
            fields: {
              'attempt': attempt,
              'elapsedMs': watch.elapsedMilliseconds,
            },
          );
        })
        .catchError((Object error, StackTrace stack) {
          failure = const PlaybackRuntimeUnavailable();
          DiagnosticLog.error(
            'player.runtime_load_failed',
            error,
            stack,
            fields: {
              'attempt': attempt,
              'elapsedMs': watch.elapsedMilliseconds,
            },
          );
          Error.throwWithStackTrace(failure!, stack);
        })
        .whenComplete(() => _pending = null);
  }
}
