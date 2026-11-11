import 'package:flutter/foundation.dart';
import '../domain/downloads.dart';
import '../domain/uploads.dart';
import '../upload/upload_task.dart';

@immutable
class NavigationTransferStatus {
  const NavigationTransferStatus({
    this.downloads = 0,
    this.uploads = 0,
    this.rapid = 0,
    this.progress = -1,
    this.completion = 0,
  });

  final int downloads, uploads, rapid, progress, completion;
  int get active => downloads + uploads + rapid;
  String get description => active == 0
      ? ''
      : '${[if (downloads > 0) '$downloads 个下载', if (uploads > 0) '$uploads 个上传', if (rapid > 0) '$rapid 个跨盘任务'].join('，')}正在传输${progress < 0 ? '' : '，本批进度 $progress%'}';

  @override
  bool operator ==(Object other) =>
      other is NavigationTransferStatus &&
      (downloads, uploads, rapid, progress, completion) ==
          (
            other.downloads,
            other.uploads,
            other.rapid,
            other.progress,
            other.completion,
          );
  @override
  int get hashCode =>
      Object.hash(downloads, uploads, rapid, progress, completion);
}

/// Observes the current batch only. Old history and removing records never
/// produce completion feedback, and finishing one file does not reset its ring.
class NavigationTransfers extends ValueNotifier<NavigationTransferStatus> {
  NavigationTransfers({
    required this.changes,
    required this.downloads,
    required this.uploads,
    required this.downloadById,
    required this.uploadById,
    this.rapid,
  }) : super(const NavigationTransferStatus()) {
    changes.addListener(_sync);
    _sync();
  }

  final Listenable changes;
  final Iterable<DownloadTask> Function() downloads;
  final Iterable<UploadTask> Function() uploads;
  final DownloadTask? Function(String) downloadById;
  final UploadTask? Function(String) uploadById;
  final int Function()? rapid;
  Map<String, ({String id, bool upload, int total})> _previous = {};
  final _interrupted = <String>{};
  int _finishedBytes = 0;

  void _sync() {
    final matching = rapid?.call() ?? 0;
    final current = <String, ({String id, bool upload, int total})>{};
    var down = 0, up = 0, bytes = 0, total = 0;
    var known = true;
    void include(String id, bool upload, int size, int sent) {
      final key = '${upload ? 'u' : 'd'}:$id';
      current[key] = (id: id, upload: upload, total: size);
      _interrupted.remove(key);
      if (size <= 0) {
        known = false;
      } else {
        total += size;
        bytes += sent.clamp(0, size);
      }
    }

    for (final task in downloads()) {
      if (!task.active) continue;
      down++;
      include(task.id, false, task.total, task.downloaded);
    }
    for (final task in uploads()) {
      if (!task.active) continue;
      up++;
      include(
        task.id,
        true,
        task.size,
        task.phase == UploadPhase.preparing ? 0 : task.sent,
      );
    }
    for (final entry in _previous.entries) {
      if (current.containsKey(entry.key)) continue;
      final previous = entry.value;
      final succeeded = previous.upload
          ? uploadById(previous.id)?.status == UploadStatus.completed
          : downloadById(previous.id)?.status == DownloadStatus.completed;
      if (succeeded) {
        final size = previous.upload
            ? uploadById(previous.id)?.size
            : downloadById(previous.id)?.total;
        _finishedBytes += (size ?? previous.total).clamp(0, 1 << 62);
      } else {
        _interrupted.add(entry.key);
      }
    }

    var completion = value.completion;
    if (current.isEmpty) {
      if (_previous.isNotEmpty && _interrupted.isEmpty && matching == 0) {
        completion++;
      }
      _finishedBytes = 0;
      _interrupted.clear();
    }
    _previous = current;
    final denominator = total + _finishedBytes;
    value = NavigationTransferStatus(
      downloads: down,
      uploads: up,
      rapid: matching,
      progress: matching == 0 && current.isNotEmpty && known && denominator > 0
          ? ((bytes + _finishedBytes) * 100 ~/ denominator).clamp(0, 99)
          : -1,
      completion: completion,
    );
  }

  @override
  void dispose() {
    changes.removeListener(_sync);
    super.dispose();
  }
}
