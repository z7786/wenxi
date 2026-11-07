import 'dart:async';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../data/cloud_repository.dart';
import '../data/http.dart';
import '../data/state_store.dart';
import '../diagnostics/app_log.dart';
import '../domain/models.dart';
import '../domain/uploads.dart';
import '../download/download_activity.dart';
import 'upload_task.dart';
import 'upload_folder.dart';
import 'upload_sources.dart';

class UploadManager extends ChangeNotifier {
  UploadManager({
    required this.store,
    required this.cloud,
    this.foreground,
    UploadSources? sources,
  }) : sources = sources ?? UploadSources();
  final StateStore store;
  final CloudRepository cloud;
  final UploadSources sources;
  final Future<void> Function()? foreground;
  final _zone = Zone.current, _writes = AsyncGate(), _commands = AsyncGate();
  final _tasks = <UploadTask>[], _sources = <String, XFile>{};
  final _fresh = <String>{};
  final completions = StreamController<UploadTask>.broadcast(sync: true);
  RequestScope? _scope;
  Future<void>? _runner;
  Future<void>? _pulse;
  Timer? _heartbeat;
  bool _closing = false, _initialized = false, _publishing = false;
  int _sequence = 0;
  List<UploadTask> get tasks => List.unmodifiable(_tasks);
  Iterable<UploadTask> get activeTasks => _tasks.where((task) => task.active);
  int get activeCount => _tasks.where((t) => t.active).length;
  UploadTask? task(String id) => _tasks.where((t) => t.id == id).firstOrNull;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final raw = store.data['uploadTasks'];
    final saved = store.data.list('uploadTasks');
    var changed = raw != null && (raw is! List || raw.length != saved.length);
    final seen = <String>{};
    const equality = DeepCollectionEquality();
    for (final value in saved) {
      try {
        final t = UploadTask.fromJson(value);
        if (t.id.isEmpty ||
            t.session.accountId?.isNotEmpty != true ||
            !seen.add(t.id)) {
          changed = true;
          continue;
        }
        if (t.active) {
          t.status = UploadStatus.interrupted;
          t.error = t.isFolder
              ? '上次文件夹上传已中断，可继续未完成的文件；请先检查目标目录'
              : '上次上传已中断，重新上传会从头开始；请先检查目标目录';
        }
        _tasks.add(t);
        _fresh.add(t.id);
        // This also sanitizes old sessions and repairs outdated task formats.
        changed = changed || !equality.equals(value, t.toJson());
      } catch (e, stack) {
        changed = true;
        DiagnosticLog.error('upload.restore_failed', e, stack);
      }
    }
    if (changed) await _save();
  }

  Future<List<String>> enqueue(
    BrowseSession session,
    String parent,
    String folderName,
    List<XFile> files, {
    List<UploadFolder> folders = const [],
  }) => _commands.run(() async {
    require(!_closing, '上传管理已关闭');
    await initialize();
    final bound = cloud.bindSession(session);
    require(
      bound.canManageFiles && bound.accountId?.isNotEmpty == true,
      '请先登录并打开个人网盘',
    );
    final account = cloud.sessionCredential(bound);
    require(account != null, '上传账号已退出，请重新登录');
    cloud.ensureAvailable(bound.platform);
    require(
      cloud.connector(bound.platform).canUploadTo(bound, parent),
      '当前目录不支持上传',
    );
    require(
      folders.isEmpty ||
          cloud.connector(bound.platform).canCreateFolderIn(bound, parent),
      '当前目录不支持上传文件夹',
    );
    final accountName =
        (cloud.vault is Vault
            ? (cloud.vault as Vault)
                  .profiles(bound.platform)
                  .where((p) => p.id == bound.accountId)
                  .firstOrNull
                  ?.name
            : null) ??
        account!.label;
    final added = <UploadTask>[];
    void checkName(String name) {
      require(
        !_tasks.any(
          (t) =>
              t.active &&
              t.session.platform == bound.platform &&
              t.session.accountId == bound.accountId &&
              t.session.personalSpaceId == bound.personalSpaceId &&
              t.session.familyId == bound.familyId &&
              t.parent == parent &&
              t.name.toLowerCase() == name.toLowerCase(),
        ),
        '此目录已有同名上传任务',
      );
      require(
        !added.any((t) => t.name.toLowerCase() == name.toLowerCase()),
        '所选文件或文件夹包含同名项目，请分开上传',
      );
    }

    for (final file in files) {
      final size = await file.length(), modified = await file.lastModified();
      require(file.path.isNotEmpty, '无法保留所选文件，请重新选择');
      // Validate the file name before committing a task.
      UploadFile(name: file.name, size: size, read: file.openRead);
      checkName(file.name);
      added.add(
        UploadTask(
          id: '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
          session: bound,
          parent: parent,
          folderName: folderName,
          accountName: accountName,
          path: file.path,
          name: file.name,
          size: size,
          modifiedAt: modified.millisecondsSinceEpoch,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          mimeType: file.mimeType ?? 'application/octet-stream',
        ),
      );
    }
    for (final folder in folders) {
      checkName(folder.name);
      // Snapshot mutable retry markers separately from the picker result.
      final plan = UploadFolder.fromJson(folder.toJson());
      require(
        plan.completedFiles == 0 && plan.remoteDirectories.isEmpty,
        '请选择新的上传文件夹',
      );
      added.add(
        UploadTask(
          id: '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
          session: bound,
          parent: parent,
          folderName: folderName,
          accountName: accountName,
          path: plan.location,
          name: plan.name,
          size: plan.size,
          modifiedAt: 0,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          folder: plan,
        ),
      );
    }
    require(
      !_closing &&
          cloud.sessionCredential(bound)?.updatedAt == account?.updatedAt,
      '上传账号已变化，请重新选择文件',
    );
    _tasks.addAll(added);
    for (var i = 0; i < files.length; i++) {
      _sources[added[i].id] = files[i];
    }
    try {
      await _save();
    } catch (_) {
      _tasks.removeWhere(added.contains);
      for (final t in added) {
        _sources.remove(t.id);
      }
      rethrow;
    }
    notifyListeners();
    _schedule();
    return added.map((t) => t.id).toList();
  });

  DownloadActivity get activity {
    final active = _tasks.where((t) => t.active).toList();
    if (active.isEmpty) return const DownloadActivity.idle();
    final current = active
        .where((t) => t.status == UploadStatus.running)
        .firstOrNull;
    final total = active.fold(0, (s, t) => s + t.size);
    final sent = active.fold(
      0,
      (s, t) =>
          s + (t.phase == UploadPhase.preparing && !t.isFolder ? 0 : t.sent),
    );
    final speed = current?.speed ?? 0;
    return DownloadActivity(
      active: active.length,
      progress: total > 0 ? (sent * 100 ~/ total).clamp(0, 100) : -1,
      text: speed > 0
          ? '${(speed / 1024 / 1024).toStringAsFixed(2)} MB/s'
          : current?.stage ?? '等待上传',
    );
  }

  Future<void> _save() => _writes.run(
    () => store.put('uploadTasks', _tasks.map((t) => t.toJson()).toList()),
  );
  void _background(Future<void> work) {
    unawaited(
      work.catchError((Object e, StackTrace s) {
        DiagnosticLog.error('upload.background_failed', e, s);
      }),
    );
  }

  void _schedule() {
    if (_closing ||
        _runner != null ||
        !_tasks.any((t) => t.status == UploadStatus.pending)) {
      return;
    }
    _runner = _zone.run(_drain);
    _background(
      _runner!.whenComplete(() {
        _runner = null;
        _schedule();
      }),
    );
  }

  Future<void> _drain() async {
    _heartbeat ??= Timer.periodic(const Duration(seconds: 2), (_) {
      if (_publishing || _closing || activeCount == 0) return;
      _publishing = true;
      _pulse = (() async {
        try {
          await foreground?.call();
          await _save();
        } catch (e) {
          await stopAll(reason: '后台上传服务已中断，请返回应用后重新上传');
        } finally {
          _publishing = false;
        }
      })();
      _background(_pulse!);
    });
    try {
      while (!_closing) {
        final next = _tasks
            .where((t) => t.status == UploadStatus.pending)
            .firstOrNull;
        if (next == null) break;
        try {
          await foreground?.call();
        } catch (e) {
          await stopAll(reason: '后台传输服务无法启动，请返回应用后重试');
          break;
        }
        if (_closing || next.status != UploadStatus.pending) continue;
        await _run(next);
      }
    } finally {
      _heartbeat?.cancel();
      _heartbeat = null;
      await foreground?.call();
    }
  }

  Future<void> _run(UploadTask t) async {
    final scope = _scope = RequestScope();
    t.status = UploadStatus.running;
    t.phase = UploadPhase.preparing;
    t.sent = t.folder?.completedBytes ?? 0;
    t.speed = 0;
    t.error = '';
    notifyListeners();
    final watch = Stopwatch()..start();
    var sampledAt = 0, sampledSent = 0, lastPaint = 0;
    void guard() {
      require(
        !_closing &&
            !scope.token.isCancelled &&
            t.status == UploadStatus.running,
        '上传已停止',
      );
    }

    try {
      await _save();
      await scope.run(
        () => RequestScope.guarded(() async {
          guard();
          require(
            cloud.sessionCredential(t.session) != null,
            '上传账号已退出，请重新登录原账号后重试',
          );
          if (_fresh.remove(t.id)) {
            t.session = await cloud.reopenSpace(t.session);
          }
          guard();
          if (t.folder != null) {
            await _runFolder(t, guard);
            guard();
            t.sent = t.size;
            t.status = UploadStatus.completed;
            return;
          }
          final file = _sources[t.id] ?? XFile(t.path, name: t.name);
          Future<void> validate() async {
            guard();
            try {
              require(
                await file.length() == t.size &&
                    (await file.lastModified()).millisecondsSinceEpoch ==
                        t.modifiedAt,
                '本地文件已变化，请重新选择上传',
              );
            } on FileSystemException {
              throw const AppException('本地文件已移走或缓存已清理，请重新选择上传');
            }
            guard();
          }

          await validate();
          DiagnosticLog.event(
            'upload.file.start',
            fields: {'platform': t.session.platform.key, 'bytes': t.size},
          );
          final result = await cloud.upload(
            t.session,
            t.parent,
            UploadFile(
              name: t.name,
              size: t.size,
              mimeType: t.mimeType,
              modifiedAt: DateTime.fromMillisecondsSinceEpoch(t.modifiedAt),
              read: file.openRead,
              validate: validate,
            ),
            onProgress: (p) {
              guard();
              final now = watch.elapsedMilliseconds,
                  changed = t.phase != p.phase;
              if (changed) {
                sampledAt = now;
                sampledSent = p.sent;
                t.speed = 0;
              }
              t.phase = p.phase;
              t.sent = p.sent.clamp(0, t.size);
              if (p.phase == UploadPhase.uploading && now - sampledAt >= 500) {
                t.speed =
                    ((p.sent - sampledSent).clamp(0, t.size) *
                    1000 ~/
                    (now - sampledAt));
                sampledAt = now;
                sampledSent = p.sent;
              }
              if (changed || now - lastPaint >= 150) {
                lastPaint = now;
                notifyListeners();
              }
              if (changed) _background(_save());
            },
          );
          guard();
          t.fileId = result.id;
          t.sent = t.size;
          t.status = UploadStatus.completed;
        }, guard),
      );
      DiagnosticLog.event(
        'upload.file.complete',
        fields: {
          'platform': t.session.platform.key,
          if (t.isFolder) 'folder': true,
        },
      );
    } catch (e, s) {
      if (t.status == UploadStatus.running) {
        t.status = UploadStatus.failed;
        final reason = e is AppException ? e.message : '上传失败，请检查网络和本地文件后重试';
        final current = t.folder?.currentItem ?? '';
        t.error = current.isEmpty ? reason : '$current：$reason';
      }
      DiagnosticLog.error(
        'upload.file.failed',
        e,
        s,
        fields: {
          'platform': t.session.platform.key,
          'phase': t.phase.name,
          if (t.isFolder) 'folder': true,
        },
      );
    } finally {
      t.speed = 0;
      _scope = null;
      await _save();
      notifyListeners();
      // A cancelled commit may still have reached the provider. Refresh rather
      // than claiming that cancellation removed the remote file.
      completions.add(t);
      if (t.status == UploadStatus.completed) _sources.remove(t.id);
    }
  }

  Future<void> _runFolder(UploadTask task, void Function() guard) async {
    final folder = task.folder!;
    final revision = cloud.sessionCredential(task.session)?.updatedAt;
    void checkpoint() {
      guard();
      cloud.ensureAvailable(task.session.platform);
      require(
        revision != null &&
            cloud.sessionCredential(task.session)?.updatedAt == revision,
        '上传账号已变化，请重新登录原账号后继续',
      );
    }

    await RequestScope.guarded(() async {
      await sources.validateFolder(folder);
      checkpoint();
      final listings = <String, List<CloudFile>>{};
      Future<List<CloudFile>> listing(String parent) async =>
          listings[parent] ??= List.of(await cloud.list(task.session, parent));
      final resolved = <String, String>{};
      final directoryWatch = Stopwatch()..start();
      var savedAt = 0, unsavedDirectories = 0;
      for (final path in folder.directories) {
        checkpoint();
        folder.currentItem = path.isEmpty
            ? folder.name
            : '${folder.name}/$path';
        final parentPath = path.isEmpty || !path.contains('/')
            ? ''
            : path.substring(0, path.lastIndexOf('/'));
        final parent = path.isEmpty ? task.parent : resolved[parentPath]!;
        final name = path.isEmpty ? folder.name : path.split('/').last;
        final entries = await listing(parent);
        checkpoint();
        final matches = entries
            .where((f) => f.name.toLowerCase() == name.toLowerCase())
            .toList();
        require(matches.length <= 1, '目标目录中有多个同名项目，请整理后重试');
        final previous = folder.remoteDirectories[path];
        final previousFile = folder.remoteDirectoryFiles[path];
        CloudFile directory;
        if (previous != null) {
          require(
            matches.isNotEmpty &&
                matches.single.isDirectory &&
                cloud.directoryId(task.session, matches.single) == previous &&
                (previousFile == null || matches.single.id == previousFile),
            '已上传的目标文件夹已变化，请检查网盘后重新选择',
          );
          directory = matches.single;
        } else if (matches.isNotEmpty) {
          require(matches.single.isDirectory, '目标目录中已有同名文件，请更改文件夹名称');
          directory = matches.single;
        } else {
          directory = await cloud.createFolder(task.session, parent, name);
          checkpoint();
          require(directory.isDirectory, '网盘没有返回有效的文件夹');
          entries.add(directory);
        }
        final id = cloud.directoryId(task.session, directory);
        require(id.isNotEmpty, '网盘没有返回有效的文件夹标识');
        resolved[path] = id;
        folder.remoteDirectories[path] = id;
        if (directory.id.isNotEmpty) {
          folder.remoteDirectoryFiles[path] = directory.id;
        }
        if (path.isEmpty) task.fileId = directory.id;
        unsavedDirectories++;
        if (path.isEmpty ||
            directoryWatch.elapsedMilliseconds - savedAt >= 500 ||
            unsavedDirectories >= 32) {
          await _save();
          savedAt = directoryWatch.elapsedMilliseconds;
          unsavedDirectories = 0;
          notifyListeners();
        }
        checkpoint();
      }
      if (unsavedDirectories > 0) await _save();

      var completedBytes = folder.completedBytes;
      for (final file in folder.files) {
        checkpoint();
        folder.currentItem = '${folder.name}/${file.relativePath}';
        final parent = resolved[file.directory]!;
        if (file.completed) {
          // Saved progress must still refer to the same remote file. Never
          // redirect a retry into a replaced directory or skip a removed file.
          final existing = await listing(parent);
          require(
            existing.any(
              (f) =>
                  f.id == file.fileId &&
                  !f.isDirectory &&
                  f.name.toLowerCase() == file.name.toLowerCase() &&
                  (!task.session.platform.exactFileSize || f.size == file.size),
            ),
            '已完成的目标文件已移走，请检查网盘后重新选择',
          );
          continue;
        }
        task.phase = UploadPhase.preparing;
        task.sent = completedBytes;
        task.speed = 0;
        notifyListeners();
        await sources.validate(file);
        checkpoint();
        final watch = Stopwatch()..start();
        var sampledAt = 0, sampledSent = 0, lastPaint = 0;
        final result = await cloud.upload(
          task.session,
          parent,
          UploadFile(
            name: file.name,
            size: file.size,
            mimeType: file.mimeType,
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(file.modifiedAt),
            read: (start, end) => sources.read(file, start, end),
            validate: () => sources.validate(file),
          ),
          onProgress: (p) {
            checkpoint();
            final now = watch.elapsedMilliseconds;
            final changed = task.phase != p.phase;
            if (changed) {
              sampledAt = now;
              sampledSent = p.sent;
              task.speed = 0;
            }
            task.phase = p.phase;
            task.sent =
                completedBytes +
                (p.phase == UploadPhase.preparing
                    ? 0
                    : p.sent.clamp(0, file.size));
            if (p.phase == UploadPhase.uploading && now - sampledAt >= 500) {
              task.speed =
                  ((p.sent - sampledSent).clamp(0, file.size) *
                  1000 ~/
                  (now - sampledAt));
              sampledAt = now;
              sampledSent = p.sent;
            }
            if (changed || now - lastPaint >= 150) {
              lastPaint = now;
              notifyListeners();
            }
          },
        );
        checkpoint();
        require(result.id.isNotEmpty, '文件已提交但网盘未返回标识，请检查目标目录');
        folder.completeFile(file, result.id);
        completedBytes += file.size;
        task.sent = completedBytes;
        task.speed = 0;
        listings[parent]?.add(result);
        await _save();
        notifyListeners();
      }
      folder.currentItem = '';
    }, checkpoint);
  }

  Future<void> cancel(String id) async {
    final t = task(id);
    if (t == null || !t.active) return;
    final running = t.status == UploadStatus.running;
    t.status = UploadStatus.cancelled;
    t.error = t.isFolder
        ? '已取消文件夹上传；已完成的文件保留，继续时只上传未完成文件'
        : '已取消；已提交的文件可能仍在网盘处理中';
    t.speed = 0;
    if (running) _scope?.cancel();
    await _save();
    notifyListeners();
  }

  Future<void> stopAll({String reason = '上传已停止'}) async {
    for (final t in _tasks.where((t) => t.active)) {
      t.status = UploadStatus.interrupted;
      t.error = '$reason${t.isFolder ? '；可继续未完成的文件' : '，重新上传将从头开始'}';
      t.speed = 0;
    }
    _scope?.cancel();
    await _save();
    notifyListeners();
  }

  Future<void> retry(String id) => _commands.run(() async {
    require(!_closing, '上传管理已关闭');
    final t = task(id);
    if (t == null || !t.canRetry) return;
    // Wait for a cancelled request to settle before sending another file.
    if (_scope?.token.isCancelled == true) await _runner;
    require(cloud.sessionCredential(t.session) != null, '请重新登录原上传账号后重试');
    require(
      !_tasks.any(
        (other) =>
            other != t &&
            other.active &&
            other.session.platform == t.session.platform &&
            other.session.accountId == t.session.accountId &&
            other.session.personalSpaceId == t.session.personalSpaceId &&
            other.session.familyId == t.session.familyId &&
            other.parent == t.parent &&
            other.name.toLowerCase() == t.name.toLowerCase(),
      ),
      '已有同名上传任务',
    );
    t.status = UploadStatus.pending;
    t.phase = UploadPhase.preparing;
    t.sent = t.folder?.completedBytes ?? 0;
    t.error = '';
    _fresh.add(t.id);
    await _save();
    notifyListeners();
    _schedule();
  });

  Future<void> remove(String id) async {
    final t = task(id);
    require(t == null || !t.active, '请先取消上传');
    _tasks.remove(t);
    _sources.remove(id);
    _fresh.remove(id);
    await _save();
    notifyListeners();
  }

  Future<void> clearCompleted() async {
    _tasks.removeWhere((t) => t.status == UploadStatus.completed);
    await _save();
    notifyListeners();
  }

  Future<void> close() async {
    if (_closing) return;
    await initialize();
    _closing = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    await stopAll(reason: '应用已退出，请先检查目标目录');
    await _runner;
    await _pulse;
    await _save();
    await completions.close();
  }
}
