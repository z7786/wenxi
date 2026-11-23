import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../domain/cloud_file_time.dart';
import '../domain/models.dart';
import 'http.dart';

/// Browsing remains usable while two bounded walkers read descendant dates.
/// A partial traversal never replaces a folder's own date with a false result.
class CloudFolderDates extends ChangeNotifier {
  CloudFolderDates({
    required this.read,
    required this.directoryId,
    required this.validate,
    this.maxDirectories = 10000,
    this.maxFiles = 200000,
  });
  final Future<CloudFilePage> Function(BrowseSession, String, String?) read;
  final String Function(BrowseSession, CloudFile) directoryId;
  final void Function(BrowseSession) validate;
  final int maxDirectories, maxFiles;
  final dates = <String, DateTime?>{};
  final _seen = <String>{}, _waiting = Queue<CloudFile>();
  Object? _key;
  RequestScope _scope = RequestScope();
  int _active = 0, failed = 0;
  bool _disposed = false, _stopped = false;
  bool get busy => _active > 0 || _waiting.isNotEmpty;

  void update(
    Object key,
    BrowseSession session,
    List<CloudFile> files,
    DateTime reference, {
    required bool enabled,
  }) {
    if (_key != key) {
      _scope.cancel();
      _scope = RequestScope();
      _key = key;
      dates.clear();
      _seen.clear();
      _waiting.clear();
      _active = failed = 0;
      _stopped = false;
    }
    if (!enabled || _stopped || _disposed) return;
    for (final file in files.where((f) => f.isDirectory)) {
      if (_seen.add(directoryId(session, file))) _waiting.add(file);
    }
    final scope = _scope;
    while (_active < 2 && _waiting.isNotEmpty) {
      final folder = _waiting.removeFirst();
      _active++;
      // update may be called during build; all notifications are asynchronous.
      unawaited(
        Future<void>.microtask(() async {
          try {
            final date = await scope.run(
              () => _walk(session, folder, reference),
            );
            if (identical(scope, _scope) && !_disposed) {
              dates[directoryId(session, folder)] = date;
            }
          } catch (_) {
            if (identical(scope, _scope) &&
                !scope.token.isCancelled &&
                !_disposed) {
              failed++;
            }
          } finally {
            if (identical(scope, _scope) && !_disposed) {
              _active--;
              update(key, session, const [], reference, enabled: enabled);
              notifyListeners();
            }
          }
        }),
      );
    }
  }

  Future<DateTime?> _walk(
    BrowseSession session,
    CloudFile folder,
    DateTime reference,
  ) async {
    final pending = Queue<String>()..add(directoryId(session, folder));
    final visited = <String>{};
    DateTime? newest;
    var count = 0, pages = 0;
    while (pending.isNotEmpty) {
      RequestScope.checkpoint();
      validate(session);
      final parent = pending.removeFirst();
      if (!visited.add(parent)) continue;
      require(visited.length <= maxDirectories, '目录过多，请进入子目录排序');
      String? cursor;
      final cursors = <String>{};
      do {
        require(++pages <= maxDirectories, '分页过多，请进入子目录排序');
        RequestScope.checkpoint();
        validate(session);
        final page = await read(session, parent, cursor);
        RequestScope.checkpoint();
        validate(session);
        for (final file in page.files) {
          require(++count <= maxFiles, '文件过多，请进入子目录排序');
          if (file.isDirectory) {
            pending.add(directoryId(session, file));
          } else {
            final date = cloudFileSortDate(
              file.modifiedAt,
              reference: reference,
            );
            if (date != null && (newest == null || date.isAfter(newest))) {
              newest = date;
            }
          }
        }
        cursor = page.nextCursor;
        require(cursor == null || cursors.add(cursor), '文件列表分页重复');
      } while (cursor != null);
    }
    return newest;
  }

  void stop() {
    _scope.cancel();
    _waiting.clear();
    _stopped = true;
  }

  @override
  void dispose() {
    _disposed = true;
    _scope.cancel();
    super.dispose();
  }
}
