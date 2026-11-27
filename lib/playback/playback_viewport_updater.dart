import 'dart:async';
import 'package:flutter/widgets.dart';

/// Coalesces window resize bursts and serializes native surface changes.
class PlaybackViewportUpdater {
  PlaybackViewportUpdater(this.apply, {required this.onError});
  final Future<void> Function(Size) apply;
  final void Function(Object, StackTrace) onError;
  Size? _target, _applied;
  Timer? _timer;
  Future<void>? _running;
  bool _closed = false;

  void request(Size? size) {
    if (_closed || size == _target) return;
    _target = size;
    _timer?.cancel();
    _timer = null;
    if (size == null || size == _applied) return;
    _schedule();
  }

  void _schedule() {
    _timer = Timer(const Duration(milliseconds: 200), () {
      _timer = null;
      if (_closed || _running != null) return;
      _running = _update().whenComplete(() {
        _running = null;
        if (!_closed &&
            _timer == null &&
            _target != null &&
            _target != _applied) {
          _schedule();
        }
      });
    });
  }

  Future<void> _update() async {
    final size = _target;
    if (size == null || size == _applied) return;
    try {
      await apply(size);
      _applied = size;
    } catch (error, stack) {
      if (_target == size) _target = null;
      if (!_closed) onError(error, stack);
    }
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    await _running;
  }
}
