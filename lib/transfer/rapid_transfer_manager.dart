import 'dart:async';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../data/cloud_repository.dart';
import '../data/http.dart';
import '../data/state_store.dart';
import '../diagnostics/app_log.dart';
import '../domain/models.dart';
import '../domain/auth.dart';
import '../domain/rapid_transfer.dart';
import '../domain/uploads.dart';
import '../download/download_activity.dart';
import '../download/mobile_data_download_guard.dart';
import 'cross_transfer_relay.dart';
import 'rapid_transfer_task.dart';

class RapidTransferManager extends ChangeNotifier {
  RapidTransferManager({
    required this.cloud,
    required this.store,
    required this.relay,
    this.confirmDownload,
    this.foreground,
  });
  final CloudRepository cloud;
  final StateStore store;
  final CrossTransferRelay relay;
  final Future<void> Function()? confirmDownload;
  final Future<void> Function()? foreground;
  final _zone = Zone.current, _commands = AsyncGate(), _writes = AsyncGate();
  final _tasks = <RapidTransferTask>[];
  final _reopen = <String>{};
  Future<void>? _runner;
  RequestScope? _scope;
  bool _closed = false;
  Future<void>? _initialization;
  final completions = StreamController<RapidTransferTask>.broadcast(sync: true);
  List<RapidTransferTask> get tasks => List.unmodifiable(_tasks);
  Iterable<RapidTransferTask> get activeTasks => _tasks.where((t) => t.active);
  int get activeCount => activeTasks.length;
  RapidTransferTask? task(String id) {
    for (final t in _tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  DownloadActivity get activity => DownloadActivity(
    active: activeCount,
    progress: -1,
    text: '跨盘传输 $activeCount 个任务',
  );
  Future<void> _save() => _writes.run(
    () =>
        store.put('rapidTransferTasks', _tasks.map((t) => t.toJson()).toList()),
  );

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    for (final value in store.data.list('rapidTransferTasks')) {
      try {
        final t = RapidTransferTask.fromJson(value);
        require(
          t.id.isNotEmpty &&
              task(t.id) == null &&
              t.parent.isNotEmpty &&
              t.target.accountId?.isNotEmpty == true &&
              t.selections.isNotEmpty,
          '跨盘传输任务记录无效',
        );
        require(
          t.selections.length <= 3000 &&
              t.entries.length <= 3000 &&
              t.folders.length <= 10000 &&
              t.entries.every((e) => e.path.length < 40),
          '跨盘传输记录超出批量限制',
        );
        for (final entry in t.entries) {
          validateTransferName(entry.file.name);
          entry.path.forEach(validateTransferName);
        }
        for (final folder in t.folders) {
          folder.forEach(validateTransferName);
        }
        if (t.active) {
          t.status = RapidTaskStatus.interrupted;
          t.error = '上次任务已中断，可继续传输未完成的文件';
        }
        _tasks.add(t);
        _reopen.add(t.id);
      } catch (e, s) {
        DiagnosticLog.error('rapid.restore_failed', e, s);
      }
    }
    notifyListeners();
  }

  Future<String> enqueue(
    BrowseSession source,
    List<CloudFile> files,
    BrowseSession target,
    String parent,
    String folderName,
  ) => _commands.run(() async {
    require(!_closed, '跨盘传输管理已关闭');
    await initialize();
    require(!_closed, '跨盘传输管理已关闭');
    source = cloud.bindSession(source);
    target = cloud.bindSession(target);
    require(
      files.isNotEmpty &&
          files.every(
            (f) =>
                f.isDirectory ||
                cloud.connector(source.platform).canDownloadFile(source, f),
          ),
      '此来源暂不支持跨盘传输',
    );
    require(parent.isNotEmpty, '请选择目标目录');
    require(files.length <= 3000, '单次最多选择 3000 项，请分批操作');
    require(
      target.accountId?.isNotEmpty == true &&
          cloud.sessionCredential(target) != null,
      '请先登录目标网盘',
    );
    require(
      cloud.connector(target.platform).canUploadTo(target, parent),
      '目标目录不支持上传，请选择可上传的目录',
    );
    require(
      source.platform != target.platform ||
          source.accountId != target.accountId,
      '请选择其他网盘或其他账号',
    );
    cloud.ensureAvailable(source.platform);
    cloud.ensureAvailable(target.platform);
    final t = RapidTransferTask(
      id: newId(),
      source: source,
      target: target,
      parent: parent,
      folderName: folderName,
      selections: List.of(files),
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    _tasks.add(t);
    try {
      await _save();
    } catch (_) {
      _tasks.remove(t);
      rethrow;
    }
    notifyListeners();
    _schedule();
    return t.id;
  });

  void _schedule() {
    if (_closed ||
        _runner != null ||
        !_tasks.any((t) => t.status == RapidTaskStatus.pending)) {
      return;
    }
    _runner = _zone.run(_drain);
    unawaited(
      _runner!
          .whenComplete(() {
            _runner = null;
            _schedule();
          })
          .catchError((Object e, StackTrace s) {
            DiagnosticLog.error('rapid.runner_failed', e, s);
          }),
    );
  }

  Future<void> _drain() async {
    while (!_closed) {
      final waiting = _tasks.where((t) => t.status == RapidTaskStatus.pending);
      if (waiting.isEmpty) break;
      final t = waiting.first;
      await _run(t);
    }
    try {
      await foreground?.call();
    } catch (_) {
      /* Queue already stopped. */
    }
  }

  Future<void> _run(RapidTransferTask t) async {
    final scope = _scope = RequestScope();
    t.status = RapidTaskStatus.running;
    t.error = '';
    notifyListeners();
    final sourceOwner = cloud.sessionCredential(t.source)?.updatedAt;
    final targetOwner = cloud.sessionCredential(t.target)?.updatedAt;
    var downloadConfirmed = false;
    final speedClock = Stopwatch();
    var speedBytes = 0;
    void progress(int bytes) {
      final elapsed = speedClock.elapsedMilliseconds;
      if (elapsed < 250) return;
      t.speed = ((bytes - speedBytes).clamp(0, bytes) * 1000 / elapsed).round();
      speedBytes = bytes;
      speedClock.reset();
      notifyListeners();
    }

    void guard() {
      require(
        !_closed &&
            t.status == RapidTaskStatus.running &&
            !scope.token.isCancelled,
        '跨盘传输已停止',
      );
      cloud.ensureAvailable(t.source.platform);
      cloud.ensureAvailable(t.target.platform);
      require(cloud.sessionCredential(t.target) != null, '目标账号已退出，请登录原账号后继续');
      require(
        cloud.sessionCredential(t.target)?.updatedAt == targetOwner &&
            cloud.sessionCredential(t.source)?.updatedAt == sourceOwner,
        '任务账号凭据已变化，请继续任务以重新确认',
      );
      require(
        t.source.accountId?.isNotEmpty != true ||
            cloud.sessionCredential(t.source) != null,
        '来源账号已退出，请登录原账号后继续',
      );
    }

    try {
      await foreground?.call();
      final heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
        unawaited(
          (() async {
            try {
              await foreground?.call();
            } catch (_) {
              scope.cancel();
            }
          })(),
        );
      });
      try {
        await scope.run(
          () => RequestScope.guarded(() async {
            guard();
            if (_reopen.remove(t.id)) {
              t.source = await cloud.reopenTransferSource(t.source);
              t.target = await cloud.reopenSpace(t.target);
              t.directories.clear();
            }
            if (!t.scanned) await _scan(t);
            final listings = <String, List<CloudFile>>{};
            final sources = <String, List<CloudFile>>{};
            Future<List<CloudFile>> listing(String parent) async =>
                listings[parent] ??= await cloud.list(t.target, parent);
            Future<String> destination(List<String> path) async {
              var parent = t.parent;
              for (var i = 0; i < path.length; i++) {
                final key = encoded(path.take(i + 1).toList());
                if (t.directories.containsKey(key)) {
                  parent = t.directories[key]!;
                  continue;
                }
                final entries = await listing(parent);
                final found = entries
                    .where((f) => f.name.toLowerCase() == path[i].toLowerCase())
                    .toList();
                require(
                  found.isEmpty ||
                      found.length == 1 && found.single.isDirectory,
                  '目标目录有同名文件或重复文件夹：${path[i]}',
                );
                final folder = found.isNotEmpty
                    ? found.single
                    : await cloud.createFolder(t.target, parent, path[i]);
                if (found.isEmpty) entries.add(folder);
                parent = folder.id;
                t.directories[key] = parent;
                await _save();
              }
              return parent;
            }

            for (final folder in t.folders) {
              await destination(folder);
            }
            for (final entry in t.entries) {
              guard();
              if (entry.finished) continue;
              try {
                final originParent = entry.file.parentId.ifEmpty(
                  t.source.rootId,
                );
                final originFiles = sources[originParent] ??= await cloud.list(
                  t.source,
                  originParent,
                );
                final original = originFiles.where(
                  (f) => f.id == entry.file.id,
                );
                require(
                  original.length == 1 &&
                      !original.single.isDirectory &&
                      original.single.name == entry.file.name &&
                      original.single.size == entry.file.size &&
                      (entry.file.modifiedAt.isEmpty ||
                          original.single.modifiedAt ==
                              entry.file.modifiedAt) &&
                      (original.single.hashType != 'md5' ||
                          entry.md5.isEmpty ||
                          contentMd5(original.single.hashValue) ==
                              contentMd5(entry.md5)),
                  '来源文件已变化，请重新选择',
                );
                final parent = await destination(entry.path);
                final existing = await listing(parent);
                final same = existing
                    .where(
                      (f) =>
                          f.name.toLowerCase() == entry.file.name.toLowerCase(),
                    )
                    .toList();
                if (same.isNotEmpty) {
                  final verified =
                      entry.submitted &&
                      same.length == 1 &&
                      !same.single.isDirectory &&
                      same.single.size == entry.size &&
                      same.single.hashType?.toLowerCase() == 'md5' &&
                      contentMd5(same.single.hashValue) ==
                          contentMd5(entry.md5) &&
                      contentMd5(entry.md5) != null;
                  entry.status = verified
                      ? entry.method == CrossTransferMethod.relay
                            ? RapidEntryStatus.uploaded
                            : RapidEntryStatus.reused
                      : RapidEntryStatus.duplicate;
                  entry.message = verified ? '已确认上次传输文件' : '已跳过目标同名项目';
                  entry.fileId = same.first.id;
                } else {
                  entry.status = RapidEntryStatus.processing;
                  entry.message = '正在判断秒传';
                  t.speed = 0;
                  notifyListeners();
                  String? hash = contentMd5(entry.md5);
                  final rapid = cloud
                      .connector(t.target.platform)
                      .canRapidTransferTo(t.target);
                  if (rapid) {
                    try {
                      hash ??= await cloud.transferMd5(t.source, entry.file);
                    } catch (e) {
                      guard();
                      if (e is AccountLoginRequired ||
                          e is RapidTransferUnavailable ||
                          e is HttpRequestFailure && e.status == 429) {
                        rethrow;
                      }
                      // A failed read of the source hash has no target side
                      // effect. The normal download can still be attempted.
                    }
                  }
                  CloudFile? saved;
                  if (rapid && hash != null) {
                    entry.md5 = hash;
                    entry.method = CrossTransferMethod.rapid;
                    entry.submitted = true;
                    await _save();
                    final result = await cloud.rapidTransfer(
                      t.target,
                      parent,
                      RapidTransferFile(
                        name: entry.file.name,
                        size: entry.file.size,
                        md5: hash,
                      ),
                    );
                    guard();
                    if (result.reused) {
                      saved = CloudFile(
                        id: result.fileId!,
                        name: entry.file.name,
                        size: entry.file.size,
                        parentId: parent,
                        hashType: 'md5',
                        hashValue: hash,
                      );
                      entry.status = RapidEntryStatus.reused;
                      entry.message = '秒传成功';
                    }
                  }
                  if (saved == null) {
                    require(
                      cloud
                          .connector(t.source.platform)
                          .canDownloadFile(t.source, entry.file),
                      '此文件不支持下载后上传',
                    );
                    if (!downloadConfirmed) {
                      await confirmDownload?.call();
                      guard();
                      downloadConfirmed = true;
                    }
                    entry.method = CrossTransferMethod.relay;
                    entry.submitted = false;
                    entry.status = RapidEntryStatus.downloading;
                    entry.downloaded = entry.sent = 0;
                    entry.message = '秒传不可用，正在下载后上传';
                    speedBytes = 0;
                    speedClock
                      ..reset()
                      ..start();
                    await _save();
                    notifyListeners();
                    saved = await relay.transfer(
                      t.source,
                      entry.file,
                      expectedMd5:
                          hash ??
                          (entry.file.hashType?.toLowerCase() == 'md5'
                              ? contentMd5(entry.file.hashValue)
                              : null),
                      onProgress: (received, total) {
                        entry.downloaded = received;
                        entry.transferSize = total;
                        progress(received);
                      },
                      upload: (file, digest) async {
                        guard();
                        final fresh = (await cloud.list(
                          t.source,
                          originParent,
                        )).where((f) => f.id == entry.file.id);
                        require(
                          fresh.length == 1 &&
                              fresh.single.name == entry.file.name &&
                              fresh.single.size == entry.file.size &&
                              (entry.file.modifiedAt.isEmpty ||
                                  fresh.single.modifiedAt ==
                                      entry.file.modifiedAt) &&
                              (fresh.single.hashType?.toLowerCase() != 'md5' ||
                                  contentMd5(fresh.single.hashValue) == digest),
                          '来源文件已变化，请重新选择',
                        );
                        entry.status = RapidEntryStatus.uploading;
                        entry.message = '下载完成，正在上传';
                        entry.md5 = digest;
                        entry.transferSize = file.size;
                        entry.submitted = true;
                        speedBytes = 0;
                        speedClock.reset();
                        t.speed = 0;
                        await _save();
                        notifyListeners();
                        return cloud.upload(
                          t.target,
                          parent,
                          file,
                          onProgress: (p) {
                            entry.sent = p.sent;
                            entry.message = p.phase == UploadPhase.preparing
                                ? '正在准备上传'
                                : p.phase == UploadPhase.finishing
                                ? '正在确认保存'
                                : '正在上传';
                            if (p.phase == UploadPhase.uploading) {
                              progress(p.sent);
                            } else {
                              t.speed = 0;
                            }
                          },
                        );
                      },
                    );
                    guard();
                    entry.status = RapidEntryStatus.uploaded;
                    entry.message = '下载后上传完成';
                  }
                  entry.fileId = saved!.id;
                  existing.add(saved);
                }
              } catch (e) {
                guard();
                if (e is AccountLoginRequired ||
                    e is RapidTransferUnavailable ||
                    e is DownloadConfirmationCancelled ||
                    e is HttpRequestFailure && e.status == 429) {
                  rethrow;
                }
                entry.status = RapidEntryStatus.failed;
                entry.message = e is AppException ? e.message : '跨盘传输失败，请稍后重试';
                // Invalidate cached listing after an uncertain mutation response.
                listings.clear();
              }
              await _save();
              t.speed = 0;
              notifyListeners();
              await RequestScope.wait(const Duration(milliseconds: 150));
            }
            guard();
            t.status = RapidTaskStatus.completed;
          }, guard),
        );
      } finally {
        heartbeat.cancel();
      }
    } catch (e) {
      if (t.status == RapidTaskStatus.running) {
        t.status = RapidTaskStatus.failed;
        t.error = e is AppException ? e.message : '跨盘传输中断，请稍后继续';
      }
    } finally {
      _scope = null;
      t.speed = 0;
      await _save();
      notifyListeners();
      if (t.succeeded > 0) completions.add(t);
      try {
        await foreground?.call();
      } catch (_) {
        /* Next start reports errors. */
      }
    }
  }

  Future<void> _scan(RapidTransferTask t) async {
    final files = <RapidTransferEntry>[], folders = <List<String>>[];
    final visited = <String>{}, seenFiles = <String>{};
    var lastPaint = DateTime.now();
    Future<void> scan(CloudFile file, List<String> path) async {
      RequestScope.checkpoint();
      validateTransferName(file.name);
      require(file.size >= 0, '来源文件大小无效');
      require(path.length < 40, '文件夹层级过深，请分开传输');
      if (!file.isDirectory) {
        if (!seenFiles.add('${file.parentId}\u0000${file.id}')) return;
        require(files.length < 3000, '单次最多传输 3000 个文件，请分开操作');
        files.add(RapidTransferEntry(file, List.of(path)));
        t.scannedFiles = files.length;
        return;
      }
      final directory = cloud.directoryId(t.source, file);
      if (!visited.add(directory)) return;
      require(folders.length < 10000, '文件夹过多，请缩小范围');
      final childPath = [...path, file.name];
      folders.add(childPath);
      t.scannedFolders = folders.length;
      final cursors = <String>{};
      String? cursor;
      do {
        final page = await cloud.listPage(t.source, directory, cursor: cursor);
        for (final child in page.files) {
          await scan(child, childPath);
        }
        cursor = page.nextCursor;
        require(cursor == null || cursors.add(cursor), '来源分页重复，请重新解析');
        if (DateTime.now().difference(lastPaint).inMilliseconds >= 100) {
          lastPaint = DateTime.now();
          notifyListeners();
        }
      } while (cursor != null);
    }

    final parents = <String, List<CloudFile>>{};
    final selections = List.of(
      t.selections,
    )..sort((a, b) => (a.isDirectory ? 0 : 1).compareTo(b.isDirectory ? 0 : 1));
    for (final selected in selections) {
      final parent = selected.parentId.isEmpty
          ? t.source.rootId
          : selected.parentId;
      final children = parents[parent] ??= await cloud.list(t.source, parent);
      final match = children.where((f) => f.id == selected.id);
      require(
        match.length == 1 &&
            match.single.name == selected.name &&
            match.single.isDirectory == selected.isDirectory &&
            (selected.isDirectory || match.single.size == selected.size),
        '来源文件已变化，请重新选择：${selected.name}',
      );
      await scan(match.single, []);
    }
    t.entries
      ..clear()
      ..addAll(files);
    t.folders
      ..clear()
      ..addAll(folders);
    t.scanned = true;
    await _save();
    notifyListeners();
  }

  Future<void> cancel(String id) => _commands.run(() async {
    final t = task(id);
    if (t == null || !t.active) return;
    final running = t.status == RapidTaskStatus.running;
    t.status = RapidTaskStatus.cancelled;
    if (running) _scope?.cancel();
    t.error = '已停止；目标中已完成的文件会保留';
    notifyListeners();
    await _save();
    await foreground?.call();
  });
  Future<void> retry(String id) => _commands.run(() async {
    require(!_closed, '跨盘传输管理已关闭');
    final t = task(id);
    require(t != null && t.canRetry, '此任务不能继续');
    for (final e in t!.entries) {
      if (!e.finished ||
          e.status == RapidEntryStatus.failed ||
          e.status == RapidEntryStatus.missed ||
          e.status == RapidEntryStatus.noHash) {
        e.status = RapidEntryStatus.pending;
        e.message = '';
        e.downloaded = e.sent = 0;
      }
    }
    _reopen.add(t.id);
    t.status = RapidTaskStatus.pending;
    t.error = '';
    await _save();
    notifyListeners();
    _schedule();
  });
  Future<void> stopAll() async {
    for (final t in List.of(activeTasks)) {
      await cancel(t.id);
    }
  }

  Future<void> clearCompleted() => _commands.run(() async {
    _tasks.removeWhere((t) => !t.active && !t.canRetry);
    await _save();
    notifyListeners();
  });
  Future<void> remove(String id) => _commands.run(() async {
    require(task(id)?.active != true, '请先停止任务');
    _tasks.removeWhere((t) => t.id == id);
    _reopen.remove(id);
    await _save();
    notifyListeners();
  });
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final t in activeTasks) {
      t.status = RapidTaskStatus.interrupted;
      t.error = '应用已退出，可继续未完成文件';
    }
    _scope?.cancel();
    await _initialization;
    await _runner;
    await _save();
    await completions.close();
  }
}
