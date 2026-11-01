import 'dart:async';
import '../diagnostics/app_log.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../data/http.dart';
import '../data/playback_store.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_folder.dart';
import 'media_backend.dart';
import 'playlist_order.dart';
import 'playback_sleep_timer.dart';
import 'playback_failure.dart';
import 'playback_selection.dart';
import 'subtitle_matching.dart';
import 'external_stream.dart';
import 'cast/cast_session.dart';
import 'cast/dlna.dart';
import 'cast/cast_platform.dart';

part 'playback_cast.dart';

CastSession _managedCastSession(CastDevice device, DownloadSpec source) =>
    CastSession(device, source, managePlatform: false);

typedef PreparePlayback =
    Future<DownloadSpec> Function(PlaybackEntry entry, RequestScope scope);

class _Session {
  _Session(
    this.entry,
    this.source,
    this.backend,
    this.hardwareAcceleration,
    this.selection,
  ) {
    selection.retain();
  }
  final PlaybackEntry entry;
  final DownloadSpec source;
  final PlaybackBackend backend;
  final bool hardwareAcceleration;
  final PlaybackSelection selection;
  late VoidCallback listener;
  bool closed = false,
      completionHandled = false,
      opened = false,
      positionWasSet = false,
      initializing = true,
      nativeClosed = false,
      failurePaused = false,
      playRequested = false;
  bool subtitleSearchStarted = false;
  bool aheadAttempted = false;
  int errorRevision = 0;
  final metadataReady = Completer<void>();
  final subtitleGate = AsyncGate();
  VideoGeometry? geometry;
  PlayerState? castBookmark;
  Future<void>? closing;
  Timer? recoveryTimer;
  Duration recoveryPosition = Duration.zero;
  int healthyRecoveryChecks = 0;
}

class _PreparedSource {
  _PreparedSource(this.entry);
  final PlaybackEntry entry;
  final scope = RequestScope();
  DownloadSpec? source;
  DateTime? readyAt;
  Timer? expiry;
  bool cancelled = false;
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required List<PlaybackEntry> entries,
    required this.initialIndex,
    required this.history,
    required this.prepare,
    required this.release,
    required this.retain,
    required this.backendFactory,
    this.checkSource,
    this.checkDownload,
    this.refresh,
    this.prepareDownload,
    this.subtitlesFor,
    this.readSubtitle,
    this.prepareAhead,
    this.checkAhead,
    this.sourceAccepted,
    this.externalStreamFactory = ExternalPlaybackStream.new,
    this.castSessionFactory = _managedCastSession,
    CastPlatform? castPlatform,
    DateTime Function()? now,
  }) : entries = List.unmodifiable(entries),
       castPlatform = castPlatform ?? CastPlatform(),
       preferences = history.preferences,
       index = initialIndex {
    require(
      entries.isNotEmpty && initialIndex >= 0 && initialIndex < entries.length,
      '播放列表为空',
    );
    sourceProgress.addListener(_changed);
    _playlistFolder = playbackFolder(current);
    playlistOrder = history.orderFor(_playlistFolder);
    _orderPlaylist();
    preferences = history.preferencesFor(folderKey);
    _persistedPreferences = preferences;
    sleepTimer = PlaybackSleepTimer(onExpired: _stopForSleep, now: now)
      ..addListener(_onSleepChanged);
  }
  final List<PlaybackEntry> entries;
  final int initialIndex;
  final PlaybackStore history;
  final PreparePlayback prepare;
  final PreparePlayback? refresh;
  final PreparePlayback? prepareDownload;
  final PreparePlayback? prepareAhead;
  final VoidCallback? checkAhead;
  final void Function(PlaybackEntry entry)? sourceAccepted;
  _PreparedSource? _prepared;
  final _aheadTasks = <Future<void>>{};
  final List<PlaybackSubtitle> Function(PlaybackEntry entry)? subtitlesFor;
  final Future<File> Function(
    PlaybackEntry entry,
    PlaybackSubtitle subtitle,
    RequestScope scope,
  )?
  readSubtitle;
  List<PlaybackSubtitle> get availableSubtitles => sortSubtitles(current.name, {
    ...(subtitlesFor?.call(current) ?? const []),
  });
  String? get cloudSubtitleId => _selection?.cloudSubtitleId;
  bool subtitleLoading = false;
  RequestScope? _subtitleScope;
  final _subtitleLoads = <Future<void>>{};
  final Future<void> Function(DownloadSpec source) release;
  final void Function(DownloadSpec source) retain;
  final PlaybackBackend Function(PlaybackEntry entry, bool hardwareAcceleration)
  backendFactory;
  final ExternalPlaybackStream Function(DownloadSpec source)
  externalStreamFactory;
  final CastSession Function(CastDevice device, DownloadSpec source)
  castSessionFactory;
  final CastPlatform castPlatform;
  CastSession? _cast;
  CastDevice? _castTarget;
  bool _castPlatformUsed = false;
  Future<void>? _castClosing;
  DownloadSpec? _castSource;
  RequestScope? _castScope;
  int _castRevision = 0;
  bool connectingCast = false;
  final _castTasks = <Future<void>>{};
  CastSession? get castSession => _cast;
  bool get casting => _cast != null;
  final VoidCallback? checkSource;
  final VoidCallback? checkDownload;
  final sourceProgress = OperationProgress();

  /// The page can finish its native orientation/layout transition before play.
  Future<void> Function()? beforePlay;
  PlaybackPreferences preferences;
  late PlaybackPreferences _persistedPreferences;
  late final String? _playlistFolder;
  late PlaybackPlaylistOrder playlistOrder;
  late List<int> playlistIndices, _playlistPositions;
  late final PlaybackSleepTimer sleepTimer;
  PlaybackSleepMode _sleepMode = PlaybackSleepMode.off;
  int _sleepRevision = 0;
  String? get folderKey => playbackFolder(current);
  bool get remembersFolder => history.remembersFolder(folderKey);
  int index, _generation = 0;
  bool loading = false, closed = false, boosting = false, _background = false;
  bool _sourceRecoveryUsed = false;
  bool _playWhenReady = true;
  String error = '', notice = '';
  Object? sourceError;
  double get subtitleDelay => _selection?.subtitleDelay ?? 0;
  double get audioDelay => _selection?.audioDelay ?? 0;
  PlaybackSelection? _selection;
  Duration resumedFrom = Duration.zero;
  _Session? _session;
  RequestScope? _scope;
  Timer? _saveTimer;
  Future<void>? _closeFuture;
  final _inflightLoads = <Future<void>>{};
  final _preferenceGate = AsyncGate();
  ExternalPlaybackStream? _externalStream;
  DownloadSpec? _externalSource;
  RequestScope? _externalScope;
  int _externalRevision = 0;
  bool openingExternalPlayer = false;
  bool get playingExternally => _externalStream != null;
  PlaybackEntry get current => entries[index];
  PlaybackBackend? get backend => _session?.backend;
  PlayerState get state =>
      _cast?.state ?? backend?.state ?? const PlayerState();
  int get playlistPosition => _playlistPositions[index];
  int playlistPositionOf(int entryIndex) => _playlistPositions[entryIndex];
  int? get previousIndex =>
      canPrevious ? playlistIndices[playlistPosition - 1] : null;
  int? get nextIndex => canNext ? playlistIndices[playlistPosition + 1] : null;
  bool get canPrevious => playlistPosition > 0;
  bool get canNext => playlistPosition + 1 < entries.length;
  bool get ready =>
      !loading &&
      !connectingCast &&
      (casting ? _cast!.connected : error.isEmpty && backend != null);
  bool get hasVideo => current.video;
  int get connections => preferences.connectionsFor(current.platform);
  bool get usingSoftwareDecoder =>
      hasVideo &&
      (backend?.hardwareDecodingActive == false ||
          _session?.hardwareAcceleration == false);
  VideoGeometry? get videoGeometry => hasVideo
      ? _session?.geometry ?? history.videoGeometry(current.key)
      : null;
  double get effectiveRate =>
      boosting ? math.max(2.0, preferences.rate) : preferences.rate;
  int get generation => _generation;
  bool canResumeAfterPanel(int generation, int stopRevision) =>
      ready &&
      !closed &&
      !_background &&
      generation == _generation &&
      !sleepTimer.stopped &&
      sleepTimer.stopRevision == stopRevision;

  Future<Uint8List> screenshot({bool includeSubtitles = false}) async {
    final session = _session;
    require(
      ready && hasVideo && session?.backend.supportsScreenshot == true,
      '请等待视频画面加载完成后截图',
    );
    final bytes = await session!.backend.screenshot(
      includeSubtitles: includeSubtitles,
    );
    require(_current(session), '视频已切换，请重新截图');
    require(
      bytes != null && bytes.isNotEmpty && bytes.length <= 32 * 1024 * 1024,
      '无法获取当前画面，视频分辨率过大或画面尚未就绪',
    );
    return bytes!;
  }

  void _changed() {
    if (!closed) notifyListeners();
  }

  void _orderPlaylist() {
    playlistIndices = orderedPlaybackIndices(entries, playlistOrder);
    _playlistPositions = List.filled(entries.length, 0);
    for (var i = 0; i < playlistIndices.length; i++) {
      _playlistPositions[playlistIndices[i]] = i;
    }
  }

  Future<void> setPlaylistOrder(PlaybackPlaylistOrder order) async {
    if (closed || loading || playlistOrder == order) return;
    playlistOrder = order;
    _orderPlaylist();
    _discardPrepared();
    _session?.aheadAttempted = false;
    _changed();
    await _preferenceGate.run(() => history.saveOrder(_playlistFolder, order));
  }

  Future<void> setRememberFolder(bool enabled) async {
    final key = folderKey, generation = _generation;
    if (key == null || loading || closed) return;
    await _preferenceGate.run(() => history.rememberFolder(key, enabled));
    if (closed || generation != _generation) return;
    final wasSubtitles = preferences.subtitles;
    preferences = history.preferencesFor(key);
    _persistedPreferences = preferences;
    _changed();
    await _command((backend) async {
      await backend.setRate(effectiveRate);
      if (generation != _generation) return;
      if (wasSubtitles != preferences.subtitles) {
        await backend.setSubtitleTrack(
          preferences.subtitles
              ? (_selection?.subtitle?.id == 'no'
                    ? SubtitleTrack.auto()
                    : _selection?.subtitle ?? SubtitleTrack.auto())
              : SubtitleTrack.no(),
        );
      }
    });
  }

  void _onSleepChanged() {
    if (closed ||
        (_sleepMode == sleepTimer.mode &&
            _sleepRevision == sleepTimer.stopRevision)) {
      return;
    }
    _sleepMode = sleepTimer.mode;
    _sleepRevision = sleepTimer.stopRevision;
    _discardPrepared();
    _session?.aheadAttempted = false;
    _changed();
    if (sleepTimer.mode == PlaybackSleepMode.episode &&
        ready &&
        state.completed) {
      unawaited(sleepTimer.finishEpisode());
    }
  }

  Future<void> _stopForSleep() async {
    if (closed) return;
    notice = '定时停止已生效，播放进度已保留';
    if (casting || connectingCast || _castTarget != null) {
      await disconnectCast();
      _changed();
      return;
    }
    await pause();
    // A timer can expire while the native play command is still completing.
    // The opening path also checks _playWhenReady after that command returns.
    if (!closed && sleepTimer.stopped && state.playing) {
      try {
        await backend?.pause();
      } catch (_) {}
    }
    _changed();
  }

  Map<String, Object?> _logFields(
    PlaybackEntry entry,
    String stage, {
    _Session? session,
    PlaybackFailure? failure,
  }) => {
    'playback': DiagnosticLog.reference(entry.key),
    'generation': _generation,
    'platform': entry.platform?.key,
    'sourceKind':
        entry.source?.kind.name ??
        (entry.platform == null ? 'unknown' : 'cloud'),
    'video': entry.video,
    'stage': stage,
    'decoder':
        (session?.hardwareAcceleration ?? preferences.hardwareAcceleration)
        ? 'hardware'
        : 'software',
    'connections': preferences.connectionsFor(entry.platform),
    'segmentSizeMiB': preferences.segmentSizeMiB,
    'positionMs': session?.backend.state.position.inMilliseconds ?? 0,
    'durationMs': session?.backend.state.duration.inMilliseconds ?? 0,
    'resumeMs': resumedFrom.inMilliseconds,
    'sourceRecoveryUsed': _sourceRecoveryUsed,
    if (session != null) ...session.backend.diagnosticFields,
    if (failure != null) ...{
      'kind': failure.kind.name,
      'status': ?failure.status,
    },
  };

  Future<void> start() => load(initialIndex);
  Future<void> load(
    int next, {
    bool fromStart = false,
    Duration? startPosition,
    bool? playWhenReady,
    bool refreshSource = false,
    bool automaticRecovery = false,
    bool automaticAdvance = false,
  }) {
    if (closed || next < 0 || next >= entries.length) return Future.value();
    if (!automaticRecovery && !automaticAdvance && playWhenReady != false) {
      sleepTimer.acknowledgePlay();
    }
    final future = _load(
      next,
      fromStart: fromStart,
      startPosition: startPosition,
      playWhenReady: playWhenReady,
      refreshSource: refreshSource,
      automaticRecovery: automaticRecovery,
    );
    _inflightLoads.add(future);
    unawaited(
      future.then<void>(
        (_) => _inflightLoads.remove(future),
        onError: (Object _, StackTrace _) {
          _inflightLoads.remove(future);
        },
      ),
    );
    return future;
  }

  Future<void> _load(
    int next, {
    required bool fromStart,
    Duration? startPosition,
    bool? playWhenReady,
    required bool refreshSource,
    required bool automaticRecovery,
  }) async {
    final continueCast = _castTarget ?? _cast?.device;
    if (_cast != null) _session?.castBookmark = _cast!.state;
    final loadWatch = Stopwatch()..start();
    DiagnosticLog.event(
      'player.load',
      fields: {
        'index': next,
        'fromStart': fromStart,
        'refresh': refreshSource,
        'automaticRecovery': automaticRecovery,
        'platform': entries[next].platform?.key,
        'playback': DiagnosticLog.reference(entries[next].key),
        'generation': _generation + 1,
      },
    );
    final generation = ++_generation, old = _session;
    _externalRevision++;
    _externalScope?.cancel();
    final retiredSelection = _selection?.key == entries[next].key
        ? null
        : _selection;
    if (_selection?.key != entries[next].key) {
      _selection = PlaybackSelection(entries[next].key);
    }
    final selection = _selection!;
    sourceProgress.clear();
    if (!automaticRecovery) _sourceRecoveryUsed = false;
    _playWhenReady = (playWhenReady ?? true) && !sleepTimer.stopped;
    _scope?.cancel();
    _subtitleScope?.cancel();
    subtitleLoading = false;
    final scope = _scope = RequestScope();
    _saveTimer?.cancel();
    _session = null;
    index = next;
    loading = true;
    error = '';
    sourceError = null;
    notice = automaticRecovery ? '视频连接中断，正在刷新地址并恢复进度' : '';
    boosting = false;
    resumedFrom = Duration.zero;
    _changed();
    await _stopExternalPlayback();
    await _stopCast(keepPlatform: continueCast != null);
    await _retire(old);
    await retiredSelection?.release();
    await _preferenceGate.run(() async {});
    if (closed || generation != _generation) return;
    preferences = history.preferencesFor(folderKey);
    _persistedPreferences = preferences;
    _changed();
    DownloadSpec? unowned;
    PlaybackBackend? warming;
    Future<void>? warmingReady;
    var stage = 'source';
    var sourceMs = 0;
    try {
      checkSource?.call();
      stage = 'backend_create';
      warming = backendFactory(current, preferences.hardwareAcceleration);
      warmingReady = warming.initialize();
      unawaited(warmingReady.catchError((Object _) {}));
      stage = 'source';
      final sourceWatch = Stopwatch()..start();
      unowned = refreshSource ? null : _takePrepared(current);
      _discardPrepared();
      if (unowned != null) checkAhead?.call();
      unowned ??= await sourceProgress.run<DownloadSpec>(
        () => (refreshSource ? refresh ?? prepare : prepare)(current, scope),
      );
      sourceMs = sourceWatch.elapsedMilliseconds;
      checkSource?.call();
      if (closed || generation != _generation) return;
      final source = unowned, entry = current;
      sourceAccepted?.call(entry);
      final bookmark = history.bookmark(entry.key);
      final start =
          startPosition ??
          (fromStart || !preferences.resume
              ? Duration.zero
              : bookmark?.resumePosition ?? Duration.zero);
      resumedFrom = start;
      var hardware = preferences.hardwareAcceleration;
      for (var attempt = 0; attempt < 2; attempt++) {
        stage = 'backend_create';
        final backend = warming ?? backendFactory(entry, hardware);
        final initialized = warmingReady;
        warming = null;
        warmingReady = null;
        final session = _Session(entry, source, backend, hardware, selection);
        unowned = null;
        _session = session;
        session.listener = () => _onState(session);
        backend.addListener(session.listener);
        _changed();
        try {
          stage = 'backend_open';
          await (initialized ?? backend.initialize());
          if (!_current(session)) return;
          await backend.setConnections(connections);
          if (!_current(session)) return;
          await backend.setSegmentSizeMiB(preferences.segmentSizeMiB);
          if (!_current(session)) return;
          await backend.open(source, start);
          if (!_current(session)) return;
          session.opened = true;
          _rememberGeometry(session);
          if (entry.video &&
              session.geometry == null &&
              session.errorRevision == 0) {
            await session.metadataReady.future.timeout(
              const Duration(seconds: 3),
              onTimeout: () {},
            );
          }
          if (!_current(session)) return;
          _checkInitialization(session);
          stage = 'configure';
          await backend.setRate(preferences.rate);
          if (!_current(session)) return;
          await backend.setVolume(preferences.volume);
          if (!_current(session)) return;
          if (!preferences.subtitles) {
            await backend.setSubtitleTrack(SubtitleTrack.no());
          }
          if (!_current(session)) return;
          await _restoreSelection(session);
          if (!_current(session)) return;
          final duration = backend.state.duration;
          if (duration > Duration.zero && start >= duration) {
            resumedFrom = Duration.zero;
            await backend.seek(Duration.zero);
          } else if (!fromStart &&
              startPosition == null &&
              preferences.skipIntroSeconds > 0 &&
              start.inSeconds < preferences.skipIntroSeconds &&
              duration.inSeconds >
                  preferences.skipIntroSeconds +
                      preferences.skipOutroSeconds +
                      5) {
            await backend.seek(Duration(seconds: preferences.skipIntroSeconds));
          }
          if (!_current(session)) return;
          _checkInitialization(session);
          stage = 'presentation';
          await beforePlay?.call();
          if (!_current(session)) return;
          stage = 'play';
          sleepTimer.checkDeadline();
          session.playRequested = _playWhenReady && !sleepTimer.stopped;
          if (_castTarget == null && !_background && session.playRequested) {
            await backend.play();
          }
          if (!_current(session)) return;
          if (!_playWhenReady || sleepTimer.stopped) await backend.pause();
          if (!_current(session)) return;
          _checkInitialization(session);
          session.initializing = false;
          loading = false;
          DiagnosticLog.event(
            'player.ready',
            fields: {
              ..._logFields(entry, 'ready', session: session),
              'automaticRecovery': automaticRecovery,
              'sourceMs': sourceMs,
              'loadElapsedMs': loadWatch.elapsedMilliseconds,
            },
          );
          try {
            await history.opened(entry.key, entry.name, entry.source);
          } catch (_) {
            notice = '播放记录未能保存，请检查存储空间';
          }
          if (!_current(session)) return;
          _saveTimer = Timer.periodic(
            const Duration(seconds: 10),
            (_) => unawaited(saveProgress()),
          );
          _onState(session);
          _autoSubtitle(session);
          if (continueCast != null) {
            // An earlier handoff can still be resolving a refreshed source.
            // Join its cancelled task before claiming the next TV session.
            await _settleCastTasks();
            if (identical(_castTarget, continueCast) &&
                _current(session) &&
                !sleepTimer.stopped) {
              try {
                await castTo(continueCast);
              } catch (e) {
                if (_current(session)) {
                  notice = e is AppException ? e.message : '下一集投屏失败，请重新连接电视';
                  _changed();
                }
              }
            }
          }
          return;
        } catch (e, stack) {
          if (!_current(session)) return;
          if (!entry.video ||
              !hardware ||
              attempt != 0 ||
              !backend.canRetryWithSoftware) {
            rethrow;
          }
          DiagnosticLog.error(
            'player.hardware_fallback',
            e,
            stack,
            fields: {
              ..._logFields(
                entry,
                stage,
                session: session,
                failure: backend.failure,
              ),
              'recovery': 'software',
            },
          );
          // Keep the source lease across reconstruction. No second share
          // transfer, expired-link refresh or premature temporary-file delete.
          retain(source);
          unowned = source;
          _session = null;
          await _retire(session);
          if (closed || generation != _generation) return;
          require(session.nativeClosed, '播放器初始化未完成，请退出播放页后重试');
          hardware = false;
          error = '';
          notice = '硬件解码初始化失败，已切换软件解码重试';
          _changed();
        }
      }
    } catch (e, stack) {
      if (!closed && generation == _generation) {
        final failure =
            _session?.backend.failure ?? (e is PlaybackFailure ? e : null);
        DiagnosticLog.error(
          'player.load_failed',
          e,
          stack,
          fields: {
            ..._logFields(
              entries[next],
              stage,
              session: _session,
              failure: failure,
            ),
            'recovery': _canRefresh(failure) ? 'refresh' : 'none',
          },
        );
        if (_canRefresh(failure)) {
          _sourceRecoveryUsed = true;
          await load(
            index,
            startPosition: _retryPosition(),
            playWhenReady: _playWhenReady,
            refreshSource: true,
            automaticRecovery: true,
          );
          return;
        }
        error = e is AppException ? e.message : '播放加载失败，请刷新链接重试，或下载后打开';
        sourceError = stage == 'source' ? e : null;
        loading = false;
        final failed = _session;
        if (failed != null) _pauseFailure(failed);
        _changed();
      }
    } finally {
      if (warming != null) {
        try {
          await warming.close();
        } catch (e, stack) {
          DiagnosticLog.error('player.prepared_backend_close', e, stack);
        }
      }
      if (unowned != null) await _releaseSafely(unowned);
      if (generation == _generation &&
          error.isNotEmpty &&
          !casting &&
          !connectingCast) {
        _castTarget = null;
        await _releaseCastPlatform();
      }
    }
  }

  void _trackAhead(Future<void> task) {
    _aheadTasks.add(task);
    unawaited(
      task.then<void>(
        (_) => _aheadTasks.remove(task),
        onError: (Object _, StackTrace _) => _aheadTasks.remove(task),
      ),
    );
  }

  void _discardPrepared() {
    final prepared = _prepared;
    _prepared = null;
    if (prepared == null) return;
    prepared.expiry?.cancel();
    prepared.cancelled = true;
    prepared.scope.cancel();
    final source = prepared.source;
    prepared.source = null;
    if (source != null) _trackAhead(_releaseSafely(source));
  }

  DownloadSpec? _takePrepared(PlaybackEntry entry) {
    final prepared = _prepared;
    if (prepared == null ||
        prepared.cancelled ||
        prepared.entry.key != entry.key ||
        prepared.source == null ||
        prepared.readyAt == null ||
        DateTime.now().difference(prepared.readyAt!) >
            const Duration(seconds: 45)) {
      return null;
    }
    _prepared = null;
    prepared.expiry?.cancel();
    final source = prepared.source;
    prepared.source = null;
    return source;
  }

  void _maybePrepareNext(_Session session) {
    final state = session.backend.state;
    if (prepareAhead == null ||
        session.aheadAttempted ||
        !ready ||
        !_current(session) ||
        !preferences.autoNext ||
        sleepTimer.mode == PlaybackSleepMode.episode ||
        sleepTimer.stopped ||
        !canNext ||
        !_playWhenReady ||
        !session.playRequested ||
        _background ||
        !state.playing ||
        state.buffering ||
        state.duration < const Duration(minutes: 2)) {
      return;
    }
    final remaining =
        state.duration -
        state.position -
        Duration(seconds: preferences.skipOutroSeconds);
    if (remaining <= Duration.zero || remaining > const Duration(seconds: 30)) {
      return;
    }
    session.aheadAttempted = true;
    _discardPrepared();
    final prepared = _prepared = _PreparedSource(entries[nextIndex!]);
    _trackAhead(_prepareNext(prepared));
  }

  Future<void> _prepareNext(_PreparedSource prepared) async {
    final deadline = Timer(const Duration(seconds: 20), () {
      prepared.cancelled = true;
      prepared.scope.cancel();
    });
    DownloadSpec? unowned;
    try {
      checkSource?.call();
      checkAhead?.call();
      unowned = await prepareAhead!(prepared.entry, prepared.scope);
      checkSource?.call();
      checkAhead?.call();
      if (closed || prepared.cancelled || !identical(prepared, _prepared)) {
        return;
      }
      prepared.source = unowned;
      prepared.readyAt = DateTime.now();
      prepared.expiry = Timer(const Duration(seconds: 45), () {
        if (identical(prepared, _prepared)) _discardPrepared();
      });
      unowned = null;
      DiagnosticLog.event(
        'player.next_source_ready',
        fields: {
          'platform': prepared.entry.platform?.key,
          'playback': DiagnosticLog.reference(prepared.entry.key),
        },
      );
    } catch (e, stack) {
      if (!closed && !prepared.cancelled) {
        DiagnosticLog.error(
          'player.next_source_failed',
          e,
          stack,
          fields: {'platform': prepared.entry.platform?.key},
        );
      }
    } finally {
      deadline.cancel();
      if (unowned != null) await _releaseSafely(unowned);
      if (identical(prepared, _prepared) && prepared.source == null) {
        _prepared = null;
      }
    }
  }

  void _checkInitialization(_Session session) {
    if (session.errorRevision != 0) {
      throw session.backend.failure ?? const AppException('播放器初始化失败');
    }
  }

  Future<void> _restoreSelection(_Session session) async {
    final selection = session.selection, backend = session.backend;
    final audio = selection.audioFor(backend.state.tracks);
    final subtitle = selection.subtitleFor(backend.state.tracks);
    try {
      if (audio != null) await backend.setAudioTrack(audio);
      if (!_current(session)) return;
      if (preferences.subtitles && subtitle != null) {
        await backend.setSubtitleTrack(subtitle);
      }
      if (!_current(session)) return;
      if (selection.audioDelay != 0) {
        await backend.setAudioDelay(selection.audioDelay);
      }
      if (!_current(session)) return;
      if (selection.subtitleDelay != 0) {
        await backend.setSubtitleDelay(selection.subtitleDelay);
      }
    } catch (e, stack) {
      if (!_current(session)) return;
      notice = '部分音轨或字幕设置未能恢复，可在播放设置中重新选择';
      DiagnosticLog.error(
        'player.selection_restore_failed',
        e,
        stack,
        fields: _logFields(
          session.entry,
          'restore_selection',
          session: session,
        ),
      );
    }
  }

  void _autoSubtitle(_Session session) {
    if (readSubtitle == null ||
        session.subtitleSearchStarted ||
        !preferences.subtitles ||
        session.selection.subtitleRevision > 0 ||
        session.selection.subtitle != null ||
        !_current(session)) {
      return;
    }
    session.subtitleSearchStarted = true;
    final candidate = matchingSubtitle(session.entry.name, availableSubtitles);
    if (candidate != null) {
      unawaited(loadCloudSubtitle(candidate, automatic: true));
    }
  }

  Future<void> loadCloudSubtitle(
    PlaybackSubtitle subtitle, {
    bool automatic = false,
  }) {
    final future = _loadCloudSubtitle(subtitle, automatic: automatic);
    _subtitleLoads.add(future);
    unawaited(
      future.then<void>(
        (_) => _subtitleLoads.remove(future),
        onError: (Object _, StackTrace _) => _subtitleLoads.remove(future),
      ),
    );
    return future;
  }

  Future<void> _loadCloudSubtitle(
    PlaybackSubtitle subtitle, {
    required bool automatic,
  }) async {
    final session = _session, reader = readSubtitle;
    if (session == null ||
        !ready ||
        reader == null ||
        !availableSubtitles.any((item) => item.id == subtitle.id)) {
      return;
    }
    _subtitleScope?.cancel();
    final scope = _subtitleScope = RequestScope();
    final expected = _generation, revision = session.selection.subtitleRevision;
    subtitleLoading = true;
    _changed();
    File? file;
    try {
      file = await reader(session.entry, subtitle, scope);
      checkSource?.call();
      if (!_current(session) ||
          scope.token.isCancelled ||
          revision != session.selection.subtitleRevision ||
          automatic && !preferences.subtitles) {
        return;
      }
      final staged = file;
      file = null;
      await _attachSubtitle(
        staged,
        subtitle.name,
        expected,
        cloudSubtitleId: subtitle.id,
        scope: scope,
      );
    } catch (e, stack) {
      if (_current(session) && !scope.token.isCancelled) {
        DiagnosticLog.error(
          'player.subtitle_load_failed',
          e,
          stack,
          fields: _logFields(session.entry, 'subtitle', session: session),
        );
        if (!automatic) notice = '字幕加载失败，请重新选择字幕';
      }
    } finally {
      if (file != null) await _deleteSubtitleFile(file);
      if (identical(scope, _subtitleScope)) {
        subtitleLoading = false;
        _changed();
      }
    }
  }

  bool _canRefresh(PlaybackFailure? failure) =>
      !closed &&
      refresh != null &&
      !_sourceRecoveryUsed &&
      failure?.refreshable == true;

  Duration _retryPosition() {
    if (state.position > Duration.zero || _session?.positionWasSet == true) {
      return state.position;
    }
    return resumedFrom > Duration.zero
        ? resumedFrom
        : history.bookmark(current.key)?.resumePosition ?? Duration.zero;
  }

  void _pauseFailure(_Session session) {
    if (!_current(session) || session.failurePaused) return;
    session.failurePaused = true;
    // Stop playback and new proxy requests even when initialization failed
    // after play() began. A second error from pause cannot start a retry loop.
    unawaited(session.backend.pause().catchError((Object _) {}));
  }

  bool _current(_Session session) =>
      !closed && identical(session, _session) && !session.closed;

  void _stopRecoveryWatch(_Session session) {
    session.recoveryTimer?.cancel();
    session.recoveryTimer = null;
    session.healthyRecoveryChecks = 0;
  }

  void _watchRecovery(_Session session) {
    final state = session.backend.state;
    if (!_sourceRecoveryUsed ||
        session.initializing ||
        loading ||
        error.isNotEmpty ||
        session.failurePaused ||
        _background ||
        !session.playRequested ||
        !state.playing ||
        state.buffering ||
        state.completed) {
      _stopRecoveryWatch(session);
      return;
    }
    if (session.recoveryTimer != null) return;
    session.recoveryPosition = state.position;
    const interval = Duration(seconds: 5);
    session.recoveryTimer = Timer.periodic(interval, (_) {
      if (!_current(session)) {
        _stopRecoveryWatch(session);
        return;
      }
      final state = session.backend.state;
      final progress = state.position - session.recoveryPosition;
      session.recoveryPosition = state.position;
      final largestStep =
          Duration(
            microseconds: (interval.inMicroseconds * effectiveRate).ceil(),
          ) +
          const Duration(seconds: 2);
      session.healthyRecoveryChecks =
          state.playing &&
              !state.buffering &&
              progress > Duration.zero &&
              progress <= largestStep
          ? session.healthyRecoveryChecks + 1
          : 0;
      if (session.healthyRecoveryChecks >= 6) {
        // Rearm after 30 seconds of actual playback, not elapsed pause time or
        // a seek jump. Consecutive failed reconnects still stop after one try.
        _sourceRecoveryUsed = false;
        _stopRecoveryWatch(session);
        DiagnosticLog.event(
          'player.recovery_rearmed',
          fields: _logFields(
            session.entry,
            'healthy_playback',
            session: session,
          ),
        );
      }
    });
  }

  void _onState(_Session session) {
    if (!_current(session)) return;
    _rememberGeometry(session);
    if (casting || connectingCast) {
      _changed();
      return;
    }
    if (session.errorRevision != session.backend.errorRevision) {
      session.errorRevision = session.backend.errorRevision;
      if (!session.initializing) {
        final failure = session.backend.failure;
        DiagnosticLog.error(
          'player.playback_failed',
          failure ?? const AppException('播放遇到问题，播放器未提供详细错误'),
          null,
          fields: {
            ..._logFields(
              session.entry,
              'playback',
              session: session,
              failure: failure,
            ),
            'recovery': _canRefresh(failure) ? 'refresh' : 'none',
          },
        );
        if (_canRefresh(failure)) {
          _sourceRecoveryUsed = true;
          final expected = _generation, position = _retryPosition();
          loading = true;
          notice = '视频连接中断，正在刷新地址并恢复进度';
          _pauseFailure(session);
          scheduleMicrotask(() {
            if (!_current(session) || expected != _generation) return;
            unawaited(
              load(
                index,
                startPosition: position,
                playWhenReady: session.playRequested,
                refreshSource: true,
                automaticRecovery: true,
              ),
            );
          });
        } else {
          error = failure?.message ?? '播放遇到问题，可刷新链接重试，或下载后使用其他播放器打开';
          loading = false;
          _pauseFailure(session);
        }
      }
      if (!session.metadataReady.isCompleted) session.metadataReady.complete();
    }
    final state = session.backend.state;
    if (state.duration > Duration.zero && resumedFrom >= state.duration) {
      resumedFrom = Duration.zero;
      unawaited(_command((backend) => backend.seek(Duration.zero)));
    }
    if (_atEnd(session) &&
        !session.completionHandled &&
        !loading &&
        error.isEmpty) {
      session.completionHandled = true;
      unawaited(_completed(session));
    }
    _watchRecovery(session);
    _maybePrepareNext(session);
    _changed();
  }

  bool _atEnd(_Session session) {
    final state = session.backend.state;
    return state.completed ||
        (sleepTimer.mode != PlaybackSleepMode.episode &&
            !sleepTimer.stopped &&
            preferences.autoNext &&
            canNext &&
            preferences.skipOutroSeconds > 0 &&
            state.playing &&
            state.duration.inSeconds >
                preferences.skipIntroSeconds +
                    preferences.skipOutroSeconds +
                    5 &&
            state.position >=
                state.duration -
                    Duration(seconds: preferences.skipOutroSeconds));
  }

  void _rememberGeometry(_Session session) {
    if (!session.entry.video) return;
    final geometry = session.backend.videoGeometry;
    if (geometry == null || geometry == session.geometry) return;
    session.geometry = geometry;
    if (!session.metadataReady.isCompleted) session.metadataReady.complete();
    unawaited(
      history
          .saveVideoGeometry(session.entry.key, geometry)
          .catchError((Object _) {}),
    );
  }

  Future<void> _completed(_Session session) async {
    if (sleepTimer.mode == PlaybackSleepMode.episode) {
      await sleepTimer.finishEpisode();
    }
    await _save(session, completed: true);
    sleepTimer.checkDeadline();
    if (_current(session) &&
        session.completionHandled &&
        _atEnd(session) &&
        preferences.autoNext &&
        !sleepTimer.stopped &&
        sleepTimer.mode != PlaybackSleepMode.episode &&
        _playWhenReady &&
        canNext &&
        !_background) {
      await load(nextIndex!, automaticAdvance: true);
    }
  }

  Future<void> _releaseSafely(DownloadSpec source) async {
    try {
      await release(source);
    } catch (_) {
      notice = '临时文件清理已保留为待处理任务';
      _changed();
    }
  }

  Future<void> _save(_Session session, {bool? completed}) async {
    final state = identical(_session, session) && casting
        ? _cast!.state
        : session.castBookmark ?? session.backend.state;
    final finished =
        completed ?? (state.completed || session.completionHandled);
    if (!session.opened ||
        state.duration <= Duration.zero ||
        (state.position <= Duration.zero &&
            !session.positionWasSet &&
            !finished)) {
      return;
    }
    final value = PlaybackBookmark(
      name: session.entry.name,
      source: session.entry.source,
      position: clampPlaybackPosition(state.position, state.duration),
      duration: state.duration,
      completed: finished,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    try {
      await history.save(session.entry.key, value);
    } catch (_) {
      notice = '播放进度未能保存，请检查存储空间';
      _changed();
    }
  }

  Future<void> saveProgress() async {
    final session = _session;
    if (session != null) await _save(session);
  }

  Future<void> _retire(_Session? session) async {
    if (session == null) return;
    await (session.closing ??= _retireOnce(session));
  }

  Future<void> _retireOnce(_Session session) async {
    session.closed = true;
    _stopRecoveryWatch(session);
    if (!session.metadataReady.isCompleted) session.metadataReady.complete();
    session.backend.removeListener(session.listener);
    await _save(session);
    await session.subtitleGate.run(() async {});
    try {
      await session.backend.pause();
    } catch (_) {
      /* close still stops native I/O */
    }
    try {
      await session.backend.close();
      session.nativeClosed = true;
    } catch (_) {
      notice = '播放器关闭未完成，临时文件已保留';
      _changed();
      return;
    }
    await session.selection.release();
    await _releaseSafely(session.source);
  }

  Future<void> _command(
    Future<void> Function(PlaybackBackend backend) action, {
    String operation = 'control',
  }) async {
    final session = _session;
    if (session == null || closed || loading || error.isNotEmpty) return;
    try {
      await action(session.backend);
    } catch (error, stack) {
      if (_current(session)) {
        DiagnosticLog.error(
          'player.command_failed',
          error,
          stack,
          fields: {
            ..._logFields(session.entry, 'command', session: session),
            'operation': operation,
          },
        );
        notice = '播放操作未能完成，请重试';
        _changed();
      }
    }
  }

  Future<void> play() async {
    if (closed) return;
    if (casting) {
      sleepTimer.acknowledgePlay();
      _playWhenReady = true;
      await _cast!.play();
      return;
    }
    sleepTimer.acknowledgePlay();
    final sleepRevision = sleepTimer.stopRevision;
    _externalRevision++;
    _externalScope?.cancel();
    if (_externalStream != null) await _stopExternalPlayback();
    if (closed) return;
    _background = false;
    _playWhenReady = true;
    _session?.playRequested = true;
    await _command((backend) async {
      if (backend.state.completed) {
        _session?.completionHandled = false;
        await backend.seek(Duration.zero);
      }
      if (sleepRevision != sleepTimer.stopRevision || sleepTimer.stopped) {
        return;
      }
      await backend.play();
      if (sleepTimer.stopped) await backend.pause();
    }, operation: 'play');
  }

  Future<void> pause() async {
    if (casting && _cast!.connected) {
      _playWhenReady = false;
      await _cast!.pause();
      await saveProgress();
      return;
    }
    _playWhenReady = false;
    _discardPrepared();
    _session?.aheadAttempted = false;
    _session?.playRequested = false;
    await endBoost();
    await _command((backend) => backend.pause(), operation: 'pause');
    await saveProgress();
  }

  Future<void> toggle() => state.playing ? pause() : play();
  Future<void> seek(Duration position) async {
    final target = clampPlaybackPosition(position, state.duration);
    if (casting) {
      await _cast!.seek(target);
      await saveProgress();
      return;
    }
    if (state.duration - target > const Duration(seconds: 45)) {
      _discardPrepared();
      _session?.aheadAttempted = false;
    }
    if (ready) {
      final session = _session;
      if (session != null) {
        session.positionWasSet = true;
        _stopRecoveryWatch(session);
      }
      if (target < state.duration) _session?.completionHandled = false;
    }
    await _command((backend) => backend.seek(target), operation: 'seek');
    await saveProgress();
  }

  Future<void> skip(int seconds) =>
      seek(state.position + Duration(seconds: seconds));
  Future<void> fromBeginning() async {
    resumedFrom = Duration.zero;
    await seek(Duration.zero);
    final session = _session;
    if (session != null && session.backend.state.duration > Duration.zero) {
      await history.save(
        session.entry.key,
        PlaybackBookmark(
          name: session.entry.name,
          position: Duration.zero,
          duration: session.backend.state.duration,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    await play();
  }

  Future<void> retry() => load(
    index,
    startPosition: _retryPosition(),
    playWhenReady: true,
    refreshSource: true,
  );
  Future<void> previous() =>
      canPrevious ? load(previousIndex!) : Future.value();
  Future<void> next() => canNext ? load(nextIndex!) : Future.value();
  Future<void> updatePreferences(
    PlaybackPreferences value, {
    bool save = true,
  }) async {
    final previous = _persistedPreferences, folder = folderKey;
    preferences = value;
    if (!preferences.autoNext) _discardPrepared();
    _changed();
    if (save) {
      _persistedPreferences = value;
      await _preferenceGate.run(
        () => history.saveEffectivePreferences(folder, value, previous),
      );
    }
  }

  Future<void> setRate(double value) async {
    require(!casting, '电视投屏使用正常速度，倍速请在电视端调整');
    await updatePreferences(preferences.copyWith(rate: value));
    await _command((backend) => backend.setRate(effectiveRate));
  }

  Future<void> setConnections(int value) async {
    final platform = current.platform;
    await updatePreferences(
      platform == null
          ? preferences.copyWith(connections: value)
          : preferences.copyWith(
              driveConnections: {
                ...preferences.driveConnections,
                platform.key: value,
              },
            ),
    );
    // Connection limits are safe to update while the source is still opening.
    // Otherwise a choice made during buffering would wait until the next file.
    if (!closed) await backend?.setConnections(connections);
  }

  Future<void> setSegmentSizeMiB(int value) async {
    final position = state.position, playing = state.playing;
    await updatePreferences(preferences.copyWith(segmentSizeMiB: value));
    if (!closed) {
      await load(index, startPosition: position, playWhenReady: playing);
    }
  }

  Future<void> setHardwareAcceleration(bool value) async {
    final position = state.position, playing = state.playing;
    await updatePreferences(preferences.copyWith(hardwareAcceleration: value));
    if (!closed) {
      await load(index, startPosition: position, playWhenReady: playing);
    }
  }

  Future<void> beginBoost() async {
    if (boosting || !ready || casting) return;
    boosting = true;
    _changed();
    await _command((backend) => backend.setRate(effectiveRate));
  }

  Future<void> endBoost() async {
    if (!boosting) return;
    boosting = false;
    _changed();
    await _command((backend) => backend.setRate(preferences.rate));
  }

  Future<void> setVolume(double value, {bool save = true}) async {
    if (casting) {
      await _cast!.setVolume(value);
      return;
    }
    preferences = preferences.copyWith(volume: value);
    _changed();
    await _command((backend) => backend.setVolume(preferences.volume));
    if (save) await updatePreferences(preferences);
  }

  Future<void> setAudioTrack(AudioTrack track) async {
    final session = _session;
    if (session == null) return;
    await _command((backend) async {
      await backend.setAudioTrack(track);
      if (_current(session)) session.selection.audio = track;
    });
  }

  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    final session = _session;
    if (session == null) return;
    final revision = ++session.selection.subtitleRevision;
    _subtitleScope?.cancel();
    await _command(
      (backend) => session.subtitleGate.run(() async {
        if (!_current(session) ||
            revision != session.selection.subtitleRevision) {
          return;
        }
        await backend.setSubtitleTrack(track);
        if (!_current(session) ||
            revision != session.selection.subtitleRevision) {
          return;
        }
        session.selection.subtitle = track;
        session.selection.cloudSubtitleId = null;
        await updatePreferences(
          preferences.copyWith(subtitles: track.id != 'no'),
        );
      }),
    );
  }

  Future<void> setSubtitleDelay(double value) async {
    final target = finiteRange(value, 0, -10, 10), session = _session;
    if (session == null || !ready) return;
    await session.backend.setSubtitleDelay(target);
    if (!_current(session)) return;
    session.selection.subtitleDelay = target;
    _changed();
  }

  Future<void> setAudioDelay(double value) async {
    final target = finiteRange(value, 0, -5, 5), session = _session;
    if (session == null || !ready) return;
    await session.backend.setAudioDelay(target);
    if (!_current(session)) return;
    session.selection.audioDelay = target;
    _changed();
  }

  Future<void> attachSubtitle(File file, String name, int generation) =>
      _attachSubtitle(file, name, generation);

  Future<void> _deleteSubtitleFile(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Private files can be retried by the next cache cleanup.
    }
  }

  Future<void> _attachSubtitle(
    File file,
    String name,
    int generation, {
    String? cloudSubtitleId,
    RequestScope? scope,
  }) async {
    final session = _session;
    if (session == null || closed || generation != _generation) {
      await _deleteSubtitleFile(file);
      throw const AppException('视频已切换，请为当前视频重新选择字幕');
    }
    session.selection.files.add(file);
    final revision = ++session.selection.subtitleRevision;
    if (!identical(scope, _subtitleScope)) _subtitleScope?.cancel();
    final track = SubtitleTrack.uri(file.uri.toString(), title: name);
    bool current() =>
        _current(session) &&
        revision == session.selection.subtitleRevision &&
        scope?.token.isCancelled != true;
    await session.subtitleGate.run(() async {
      if (!current()) return;
      await session.backend.setSubtitleTrack(track);
      if (!current()) return;
      session.selection.subtitle = track;
      session.selection.cloudSubtitleId = cloudSubtitleId;
      await updatePreferences(preferences.copyWith(subtitles: true));
    });
  }

  Future<void> enqueueDownload(
    Future<void> Function(DownloadSpec source) enqueue,
  ) async {
    final source = await acquireForDownload();
    var transferred = false;
    try {
      await enqueue(source);
      // Cloud downloads retain their source lease. BT downloads store torrent
      // metadata and never own the player's temporary loopback stream.
      transferred = !source.isTorrent;
    } finally {
      if (!transferred) await _releaseSafely(source);
    }
  }

  Future<DownloadSpec> acquireForDownload() async {
    checkDownload?.call();
    checkSource?.call();
    require(!closed, '播放器已关闭');
    final session = _session;
    if (prepareDownload == null &&
        session != null &&
        session.backend.failure?.sourceFailure != true) {
      retain(session.source);
      return session.source;
    }
    final expected = _generation, entry = current, scope = RequestScope();
    final source =
        await (prepareDownload ??
            (session?.backend.failure?.sourceFailure == true
                ? refresh ?? prepare
                : prepare))(entry, scope);
    try {
      checkSource?.call();
      checkDownload?.call();
      require(!closed && expected == _generation, '视频已切换，请重新添加下载');
      return source;
    } catch (_) {
      await _releaseSafely(source);
      rethrow;
    }
  }

  Future<void> background({required bool pictureInPicture}) async {
    _background = !pictureInPicture;
    await saveProgress();
    if (casting || connectingCast || _castTarget != null) return;
    if (pictureInPicture) return;
    _discardPrepared();
    await pause();
  }

  void foreground() {
    _background = false;
    sleepTimer.checkDeadline();
  }

  Future<bool> openExternalPlayer(
    Future<bool> Function(String url, String title, Duration position) open,
  ) async {
    require(!closed && !loading && hasVideo, '请等待视频地址准备完成');
    require(!openingExternalPlayer, '正在选择第三方播放器');
    require(!casting && !connectingCast, '请先断开电视投屏');
    checkSource?.call();
    openingExternalPlayer = true;
    final revision = ++_externalRevision, generation = _generation;
    final scope = _externalScope = RequestScope();
    final wasPlaying = state.playing;
    final position = _retryPosition();
    final entry = current;
    var launched = false;
    DownloadSpec? unowned;
    ExternalPlaybackStream? stream;
    bool currentRequest() =>
        !closed &&
        generation == _generation &&
        revision == _externalRevision &&
        !scope.token.isCancelled;
    void check() {
      require(currentRequest(), '视频已切换，请重新选择第三方播放器');
      checkSource?.call();
    }

    _changed();
    try {
      await _stopExternalPlayback();
      check();
      final session = _session;
      if (session != null && session.backend.failure?.sourceFailure != true) {
        retain(session.source);
        unowned = session.source;
      } else {
        unowned = await (refresh ?? prepare)(entry, scope);
      }
      check();
      stream = externalStreamFactory(unowned);
      _externalStream = stream;
      _externalSource = unowned;
      unowned = null;
      await pause();
      // Normal controls report a failed pause as a notice. Handoff must stop
      // the old audio before another app starts, so propagate a retry failure.
      if (state.playing) await backend?.pause();
      check();
      await stream.start();
      check();
      launched = await open(stream.url, entry.name, position);
      check();
      return launched;
    } finally {
      if (!launched || !currentRequest()) {
        if (identical(_externalStream, stream)) await _stopExternalPlayback();
      }
      if (unowned != null) await _releaseSafely(unowned);
      if (identical(_externalScope, scope)) _externalScope = null;
      openingExternalPlayer = false;
      _changed();
      if (!launched &&
          wasPlaying &&
          currentRequest() &&
          !sleepTimer.stopped &&
          !_background &&
          ready) {
        await play();
      }
    }
  }

  Future<void> _stopExternalPlayback() async {
    final stream = _externalStream, source = _externalSource;
    _externalStream = null;
    _externalSource = null;
    try {
      await stream?.close();
    } finally {
      if (source != null) await _releaseSafely(source);
    }
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    closed = true;
    sleepTimer.removeListener(_onSleepChanged);
    sleepTimer.dispose();
    sourceProgress.close();
    sourceProgress.removeListener(_changed);
    ++_generation;
    _externalRevision++;
    _externalScope?.cancel();
    _scope?.cancel();
    _subtitleScope?.cancel();
    _discardPrepared();
    _saveTimer?.cancel();
    final session = _session;
    if (_cast != null) session?.castBookmark = _cast!.state;
    _session = null;
    final selection = _selection;
    _selection = null;
    await _stopExternalPlayback();
    await _stopCast();
    await _retire(session);
    await selection?.release();
    // Late source resolutions still own cleanup leases, even after the route is gone.
    await Future.wait(_inflightLoads.toList());
    await Future.wait(_subtitleLoads.toList());
    await Future.wait(_aheadTasks.toList());
    await _settleCastTasks();
    await sleepTimer.settle();
    await _preferenceGate.run(() async {});
    await history.store.flush();
    super.dispose();
  }
}
