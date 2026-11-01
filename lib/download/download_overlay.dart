import 'dart:async';
import 'mobile_data_download_guard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import '../domain/downloads.dart';
import '../platform/native_engine.dart';
import '../domain/uploads.dart';
import '../upload/upload_task.dart';

/// A value snapshot: upload tasks are mutable and must not be retained between
/// refreshes. Only presentation data crosses the platform channel.
class _OverlayTask {
  const _OverlayTask({
    required this.id,
    required this.name,
    required this.status,
    required this.createdAt,
    required this.bytes,
    required this.total,
    required this.speed,
    required this.label,
    required this.action,
    required this.actionLabel,
    this.upload = false,
  });
  final String id, name, status, label, action, actionLabel;
  final int createdAt, bytes, total, speed;
  final bool upload;
  String get key => '${upload ? 'upload' : 'download'}:$id';
  bool get active => status == 'running' || status == 'pending';
  bool get completed => status == 'completed';
  bool get failed => status == 'failed' || status == 'interrupted';

  factory _OverlayTask.download(DownloadTask t) => _OverlayTask(
    id: t.id,
    name: t.spec.fileName,
    status: t.status.name,
    createdAt: t.createdAt,
    bytes: t.downloaded,
    total: t.total,
    speed: t.active ? t.speed : 0,
    label: t.phase.isNotEmpty && t.active ? t.phase : t.status.label,
    action: t.active
        ? 'pause'
        : t.status == DownloadStatus.paused || t.status == DownloadStatus.failed
        ? 'resume'
        : '',
    actionLabel: t.active ? '暂停' : '继续',
  );
  factory _OverlayTask.upload(UploadTask t) => _OverlayTask(
    id: t.id,
    name: t.name,
    status: t.status.name,
    upload: true,
    createdAt: t.createdAt,
    bytes: t.status == UploadStatus.completed
        ? t.size
        : t.phase == UploadPhase.preparing
        ? 0
        : t.sent,
    total: t.size,
    speed: t.status == UploadStatus.running && t.phase == UploadPhase.uploading
        ? t.speed
        : 0,
    label: t.stage,
    action: t.canRetry ? 'retryUpload' : 'openUploads',
    actionLabel: t.canRetry
        ? '重传'
        : t.active
        ? '管理'
        : '查看',
  );
}

/// Tracks the current run, excluding unrelated completed, failed and paused history.
class DownloadOverlayBatch {
  final _ids = <String>{};
  final _previous = <String, String>{};
  bool _initialized = false;

  void reset() {
    _ids.clear();
    _previous.clear();
    _initialized = false;
  }

  static bool _active(String? status) =>
      status == 'pending' || status == 'running';

  Json snapshot(
    List<DownloadTask> downloads, {
    List<UploadTask> uploads = const [],
    bool dark = false,
  }) {
    final all = [
      ...downloads.map(_OverlayTask.download),
      ...uploads.map(_OverlayTask.upload),
    ];
    final available = all
        .where((t) => t.upload || t.status != 'cancelled')
        .toList();
    final activeTasks = available.where((t) => t.active).toList();
    if (!_initialized) {
      _ids.addAll(activeTasks.map((t) => t.key));
      if (_ids.isEmpty && available.isNotEmpty) {
        final latest = available.reduce(
          (a, b) => a.createdAt >= b.createdAt ? a : b,
        );
        _ids.add(latest.key);
      }
      _initialized = true;
    } else {
      final started = available.where((t) {
        final previous = _previous[t.key];
        // Also observe short downloads/retries that finish between UI updates.
        return previous == null ||
            t.active && !_active(previous) ||
            t.completed && previous != 'completed' && !_active(previous);
      }).toList();
      if (started.isNotEmpty) {
        final runContinues = activeTasks.any(
          (t) => _ids.contains(t.key) && _active(_previous[t.key]),
        );
        if (!runContinues) _ids.clear();
        _ids.addAll(started.map((t) => t.key));
      }
      _ids.addAll(activeTasks.map((t) => t.key));
    }
    final availableIds = available.map((t) => t.key).toSet();
    _ids.removeWhere((id) => !availableIds.contains(id));
    _previous
      ..clear()
      ..addEntries(all.map((t) => MapEntry(t.key, t.status)));
    final tasks = available.where((t) => _ids.contains(t.key)).toList()
      ..sort((a, b) {
        final status = (a.active ? 0 : 1).compareTo(b.active ? 0 : 1);
        return status != 0 ? status : b.createdAt.compareTo(a.createdAt);
      });
    final complete = tasks.isNotEmpty && tasks.every((t) => t.completed);
    final known = tasks.isNotEmpty && tasks.every((t) => t.total > 0);
    final total = tasks.fold<int>(0, (n, t) => n + t.total);
    final received = tasks.fold<int>(
      0,
      (n, t) => n + (t.total > 0 ? t.bytes.clamp(0, t.total) : t.bytes),
    );
    final active = tasks.where((t) => t.active).length;
    final failed = tasks.where((t) => t.failed).length;
    final completed = tasks.where((t) => t.completed).length;
    final down = tasks.where((t) => !t.upload).toList();
    final up = tasks.where((t) => t.upload).toList();
    final downActive = down.where((t) => t.active).length;
    final upActive = up.where((t) => t.active).length;
    final direction = down.isNotEmpty && up.isNotEmpty
        ? 'mixed'
        : up.isNotEmpty
        ? 'upload'
        : 'download';
    return {
      'dark': dark,
      'runId': (tasks.map((t) => t.key).toList()..sort()).join(','),
      'direction': direction,
      'downloadCount': down.length,
      'uploadCount': up.length,
      'downloadActive': downActive,
      'uploadActive': upActive,
      'downloadSpeed': down
          .where((t) => t.active)
          .fold<int>(0, (n, t) => n + t.speed),
      'uploadSpeed': up
          .where((t) => t.active)
          .fold<int>(0, (n, t) => n + t.speed),
      'count': tasks.length,
      'active': active,
      'completed': completed,
      'failed': failed,
      'downloaded': received,
      'total': known ? total : 0,
      'progress': complete
          ? 100
          : known
          ? (received * 100 ~/ total).clamp(0, 99)
          : -1,
      'speed': tasks.where((t) => t.active).fold<int>(0, (n, t) => n + t.speed),
      'status': tasks.isEmpty
          ? '暂无任务'
          : complete
          ? '全部完成'
          : active > 0
          ? downActive > 0 && upActive > 0
                ? '正在传输'
                : upActive > 0
                ? '正在上传'
                : '正在下载'
          : failed > 0
          ? (completed > 0
                ? '部分失败'
                : direction == 'upload'
                ? '上传失败'
                : direction == 'mixed'
                ? '传输失败'
                : '下载失败')
          : up.isNotEmpty && down.isEmpty
          ? '已取消'
          : '已暂停',
      'canPause': downActive > 0,
      'canResume': down.any(
        (t) => t.status == 'paused' || t.status == 'failed',
      ),
      'tasks': [
        for (final t in tasks.take(20))
          {
            'id': t.key,
            'taskId': t.id,
            'direction': t.upload ? 'upload' : 'download',
            'name': String.fromCharCodes(t.name.runes.take(120)),
            'status': t.status,
            'label': t.label,
            'downloaded': t.bytes,
            'total': t.total,
            'speed': t.active ? t.speed : 0,
            'progress': t.completed
                ? 100
                : t.total > 0
                ? (t.bytes * 100 ~/ t.total).clamp(0, 99)
                : -1,
            'action': t.action,
            'actionLabel': t.actionLabel,
          },
      ],
    };
  }
}

class DownloadOverlay extends ChangeNotifier {
  DownloadOverlay({
    required this.supported,
    required this.changes,
    required this.tasks,
    required this.pause,
    required this.resume,
    required this.pauseAll,
    required this.resumeAll,
    required this.openDownloads,
    required this.dark,
    this.appearance,
    this.uploadTasks,
    this.retryUpload,
    this.openUploads,
    Future<Object?> Function(String, Json)? invoke,
  }) : _invoke =
           invoke ??
           ((method, args) =>
               nativeChannel.invokeMethod<Object?>(method, args)) {
    if (supported) changes.addListener(_changed);
  }
  final bool supported;
  final Listenable changes;
  final List<DownloadTask> Function() tasks;
  final List<UploadTask> Function()? uploadTasks;
  final Future<void> Function(String)? retryUpload;
  final VoidCallback? openUploads;
  final Future<void> Function(String) pause, resume;
  final Future<void> Function() pauseAll, resumeAll;
  final VoidCallback openDownloads;
  final bool Function() dark;
  final Json Function(bool dark)? appearance;
  final Future<Object?> Function(String, Json) _invoke;
  final _batch = DownloadOverlayBatch();
  Timer? _timer;
  bool visible = false,
      pendingPermission = false,
      _closed = false,
      _opening = false;

  Future<void> toggle() async {
    if (!supported || _closed || _opening) return;
    _opening = true;
    try {
      if (visible || pendingPermission) {
        await _invoke('downloadOverlayClose', {});
        stateChanged({});
      } else {
        _batch.reset();
        final state = await _invoke('downloadOverlayShow', _snapshot());
        stateChanged(asJson(state));
      }
    } on PlatformException catch (e) {
      throw AppException(e.message ?? '无法开启传输悬浮窗，请检查悬浮窗权限');
    } finally {
      _opening = false;
    }
  }

  Json _snapshot() {
    final isDark = dark();
    return {
      ..._batch.snapshot(
        tasks(),
        uploads: uploadTasks?.call() ?? const [],
        dark: isDark,
      ),
      if (appearance != null) 'appearance': appearance!(isDark),
    };
  }

  void refreshAppearance() => _changed();
  void stateChanged(Json state) {
    if (_closed) return;
    visible = state.boolean('visible');
    pendingPermission = state.boolean('pendingPermission');
    notifyListeners();
    if (visible) _changed();
  }

  void _changed() {
    if (_closed || !visible || _timer != null) return;
    _timer = Timer(const Duration(milliseconds: 750), () async {
      _timer = null;
      if (_closed || !visible) return;
      try {
        await _invoke('downloadOverlayUpdate', _snapshot());
      } on PlatformException {
        stateChanged({});
      } on MissingPluginException {
        stateChanged({});
      }
    });
  }

  Future<void> action(Json arguments) async {
    if (_closed) return;
    try {
      await _action(arguments);
    } on DownloadConfirmationCancelled {
      // The foreground confirmation was dismissed; keep tasks paused.
    }
  }

  Future<void> _action(Json arguments) async {
    final id = arguments.str('id');
    switch (arguments.str('action')) {
      case 'pause':
        if (tasks().any((t) => t.id == id && t.active)) {
          await pause(id);
        }
      case 'resume':
        if (tasks().any(
          (t) =>
              t.id == id &&
              (t.status == DownloadStatus.paused ||
                  t.status == DownloadStatus.failed),
        )) {
          await resume(id);
        }
      case 'pauseAll':
        await pauseAll();
      case 'resumeAll':
        await resumeAll();
      case 'openDownloads':
        openDownloads();
      case 'openUploads':
        (openUploads ?? openDownloads)();
      case 'retryUpload':
        if (uploadTasks?.call().any((t) => t.id == id && t.canRetry) == true) {
          await retryUpload?.call(id);
        }
    }
    _changed();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    if (supported) {
      changes.removeListener(_changed);
      try {
        await _invoke('downloadOverlayClose', {});
      } on PlatformException {
        /* Platform already detached. */
      } on MissingPluginException {
        /* No Android host. */
      }
    }
    dispose();
  }
}
