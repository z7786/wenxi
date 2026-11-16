import 'dart:async';
import 'dart:collection';
import '../http.dart';

/// Shared by ordinary uploads and cross-cloud relay uploads. Queued work keeps
/// its caller's cancellation and account guard without holding a connection.
class UploadWorkLimiter {
  UploadWorkLimiter(this.limit, {this.reentrant = false}) : assert(limit > 0);
  final int limit;
  final bool reentrant;
  final _leaseKey = Object();
  final _waiting = Queue<_UploadSlot>();
  int _active = 0;

  Future<T> run<T>(Future<T> Function() action) async {
    RequestScope.checkpoint();
    if (reentrant && Zone.current[_leaseKey] == true) return action();
    final slot = _UploadSlot();
    _waiting.add(slot);
    _fill();
    try {
      await RequestScope.cancellable(slot.ready.future);
      return await runZoned(action, zoneValues: {_leaseKey: true});
    } finally {
      if (slot.acquired) {
        _active--;
      } else {
        _waiting.remove(slot);
      }
      _fill();
    }
  }

  void _fill() {
    while (_active < limit && _waiting.isNotEmpty) {
      final slot = _waiting.removeFirst();
      slot.acquired = true;
      _active++;
      slot.ready.complete();
    }
  }
}

class _UploadSlot {
  final ready = Completer<void>();
  bool acquired = false;
}

final uploadConnections = UploadWorkLimiter(6, reentrant: true);
final uploadHashWorkers = UploadWorkLimiter(2);
