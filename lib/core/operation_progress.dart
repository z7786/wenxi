import 'dart:async';
import 'package:flutter/foundation.dart';

enum OperationStage {
  verifyShare('验证分享链接'),
  readFiles('读取文件列表'),
  createTemporary('创建临时转存目录'),
  transfer('转存文件'),
  waitTransfer('等待转存完成'),
  downloadLink('获取下载链接'),
  playbackLink('获取播放链接'),
  parserQueue('等待解析'),
  serverParse('解析文件'),
  deleteDownloads('删除下载任务'),
  waitDownloadOperation('等待任务操作完成'),
  stopDownloads('停止下载'),
  deleteFiles('删除本地文件'),
  removeDownloadRecords('移除下载记录'),
  cleanup('删除临时转存');

  const OperationStage(this.label);
  final String label;
  String get runningLabel => '正在$label…';
}

enum OperationStepStatus { running, completed, failed, cancelled }

/// Processed items can still be awaiting a grouped record save. Only confirmed
/// outcomes belong in succeeded, failed, and skipped.
typedef OperationItems = ({
  int processed,
  int total,
  int succeeded,
  int failed,
  int skipped,
  OperationStage? activity,
});

class OperationStep {
  const OperationStep(
    this.id,
    this.stage,
    this.status, {
    this.itemsRead,
    this.items,
    this.queuePosition,
    this.waitingForRetry = false,
  });
  final int id;
  final OperationStage stage;
  final OperationStepStatus status;
  final int? itemsRead;
  final OperationItems? items;
  final int? queuePosition;
  final bool waitingForRetry;
}

class _ProgressBinding {
  const _ProgressBinding(this.progress, this.generation);
  final OperationProgress progress;
  final int generation;
}

/// Progress belongs to the operation that started it, including across account
/// scopes. Only fixed stages and counts are exposed; links and credentials stay out.
class OperationProgress extends ValueNotifier<List<OperationStep>> {
  OperationProgress() : super(const []);
  static final _key = Object();
  static final _stageKey = Object();
  static final _activeStepsKey = Object();
  static OperationStage? get currentStage =>
      Zone.current[_stageKey] as OperationStage?;
  final _notificationZone = Zone.current;
  int _generation = 0, _nextId = 0;
  bool _closed = false;

  Future<T> run<T>(Future<T> Function() action) {
    _closed = false;
    final generation = ++_generation;
    _publish(const []);
    final previous = Zone.current[_key] as List<_ProgressBinding>? ?? const [];
    return runZoned(
      action,
      zoneValues: {
        _key: [
          for (final binding in previous)
            if (binding.progress != this) binding,
          _ProgressBinding(this, generation),
        ],
      },
    );
  }

  /// Background cleanup keeps its own progress without extending the dialog
  /// for the operation that queued it.
  static T detached<T>(T Function() action) => runZoned(
    action,
    zoneValues: {
      _key: const <_ProgressBinding>[],
      _stageKey: null,
      _activeStepsKey: const <(_ProgressBinding, int)>[],
    },
  );

  static Future<T> step<T>(
    OperationStage stage,
    Future<T> Function() action, {
    OperationStepStatus Function(T result)? statusForResult,
  }) async {
    final bindings = Zone.current[_key] as List<_ProgressBinding>? ?? const [];
    final started = [
      for (final binding in bindings)
        (binding, binding.progress._start(binding.generation, stage)),
    ];
    try {
      final result = await runZoned(
        action,
        zoneValues: {_stageKey: stage, _activeStepsKey: started},
      );
      final status =
          statusForResult?.call(result) ?? OperationStepStatus.completed;
      for (final (binding, id) in started) {
        binding.progress._finish(binding.generation, id, status);
      }
      return result;
    } catch (_) {
      for (final (binding, id) in started) {
        binding.progress._finish(
          binding.generation,
          id,
          OperationStepStatus.failed,
        );
      }
      rethrow;
    }
  }

  static void reportFiles(int count, {bool waitingForRetry = false}) {
    if (count < 0 || currentStage != OperationStage.readFiles) return;
    final active =
        Zone.current[_activeStepsKey] as List<(_ProgressBinding, int)>? ??
        const [];
    for (final (binding, id) in active) {
      binding.progress._files(binding.generation, id, count, waitingForRetry);
    }
  }

  static void reportItems(OperationItems items) {
    if (items.total < 0 ||
        items.processed < 0 ||
        items.processed > items.total ||
        items.succeeded < 0 ||
        items.failed < 0 ||
        items.skipped < 0 ||
        items.succeeded + items.failed + items.skipped > items.processed) {
      return;
    }
    final active =
        Zone.current[_activeStepsKey] as List<(_ProgressBinding, int)>? ??
        const [];
    for (final (binding, id) in active) {
      binding.progress._items(binding.generation, id, items);
    }
  }

  static void reportServerStage(OperationStage stage, {int? queuePosition}) {
    final active =
        Zone.current[_activeStepsKey] as List<(_ProgressBinding, int)>? ??
        const [];
    for (final (binding, id) in active) {
      binding.progress._serverStage(
        binding.generation,
        id,
        stage,
        queuePosition,
      );
    }
  }

  void _serverStage(
    int generation,
    int id,
    OperationStage stage,
    int? position,
  ) {
    if (!_current(generation)) return;
    final index = value.indexWhere(
      (step) => step.id == id && step.status == OperationStepStatus.running,
    );
    if (index < 0) return;
    if (value[index].stage == stage && value[index].queuePosition == position) {
      return;
    }
    final entries = value.toList();
    entries[index] = OperationStep(
      id,
      stage,
      OperationStepStatus.running,
      items: value[index].items,
      queuePosition: stage == OperationStage.parserQueue ? position : null,
    );
    _publish(entries);
  }

  void _files(int generation, int id, int count, bool waitingForRetry) {
    if (!_current(generation)) return;
    final index = value.indexWhere(
      (step) =>
          step.id == id &&
          step.stage == OperationStage.readFiles &&
          step.status == OperationStepStatus.running,
    );
    if (index < 0) return;
    final step = value[index];
    if (step.itemsRead == count && step.waitingForRetry == waitingForRetry) {
      return;
    }
    final entries = value.toList();
    entries[index] = OperationStep(
      id,
      step.stage,
      step.status,
      itemsRead: count,
      items: step.items,
      waitingForRetry: waitingForRetry,
    );
    _publish(entries);
  }

  void _items(int generation, int id, OperationItems items) {
    if (!_current(generation)) return;
    final index = value.indexWhere(
      (step) => step.id == id && step.status == OperationStepStatus.running,
    );
    if (index < 0) return;
    final step = value[index];
    if (step.items == items) return;
    final entries = value.toList();
    entries[index] = OperationStep(
      id,
      step.stage,
      step.status,
      itemsRead: step.itemsRead,
      items: items,
      queuePosition: step.queuePosition,
      waitingForRetry: step.waitingForRetry,
    );
    _publish(entries);
  }

  bool _current(int generation) => !_closed && generation == _generation;

  int _start(int generation, OperationStage stage) {
    final id = ++_nextId;
    if (!_current(generation)) return id;
    final entries = [
      ...value,
      OperationStep(id, stage, OperationStepStatus.running),
    ];
    // Keep long batch downloads bounded while preserving active steps.
    while (entries.length > 12) {
      final old = entries.indexWhere(
        (step) => step.status != OperationStepStatus.running,
      );
      if (old < 0) break;
      entries.removeAt(old);
    }
    _publish(entries);
    return id;
  }

  void _finish(int generation, int id, OperationStepStatus status) {
    if (!_current(generation)) return;
    _publish([
      for (final step in value)
        step.id == id
            ? OperationStep(
                id,
                step.stage,
                status,
                itemsRead: step.itemsRead,
                items: step.items,
                queuePosition: step.queuePosition,
              )
            : step,
    ]);
  }

  void _publish(List<OperationStep> steps) {
    if (steps.isEmpty && value.isEmpty) return;
    _notificationZone.run(() => value = List.unmodifiable(steps));
  }

  void close({bool cancelled = false, bool failed = false}) {
    if (_closed) return;
    _closed = true;
    _generation++;
    if (cancelled || failed) {
      _publish([
        for (final step in value)
          step.status == OperationStepStatus.running
              ? OperationStep(
                  step.id,
                  step.stage,
                  cancelled
                      ? OperationStepStatus.cancelled
                      : OperationStepStatus.failed,
                  itemsRead: step.itemsRead,
                  items: step.items,
                  queuePosition: step.queuePosition,
                )
              : step,
      ]);
    }
  }

  void clear() {
    close();
    _publish(const []);
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
