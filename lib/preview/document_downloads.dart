import '../core/json.dart';
import '../domain/downloads.dart';
import '../download/download_manager.dart';
import '../platform/file_access.dart';

/// Reuses only the same remote file and owner. URLs, cookies and share tokens
/// are temporary and deliberately do not form part of the identity.
class DocumentDownloads {
  DocumentDownloads(this.downloads);
  final DownloadManager downloads;
  final _pending = <String, Future<String?>>{};

  static String _key(DownloadOrigin origin) {
    final session = origin.session, file = origin.file;
    return [
      session.platform.key,
      session.mode.name,
      session.accountId ?? '',
      session.rootId,
      session.personalSpaceId,
      session.familyId,
      session.meta('webdavRoot'),
      session.sourceLink?.shareId ?? '',
      file.id,
    ].map(Uri.encodeComponent).join('/');
  }

  static bool matches(DownloadTask task, DownloadOrigin requested) {
    if (task.spec.isTorrent ||
        task.spec.source == null ||
        task.status == DownloadStatus.cancelled) {
      return false;
    }
    try {
      final stored = DownloadOrigin.fromJson(task.spec.source!);
      if (_key(stored) != _key(requested)) return false;
      final a = stored.file, b = requested.file;
      if (a.size > 0 && b.size > 0 && a.size != b.size) return false;
      if (a.modifiedAt.isNotEmpty &&
          b.modifiedAt.isNotEmpty &&
          a.modifiedAt != b.modifiedAt) {
        return false;
      }
      if (a.hashType != null &&
          a.hashValue?.isNotEmpty == true &&
          b.hashType == a.hashType &&
          b.hashValue?.isNotEmpty == true &&
          a.hashValue!.toLowerCase() != b.hashValue!.toLowerCase()) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Check actual saved files first, then reuse an unfinished task. A missing
  /// completed file is never passed to the viewer just because its record exists.
  Future<String?> resolve(
    DownloadOrigin origin, {
    required Future<String?> Function() create,
  }) {
    final file = origin.file;
    final key = [
      _key(origin),
      '${file.size}',
      file.modifiedAt,
      file.hashType ?? '',
      file.hashValue?.toLowerCase() ?? '',
    ].map(Uri.encodeComponent).join('/');
    return _pending.putIfAbsent(key, () {
      final result = _resolve(origin, create);
      return result.whenComplete(() {
        _pending.remove(key);
      });
    });
  }

  Future<String?> _resolve(
    DownloadOrigin origin,
    Future<String?> Function() create,
  ) async {
    return await find(origin) ?? await create();
  }

  /// Inspect matching downloads without creating, resuming or retrying a task.
  /// Opening a preview is not authorization to start a new download.
  Future<String?> find(DownloadOrigin origin) async {
    final candidates = downloads.tasks
        .where((task) => matches(task, origin))
        .toList();
    var inaccessible = false;
    for (final task in candidates) {
      if (task.status != DownloadStatus.completed) continue;
      final state = await downloads.files.inspect(task.savedPath);
      final current = downloads.task(task.id);
      inaccessible |= state == FileAvailability.inaccessible;
      if (state == FileAvailability.present &&
          current?.status == DownloadStatus.completed &&
          current?.savedPath == task.savedPath &&
          matches(current!, origin)) {
        return task.id;
      }
    }
    for (final task in candidates) {
      final current = downloads.task(task.id);
      if (current != null && !current.terminal && matches(current, origin)) {
        return current.id;
      }
    }
    require(!inaccessible, '已下载的文档无法访问，请先检查保存目录权限');
    return null;
  }
}
