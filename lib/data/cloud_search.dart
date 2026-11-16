import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../domain/auth.dart';
import '../domain/models.dart';
import 'http.dart';
import 'http_retry.dart';

enum CloudSearchPhase {
  idle,
  running,
  completed,
  partial,
  stopped,
  limited,
  failed,
}

class CloudSearchHit {
  CloudSearchHit(this.file, List<(String, String)> trail)
    : trail = List.unmodifiable(trail),
      key = jsonEncode([trail.last.$1, file.id]);
  final CloudFile file;
  final List<(String, String)> trail;
  final String key;
  String get path => trail.map((entry) => entry.$2).join(' / ');
}

class CloudSearchIssue {
  const CloudSearchIssue(this.path, this.message);
  final String path, message;
}

class _Directory {
  const _Directory(this.trail, this.depth);
  final List<(String, String)> trail;
  final int depth;
  String get id => trail.last.$1;
}

class _SearchRun {
  _SearchRun(this.session, this.query, this.trail, this.matches);
  final BrowseSession session;
  final String query;
  final List<(String, String)> trail;
  final bool Function(CloudFile)? matches;
  final scope = RequestScope();
  final queue = Queue<_Directory>();
  final seenDirectories = <String>{}, seenFiles = <String>{};
  int parallel = 2, failuresInARow = 0;
  bool limited = false;
  String fatal = '';
}

/// A bounded, cancellable search inside one account/space or one share tree.
/// Listings retain their original file metadata for preview and download.
class CloudDirectorySearch extends ChangeNotifier {
  CloudDirectorySearch({
    required this.read,
    required this.directoryId,
    required this.validate,
    this.maxFolders = 2000,
    this.maxEntries = 50000,
    this.maxResults = 5000,
    this.cacheLifetime = const Duration(seconds: 45),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final Future<List<CloudFile>> Function(BrowseSession, String) read;
  final String Function(BrowseSession, CloudFile) directoryId;
  final void Function(BrowseSession) validate;
  final int maxFolders, maxEntries, maxResults;
  final Duration cacheLifetime;
  final DateTime Function() clock;
  final _hits = <CloudSearchHit>[];
  final _byFile = HashMap<CloudFile, CloudSearchHit>.identity();
  final _issues = <CloudSearchIssue>[];
  final _cache = <String, (DateTime, List<CloudFile>)>{};
  BrowseSession? _cacheSession;
  _SearchRun? _run;
  bool _disposed = false;
  int _cacheEntries = 0;
  CloudSearchPhase phase = CloudSearchPhase.idle;
  int searchedFolders = 0, scannedEntries = 0, failedFolders = 0;
  String error = '';

  bool get running => phase == CloudSearchPhase.running;
  List<CloudSearchHit> get hits => UnmodifiableListView(_hits);
  List<CloudSearchIssue> get issues => UnmodifiableListView(_issues);
  CloudSearchHit? hitFor(CloudFile file) => _byFile[file];

  bool _current(_SearchRun run) => !_disposed && identical(_run, run);
  bool _active(_SearchRun run) =>
      _current(run) && running && !run.scope.token.isCancelled;

  void clearCache() {
    _cache.clear();
    _cacheEntries = 0;
    _cacheSession = null;
  }

  void remember(BrowseSession session, String parent, List<CloudFile> files) {
    if (!identical(session, _cacheSession)) {
      clearCache();
      _cacheSession = session;
    }
    final old = _cache.remove(parent);
    _cacheEntries -= old?.$2.length ?? 0;
    if (files.length > 20000) return;
    while (_cache.isNotEmpty &&
        (_cache.length >= 128 || _cacheEntries + files.length > 20000)) {
      _cacheEntries -= _cache.remove(_cache.keys.first)!.$2.length;
    }
    _cache[parent] = (clock(), List.unmodifiable(files));
    _cacheEntries += files.length;
  }

  List<CloudFile>? cached(BrowseSession session, String parent) {
    if (!identical(session, _cacheSession)) return null;
    final entry = _cache.remove(parent);
    if (entry == null) return null;
    if (clock().difference(entry.$1) > cacheLifetime) {
      _cacheEntries -= entry.$2.length;
      return null;
    }
    _cache[parent] = entry;
    return entry.$2;
  }

  void stop() {
    if (!running) return;
    _run?.scope.cancel();
    phase = CloudSearchPhase.stopped;
    notifyListeners();
  }

  void clear() {
    _run?.scope.cancel();
    _run = null;
    _hits.clear();
    _byFile.clear();
    _issues.clear();
    phase = CloudSearchPhase.idle;
    searchedFolders = scannedEntries = failedFolders = 0;
    error = '';
    if (!_disposed) notifyListeners();
  }

  void _guard(_SearchRun run) {
    if (!_active(run)) throw const AppException('搜索已停止');
    try {
      validate(run.session);
    } catch (failure) {
      run.fatal = _message(failure);
      run.scope.cancel();
      rethrow;
    }
  }

  static String _message(Object failure) =>
      failure is AppException ? failure.message : '文件夹读取失败，请检查网络后重试';

  Future<void> start(
    BrowseSession session,
    List<(String, String)> trail,
    String query, {
    bool refresh = false,
    bool Function(CloudFile)? matches,
  }) async {
    clear();
    if (_disposed || query.trim().isEmpty && matches == null || trail.isEmpty) {
      return;
    }
    if (refresh) clearCache();
    final run = _SearchRun(
      session,
      query.trim().toLowerCase(),
      List.of(trail),
      matches,
    );
    _run = run;
    phase = CloudSearchPhase.running;
    run.queue.add(_Directory(run.trail, 0));
    run.seenDirectories.add(trail.last.$1);
    notifyListeners();
    try {
      while (_active(run) && run.queue.isNotEmpty) {
        _guard(run);
        final batch = <_Directory>[];
        while (batch.length < run.parallel && run.queue.isNotEmpty) {
          batch.add(run.queue.removeFirst());
        }
        await Future.wait(batch.map((folder) => _scan(run, folder)));
      }
    } catch (failure) {
      if (_active(run)) run.fatal = _message(failure);
    } finally {
      if (_current(run) && phase == CloudSearchPhase.running) {
        error = run.fatal;
        phase = run.fatal.isNotEmpty
            ? CloudSearchPhase.failed
            : run.limited
            ? CloudSearchPhase.limited
            : failedFolders > 0
            ? CloudSearchPhase.partial
            : CloudSearchPhase.completed;
        notifyListeners();
      }
    }
  }

  Future<void> _scan(_SearchRun run, _Directory folder) async {
    var counted = false;
    try {
      _guard(run);
      var files = cached(run.session, folder.id);
      if (files == null) {
        files = await run.scope.run<List<CloudFile>>(
          () => RequestScope.guarded(
            () => ReadRetryScope(
              retries: 1,
              checkpoint: () => _guard(run),
              onRetry: (attempt) async {
                if (attempt.failure.status == 429 ||
                    attempt.failure.status == 503) {
                  run.parallel = 1;
                }
              },
            ).run(() => RequestScope.cancellable(read(run.session, folder.id))),
            () => _guard(run),
          ),
        );
        _guard(run);
        remember(run.session, folder.id, files);
      }
      _guard(run);
      searchedFolders++;
      counted = true;
      run.failuresInARow = 0;
      for (final file in files) {
        _guard(run);
        if (scannedEntries >= maxEntries || _hits.length >= maxResults) {
          run.limited = true;
          run.scope.cancel();
          break;
        }
        scannedEntries++;
        final key = jsonEncode([folder.id, file.id]);
        if (!run.seenFiles.add(key)) continue;
        if ((file.displayName.toLowerCase().contains(run.query) ||
                file.name.toLowerCase().contains(run.query)) &&
            (run.matches?.call(file) ?? true)) {
          final hit = CloudSearchHit(file, folder.trail);
          _hits.add(hit);
          _byFile[file] = hit;
        }
        if (file.isDirectory) {
          final id = directoryId(run.session, file);
          if (!run.seenDirectories.contains(id)) {
            if (folder.depth >= 64 ||
                run.seenDirectories.length >= maxFolders) {
              run.limited = true;
            } else {
              run.seenDirectories.add(id);
              run.queue.add(
                _Directory([
                  ...folder.trail,
                  (id, file.name),
                ], folder.depth + 1),
              );
            }
          }
        }
        // Large cached directories also yield so stop/typing stays responsive.
        if (scannedEntries % 200 == 0) {
          if (_current(run)) notifyListeners();
          await Future<void>.delayed(Duration.zero);
        }
      }
    } catch (failure) {
      if (!_active(run)) return;
      if (!counted) searchedFolders++;
      failedFolders++;
      run.failuresInARow++;
      if (_issues.length < 30) {
        _issues.add(
          CloudSearchIssue(
            folder.trail.map((entry) => entry.$2).join(' / '),
            _message(failure),
          ),
        );
      }
      if (failure is AccountLoginRequired || run.failuresInARow >= 5) {
        run.fatal = failure is AccountLoginRequired
            ? failure.message
            : '连续多个文件夹读取失败，已停止搜索，请检查网络或登录状态';
        run.scope.cancel();
      }
    } finally {
      if (_current(run)) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _run?.scope.cancel();
    clearCache();
    super.dispose();
  }
}
