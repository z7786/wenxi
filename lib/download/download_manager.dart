import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../diagnostics/app_log.dart';
import '../data/cleanup_outbox.dart';
import '../data/http.dart';
import '../data/state_store.dart';
import '../domain/auth.dart';
import '../domain/baidu_share_route.dart';
import '../domain/bt_sources.dart';
import '../domain/downloads.dart';
import '../domain/ed2k.dart';
import '../domain/file_types.dart';
import '../domain/models.dart';
import '../domain/settings.dart';
import '../domain/torrent.dart';
import '../platform/file_access.dart';
import '../platform/native_engine.dart';
import 'hls.dart';
import 'download_activity.dart';
import 'download_request.dart';
import 'download_playback_cache.dart';
import 'space_budget.dart';
import 'transfer_http.dart';
import 'baidu_transfer_recovery.dart';
import 'aliyun_transfer_recovery.dart';

class _Stopped implements Exception {}

class _RecoverBaidu implements Exception {
  const _RecoverBaidu(this.action);
  final BaiduRecoveryAction action;
}

class _RecoverAliyun implements Exception {}

bool _isAliyun(DownloadSpec spec) =>
    spec.platform == CloudPlatform.aliyun || spec.profile == 'aliyun';

String _aliyunAccountGroup(DownloadSpec spec) {
  final session = asJson(spec.source?['session']);
  final account = session.obj('metadata').str('accountId');
  return account.isEmpty
      ? ''
      : sha256.convert(utf8.encode('aliyun:$account')).toString();
}

class _GuestDownloadBatch {
  bool notified = false;
}

class _DeletionProgress {
  _DeletionProgress(this.total);

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

class _Run {
  _Run(this.clock);
  final Stopwatch clock;
  final baiduRecovery = BaiduTransferRecovery();
  final aliyunRecovery = AliyunTransferRecovery();
  int aliyunPolicyLimit = 0;
  bool aliyunWaiting = false;
  final scope = RequestScope();
  final wake = Completer<void>();
  bool stopped = false;
  Future<void> done = Future.value();
  int networkRetries = 0;
  bool networkActive = true;
  ({int active, int total})? httpConnections;
  BtSources? btSources;
  late StoragePlan storage;
  void stop() {
    stopped = true;
    scope.cancel();
    if (!wake.isCompleted) wake.complete();
  }

  void check() {
    if (stopped) throw _Stopped();
  }

  Future<void> delay(Duration duration) async {
    final elapsed = Completer<void>();
    final timer = Timer(duration, elapsed.complete);
    try {
      await Future.any([wake.future, elapsed.future]);
    } finally {
      timer.cancel();
    }
  }
}

class _DownloadTasks extends MapBase<String, DownloadTask> {
  final _entries = <String, DownloadTask>{};
  List<String>? _orderedIds;

  @override
  DownloadTask? operator [](Object? key) => _entries[key];

  @override
  void operator []=(String key, DownloadTask value) {
    if (_entries[key]?.createdAt != value.createdAt) _orderedIds = null;
    _entries[key] = value;
  }

  @override
  Iterable<String> get keys => _entries.keys;

  @override
  Iterable<DownloadTask> get values => _entries.values;

  @override
  int get length => _entries.length;

  @override
  bool containsKey(Object? key) => _entries.containsKey(key);

  @override
  DownloadTask? remove(Object? key) {
    final removed = _entries.remove(key);
    if (removed != null) _orderedIds = null;
    return removed;
  }

  @override
  void clear() {
    _entries.clear();
    _orderedIds = null;
  }

  List<DownloadTask> get ordered {
    final ids = _orderedIds ??=
        (_entries.values.toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt)))
            .map((task) => task.id)
            .toList(growable: false);
    // Return a fresh snapshot containing the latest progress. Callers can
    // filter or sort it without changing the manager's cached order.
    return [for (final id in ids) _entries[id]!];
  }
}

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required this.store,
    required this.engine,
    required this.files,
    required this.cleanups,
    required this.http,
    required this.refreshSource,
    this.foreground,
    this.checkNewCloudTask,
    this.onGuestDownload,
    this.confirmDownload,
    this.transferClock = Stopwatch.new,
  }) {
    space = SpaceBudget(
      () => files.freeBytes(engine.cache.path),
      availableOnVolume: (volume) {
        final path = _volumePaths[volume];
        require(path != null, '无法确认下载磁盘，请重新开始任务');
        return files.freeBytes(path!);
      },
    );
  }
  final StateStore store;
  final GopeedEngine engine;
  final FileAccess files;
  final CleanupOutbox cleanups;
  final TransferHttp http;
  final Future<DownloadSpec> Function(DownloadSpec) refreshSource;
  final void Function(CloudPlatform)? checkNewCloudTask;
  final VoidCallback? onGuestDownload;
  final Future<void> Function()? confirmDownload;
  @visibleForTesting
  final Stopwatch Function() transferClock;
  final Future<void> Function(DownloadActivity activity)? foreground;
  late final SpaceBudget space;
  final _tasks = _DownloadTasks();
  final _running = <String, _Run>{};
  final _unsettledRuns = <_Run>{};
  final _controls = <String, AsyncGate>{};
  final _guestDownloadBatches = <String, _GuestDownloadBatch>{};
  final _pumpGate = AsyncGate();
  final _removalGate = AsyncGate();
  final _foregroundGate = AsyncGate();
  final _interrupted = <String>{};
  final _volumePaths = <String, String>{};
  final _exportProgress = <String, double>{};
  final _postWaiters = <Completer<void>>[];
  final _playbackHolds = <String, int>{};
  final _cacheAccess = <String, AsyncGate>{};
  final _readable = <String, DownloadReadableState>{};
  final _directTargets = <String, DirectDownloadTarget>{};
  int _torrentPlaybackHolds = 0;
  bool _postBusy = false;
  Timer? _progressFlush;
  Timer? _foregroundTimer;
  bool _foregroundPublishing = false;
  Future<void>? _pausingAll;
  double? exportProgress(String id) => _exportProgress[id];
  ({int active, int total})? httpConnections(String id) {
    final run = _running[id];
    return run != null &&
            !run.stopped &&
            run.networkActive &&
            _tasks[id]?.status == DownloadStatus.running
        ? run.httpConnections
        : null;
  }

  BtSources? btSources(String id) {
    final run = _running[id];
    return run != null &&
            !run.stopped &&
            run.networkActive &&
            _tasks[id]?.status == DownloadStatus.running
        ? run.btSources
        : null;
  }

  int get _networkCount =>
      _running.values.where((run) => run.networkActive).length;
  bool _closing = false, _initialised = false;
  String? lastError;
  List<DownloadTask> get tasks => _tasks.ordered;
  Iterable<DownloadTask> get activeTasks =>
      _tasks.values.where((task) => task.active);
  int get activeCount => _running.length;
  AppSettings get settings => AppSettings.fromJson(store.data.obj('settings'));
  DownloadTask? task(String id) => _tasks[id];

  bool canStream(DownloadTask task) =>
      !task.spec.isTorrent &&
      task.status != DownloadStatus.cancelled &&
      {FileKind.video, FileKind.audio}.contains(fileKind(task.spec.fileName)) &&
      {'http', 'https'}.contains(Uri.tryParse(task.spec.url)?.scheme);

  Future<DownloadPlaybackCache> acquirePlayback(
    String id, {
    bool refresh = false,
  }) async {
    require(!_closing, '应用正在退出');
    final current = _tasks[id];
    require(current != null && canStream(current), '此下载任务无法边下边播');
    await (_cacheAccess[id] ??= AsyncGate()).run(() async {
      require(!_closing && _tasks.containsKey(id), '下载任务已关闭');
      _playbackHolds[id] = (_playbackHolds[id] ?? 0) + 1;
    });
    DownloadSpec? source;
    var released = false;
    Future<void> release() async {
      if (released) return;
      released = true;
      final count = (_playbackHolds[id] ?? 1) - 1;
      if (count <= 0) {
        _playbackHolds.remove(id);
      } else {
        _playbackHolds[id] = count;
      }
      final retainedSource = source;
      if (retainedSource != null) {
        await cleanups.release(retainedSource.cleanup);
        await cleanups.ready(retainedSource.cleanup);
      }
      if (!_closing) {
        await _pumpGate.run(() async {
          if (!_playbackHolds.containsKey(id) && !_running.containsKey(id)) {
            await engine.pause(id);
            await _releaseDirectTarget(id, onlyIfUnused: true);
          }
        });
        await _drainCompletedCaches();
        _background(cleanups.drain());
      }
    }

    try {
      if (refresh && current!.spec.source != null) {
        // CloudRepository.refresh returns a retained source of the same file.
        source = await refreshSource(current.spec);
      } else {
        source = current!.spec.copyWith();
        cleanups.retain(source.cleanup);
      }
      require(!_closing && _tasks[id] != null, '下载任务已关闭');
      await resume(id);
      _schedule();
      return DownloadPlaybackCache(
        source: source,
        read: (start, end, identity) async {
          require(!released && !_closing, '播放已结束');
          final bytes = await _readPlaybackCache(id, start, end, identity);
          if (bytes != null) return bytes;
          final task = _tasks[id];
          require(task != null, '下载任务已删除');
          require(
            task!.active || task.status == DownloadStatus.completed,
            task.status == DownloadStatus.failed
                ? '下载失败，请继续下载后重试播放'
                : '下载已暂停，请继续下载后重试播放',
          );
          return null;
        },
        onRelease: release,
      );
    } catch (_) {
      await release();
      rethrow;
    }
  }

  Future<Uint8List?> _readPlaybackCache(
    String id,
    int start,
    int end,
    RemoteIdentity identity,
  ) => (_cacheAccess[id] ??= AsyncGate()).run(() async {
    final state = _readable[id];
    if (state == null ||
        start < 0 ||
        end < start ||
        end - start >= 16 * 1024 * 1024 ||
        !state.identity.canResume(identity) ||
        !state.contains(start, end)) {
      return null;
    }
    RandomAccessFile? handle;
    try {
      File file;
      if (_tasks[id]?.directOutput == true) {
        final target = _directTargets[id];
        if (target == null) return null;
        file = target.file;
      } else {
        final directory = await engine.checkedTaskDirectory(id);
        if (directory == null) return null;
        final path = p.join(directory.path, 'payload.gopeed');
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          return null;
        }
        file = File(path);
      }
      handle = await file.open();
      if (await handle.length() < end + 1) return null;
      await handle.setPosition(start);
      final bytes = await handle.read(end - start + 1);
      return bytes.length == end - start + 1 ? bytes : null;
    } on FileSystemException {
      return null;
    } finally {
      await handle?.close();
    }
  });

  DownloadActivity get activity => DownloadActivity.fromTasks(
    _tasks.values.where(
      (task) =>
          _running.containsKey(task.id) ||
          (task.active && (!task.spec.isTorrent || _torrentPlaybackHolds == 0)),
    ),
  );

  Future<void> _syncForeground() async {
    if (foreground == null) return;
    await _foregroundGate.run(() async {
      // Compute inside the gate: a delayed idle update must never stop a newer
      // task's service. Pending tasks keep it alive across background handoffs.
      final current = activity;
      if (current.active == 0) {
        _foregroundTimer?.cancel();
        _foregroundTimer = null;
      }
      await foreground!(current);
      if (current.active > 0 && !_closing) {
        _foregroundTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
          if (_foregroundPublishing) return;
          _foregroundPublishing = true;
          unawaited(
            _syncForeground()
                .catchError((Object error, StackTrace stack) {
                  DiagnosticLog.error('download.foreground_lost', error, stack);
                  _background(pauseAll(reason: '后台下载服务已中断，请返回应用继续'));
                })
                .whenComplete(() => _foregroundPublishing = false),
          );
        });
      }
    });
  }

  /// Only the Android service's system restart invokes this. Opening the app
  /// normally does not resume paused/failed history or a user's explicit stop.
  Future<void> recoverInterrupted() async {
    if (_closing) return;
    final ids = _interrupted.toList();
    final result = await batch(ids, DownloadBatchAction.resume);
    if (result.failed.isNotEmpty) throw result.failed.values.first;
    _interrupted.removeWhere(
      (id) => _tasks[id]?.status != DownloadStatus.paused,
    );
    await _persist();
    await _syncForeground();
    DiagnosticLog.event(
      'download.service_recovered',
      fields: {'count': ids.length},
    );
  }

  Future<void> initialize() async {
    // Recovery is explicitly authorized by the native service after startup.
    if (_initialised) return;
    final watch = Stopwatch()..start();
    _loadSnapshot();
    await _persist();
    _initialised = true;
    await cleanups.reconcile(recoverOrphans: true);
    _background(cleanups.drain());
    _background(_drainRemovedDownloads());
    _background(_drainCompletedCaches());
    DiagnosticLog.event(
      'download.queue_loaded',
      fields: {
        'count': _tasks.length,
        'interrupted': _interrupted.length,
        'elapsedMs': watch.elapsedMilliseconds,
      },
    );
  }

  Future<void> discardInterrupted() async {
    if (_interrupted.isEmpty) return;
    _interrupted.clear();
    await _persist();
  }

  void _loadSnapshot() {
    final loaded = <String, DownloadTask>{};
    _interrupted
      ..clear()
      ..addAll(
        (store.data['downloadRecovery'] as List? ?? []).whereType<String>(),
      );
    for (final value in store.data.list('tasks')) {
      var task = DownloadTask.fromJson(value);
      engine.validateId(task.id);
      if (task.active) {
        _interrupted.add(task.id);
        task = task.update({'status': 'paused', 'phase': '', 'speed': 0});
      }
      if (store.data.integer('baiduConnectionsPolicy') < 1 &&
          BaiduShareRoute.usesAccountDownload(task.spec) &&
          task.spec.profile != 'baidu_direct' &&
          task.status == DownloadStatus.paused &&
          task.connections == 1) {
        task = task.update({
          'connections': settings.connectionsFor(
            task.spec.platform,
            task.spec.profile,
          ),
          if (task.spec.needsPreparation)
            'connectionOptions': {
              ...task.connectionOptions,
              for (final profile in ['baidu', 'baidu_direct'])
                profile: settings.connectionsFor(CloudPlatform.baidu, profile),
            },
        });
      }
      loaded[task.id] = task;
    }
    _interrupted.removeWhere(
      (id) => loaded[id]?.status != DownloadStatus.paused,
    );
    _tasks
      ..clear()
      ..addAll(loaded);
  }

  /// Hold scheduling while merging legacy records, then reload the committed
  /// queue before any later write can overwrite the imported tasks.
  Future<void> importPausedQueue(Future<void> Function() import) =>
      _pumpGate.run(() async {
        require(!_closing && _running.isEmpty, '请先暂停下载再导入旧版数据');
        await import();
        _loadSnapshot();
        await _persist();
        await cleanups.reconcile(recoverOrphans: true);
        _background(cleanups.drain());
        notifyListeners();
      });

  Future<void> _persist({
    Json addedTorrents = const {},
    Json cacheRoots = const {},
    bool changeDestination = false,
    String? destination,
    String? completedDownload,
    String? removedDownload,
    List<String> removedDownloads = const [],
    List<DownloadCleanup?> removedCleanups = const [],
  }) {
    _progressFlush?.cancel();
    _progressFlush = null;
    return store.change((draft) {
      draft['baiduConnectionsPolicy'] = 1;
      final removed = {?removedDownload, ...removedDownloads};
      final retained = _tasks.values
          .where((task) => !removed.contains(task.id))
          .toList();
      draft['tasks'] = retained.map((t) => t.toJson()).toList();
      draft['downloadRecovery'] = _interrupted
          .where((id) => !removed.contains(id))
          .toList();
      if (cacheRoots.isNotEmpty) {
        draft['downloadCacheRoots'] = <String, dynamic>{
          ...draft.obj('downloadCacheRoots'),
          ...cacheRoots,
        }..removeWhere((_, value) => value == null);
      }
      if (changeDestination) {
        draft['settings'] = AppSettings.fromJson(
          draft.obj('settings'),
        ).update({'destination': destination}).toJson();
      }
      if (completedDownload != null) {
        draft['completedCacheRemovals'] = <String>{
          ...(draft['completedCacheRemovals'] as List? ?? [])
              .whereType<String>(),
          completedDownload,
        }.toList();
      }
      final used = retained
          .where((t) => t.spec.isTorrent)
          .map((t) => t.spec.torrent!.str('hash'))
          .toSet();
      draft['torrents'] = <String, dynamic>{
        ...draft.obj('torrents'),
        ...addedTorrents,
      }..removeWhere((key, _) => !used.contains(key));
      if (removedDownload != null || removedDownloads.isNotEmpty) {
        // Commit the history removal and cleanup markers together. A file
        // provider or native cleanup failure must not bring the row back.
        for (final key in ['downloadRemovals', 'nativeRemovals']) {
          draft[key] = <String>{
            ...(draft[key] as List? ?? []).map((value) => '$value'),
            ?removedDownload,
            ...removedDownloads,
          }.toList();
        }
        cleanups.readyInDraft(draft, removedCleanups);
      }
    });
  }

  Future<void> _update(
    String id,
    Json fields, {
    bool persist = true,
    bool progress = false,
    bool connectionsChanged = false,
  }) async {
    final old = _tasks[id];
    if (old == null) return;
    final updated = old.update(fields);
    if (!identical(old, updated)) _tasks[id] = updated;
    if (!identical(old, updated) || connectionsChanged) notifyListeners();
    if (persist) {
      if (progress) {
        _progressFlush ??= Timer(const Duration(seconds: 2), () {
          _progressFlush = null;
          _background(_persist());
        });
      } else {
        await _persist();
      }
    }
  }

  void _background(Future<void> future) {
    unawaited(
      future.catchError((Object e, StackTrace stack) {
        DiagnosticLog.error('download.background_error', e, stack);
        lastError = e is AppException ? e.message : '操作失败，请检查存储空间后重试';
        notifyListeners();
      }),
    );
  }

  Future<String> enqueue(DownloadSpec spec, {int? connections}) async =>
      (await enqueueAll([spec], connections: connections)).single;

  bool _usesInternet(DownloadSpec spec) =>
      spec.profile != 'lan' || spec.platform != null;

  Future<void> _confirmDownload() async {
    require(!_closing, '应用正在退出');
    RequestScope.checkpoint();
    await confirmDownload?.call();
    RequestScope.checkpoint();
    require(!_closing, '应用正在退出');
  }

  void _notifyGuestDownload(String id, {bool attempted = false}) {
    final task = _tasks[id];
    if (_closing || task == null || (!attempted && !task.spec.guestDownload)) {
      return;
    }
    final batch = _guestDownloadBatches.putIfAbsent(
      id,
      _GuestDownloadBatch.new,
    );
    if (batch.notified) return;
    batch.notified = true;
    // Informational UI must never turn a working transfer into a failed task.
    try {
      onGuestDownload?.call();
    } catch (error, stack) {
      DiagnosticLog.error('download.guest_notice_failed', error, stack);
    }
  }

  Future<List<String>> enqueueAll(
    List<DownloadSpec> specs, {
    String? destination,
    int? connections,
  }) async {
    require(specs.isNotEmpty && specs.length <= 10000, '请选择 1–10000 个文件');
    require(
      connections == null || connections >= 1 && connections <= 512,
      '线程数请输入 1–512 之间的整数',
    );
    final selected = List<DownloadSpec>.of(specs, growable: false);
    if (confirmDownload != null && selected.any(_usesInternet)) {
      await _confirmDownload();
    }
    return _enqueueAll(
      selected,
      destination: destination,
      connections: connections,
    );
  }

  Future<List<String>> _enqueueAll(
    List<DownloadSpec> specs, {
    String? destination,
    int? connections,
  }) => _pumpGate.run(() async {
    require(!_closing, '应用正在退出');
    RequestScope.checkpoint();
    final watch = Stopwatch()..start();
    final options = settings;
    // Capture a one-task choice without changing global preferences. Provider
    // limits (Baidu account, Aliyun, LAN) still apply through connectionsFor.
    final connectionSettings = connections == null
        ? options
        : AppSettings(
            threads: connections,
            threadOverrides: {
              for (final profile in AppSettings.profiles.keys)
                profile: connections,
            },
          );
    final target = destination ?? options.destination;
    final cacheRoot = await files.downloadCacheRoot(target);
    final tasks = <DownloadTask>[];
    final ed2kIdentities = <String>{
      for (final existing in _tasks.values)
        if (!existing.terminal && existing.spec.isEd2k)
          '${Ed2kLink.parse(existing.spec.url).hash}:${Ed2kLink.parse(existing.spec.url).size}',
    };
    for (final spec in specs) {
      if (tasks.isNotEmpty && tasks.length % 128 == 0) {
        await RequestScope.wait(Duration.zero);
        require(!_closing, '应用正在退出');
      }
      if (spec.platform case final platform?) {
        checkNewCloudTask?.call(platform);
      }
      if (spec.needsPreparation) {
        final origin = DownloadOrigin.fromJson(spec.source!);
        require(
          origin.file.id.isNotEmpty && !origin.file.isDirectory,
          '下载文件信息不完整',
        );
      } else {
        _validateDownloadUrl(spec);
      }
      if (spec.isEd2k) {
        final file = Ed2kLink.parse(spec.url);
        require(
          ed2kIdentities.add('${file.hash}:${file.size}'),
          '相同 ED2K 文件已有下载任务，请继续原任务',
        );
      }
      final safeSpec = spec.copyWith(
        fileName: safeFileName(spec.fileName),
        relativePath: safeRelativePath(spec.relativePath),
        profile: BaiduShareRoute.downloadProfile(spec),
      );
      tasks.add(
        DownloadTask(
          id: newId(),
          spec: safeSpec,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          total: spec.isEd2k
              ? Ed2kLink.parse(spec.url).size
              : spec.expectedSize,
          connections: spec.isEd2k
              ? 1
              : connectionSettings.connectionsFor(
                  safeSpec.platform,
                  safeSpec.profile,
                ),
          retries: options.retries,
          speedLimit: options.speedLimit,
          destination: target,
          directOutput: files.directDownloads,
          phase: spec.needsPreparation ? '等待获取下载链接' : '',
          connectionOptions: spec.needsPreparation
              ? {
                  'default': connectionSettings.threads,
                  for (final profile in AppSettings.profiles.keys)
                    profile: connectionSettings.connectionsFor(
                      spec.platform,
                      profile,
                    ),
                }
              : const {},
        ),
      );
    }
    RequestScope.checkpoint();
    for (final task in tasks) {
      _tasks[task.id] = task;
    }
    try {
      await _persist(
        cacheRoots: {
          if (cacheRoot != null)
            for (final task in tasks) task.id: cacheRoot,
        },
      );
    } catch (_) {
      for (final task in tasks) {
        _tasks.remove(task.id);
      }
      rethrow;
    }
    final guestBatch = _GuestDownloadBatch();
    var reported = 0;
    for (final task in tasks) {
      _guestDownloadBatches[task.id] = guestBatch;
      _notifyGuestDownload(task.id);
      await cleanups.release(task.spec.cleanup);
      if (tasks.length <= 64) {
        DiagnosticLog.event(
          'download.enqueue',
          fields: {
            'ref': DiagnosticLog.reference(task.id),
            'platform': task.spec.platform?.name,
            'bytes': task.total,
            'connections': task.connections,
            'preparing': task.spec.needsPreparation,
          },
        );
      }
      if (++reported % 128 == 0) await Future<void>.delayed(Duration.zero);
    }
    DiagnosticLog.event(
      'download.batch_enqueued',
      fields: {
        'count': tasks.length,
        'queueSize': _tasks.length,
        'elapsedMs': watch.elapsedMilliseconds,
      },
    );
    notifyListeners();
    _schedule();
    return tasks.map((task) => task.id).toList();
  });

  void _validateDownloadUrl(DownloadSpec spec) {
    if (spec.isEd2k) {
      final link = Ed2kLink.parse(spec.url);
      require(
        spec.headers.isEmpty && spec.networkPolicy == null,
        'ED2K 不支持 HTTP 请求头',
      );
      require(
        spec.expectedSize == 0 || spec.expectedSize == link.size,
        'ED2K 文件大小与链接不一致',
      );
      return;
    }
    require(
      spec.source?['kind'] != 'remoteSource' || spec.networkPolicy != null,
      '来源下载权限缺失，请重新解析链接',
    );
    spec.networkPolicy?.checkedUrl(spec.url);
    final uri = Uri.tryParse(spec.url);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty,
      '只支持 HTTP / HTTPS 文件下载',
    );
  }

  Future<List<String>> enqueueTorrent(
    TorrentInfo info,
    List<int> selected,
  ) async {
    final indices = selected.toSet().toList()..sort();
    require(
      indices.isNotEmpty &&
          indices.length <= maxTorrentFiles &&
          indices.every((i) => i >= 0 && i < info.files.length),
      '每次请选择 1–$maxTorrentFiles 个文件',
    );
    if (confirmDownload != null) await _confirmDownload();
    return _enqueueTorrent(info, indices);
  }

  Future<List<String>> _enqueueTorrent(TorrentInfo info, List<int> indices) =>
      _pumpGate.run(() async {
        require(!_closing, '应用正在退出');
        RequestScope.checkpoint();
        final selectedIndices = indices.toSet();
        require(
          !_tasks.values.any(
            (t) =>
                !t.terminal &&
                t.spec.torrent?.str('hash') == info.hash &&
                selectedIndices.contains(t.spec.torrent!.integer('index')),
          ),
          '选中的文件已有下载任务，请在下载页继续',
        );
        final tasks = <DownloadTask>[], options = settings;
        final cacheRoot = await files.downloadCacheRoot(options.destination);
        for (final index in indices) {
          if (tasks.isNotEmpty && tasks.length % 128 == 0) {
            await RequestScope.wait(Duration.zero);
            require(!_closing, '应用正在退出');
          }
          final file = info.files[index], id = newId();
          tasks.add(
            DownloadTask(
              id: id,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              spec: DownloadSpec(
                url: info.magnet,
                fileName: safeFileName(file.name),
                relativePath: safeRelativePath(file.directory),
                expectedSize: file.size,
                torrent: {
                  'hash': info.hash,
                  'index': file.index,
                  'path': file.path,
                },
              ),
              total: file.size,
              connections: 80,
              retries: options.retries,
              speedLimit: options.speedLimit,
              destination: options.destination,
              directOutput: files.directDownloads,
            ),
          );
        }
        RequestScope.checkpoint();
        for (final task in tasks) {
          _tasks[task.id] = task;
        }
        try {
          await _persist(
            cacheRoots: {
              if (cacheRoot != null)
                for (final task in tasks) task.id: cacheRoot,
            },
            addedTorrents: {
              info.hash: {
                'data': info.data,
                'name': info.name,
                'pieceLength': info.pieceLength,
              },
            },
          );
        } catch (_) {
          for (final task in tasks) {
            _tasks.remove(task.id);
          }
          rethrow;
        }
        notifyListeners();
        _schedule();
        return tasks.map((task) => task.id).toList();
      });

  void _schedule() {
    if (_closing || _pausingAll != null) return;
    _background(
      _pumpGate.run(() async {
        while (!_closing &&
            _pausingAll == null &&
            _networkCount < settings.concurrent &&
            _running.length < settings.concurrent + 2) {
          final pending = _tasks.values
              .where(
                (t) =>
                    t.status == DownloadStatus.pending &&
                    !_running.containsKey(t.id) &&
                    (!t.spec.isEd2k ||
                        !_running.keys.any(
                          (id) => _tasks[id]?.spec.isEd2k == true,
                        )) &&
                    (!t.spec.isTorrent ||
                        (_torrentPlaybackHolds == 0 &&
                            !_running.keys.any(
                              (id) => _tasks[id]?.spec.isTorrent == true,
                            ))),
              )
              .toList();
          final next =
              pending
                  .where((task) => _playbackHolds.containsKey(task.id))
                  .firstOrNull ??
              pending.firstOrNull;
          if (next == null) break;
          final run = _Run(transferClock()..start());
          _running[next.id] = run;
          _unsettledRuns.add(run);
          run.done = run.scope
              .run(
                () => DownloadRequestContext(
                  id: next.id,
                  retries: next.retries,
                  onGuestDownload: () =>
                      _notifyGuestDownload(next.id, attempted: true),
                  onRetry: (_) async {
                    run.check();
                    run.networkRetries++;
                    await _update(next.id, {
                      'phase': '获取下载链接（重试中）',
                      'speed': 0,
                    }, persist: false);
                  },
                ).run(() => _run(next.id, run)),
              )
              .catchError((Object e) {
                lastError = e is AppException ? e.message : '下载状态保存失败，请检查存储空间';
              })
              .whenComplete(() async {
                try {
                  _running.remove(next.id);
                  _background(_drainCompletedCaches());
                  space.release(next.id);
                  _exportProgress.remove(next.id);
                  try {
                    await _syncForeground();
                  } catch (error, stack) {
                    DiagnosticLog.error(
                      'download.foreground_update_failed',
                      error,
                      stack,
                    );
                    _background(pauseAll(reason: '后台下载服务已中断，请返回应用继续'));
                  }
                  notifyListeners();
                  _schedule();
                } finally {
                  _unsettledRuns.remove(run);
                }
              });
        }
      }),
    );
  }

  Future<void> settingsChanged() async {
    // Existing transfers keep their captured thread/speed settings.
    if (_networkCount > settings.concurrent) {
      for (final id
          in _running.entries
              .where((e) => e.value.networkActive)
              .map((e) => e.key)
              .skip(settings.concurrent)
              .toList()) {
        await pause(id);
      }
    }
    _schedule();
  }

  /// Changing destinations never moves a live payload or discards a native
  /// checkpoint. Only tasks that have no cache yet adopt the new cache root.
  Future<bool> _canChangeCacheRoot(DownloadTask task, String cacheRoot) async =>
      !task.directOutput &&
      !p.equals(engine.taskCacheRoot(task.id).path, cacheRoot) &&
      task.downloaded == 0 &&
      !task.payloadReady &&
      await FileSystemEntity.type(
            engine.taskDirectory(task.id).path,
            followLinks: false,
          ) ==
          FileSystemEntityType.notFound &&
      await Directory(
        p.rootPrefix(engine.taskCacheRoot(task.id).absolute.path),
      ).exists();

  Future<int> changeDestination(
    String? destination, {
    bool includeUnfinished = false,
  }) async {
    require(!_closing, '应用正在退出');
    final cacheRoot = await files.downloadCacheRoot(destination);
    var changed = 0;
    try {
      await _pumpGate.run(() async {
        require(!_closing, '应用正在退出');
        RequestScope.checkpoint();
        if (!includeUnfinished) {
          await _persist(changeDestination: true, destination: destination);
          return;
        }
        final ids = _tasks.values
            .where((task) => !task.terminal)
            .map((task) => task.id)
            .toList();
        final applied = await _withTaskControls(ids, () async {
          var paused = false;
          for (final id in ids) {
            final task = _tasks[id];
            if (task?.active != true) continue;
            _running[id]?.stop();
            _interrupted.remove(id);
            _tasks[id] = task!.update({
              'status': 'paused',
              'speed': 0,
              'phase': '',
            });
            paused = true;
          }
          // Persist an explicit pause even if the directory change later
          // fails. Join export writers before replacing their destination.
          try {
            if (paused) await _persist();
          } finally {
            await Future.wait([
              for (final id in ids)
                if (_running.containsKey(id)) _stop(id),
            ]);
          }
          final originals = <String, DownloadTask>{};
          final replacements = <String, DownloadTask>{};
          final roots = <String, dynamic>{};
          for (final id in ids) {
            if (replacements.isNotEmpty && replacements.length % 64 == 0) {
              await RequestScope.wait(Duration.zero);
              require(!_closing, '应用正在退出');
            }
            final task = _tasks[id];
            if (task == null || task.terminal) continue;
            if (task.directOutput) {
              final target = await files.inspectDownloadTarget(id);
              if (target != null && target['destination'] != destination) {
                // The native checkpoint belongs to this document. A settings
                // change must not pair those ranges with a new empty file.
                continue;
              }
            }
            originals[id] = task;
            replacements[id] = task.update({'destination': destination});
            if (cacheRoot != null &&
                await _canChangeCacheRoot(task, cacheRoot)) {
              roots[id] = cacheRoot;
            }
          }
          RequestScope.checkpoint();
          require(!_closing, '应用正在退出');
          _tasks.addAll(replacements);
          try {
            await _persist(
              cacheRoots: roots,
              changeDestination: true,
              destination: destination,
            );
          } catch (_) {
            for (final entry in originals.entries) {
              if (identical(_tasks[entry.key], replacements[entry.key])) {
                _tasks[entry.key] = entry.value;
              }
            }
            rethrow;
          }
          changed = replacements.length;
        });
        require(applied, '修改下载目录已取消');
      });
      DiagnosticLog.event(
        'download.destination_changed',
        fields: {'includeUnfinished': includeUnfinished, 'updated': changed},
      );
      return changed;
    } finally {
      notifyListeners();
      _schedule();
    }
  }

  /// Playback gets BT bandwidth without changing a user's explicit pause.
  /// Interrupted downloads remain queued with their native checkpoint intact.
  Future<VoidCallback> prioritizeTorrentPlayback() async {
    require(!_closing, '应用正在退出');
    _torrentPlaybackHolds++;
    try {
      await _pumpGate.run(() async {
        final ids = _running.entries
            .where(
              (entry) =>
                  entry.value.networkActive &&
                  _tasks[entry.key]?.spec.isTorrent == true,
            )
            .map((entry) => entry.key)
            .toList();
        for (final id in ids) {
          await _control(id, () async {
            final task = _tasks[id];
            if (task == null ||
                !task.active ||
                _running[id]?.networkActive != true) {
              return;
            }
            await _stop(id);
            if (_tasks[id] != null && !_tasks[id]!.terminal) {
              await _update(id, {
                'status': 'pending',
                'speed': 0,
                'phase': '在线播放优先，稍后继续下载',
              });
            }
          });
        }
      });
    } catch (_) {
      _torrentPlaybackHolds--;
      _schedule();
      rethrow;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      _torrentPlaybackHolds--;
      _schedule();
    };
  }

  Future<void> resume(String id) async {
    if (confirmDownload == null) return _resume(id);
    DownloadTask? candidate;
    // Observe a preceding pause after it commits, then release the task gate
    // before waiting for UI. A quick pause/resume must still request consent.
    await _control(id, () async {
      candidate = _tasks[id];
    });
    final current = candidate;
    if (current == null || current.terminal || current.active) return;
    if (_usesInternet(current.spec)) await _confirmDownload();
    return _resume(id);
  }

  Future<void> _resume(String id) => _control(id, () async {
    require(!_closing, '应用正在退出');
    RequestScope.checkpoint();
    _interrupted.remove(id);
    final current = _tasks[id];
    if (current == null || current.terminal || current.active) return;
    await _update(id, {
      'status': 'pending',
      'error': '',
      'recoveryAction': DownloadRecoveryAction.none.name,
      'phase': '',
    });
    _schedule();
  });
  Future<T> _control<T>(String id, Future<T> Function() action) =>
      (_controls[id] ??= AsyncGate()).run(action);
  Future<void> _stop(String id) async {
    final run = _running[id];
    if (run != null) {
      run.stop();
      await files.cancelExport(id);
      await engine.pause(id);
      await run.done;
    }
  }

  Future<void> pause(String id) => _control(id, () async {
    _interrupted.remove(id);
    DiagnosticLog.event(
      'download.pause',
      fields: {'ref': DiagnosticLog.reference(id)},
    );
    // Commit the user's pause before waiting for native/export writers. A
    // process loss during cancellation must not restore it as active work.
    if (_tasks[id]?.active == true) {
      _running[id]?.stop();
      await _update(id, {'status': 'paused', 'speed': 0, 'phase': ''});
    }
    await _stop(id);
    final current = _tasks[id];
    if (current != null && !current.terminal) {
      await _update(id, {'status': 'paused', 'speed': 0, 'phase': ''});
    }
  });
  Future<void> pauseAll({String reason = ''}) =>
      _pausingAll ??= _pauseAll(reason).whenComplete(() {
        _pausingAll = null;
        if (!_closing) Timer.run(_schedule);
      });

  Future<void> _pauseAll(String reason) async {
    _interrupted.clear();
    final ids = _tasks.values.where((t) => t.active).map((t) => t.id).toSet();
    // Mark all pending tasks before the first writer finishes and frees a slot.
    for (final id in ids) {
      _running[id]?.stop();
      _tasks[id] = _tasks[id]!.update({
        'status': 'paused',
        'speed': 0,
        'phase': '',
      });
    }
    await _pumpGate.run(() async {
      // Also cover a batch that was still committing when pause-all started.
      for (final task in _tasks.values.where((task) => task.active).toList()) {
        ids.add(task.id);
        _running[task.id]?.stop();
        _tasks[task.id] = task.update({
          'status': 'paused',
          'speed': 0,
          'phase': '',
        });
      }
      await _persist();
      // Queued files have no writer. Calling pause() on each of them used to
      // rewrite the entire queue once per file during shutdown.
      await Future.wait([
        for (final id in ids)
          if (_running.containsKey(id)) _control(id, () => _stop(id)),
      ]);
      if (reason.isNotEmpty) {
        for (final id in ids) {
          if (_tasks[id]?.status == DownloadStatus.paused) {
            _tasks[id] = _tasks[id]!.update({'phase': reason});
          }
        }
        await _persist();
        DiagnosticLog.event(
          'download.service_paused',
          fields: {'reason': reason, 'count': ids.length},
        );
      }
    });
    await _syncForeground();
    notifyListeners();
  }

  Future<void> resumeAll() async {
    final result = await batch(
      tasks.where(DownloadBatchAction.resume.accepts).map((task) => task.id),
      DownloadBatchAction.resume,
    );
    if (result.failed.isNotEmpty) throw result.failed.values.first;
  }

  Future<DownloadBatchResult> _changeStatuses(
    List<String> ids,
    DownloadBatchAction action,
  ) async {
    final succeeded = <String>[], skipped = <String>[];
    final failed = <String, Object>{};
    var cancelled = false;
    Future<void> commit() async {
      final originals = <String, DownloadTask>{},
          changed = <String, DownloadTask>{};
      final recovered = _interrupted.intersection(ids.toSet());
      for (final id in ids) {
        final task = _tasks[id];
        if (task == null || !action.accepts(task)) {
          skipped.add(id);
          continue;
        }
        originals[id] = task;
        _interrupted.remove(id);
        if (action == DownloadBatchAction.pause) _running[id]?.stop();
        changed[id] = _tasks[id] = task.update({
          'status': action == DownloadBatchAction.pause ? 'paused' : 'pending',
          'phase': '',
          'speed': 0,
          if (action == DownloadBatchAction.resume) ...{
            'error': '',
            'recoveryAction': DownloadRecoveryAction.none.name,
          },
        });
      }
      if (changed.isEmpty) return;
      try {
        await _persist();
      } catch (error) {
        for (final entry in originals.entries) {
          // A failed resume must never be scheduled by a later queue write.
          // Pauses remain stopped in memory, as with a single-task pause.
          if (action == DownloadBatchAction.resume &&
              identical(_tasks[entry.key], changed[entry.key])) {
            _tasks[entry.key] = entry.value;
            if (recovered.contains(entry.key)) _interrupted.add(entry.key);
          }
          failed[entry.key] = error;
        }
        notifyListeners();
        return;
      }
      notifyListeners();
      for (final id in changed.keys) {
        try {
          if (action == DownloadBatchAction.pause && _running.containsKey(id)) {
            await _stop(id);
          }
          succeeded.add(id);
        } catch (error) {
          failed[id] = error;
        }
      }
      DiagnosticLog.event(
        'download.batch_status',
        fields: {
          'action': action.name,
          'count': succeeded.length,
          'failed': failed.length,
        },
      );
    }

    cancelled = !await _withTaskControls(ids, commit);
    return DownloadBatchResult(
      succeeded: succeeded,
      skipped: skipped,
      failed: failed,
      cancelled: cancelled || RequestScope.current?.isCancelled == true,
    );
  }

  Future<bool> _withTaskControls(
    List<String> ids,
    Future<void> Function() action,
  ) async {
    // Hold per-task controls with a flat barrier. Nesting one Future per task
    // overflows the stack when thousands of nested gates complete at once.
    final release = Completer<void>();
    final controls = <Future<void>>[];
    final entered = <Future<void>>[];
    var cancelled = false;
    try {
      // Reserve every selected control before yielding. A later single-task
      // pause/delete must run after this batch, including its last selected ID.
      for (final id in ids) {
        final ready = Completer<void>();
        controls.add(
          _control(id, () {
            ready.complete();
            return release.future;
          }),
        );
        entered.add(ready.future);
      }
      for (var index = 0; index < entered.length; index += 128) {
        if (index > 0) await Future<void>.delayed(Duration.zero);
        if (_closing || RequestScope.current?.isCancelled == true) {
          cancelled = true;
          break;
        }
        await Future.wait(entered.skip(index).take(128));
      }
      cancelled |= _closing || RequestScope.current?.isCancelled == true;
      if (!cancelled) await action();
    } finally {
      release.complete();
      await Future.wait(controls);
    }
    return !cancelled;
  }

  Future<DownloadBatchResult> batch(
    Iterable<String> ids,
    DownloadBatchAction action, {
    bool deleteFiles = false,
  }) async {
    require(!_closing, '应用正在退出');
    final selected = ids.toSet().toList(growable: false);
    if (confirmDownload != null &&
        action == DownloadBatchAction.resume &&
        selected.any((id) {
          final task = _tasks[id];
          return task != null &&
              action.accepts(task) &&
              _usesInternet(task.spec);
        })) {
      await _confirmDownload();
    }
    try {
      // Hold scheduling so stopping one writer cannot start another selected
      // queued task before its pause or deletion is processed.
      if (action != DownloadBatchAction.delete) {
        return await _pumpGate.run(() => _changeStatuses(selected, action));
      }
      return await _trackDeletion(
        selected.length,
        (progress) =>
            _pumpGate.run(() => _deleteBatch(selected, deleteFiles, progress)),
        deleteFiles: deleteFiles,
      );
    } finally {
      _schedule();
    }
  }

  Future<T> _trackDeletion<T>(
    int total,
    Future<T> Function(_DeletionProgress progress) action, {
    required bool deleteFiles,
  }) {
    final progress = _DeletionProgress(total);
    return OperationProgress.step<T>(
      deleteFiles
          ? OperationStage.deleteDownloads
          : OperationStage.removeDownloadRecords,
      () async {
        progress.report(force: true);
        try {
          return await action(progress);
        } finally {
          progress.finish();
        }
      },
      statusForResult: (_) =>
          progress.cancelled ||
              _closing ||
              RequestScope.current?.isCancelled == true
          ? OperationStepStatus.cancelled
          : progress.failed > 0
          ? OperationStepStatus.failed
          : OperationStepStatus.completed,
    );
  }

  Future<DownloadBatchResult> _deleteBatch(
    List<String> selected,
    bool deleteFiles,
    _DeletionProgress progress,
  ) async {
    final succeeded = <String>[], skipped = <String>[];
    final failed = <String, Object>{};
    var cancelled = false;
    for (var index = 0; index < selected.length; index++) {
      final id = selected[index];
      if (_closing || RequestScope.current?.isCancelled == true) {
        cancelled = true;
        break;
      }
      final chunk = selected.sublist(
        index,
        (index + 64).clamp(0, selected.length),
      );
      final result = await _deleteIdleRecords(
        chunk,
        deleteFiles: deleteFiles,
        progress: progress,
      );
      if (result != null) {
        succeeded.addAll(result.succeeded);
        skipped.addAll(result.skipped);
        failed.addAll(result.failed);
        index += chunk.length - 1;
        if (result.cancelled) {
          cancelled = true;
          break;
        }
        continue;
      }
      try {
        final removed = await _deleteTask(
          id,
          deleteFile: deleteFiles,
          progress: progress,
        );
        if (removed == null) {
          cancelled = true;
          break;
        }
        if (removed) {
          succeeded.add(id);
          progress.processedItem(succeeded: 1);
        } else {
          skipped.add(id);
          progress.processedItem(skipped: 1);
        }
      } catch (e) {
        failed[id] = e;
        progress.processedItem(failed: 1);
      }
    }
    progress.cancelled = cancelled || RequestScope.current?.isCancelled == true;
    return DownloadBatchResult(
      succeeded: succeeded,
      skipped: skipped,
      failed: failed,
      cancelled: progress.cancelled,
    );
  }

  Future<void> delete(String id, {bool deleteFile = false}) =>
      _trackDeletion<void>(1, (progress) async {
        try {
          final removed = await _deleteTask(
            id,
            deleteFile: deleteFile,
            progress: progress,
          );
          if (removed == null) {
            progress.cancelled = true;
          } else {
            progress.processedItem(
              succeeded: removed ? 1 : 0,
              skipped: removed ? 0 : 1,
            );
          }
        } catch (_) {
          progress.processedItem(failed: 1);
          rethrow;
        }
      }, deleteFiles: deleteFile);

  Future<bool?> _deleteTask(
    String id, {
    required bool deleteFile,
    required _DeletionProgress progress,
  }) => _control(id, () async {
    if (_closing || RequestScope.current?.isCancelled == true) return null;
    _interrupted.remove(id);
    var current = _tasks[id];
    if (current == null) return false;
    require(!_playbackHolds.containsKey(id), '请先关闭此任务的播放器再删除');
    DiagnosticLog.event(
      'download.remove_start',
      fields: {
        'ref': DiagnosticLog.reference(id),
        'status': current.status.name,
        'deleteFile': deleteFile,
      },
    );
    if (current.active ||
        current.status != DownloadStatus.completed &&
            _running.containsKey(id)) {
      progress.report(
        activity: OperationStage.stopDownloads,
        force: progress.total == 1,
      );
    }
    if (current.active) {
      _running[id]?.stop();
      await _update(id, {'status': 'paused', 'speed': 0});
    }
    try {
      // Completed exports have no file writer left. Their run may still
      // be waiting for native/cache cleanup, which must not block history.
      if (current.status != DownloadStatus.completed) await _stop(id);
      current = _tasks[id]!;
      if (deleteFile) {
        progress.report(
          activity: OperationStage.deleteFiles,
          force: progress.total == 1,
        );
        await _deleteSavedFile(current);
      }
      progress.report(
        activity: OperationStage.removeDownloadRecords,
        force: true,
      );
      _tasks.remove(id);
      // Once writers are stopped, persist removal before slow native or
      // filesystem cleanup. The durable markers retry after a restart.
      await _persist(removedDownload: id);
      _guestDownloadBatches.remove(id);
      DiagnosticLog.event(
        'download.record_removed',
        fields: {'ref': DiagnosticLog.reference(id)},
      );
      notifyListeners();
      _background(OperationProgress.detached(_drainRemovedDownloads));
      _background(
        OperationProgress.detached(
          () => _readyRemovedCleanup(current!.spec.cleanup),
        ),
      );
      return true;
    } catch (e, stack) {
      DiagnosticLog.error(
        'download.remove_failed',
        e,
        stack,
        fields: {'ref': DiagnosticLog.reference(id), 'deleteFile': deleteFile},
      );
      _tasks[id] ??= current!;
      await _update(id, {
        'error': e is AppException ? e.message : '删除未完成，记录已保留，请重试',
      });
      rethrow;
    }
  });

  Future<void> _deleteSavedFile(DownloadTask task) async {
    var savedPath = task.savedPath;
    if (savedPath == null && task.directOutput) {
      final target = await files.inspectDownloadTarget(task.id);
      if (target != null &&
          (target.boolean('published') || target.boolean('publishing'))) {
        savedPath = await _finishStoredTarget(task.id, target);
      }
    }
    await files.delete(savedPath);
  }

  Future<DownloadBatchResult?> _deleteIdleRecords(
    List<String> ids, {
    bool deleteFiles = false,
    required _DeletionProgress progress,
  }) async {
    bool idle() => ids.every((id) {
      final task = _tasks[id];
      return task == null ||
          !task.active &&
              (task.status == DownloadStatus.completed ||
                  !_running.containsKey(id));
    });
    if (!idle()) return null;
    DownloadBatchResult? result;
    // Serialize against per-task pause/resume/delete while committing one
    // bounded group. Batches already share the scheduling gate.
    Future<void> locked(int index) async {
      if (index < ids.length) {
        await _control(ids[index], () => locked(index + 1));
        return;
      }
      if (!idle()) return;
      final failed = <String, Object>{}, skipped = <String>[];
      if (_closing || RequestScope.current?.isCancelled == true) {
        result = DownloadBatchResult(
          succeeded: [],
          skipped: [],
          failed: {},
          cancelled: true,
        );
        return;
      }
      final removed = <String, DownloadTask>{};
      var cancelled = false;
      progress.report(
        activity: deleteFiles
            ? OperationStage.deleteFiles
            : OperationStage.removeDownloadRecords,
        force: true,
      );
      for (final id in ids) {
        if (_closing || RequestScope.current?.isCancelled == true) {
          cancelled = true;
          break;
        }
        final task = _tasks[id];
        if (task == null) {
          skipped.add(id);
          progress.processedItem(skipped: 1);
          continue;
        }
        if (_playbackHolds.containsKey(id)) {
          failed[id] = const AppException('请先关闭此任务的播放器再删除');
          progress.processedItem(failed: 1);
          continue;
        }
        if (deleteFiles) {
          try {
            await _deleteSavedFile(task);
          } catch (error, stack) {
            failed[id] = error;
            progress.processedItem(failed: 1);
            _tasks[id] = task.update({
              'error': error is AppException
                  ? error.message
                  : '删除未完成，记录已保留，请重试',
            });
            DiagnosticLog.error(
              'download.remove_failed',
              error,
              stack,
              fields: {'ref': DiagnosticLog.reference(id), 'deleteFile': true},
            );
            continue;
          }
        }
        removed[id] = task;
        progress.processedItem();
      }
      if (removed.isNotEmpty || deleteFiles && failed.isNotEmpty) {
        progress.report(
          activity: OperationStage.removeDownloadRecords,
          force: true,
        );
        try {
          await _persist(
            removedDownloads: removed.keys.toList(),
            removedCleanups: removed.values.map((t) => t.spec.cleanup).toList(),
          );
        } catch (error) {
          progress.confirm(failed: removed.length);
          for (final id in removed.keys) {
            failed[id] = error;
            if (deleteFiles) {
              _tasks[id] = _tasks[id]!.update({
                'error': error is AppException
                    ? error.message
                    : '删除未完成，记录已保留，请重试',
              });
            }
          }
          removed.clear();
          notifyListeners();
        }
        if (removed.isNotEmpty) {
          // Keep the live rows until the removal and cleanup markers commit.
          // An unrelated queued state save must not publish half a removal.
          for (final id in removed.keys) {
            _tasks.remove(id);
            _guestDownloadBatches.remove(id);
            _interrupted.remove(id);
          }
          DiagnosticLog.event(
            'download.records_removed',
            fields: {'count': removed.length},
          );
          progress.confirm(succeeded: removed.length);
          notifyListeners();
          _background(OperationProgress.detached(_drainRemovedDownloads));
          _background(OperationProgress.detached(cleanups.drain));
        } else if (deleteFiles && failed.isNotEmpty) {
          notifyListeners();
        }
      }
      result = DownloadBatchResult(
        succeeded: removed.keys.toList(),
        skipped: skipped,
        failed: failed,
        cancelled: cancelled || RequestScope.current?.isCancelled == true,
      );
    }

    await locked(0);
    return result;
  }

  Future<void> _readyRemovedCleanup(DownloadCleanup? cleanup) async {
    await cleanups.ready(cleanup);
    await cleanups.drain();
  }

  /// Removed history no longer owns a live writer. Retry its private cache
  /// separately, keeping the durable marker until cleanup succeeds.
  Future<void> _drainRemovedDownloads() => _removalGate.run(() async {
    final ids = (store.data['downloadRemovals'] as List? ?? [])
        .map((value) => '$value')
        .toList();
    final removed = <String>{}, nativeRemoved = <String>{};
    Future<void> commit() async {
      if (removed.isEmpty && nativeRemoved.isEmpty) return;
      await store.change((draft) {
        final cleaned = removed.where((id) => !_tasks.containsKey(id)).toSet();
        final nativeCleaned = nativeRemoved
            .where((id) => !_tasks.containsKey(id))
            .toSet();
        if (cleaned.isNotEmpty) {
          draft['downloadRemovals'] = (draft['downloadRemovals'] as List? ?? [])
              .where((value) => !cleaned.contains(value))
              .toList();
          final roots = draft.obj('downloadCacheRoots')
            ..removeWhere((id, _) => cleaned.contains(id));
          if (draft.containsKey('downloadCacheRoots')) {
            draft['downloadCacheRoots'] = roots;
          }
          if (draft.containsKey('completedCacheRemovals')) {
            draft['completedCacheRemovals'] =
                (draft['completedCacheRemovals'] as List? ?? [])
                    .where((value) => !cleaned.contains(value))
                    .toList();
          }
        }
        if (nativeCleaned.isNotEmpty) {
          draft['nativeRemovals'] = (draft['nativeRemovals'] as List? ?? [])
              .where((value) => !nativeCleaned.contains(value))
              .toList();
        }
      });
      removed.clear();
      nativeRemoved.clear();
    }

    var processed = 0;
    try {
      for (final id in ids) {
        if (_closing) break;
        if (_tasks.containsKey(id)) continue;
        try {
          if (await engine.remove(id, deferPersistence: true)) {
            nativeRemoved.add(id);
          }
          if (_tasks.containsKey(id)) continue;
          await _cleanRemovedTarget(id);
          await _deleteCache(id);
          removed.add(id);
        } catch (error, stack) {
          DiagnosticLog.error(
            'download.cleanup_deferred',
            error,
            stack,
            fields: {'ref': DiagnosticLog.reference(id)},
          );
          // Failed items retain their marker for the next removal or restart.
          // Exported files are never touched here.
        }
        if (++processed >= 64) {
          await commit();
          processed = 0;
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      // Flush a partial batch on shutdown as well. A failed commit leaves the
      // markers intact, so repeating an already-finished cleanup is safe.
      await commit();
    }
  });

  Future<void> _drainCompletedCaches() => _removalGate.run(() async {
    final ids = (store.data['completedCacheRemovals'] as List? ?? [])
        .map((value) => '$value')
        .toList();
    for (final id in ids) {
      if (_closing) return;
      if (_playbackHolds.containsKey(id) ||
          _running.containsKey(id) ||
          (_tasks[id] != null &&
              _tasks[id]!.status != DownloadStatus.completed)) {
        continue;
      }
      try {
        await _cleanCompletedDownload(id);
      } catch (error, stack) {
        DiagnosticLog.error('download.playback_cache_cleanup', error, stack);
      }
    }
  });

  Future<void> _deleteCache(String id) =>
      (_cacheAccess[id] ??= AsyncGate()).run(() => _deleteCacheUnlocked(id));

  Future<void> _deleteCacheUnlocked(String id) async {
    _readable.remove(id);
    final directory = await engine.checkedTaskDirectory(id);
    if (directory == null) return;
    await directory.delete(recursive: true);
  }

  /// Preserve checkpoints made by older versions. Only tasks with no cached
  /// payload can adopt direct output without moving an in-progress file.
  Future<Json?> _prepareDirectOutput(String id) async {
    final task = _tasks[id]!;
    if (!files.directDownloads) {
      require(!task.directOutput, '此任务需要在安卓设备上继续下载');
      return null;
    }
    final target = await files.inspectDownloadTarget(id);
    if (target == null) {
      final directory = await engine.checkedTaskDirectory(id);
      final hasCache =
          directory != null &&
          !await directory.list(followLinks: false).isEmpty;
      if (!task.directOutput &&
          (hasCache || task.downloaded > 0 || task.payloadReady)) {
        return null;
      }
      require(
        !task.directOutput ||
            !hasCache && task.downloaded == 0 && !task.payloadReady,
        '下载目标记录已丢失，请重新添加任务；已有文件未被删除',
      );
    }
    if (!task.directOutput) await _update(id, {'directOutput': true});
    return target;
  }

  Future<DirectDownloadTarget?> _openDirectTarget(String id, _Run run) async {
    if (!_tasks[id]!.directOutput) return null;
    await engine.requireDirectOutput();
    return (_cacheAccess[id] ??= AsyncGate()).run(() async {
      run.check();
      final task = _tasks[id]!;
      final target = _directTargets[id] ??= await files.openDownloadTarget(
        id: id,
        name: task.spec.fileName,
        relativePath: task.spec.relativePath,
        destination: task.destination,
      );
      // Keep the lease registered even if a pause arrived while opening it;
      // the run's finally block releases it after every writer has stopped.
      run.check();
      return target;
    });
  }

  Future<void> _releaseDirectTarget(
    String id, {
    bool forget = false,
    bool onlyIfUnused = false,
  }) => (_cacheAccess[id] ??= AsyncGate()).run(() async {
    if (onlyIfUnused && _playbackHolds.containsKey(id)) return;
    await _releaseDirectTargetUnlocked(id, forget: forget);
  });

  Future<void> _releaseDirectTargetUnlocked(
    String id, {
    bool forget = false,
  }) async {
    final target = _directTargets[id];
    if (target != null) {
      await files.releaseDownloadTarget(id, target);
      _directTargets.remove(id);
      _readable.remove(id);
    }
    if (forget) await files.forgetDownloadTarget(id);
  }

  Future<void> _markCompleted(String id, String savedPath) async {
    final task = _tasks[id];
    if (task == null) return;
    _tasks[id] = task.update({
      'status': 'completed',
      'savedPath': savedPath,
      'error': '',
      'phase': '',
      'speed': 0,
    });
    notifyListeners();
    // The journal acknowledgement is retried after a crash. Never forget the
    // only durable reference to a published file before recording its URI.
    await _persist(completedDownload: id);
  }

  Future<void> _cleanCompletedDownload(String id) async {
    await engine.remove(id);
    final cleaned = await (_cacheAccess[id] ??= AsyncGate()).run(() async {
      if (_playbackHolds.containsKey(id)) return false;
      await _deleteCacheUnlocked(id);
      await _releaseDirectTargetUnlocked(id, forget: files.directDownloads);
      return true;
    });
    if (!cleaned) return;
    await store.change((draft) {
      draft['completedCacheRemovals'] =
          (draft['completedCacheRemovals'] as List? ?? [])
              .where((value) => value != id)
              .toList();
    });
  }

  Future<void> _afterCompleted(String id, DownloadSpec spec) async {
    try {
      if (!_playbackHolds.containsKey(id)) await _cleanCompletedDownload(id);
    } catch (_) {
      await _update(id, {'phase': '已完成，下载记录稍后清理'});
    }
    await cleanups.ready(spec.cleanup);
    _background(cleanups.drain());
  }

  Future<String> _finishStoredTarget(String id, Json state) async {
    if (state.boolean('published')) return state.str('uri');
    final target = await (_cacheAccess[id] ??= AsyncGate()).run(
      () async => _directTargets[id] ??= await files.openDownloadTarget(
        id: id,
        name: state.str('name'),
        relativePath: state.str('relativePath'),
        destination: state['destination'] as String?,
      ),
    );
    try {
      return await files.finishDownloadTarget(id, target, state.str('name'));
    } finally {
      await _releaseDirectTarget(id);
    }
  }

  /// A removed row may have been published just before its Dart state write
  /// failed. Finish that publication and keep the file; only partial output
  /// is discarded when removing history without requesting file deletion.
  Future<void> _cleanRemovedTarget(String id) async {
    if (!files.directDownloads) return;
    var state = await files.inspectDownloadTarget(id);
    if (state == null) {
      await _releaseDirectTarget(id);
      return;
    }
    if (state.boolean('publishing') && !state.boolean('published')) {
      await _finishStoredTarget(id, state);
      state = {...state, 'published': true};
    }
    if (state.boolean('published')) {
      await _releaseDirectTarget(id, forget: true);
    } else {
      await _releaseDirectTarget(id);
      await files.discardDownloadTarget(id);
    }
  }

  Future<void> _run(String id, _Run run) async {
    String? newSaved;
    var committed = false;
    try {
      run.check();
      await _update(id, {'status': 'running', 'error': '', 'phase': '连接中'});
      await _syncForeground();
      run.check();
      final recordedTarget = await _prepareDirectOutput(id);
      run.check();
      if (recordedTarget != null &&
          (recordedTarget.boolean('published') ||
              recordedTarget.boolean('publishing'))) {
        // Verification and fsync preceded the publication journal. A restart
        // here must finish locally, even if the original URL has expired.
        if (recordedTarget.boolean('published')) {
          newSaved = recordedTarget.str('uri');
        } else {
          final target = (await _openDirectTarget(id, run))!;
          await engine.pause(id);
          run.check();
          newSaved = await files.finishDownloadTarget(
            id,
            target,
            _tasks[id]!.spec.fileName,
          );
        }
        require(newSaved.isNotEmpty, '下载目标记录无效，文件已保留');
        final spec = _tasks[id]!.spec;
        await _markCompleted(id, newSaved);
        committed = true;
        await _afterCompleted(id, spec);
        return;
      }
      final task = _tasks[id]!;
      if (!task.directOutput && task.downloaded == 0 && !task.payloadReady) {
        // Tasks restored from older versions may have a selected destination
        // but no per-task cache root. Adopt it before checking disk capacity,
        // while retaining every existing payload and native checkpoint.
        final cacheRoot = await files.downloadCacheRoot(task.destination);
        if (cacheRoot != null && await _canChangeCacheRoot(task, cacheRoot)) {
          run.check();
          await _persist(cacheRoots: {id: cacheRoot});
        }
      }
      run.check();
      run.storage = await files.storagePlan(
        engine.taskCacheRoot(id).path,
        _tasks[id]!.destination,
      );
      if (_tasks[id]!.directOutput) {
        run.storage = run.storage.forDirectOutput();
      }
      _volumePaths[run.storage.cache.id] = run.storage.cache.path;
      _volumePaths.putIfAbsent(
        run.storage.target.id,
        () => run.storage.target.path,
      );
      if (_tasks[id]!.spec.needsPreparation) {
        await _prepareSource(id, run);
      }
      _notifyGuestDownload(id);
      File? output;
      final old = _tasks[id]!;
      if (old.payloadReady) {
        final target = await _openDirectTarget(id, run);
        if (target == null) await engine.checkedTaskDirectory(id);
        final cached =
            target?.file ??
            File(
              p.join(
                engine.taskDirectory(id).path,
                old.hls.isEmpty ? 'payload.gopeed' : 'payload.hls',
              ),
            );
        if (await cached.exists() && await cached.length() == old.total) {
          output = cached;
        }
      }
      if (output == null) {
        var refresh = 0;
        while (true) {
          run.check();
          try {
            output = await _networkRetry<File>(
              id,
              run,
              () => _transfer(id, run),
            );
            break;
          } on _RecoverBaidu catch (recovery) {
            await engine.pause(id);
            run.check();
            if (recovery.action == BaiduRecoveryAction.refreshLink &&
                _tasks[id]!.spec.source != null) {
              try {
                await _prepareSource(id, run, preserveProgress: true);
              } catch (error) {
                run.check();
                // Recovery is optional. A failed refresh keeps the last
                // working source and never discards an existing checkpoint.
                DiagnosticLog.event(
                  'download.slow_refresh_skipped',
                  fields: {
                    'ref': DiagnosticLog.reference(id),
                    'kind': error.runtimeType.toString(),
                  },
                );
              }
            }
          } on _RecoverAliyun {
            await engine.pause(id);
            run.check();
            await _update(id, {'phase': '正在恢复阿里下载连接', 'speed': 0});
            await run.delay(Duration(seconds: 2 * run.aliyunRecovery.attempts));
            run.check();
          } on DownloadHttpException catch (e) {
            if (!e.mayRefresh ||
                refresh >= 2 ||
                _tasks[id]!.spec.source == null) {
              rethrow;
            }
            refresh++;
            await engine.pause(id);
            await _prepareSource(
              id,
              run,
              preserveProgress:
                  _isAliyun(_tasks[id]!.spec) && _tasks[id]!.downloaded > 0,
            );
          }
        }
      }
      run.check();
      // A completed BT task can still seed. Join native writers before
      // checking/publishing a target whose descriptor will then be released.
      await engine.pause(id);
      run.check();
      final readyLength = await output.length();
      await _reserve(id, run, readyLength, readyLength, waitForExport: true);
      run.networkActive = false;
      await _update(id, {'phase': '等待校验 / 保存', 'speed': 0});
      _schedule();
      await _acquirePost(run);
      try {
        run.check();
        await _update(id, {'phase': '校验文件', 'speed': 0});
        final task = _tasks[id]!;
        if (task.hls.isEmpty) await _verify(output, task.spec, run);
        run.check();
        final length = await output.length();
        final target = _directTargets[id];
        await _update(id, {
          'payloadReady': true,
          'total': length,
          'downloaded': length,
          'phase': target != null ? '完成下载' : '保存文件',
        });
        await _reserve(id, run, length, length);
        var copied = 0, lastUi = 0;
        final saveClock = Stopwatch()..start();
        if (target != null) {
          run.check();
          newSaved = await files.finishDownloadTarget(
            id,
            target,
            task.spec.fileName,
          );
        } else {
          _exportProgress[id] = 0;
          newSaved = await files.save(
            id: id,
            source: output,
            name: task.spec.fileName,
            relativePath: task.spec.relativePath,
            destination: task.destination,
            checkpoint: run.check,
            onProgress: (written, total) {
              if (run.stopped) return;
              final current = written.clamp(copied, length);
              space.consume(id, run.storage.target.id, current - copied);
              copied = current;
              _exportProgress[id] = length == 0 ? 1 : copied / length;
              if (saveClock.elapsedMilliseconds - lastUi >= 250 ||
                  copied == length) {
                lastUi = saveClock.elapsedMilliseconds;
                final task = _tasks[id];
                if (task != null) {
                  _tasks[id] = task.update({
                    'phase': '保存文件 ${(_exportProgress[id]! * 100).round()}%',
                  });
                  notifyListeners();
                }
              }
            },
          );
          run.check();
        }
        DiagnosticLog.event(
          'download.saved',
          fields: {
            'ref': DiagnosticLog.reference(id),
            'bytes': length,
            'saveMs': saveClock.elapsedMilliseconds,
            'retries': run.networkRetries,
            'directOutput': target != null,
            'sameVolume': run.storage.cache.id == run.storage.target.id,
          },
        );
        await _markCompleted(id, newSaved);
        committed = true;
        await _afterCompleted(id, task.spec);
      } finally {
        _releasePost();
      }
    } catch (e, stack) {
      if (!run.stopped && e is! _Stopped) {
        DiagnosticLog.error(
          'download.transfer_failed',
          e,
          stack,
          fields: {
            'ref': DiagnosticLog.reference(id),
            'phase': _tasks[id]?.phase,
            if (e is HttpRequestFailure) 'kind': e.kind,
            if (e is HttpRequestFailure) 'status': e.status ?? 0,
            if (e is DownloadSpaceException) ...{
              'volume': e.volume,
              'disk': _spaceFailureDisk(run, e),
              'spaceRole': run.storage.cache.id == run.storage.target.id
                  ? 'cache_and_target'
                  : e.volume == run.storage.cache.id
                  ? 'cache'
                  : 'target',
              'sameVolume': run.storage.cache.id == run.storage.target.id,
              'copyOnSave': run.storage.copyOnSave,
              'freeBytes': e.freeBytes,
              'requiredBytes': e.requiredBytes,
              'reservedBytes': e.reservedBytes,
              'marginBytes': e.marginBytes,
            },
          },
        );
      }
      if (!committed) {
        if (newSaved != null && _tasks[id]?.directOutput != true) {
          try {
            await files.delete(newSaved);
          } catch (_) {
            await _update(id, {
              'savedPath': newSaved,
              'error': '保存被中断且文件清理失败，请在任务详情中删除',
            });
          }
        }
        final message = run.stopped || e is _Stopped
            ? ''
            : _tasks[id]?.spec.profile == 'lan' &&
                  e is DownloadHttpException &&
                  e.status == 410
            ? '设备互联分享已结束或过期，请让发送方重新分享'
            : _tasks[id]?.spec.profile == 'lan' &&
                  e is DownloadHttpException &&
                  e.status == 409
            ? '发送方的源文件已修改，请重新分享后接收'
            : _tasks[id]?.spec.profile == 'lan' && e is DownloadNetworkException
            ? '无法连接发送设备，请确认处于同一局域网且对方保持分享开启'
            : e is DownloadSpaceException
            ? _spaceFailureMessage(run, e)
            : e is AppException
            ? e.message
            : e is FileSystemException
            ? '读写文件失败，请检查存储空间和目录权限'
            : '下载失败，请检查网络后重试';
        await _update(id, {
          'status': run.stopped || e is _Stopped ? 'paused' : 'failed',
          'error': message,
          'recoveryAction': !run.stopped && e is UcTvAuthorizationRequired
              ? DownloadRecoveryAction.ucAuthorization.name
              : DownloadRecoveryAction.none.name,
          'speed': 0,
          'phase': '',
        });
      }
    } finally {
      try {
        await engine.pause(id);
        await _releaseDirectTarget(id, onlyIfUnused: !_closing);
      } catch (_) {
        if (!committed) lastError = '暂停下载组件失败，重试前请重新打开应用';
      }
    }
  }

  Future<void> _acquirePost(_Run run) async {
    run.check();
    if (!_postBusy) {
      _postBusy = true;
      return;
    }
    final turn = Completer<void>();
    _postWaiters.add(turn);
    await Future.any([turn.future, run.wake.future]);
    if (run.stopped) {
      if (!_postWaiters.remove(turn)) _releasePost();
      run.check();
    }
  }

  void _releasePost() {
    if (_postWaiters.isEmpty) {
      _postBusy = false;
    } else {
      _postWaiters.removeAt(0).complete();
    }
  }

  Future<void> _reserve(
    String id,
    _Run run,
    int total,
    int downloaded, {
    int overhead = 0,
    bool waitForExport = false,
  }) async {
    final phase = _tasks[id]!.phase;
    var waiting = false;
    while (true) {
      run.check();
      try {
        await space.reserveVolumes(
          id,
          run.storage.requirements(total, downloaded, overhead: overhead),
        );
        if (waiting) await _update(id, {'phase': phase}, persist: false);
        return;
      } on DownloadSpaceException {
        if (!waitForExport ||
            !_running.entries.any(
              (entry) => entry.key != id && !entry.value.networkActive,
            )) {
          rethrow;
        }
        if (!waiting) {
          waiting = true;
          await _update(id, {'phase': '等待保存释放空间', 'speed': 0}, persist: false);
        }
        await run.delay(const Duration(milliseconds: 250));
      }
    }
  }

  String? _spaceFailureDisk(_Run run, DownloadSpaceException error) {
    if (!Platform.isWindows || error.volume == null) return null;
    final volume = error.volume == run.storage.cache.id
        ? run.storage.cache
        : run.storage.target;
    // Only retain the drive letter, never the directory or UNC share name.
    final root = p.rootPrefix(volume.path);
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(root)
        ? root.substring(0, 2).toUpperCase()
        : null;
  }

  String _spaceFailureMessage(_Run run, DownloadSpaceException error) {
    final disk = _spaceFailureDisk(run, error);
    if (disk == null) return error.message;
    final cacheOnly =
        error.volume == run.storage.cache.id &&
        run.storage.cache.id != run.storage.target.id;
    final location = cacheOnly ? '下载缓存' : '下载目录';
    return '$location所在磁盘（$disk）空间不足，进度已保留，请释放空间后继续';
  }

  Future<void> _prepareSource(
    String id,
    _Run run, {
    bool preserveProgress = false,
  }) async {
    run.check();
    final previous = _tasks[id]!;
    await _update(id, {
      'phase': previous.spec.needsPreparation ? '获取下载链接' : '刷新下载地址',
      'speed': 0,
    });
    final fresh = await refreshSource(previous.spec);
    var committed = false;
    try {
      run.check();
      _validateDownloadUrl(fresh);
      require(fresh.platform == previous.spec.platform, '下载来源发生变化，请重新添加任务');
      if (preserveProgress) {
        require(
          previous.spec.profile != 'baidu_preview' ||
              {'baidu_preview', 'baidu_direct'}.contains(fresh.profile),
          '预览通道暂不可用，保留当前下载地址',
        );
        final probe = await http.probeDownload(
          settings.githubAcceleration.apply(fresh),
        );
        run.check();
        require(
          !probe.hls &&
              probe.rangeSupported &&
              previous.identity.canResume(probe.identity),
          '新地址无法确认断点，保留当前下载地址',
        );
      }
      final profile = settings.connectionProfileFor(
        fresh.platform,
        BaiduShareRoute.downloadProfile(fresh),
      );
      final spec = fresh
          .copyWith(
            fileName: previous.spec.fileName,
            relativePath: previous.spec.relativePath,
            appUpdateKey: previous.spec.appUpdateKey,
            profile: BaiduShareRoute.downloadProfile(fresh),
          )
          .toJson();
      if (fresh.expectedSize <= 0 && previous.spec.expectedSize > 0) {
        spec['expectedSize'] = previous.spec.expectedSize;
      }
      if (fresh.checksumType?.isNotEmpty != true ||
          fresh.checksumValue?.isNotEmpty != true) {
        spec['checksumType'] = previous.spec.checksumType;
        spec['checksumValue'] = previous.spec.checksumValue;
      }
      try {
        await _update(id, {
          'spec': spec,
          'connections':
              fresh.profile == 'baidu_direct' &&
                  previous.spec.profile != 'baidu_direct'
              ? settings.connectionsFor(fresh.platform, profile)
              : BaiduShareRoute.usesPublicDownload(previous.spec) &&
                    previous.spec.profile !=
                        BaiduShareRoute.publicDownloadProfile
              ? settings.connectionsFor(fresh.platform, profile)
              : previous.spec.needsPreparation
              ? previous.connectionOptions[profile == 'baidu_preview'
                        ? 'baidu'
                        : profile ?? 'default'] ??
                    previous.connections
              : previous.connections,
          'connectionOptions': <String, int>{},
          'phase': '连接中',
        });
      } catch (_) {
        final current = _tasks[id];
        if (current != null) {
          _tasks[id] = current.update({
            'spec': previous.spec.toJson(),
            'connections': previous.connections,
            'connectionOptions': previous.connectionOptions,
          });
          notifyListeners();
        }
        rethrow;
      }
      committed = true;
    } finally {
      await cleanups.release(fresh.cleanup);
      if (!committed) await cleanups.ready(fresh.cleanup);
    }
    _notifyGuestDownload(id);
    await cleanups.ready(previous.spec.cleanup);
  }

  Future<void> _retryWait(
    String id,
    _Run run,
    int attempt,
    Object error,
  ) async {
    run.check();
    final delay = downloadRetryDelay(attempt, error);
    final phase = _tasks[id]!.phase;
    run.networkRetries++;
    DiagnosticLog.event(
      'download.retry',
      fields: {
        'ref': DiagnosticLog.reference(id),
        'attempt': run.networkRetries,
        'status': error is DownloadHttpException ? error.status : 0,
        'kind': error is DownloadNetworkException ? error.kind : 'network',
        'waitMs': delay.inMilliseconds,
      },
    );
    await _update(id, {'phase': '${delay.inSeconds} 秒后重试', 'speed': 0});
    await run.delay(delay);
    run.check();
    await _update(id, {'phase': phase}, persist: false);
  }

  Future<T> _networkRetry<T>(
    String id,
    _Run run,
    Future<T> Function() operation,
  ) async {
    for (var attempt = 0; ; attempt++) {
      run.check();
      try {
        return await operation();
      } catch (error) {
        run.check();
        if (!retryableDownloadError(error)) rethrow;
        if (attempt >= _tasks[id]!.retries) throw DownloadRetryExhausted(error);
        await engine.pause(id);
        await _retryWait(id, run, attempt, error);
      }
    }
  }

  Future<Probe> _probe(String id, _Run run, DownloadSpec spec) async {
    if (spec.profile != 'wopan') return http.probeDownload(spec);
    // Use the same TLS implementation as the actual Wopan file transfer.
    // Each native call returns promptly so pause/delete can cancel the probe.
    try {
      await engine.httpProbeCall('httpProbeStart', {
        'id': id,
        'url': spec.url,
        'headers': http.headers(spec.headers),
      });
      while (true) {
        run.check();
        final state = await engine.httpProbeCall('httpProbeStatus', {'id': id});
        run.check();
        final status = state.str('status');
        if (status == 'done') {
          return Probe.response(state.integer('code'), {
            for (final entry in state.obj('headers').entries)
              if (entry.value is String) entry.key: entry.value as String,
          }, hlsPath: state.boolean('hlsPath'));
        }
        if (status == 'error') {
          if (state.str('errorKind') == 'certificate') {
            throw const AppException('服务器证书校验失败');
          }
          throw DownloadNetworkException(
            'nativeProbe',
            retryable: state.boolean('retryable'),
          );
        }
        require(status == 'running', '下载连接检查已取消或响应无效');
        await run.delay(const Duration(milliseconds: 100));
      }
    } finally {
      await engine.httpProbeCall('httpProbeStop', {'id': id});
    }
  }

  Future<File> _transfer(String id, _Run run) async {
    run.httpConnections = null;
    var task = _tasks[id]!;
    if (task.spec.isTorrent) return _torrent(id, run);
    if (task.spec.isEd2k) return _ed2k(id, run);
    _validateDownloadUrl(task.spec);
    // Choose once per transfer so the probe and native engine use the same
    // endpoint even if settings change while the connection is being opened.
    final transferSpec = settings.githubAcceleration.apply(task.spec);
    final probe = await _probe(id, run, transferSpec);
    run.check();
    if (probe.hls) {
      require(task.spec.networkPolicy == null, '该来源暂不支持流媒体清单下载');
      return _hls(id, run);
    }
    final aliyun = _isAliyun(task.spec);
    require(
      !(task.spec.expectedSize > 0 &&
          probe.identity.total > 0 &&
          task.spec.expectedSize != probe.identity.total),
      '远端文件长度已变化，请重新添加下载',
    );
    final reset = !task.identity.canResume(probe.identity);
    if (reset) {
      require(
        !aliyun || task.downloaded == 0,
        '阿里文件的断点信息发生变化，已保留下载进度，请刷新文件列表后确认',
      );
      await engine.remove(id);
      await _deleteCache(id);
      await _update(id, {'downloaded': 0, 'hls': {}});
    }
    final total = probe.identity.total > 0
        ? probe.identity.total
        : task.spec.expectedSize;
    await _update(id, {
      'identity': probe.identity.toJson(),
      'total': total,
      if (BaiduShareRoute.usesPublicDownload(task.spec) &&
          task.spec.profile != BaiduShareRoute.publicDownloadProfile) ...{
        'spec': task.spec
            .copyWith(profile: BaiduShareRoute.publicDownloadProfile)
            .toJson(),
        'connections': settings.connectionsFor(
          task.spec.platform,
          BaiduShareRoute.publicDownloadProfile,
        ),
      },
      'payloadReady': false,
      'phase': '',
    });
    task = _tasks[id]!;
    await _reserve(id, run, total, task.downloaded, waitForExport: true);
    final headers = {
      ...http.headers(task.spec.headers),
      if (probe.identity.ifRange != null) 'If-Range': probe.identity.ifRange!,
    };
    run.check();
    final target = await _openDirectTarget(id, run);
    // The native resume can discard an evicted or truncated payload. Do not
    // reuse the previous run's intervals until its new snapshot arrives.
    await (_cacheAccess[id] ??= AsyncGate()).run(() async {
      run.check();
      _readable.remove(id);
      if (reset && target != null) {
        final handle = await target.file.open(mode: FileMode.append);
        try {
          await handle.truncate(0);
        } finally {
          await handle.close();
        }
      }
      run.check();
      await engine.begin({
        'id': id,
        'url': transferSpec.url,
        'headers': headers,
        if (task.spec.networkPolicy != null)
          'networkPolicy': task.spec.networkPolicy!.toJson(),
        'connections': aliyun
            ? run.aliyunRecovery.connections(task.connections)
            : task.connections,
        'connectionProfile': settings.connectionProfileFor(
          task.spec.platform,
          BaiduShareRoute.downloadProfile(task.spec),
        ),
        'retries': task.retries,
        'speedLimit': task.speedLimit,
        if (aliyun) 'aliyunGroup': _aliyunAccountGroup(task.spec),
        if (target != null) ...target.engineArguments,
      });
    });
    var persisted = 0;
    if (aliyun) {
      run.aliyunRecovery.start(run.clock.elapsed, task.downloaded);
    }
    final baidu = BaiduShareRoute.usesAccountDownload(task.spec);
    if (baidu) {
      run.baiduRecovery.start(run.clock.elapsed, task.downloaded);
      DiagnosticLog.event(
        'download.baidu_transfer_start',
        fields: {
          'ref': DiagnosticLog.reference(id),
          'profile': task.spec.profile,
          'probeHost': probe.host,
          'downloaded': task.downloaded,
          'total': total,
          'resumable': probe.rangeSupported && probe.identity.ifRange != null,
          'recoveryAttempt': run.baiduRecovery.attempts,
        },
      );
    }
    while (true) {
      run.check();
      final state = await engine.snapshot(id),
          now = DateTime.now().millisecondsSinceEpoch;
      final nativeTotal = state.integer('total'),
          downloaded = state.integer('downloaded');
      final connections = state.integer('totalConnections');
      final previousConnections = run.httpConnections;
      run.httpConnections = connections > 0
          ? (
              active: state.str('status') == 'running'
                  ? state.integer('activeConnections').clamp(0, connections)
                  : 0,
              total: connections,
            )
          : null;
      require(
        !(total > 0 && nativeTotal > 0 && total != nativeTotal),
        '远端文件内容已变化，请重新添加下载',
      );
      final currentTotal = nativeTotal > 0 ? nativeTotal : total;
      final aliyunPolicy = aliyun ? state.obj('aliyun') : <String, dynamic>{};
      final aliyunLimit = aliyunPolicy.integer(
        'limit',
        run.aliyunRecovery.connections(task.connections),
      );
      final aliyunWaitMs = aliyunPolicy.integer('waitMs');
      final aliyunQueued = aliyunPolicy.boolean('queued');
      final aliyunWaiting = aliyunWaitMs > 0 || aliyunQueued;
      final aliyunPhase = state.integer('activeConnections') > 0
          ? ''
          : aliyunWaitMs > 0
          ? '阿里下载 ${(aliyunWaitMs + 999) ~/ 1000} 秒后重试'
          : aliyunQueued
          ? '等待阿里下载连接'
          : '';
      if (aliyun &&
          (run.aliyunPolicyLimit != aliyunLimit ||
              run.aliyunWaiting != aliyunWaiting)) {
        run.aliyunPolicyLimit = aliyunLimit;
        run.aliyunWaiting = aliyunWaiting;
        DiagnosticLog.event(
          'download.aliyun_policy',
          fields: {
            'ref': DiagnosticLog.reference(id),
            'limit': aliyunLimit,
            'active': state.integer('activeConnections'),
            'waitMs': aliyunWaitMs,
            'queued': aliyunQueued,
          },
        );
      }
      final ranges = <(int, int)>[];
      for (final value in state['readableRanges'] as List? ?? const []) {
        if (value is List &&
            value.length == 2 &&
            value[0] is int &&
            value[1] is int &&
            value[0] >= 0 &&
            value[1] > value[0] &&
            value[1] <= currentTotal) {
          ranges.add((value[0] as int, value[1] as int));
        }
      }
      if (state.str('status') == 'done' && currentTotal > 0) {
        ranges.add((0, currentTotal));
      }
      _readable[id] = DownloadReadableState(probe.identity, ranges);
      if (now - persisted >= 1500) {
        await _reserve(id, run, currentTotal, downloaded);
        persisted = now;
        await _update(
          id,
          {
            'total': currentTotal,
            'downloaded': downloaded,
            'speed': state.str('status') == 'running'
                ? state.integer('speed').clamp(0, 1 << 60)
                : 0,
            if (aliyun) 'phase': aliyunPhase,
          },
          progress: true,
          connectionsChanged: previousConnections != run.httpConnections,
        );
      } else {
        await _update(
          id,
          {
            'total': currentTotal,
            'downloaded': downloaded,
            'speed': state.str('status') == 'running'
                ? state.integer('speed').clamp(0, 1 << 60)
                : 0,
            if (aliyun) 'phase': aliyunPhase,
          },
          persist: false,
          connectionsChanged: previousConnections != run.httpConnections,
        );
      }
      if (state.str('status') == 'done') {
        final file = target?.file ?? File(state.str('path'));
        if (target != null) {
          require(
            state.str('path') == target.path && await file.exists(),
            '下载目标已失效',
          );
        } else {
          final parent = await engine.taskDirectory(id).resolveSymbolicLinks();
          require(
            await file.exists() &&
                p.equals(p.dirname(await file.resolveSymbolicLinks()), parent),
            '下载结果路径无效',
          );
        }
        require(
          currentTotal <= 0 || await file.length() == currentTotal,
          '下载文件长度不完整',
        );
        return file;
      }
      if (state.str('status') == 'error') {
        if (state.integer('httpCode') == 412) {
          throw const AppException('远端文件内容已变化，请重新添加下载');
        }
        if (state.integer('httpCode') != 0) {
          throw DownloadHttpException(
            state.integer('httpCode'),
            retryAfter: Duration(milliseconds: state.integer('retryAfterMs')),
            exhausted: state.boolean('retryExhausted', true),
          );
        }
        if (state.str('errorKind') == 'network') {
          throw DownloadNetworkException(
            'native',
            retryable: !state.boolean('retryExhausted', true),
          );
        }
        throw AppException(state.str('error').ifEmpty('Gopeed 下载失败，请重试'));
      }
      if (state.str('status') == 'pause') {
        run.check();
        throw const AppException('下载组件已暂停，请继续任务');
      }
      if (aliyun &&
          run.aliyunRecovery.observe(
            now: run.clock.elapsed,
            downloaded: downloaded,
            total: currentTotal,
            currentLimit: aliyunLimit,
            retries: task.retries,
            canRecover:
                state.str('status') == 'running' &&
                !aliyunWaiting &&
                task.speedLimit == 0 &&
                probe.rangeSupported &&
                probe.identity.ifRange != null &&
                !_playbackHolds.containsKey(id),
          )) {
        DiagnosticLog.event(
          'download.aliyun_recovery',
          fields: {
            'ref': DiagnosticLog.reference(id),
            'attempt': run.aliyunRecovery.attempts,
            'downloaded': downloaded,
            'limit': run.aliyunRecovery.connections(task.connections),
            'stallMs': AliyunTransferRecovery.stallWindow.inMilliseconds,
          },
        );
        throw _RecoverAliyun();
      }
      if (baidu) {
        final sample = run.baiduRecovery.observe(
          now: run.clock.elapsed,
          downloaded: downloaded,
          total: currentTotal,
          speedLimit: task.speedLimit,
          canRecover:
              state.str('status') == 'running' &&
              state.integer('activeConnections') > 0 &&
              probe.rangeSupported &&
              probe.identity.ifRange != null &&
              _networkCount == 1 &&
              !_playbackHolds.containsKey(id),
        );
        if (sample != null) {
          DiagnosticLog.event(
            'download.baidu_speed',
            fields: {
              'ref': DiagnosticLog.reference(id),
              'profile': task.spec.profile,
              'bytesPerSecond': sample.bytesPerSecond,
              'windowMs': sample.windowMs,
              'downloaded': downloaded,
              'total': currentTotal,
              'recoveryAttempt': run.baiduRecovery.attempts,
            },
          );
          if (sample.action != null) {
            DiagnosticLog.event(
              'download.slow_recovery',
              fields: {
                'ref': DiagnosticLog.reference(id),
                'action': sample.action!.name,
                'attempt': run.baiduRecovery.attempts,
                'bytesPerSecond': sample.bytesPerSecond,
              },
            );
            await _update(id, {'phase': '连接持续较慢，正在尝试恢复', 'speed': 0});
            throw _RecoverBaidu(sample.action!);
          }
        }
      }
      await run.delay(const Duration(milliseconds: 350));
    }
  }

  Future<File> _ed2k(String id, _Run run) async {
    final task = _tasks[id]!;
    _validateDownloadUrl(task.spec);
    final link = Ed2kLink.parse(task.spec.url);
    await _reserve(id, run, link.size, task.downloaded);
    run.check();
    final target = await _openDirectTarget(id, run);
    run.check();
    await engine.begin({
      'id': id,
      'url': link.url,
      'connections': 1,
      'retries': task.retries,
      'speedLimit': task.speedLimit,
      if (target != null) ...target.engineArguments,
    });
    var persisted = 0;
    while (true) {
      run.check();
      final state = await engine.snapshot(id);
      require(
        state.integer('total') == link.size || state.integer('total') == 0,
        'ED2K 文件长度与链接不一致',
      );
      final downloaded = state.integer('downloaded').clamp(0, link.size);
      final peers = state.integer('totalConnections').clamp(0, 100000);
      final active = state.integer('activeConnections').clamp(0, peers);
      run.httpConnections = (active: active, total: peers);
      final now = DateTime.now().millisecondsSinceEpoch;
      final persist = now - persisted >= 1500;
      if (persist) {
        persisted = now;
        await _reserve(id, run, link.size, downloaded);
      }
      await _update(
        id,
        {
          'total': link.size,
          'downloaded': downloaded,
          'speed': state.str('status') == 'running'
              ? state.integer('speed').clamp(0, 1 << 60)
              : 0,
          'phase': downloaded == link.size
              ? 'ED2K 校验分片'
              : active > 0
              ? 'ED2K 分片下载'
              : peers > 0
              ? 'ED2K 等待来源排队'
              : 'ED2K 正在查找来源',
        },
        persist: persist,
        progress: true,
      );
      if (state.str('status') == 'done') {
        // Drain and close native writers before publishing the document.
        await engine.pause(id);
        run.check();
        final file = target?.file ?? File(state.str('path'));
        require(
          await file.exists() && await file.length() == link.size,
          'ED2K 下载结果不完整或目标已失效',
        );
        if (target != null) {
          require(state.str('path') == target.path, 'ED2K 下载目标已失效');
        } else {
          final root = await engine.taskDirectory(id).resolveSymbolicLinks();
          require(
            p.isWithin(root, await file.resolveSymbolicLinks()),
            'ED2K 下载路径无效',
          );
        }
        return file;
      }
      if (state.str('status') == 'error') {
        throw AppException(state.str('error').ifEmpty('ED2K 下载失败，请重试'));
      }
      if (state.str('status') == 'pause') {
        run.check();
        throw const AppException('ED2K 下载已暂停，请继续任务');
      }
      await run.delay(const Duration(milliseconds: 350));
    }
  }

  Future<File> _torrent(String id, _Run run) async {
    final task = _tasks[id]!, selection = _tasks[id]!.spec.torrent!;
    final metadata = store.data.obj('torrents').obj(selection.str('hash'));
    final data = metadata.str('data');
    final boundaryBytes = metadata.integer('pieceLength', 4 * 1024 * 1024) * 2;
    require(data.startsWith(torrentDataPrefix), '种子信息已丢失，请重新添加种子');
    await _reserve(
      id,
      run,
      task.total,
      task.downloaded,
      overhead: boundaryBytes,
    );
    run.check();
    final target = await _openDirectTarget(id, run);
    run.check();
    await engine.begin({
      'id': id,
      'url': task.spec.url,
      'torrentData': data,
      'torrentIndex': selection.integer('index'),
      'btUploadLimit': settings.btUploadLimit,
      'connections': task.connections,
      'retries': task.retries,
      'speedLimit': task.speedLimit,
      if (target != null) ...target.engineArguments,
    });
    var persisted = 0;
    while (true) {
      run.check();
      final state = await engine.snapshot(id),
          now = DateTime.now().millisecondsSinceEpoch;
      require(
        state.integer('total') == task.total || state.integer('total') == 0,
        'BT 文件长度与种子不一致',
      );
      final downloaded = state.integer('downloaded');
      final persist = now - persisted >= 1500;
      if (persist) {
        persisted = now;
        await _reserve(
          id,
          run,
          task.total,
          downloaded,
          overhead: boundaryBytes,
        );
      }
      final previousSources = run.btSources;
      run.btSources = state['bt'] is Map
          ? BtSources.fromJson(state.obj('bt'))
          : null;
      await _update(
        id,
        {
          'downloaded': downloaded.clamp(0, task.total),
          'speed': state.str('status') == 'running'
              ? state.integer('speed').clamp(0, 1 << 60)
              : 0,
          'phase': downloaded == 0 ? '连接做种者 / 校验分片' : 'BT 分片下载',
        },
        persist: persist,
        progress: true,
        connectionsChanged: previousSources != run.btSources,
      );
      if (state.str('status') == 'done') {
        if (target != null) {
          require(
            state.str('path') == target.path &&
                await target.file.exists() &&
                await target.file.length() == task.total,
            'BT 下载结果不完整或目标已失效',
          );
          return target.file;
        }
        final file = File(state.str('path')),
            directory = engine.taskDirectory(id);
        final root = await directory.resolveSymbolicLinks();
        require(
          await file.exists() &&
              p.isWithin(root, await file.resolveSymbolicLinks()) &&
              await file.length() == task.total,
          'BT 下载结果不完整或路径无效',
        );
        // Close the torrent and its seeding handles before moving/exporting.
        await engine.remove(id);
        run.check();
        final output = File(p.join(directory.path, 'payload.gopeed'));
        if (p.equals(file.path, output.path)) return file;
        if (await output.exists()) await output.delete();
        return file.rename(output.path);
      }
      if (state.str('status') == 'error') {
        throw AppException(state.str('error').ifEmpty('BT 下载失败，请检查做种人数后重试'));
      }
      if (state.str('status') == 'pause') {
        run.check();
        throw const AppException('BT 下载已暂停，请继续任务');
      }
      await run.delay(const Duration(milliseconds: 350));
    }
  }

  Future<void> _verify(File file, DownloadSpec spec, _Run run) async {
    if (spec.checksumValue?.isNotEmpty != true) return;
    final algorithm = spec.checksumType?.toLowerCase().replaceAll('-', '');
    final hash = switch (algorithm) {
      'md5' => md5,
      'sha1' => sha1,
      'sha256' => sha256,
      _ => null,
    };
    if (hash == null) return;
    final digest = await file
        .openRead()
        .map((chunk) {
          run.check();
          return chunk;
        })
        .transform(hash)
        .first;
    require(
      digest.toString().toLowerCase() == spec.checksumValue!.toLowerCase(),
      '文件校验失败，请删除此任务后重新下载',
    );
  }

  Future<File> _hls(String id, _Run run) async {
    final task = _tasks[id]!;
    var playlist = await http.textResponse(task.spec.url, task.spec.headers);
    for (var depth = 0; depth < 4; depth++) {
      final selected = HlsPlaylist.choose(playlist.url, playlist.text);
      if (selected == playlist.url) break;
      playlist = await http.textResponse(selected, task.spec.headers);
    }
    require(!playlist.text.contains('#EXT-X-STREAM-INF'), '视频播放列表嵌套过多');
    final media = HlsPlaylist.media(playlist.url, playlist.text);
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(media.urls)))
        .toString();
    final extension = media.fragmentedMp4 ? '.mp4' : '.ts';
    final spec = task.spec.copyWith(
      fileName: '${p.basenameWithoutExtension(task.spec.fileName)}$extension',
    );
    // Choose the final container name before creating the durable document.
    await _update(id, {'spec': spec.toJson()});
    final target = await _openDirectTarget(id, run);
    final directory = engine.taskDirectory(id);
    final output = target?.file ?? File(p.join(directory.path, 'payload.hls'));
    var index = task.hls.integer('index'), retained = task.hls.integer('bytes');
    if (task.hls.str('fingerprint') != fingerprint ||
        !await output.exists() ||
        await output.length() < retained ||
        index > media.urls.length) {
      await engine.remove(id);
      await _deleteCache(id);
      index = 0;
      retained = 0;
    }
    if (target == null) await engine.checkedTaskDirectory(id, create: true);
    await _update(id, {
      'spec': spec.toJson(),
      'total': 0,
      'downloaded': retained,
      'phase': '下载视频分片',
      'payloadReady': false,
      'hls': {'fingerprint': fingerprint, 'index': index, 'bytes': retained},
    });
    final speedClock = Stopwatch()..start();
    var received = 0;
    run.check();
    final handle = await output.open(mode: FileMode.append);
    try {
      await handle.truncate(retained);
      await handle.setPosition(retained);
      for (; index < media.urls.length; index++) {
        var success = false;
        for (var attempt = 0; attempt <= task.retries; attempt++) {
          run.check();
          await handle.truncate(retained);
          await handle.setPosition(retained);
          var segmentBytes = 0;
          try {
            final response = await http.stream(
              media.urls[index],
              http.headers(task.spec.headers),
            );
            final code = response.statusCode ?? 0;
            if (code < 200 || code >= 300) {
              await response.data!.stream.listen((_) {}).cancel();
              throw DownloadHttpException.response(response);
            }
            await for (final chunk in response.data!.stream) {
              run.check();
              await _reserve(
                id,
                run,
                retained + segmentBytes + chunk.length,
                retained + segmentBytes,
              );
              await handle.writeFrom(chunk);
              segmentBytes += chunk.length;
              received += chunk.length;
              if (task.speedLimit > 0) {
                final target = received * 1000 ~/ task.speedLimit,
                    delay = target - speedClock.elapsedMilliseconds;
                if (delay > 0) await run.delay(Duration(milliseconds: delay));
              }
            }
            require(segmentBytes > 0, '视频分片为空');
            await handle.flush();
            retained += segmentBytes;
            await _update(id, {
              'downloaded': retained,
              'speed': received * 1000 ~/ (speedClock.elapsedMilliseconds + 1),
              'phase': '视频分片 ${index + 1}/${media.urls.length}',
              'hls': {
                'fingerprint': fingerprint,
                'index': index + 1,
                'bytes': retained,
              },
            });
            success = true;
            break;
          } catch (e) {
            run.check();
            if (!retryableDownloadError(e)) rethrow;
            if (attempt == task.retries) throw DownloadRetryExhausted(e);
            await _retryWait(id, run, attempt, e);
          }
        }
        require(success, '视频分片下载失败');
      }
    } finally {
      await handle.close();
    }
    return output;
  }

  Future<void> close() async {
    _closing = true;
    _foregroundTimer?.cancel();
    _foregroundTimer = null;
    await pauseAll();
    // Completed tasks can still be cleaning files or publishing their last
    // notification, after they no longer count as active downloads.
    await Future.wait(_unsettledRuns.map((run) => run.done).toList());
    _guestDownloadBatches.clear();
    await _removalGate.run(() async {});
    await engine.close();
    for (final id in _directTargets.keys.toList()) {
      await _releaseDirectTarget(id);
    }
    await store.flush();
  }

  @override
  void dispose() {
    _progressFlush?.cancel();
    _foregroundTimer?.cancel();
    super.dispose();
  }
}
