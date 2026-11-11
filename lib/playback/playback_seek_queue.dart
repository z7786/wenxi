import 'dart:async';

/// While a native seek is pending, keep only the newest user target.
class PlaybackSeekQueue {
  PlaybackSeekQueue(this.send);
  final Future<void> Function(Duration) send;
  Duration? _pending;
  Future<void>? _running;
  bool _closed = false;

  Future<void> seek(Duration position) {
    if (_closed) return Future.value();
    _pending = position;
    return _running ??= _drain();
  }

  Future<void> _drain() async {
    // Assign _running before invoking send, even if send throws synchronously.
    await Future<void>.value();
    try {
      while (!_closed && _pending != null) {
        final position = _pending!;
        _pending = null;
        await send(position);
      }
    } finally {
      _pending = null;
      _running = null;
    }
  }

  void close() {
    _closed = true;
    _pending = null;
  }
}
