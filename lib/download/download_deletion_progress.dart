import 'dart:async';
import '../core/operation_progress.dart';

class DownloadDeletionProgress {
  DownloadDeletionProgress(this.total);

  final int total;
  int processed = 0, succeeded = 0, failed = 0, skipped = 0;
  bool cancelled = false;
  OperationStage _activity = OperationStage.waitDownloadOperation;
  final _clock = Stopwatch()..start();
  int _lastReport = -100000;
  Timer? _pending;

  void report({OperationStage? activity, bool force = false}) {
    if (activity != null) _activity = activity;
    final remaining = 100000 - (_clock.elapsedMicroseconds - _lastReport);
    if (force || remaining <= 0) {
      _publish();
    } else {
      // Keep a fast item visible even when the next file or record save stalls.
      _pending ??= Timer(Duration(microseconds: remaining), _publish);
    }
  }

  void processedItem({int succeeded = 0, int failed = 0, int skipped = 0}) {
    processed++;
    this.succeeded += succeeded;
    this.failed += failed;
    this.skipped += skipped;
    report();
  }

  void confirm({int succeeded = 0, int failed = 0}) {
    this.succeeded += succeeded;
    this.failed += failed;
    report(force: true);
  }

  void _publish() {
    _pending?.cancel();
    _pending = null;
    _lastReport = _clock.elapsedMicroseconds;
    OperationProgress.reportItems((
      processed: processed,
      total: total,
      succeeded: succeeded,
      failed: failed,
      skipped: skipped,
      activity: _activity,
    ));
  }

  void finish() => _publish();
}
