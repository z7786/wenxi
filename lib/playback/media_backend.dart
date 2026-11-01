import 'dart:async';
import 'dart:math' as math;
import '../diagnostics/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/downloads.dart';
import '../domain/playback.dart';
import 'stream_proxy.dart';
import 'playback_failure.dart';
import 'playback_stall_monitor.dart';
import 'playback_buffer_policy.dart';
import 'playback_metrics.dart';
import 'subtitle_fonts.dart';

/// The controller also runs against a deterministic backend in lifecycle tests.
abstract class PlaybackBackend extends ChangeNotifier {
  PlayerState get state;
  VideoGeometry? get videoGeometry {
    final params = state.videoParams;
    // Demuxed track information comes from the container header, before a
    // decoded frame. Ignore cover artwork and honor the selected video track.
    final tracks = state.tracks.video.where(
      (track) =>
          track.id != 'auto' &&
          track.id != 'no' &&
          track.albumart != true &&
          track.image != true,
    );
    final selected = state.track.video.id;
    final track =
        tracks.where((track) => track.id == selected).firstOrNull ??
        ({'auto', 'no'}.contains(selected)
            ? tracks.where((track) => track.isDefault == true).firstOrNull ??
                  tracks.firstOrNull
            : null);
    // mpv can publish raw w/h before rotation and pixel aspect arrive. Keep
    // the selected container's known values until decoded values are present;
    // an explicit decoded rotation of zero still takes precedence.
    final decoded =
        VideoGeometry.fromMetadata(
          width: params.dw,
          height: params.dh,
          rotation: params.rotate ?? track?.rotate ?? 0,
        ) ??
        VideoGeometry.fromMetadata(
          width: params.w,
          height: params.h,
          rotation: params.rotate ?? track?.rotate ?? 0,
          pixelAspect: params.par ?? track?.par ?? 1,
        );
    if (decoded != null) return decoded;
    final metadata = track == null
        ? null
        : VideoGeometry.fromMetadata(
            width: track.w,
            height: track.h,
            rotation: track.rotate ?? 0,
            pixelAspect: track.par ?? 1,
          );
    return metadata ??
        VideoGeometry.fromMetadata(width: state.width, height: state.height);
  }

  VideoController? get videoController => null;
  int get errorRevision;
  PlaybackFailure? get failure => null;
  bool get canRetryWithSoftware => true;
  String get streamingDescription => '';
  Map<String, Object?> get diagnosticFields => const {};
  bool get rendersSubtitlesNatively => false;
  bool get supportsScreenshot => false;
  Future<Uint8List?> screenshot({bool includeSubtitles = false}) async => null;
  String get subtitleFontMessage => '';
  bool get subtitleFontLoading => false;
  Future<void> retrySubtitleFont() async {}
  bool? get hardwareDecodingActive => null;
  Future<void> initialize() async {}
  Future<void> setSubtitlePresentation({
    required double size,
    required double height,
    required double bottom,
    int? backgroundColor,
  }) async {}
  Future<void> setConnections(int value) async {}
  Future<void> setSegmentSizeMiB(int value) async {}
  Future<void> open(DownloadSpec source, Duration start);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double value);
  Future<void> setVolume(double value);
  Future<void> setAudioTrack(AudioTrack track);
  Future<void> setSubtitleTrack(SubtitleTrack track);
  Future<void> setSubtitleDelay(double seconds);
  Future<void> setAudioDelay(double seconds);
  Future<void> close();
}

class MediaKitBackend extends PlaybackBackend {
  MediaKitBackend({
    required bool video,
    bool hardwareAcceleration = true,
    Player? player,
    SubtitleFontStore? subtitleFonts,
    this.downloadCache,
  }) : subtitleFonts = subtitleFonts ?? SubtitleFontStore.shared,
       player =
           player ??
           Player(
             configuration: PlayerConfiguration(
               title: '文析助手',
               bufferSize: 16 * 1024 * 1024,
               libass: video,
             ),
           ) {
    if (video) {
      _video = VideoController(
        this.player,
        configuration: VideoControllerConfiguration(
          // On Windows this flag controls GPU rendering, not video decoding.
          // Keep it when decoding on the CPU; the native output already falls
          // back to CPU rendering if ANGLE cannot initialize.
          enableHardwareAcceleration:
              defaultTargetPlatform == TargetPlatform.windows ||
              hardwareAcceleration,
          hwdec: hardwareAcceleration ? null : 'no',
        ),
      );
      // Attach an error handler immediately; open also awaits this future so
      // the controller can rebuild once in software mode if creation fails.
      unawaited(
        _video!.platform.future.then<void>((_) {}, onError: (Object _) {}),
      );
      unawaited(
        _video!.waitUntilFirstFrameRendered.then<void>((_) {
          if (_closing) return;
          _surfaceReady = true;
          _onPlayerState();
        }, onError: (Object _) {}),
      );
    }
    for (final stream in <Stream<Object?>>[
      this.player.stream.playing,
      this.player.stream.completed,
      this.player.stream.position,
      this.player.stream.duration,
      this.player.stream.buffer,
      this.player.stream.buffering,
      this.player.stream.volume,
      this.player.stream.rate,
      this.player.stream.tracks,
      this.player.stream.track,
      this.player.stream.videoParams,
      this.player.stream.width,
      this.player.stream.height,
      this.player.stream.subtitle,
    ]) {
      _subscriptions.add(stream.listen((_) => _onPlayerState()));
    }
    final native = this.player.platform;
    _subscriptions.add(
      this.player.stream.log.listen((value) {
        if (_closing || !{'error', 'fatal'}.contains(value.level)) return;
        DiagnosticLog.error(
          'player.backend_log',
          value.text,
          null,
          fields: {'component': value.prefix},
        );
        if (RegExp(
          r'subtitle|sub-add',
          caseSensitive: false,
        ).hasMatch(value.text)) {
          return;
        }
        final hint = PlaybackFailure.fromLog(value.text);
        if (hint != null) {
          _failureHint = hint;
          _hintAt = DateTime.now();
        }
      }),
    );
    _subscriptions.add(
      this.player.stream.error.listen((value) {
        if (_closing) return;
        DiagnosticLog.error('player.backend', value, null);
        // media_kit also emits recoverable TCP and decoder log lines here.
        // Native playback is failed only by END_FILE_REASON_ERROR or by a
        // demanded proxy read that can no longer return verified bytes.
        if (native is! NativePlayer &&
            !RegExp(
              r'subtitle|sub-add',
              caseSensitive: false,
            ).hasMatch(value)) {
          _reportFailure(
            PlaybackFailure.fromLog(value) ??
                const PlaybackFailure(
                  '视频播放失败，请刷新重试或下载后打开',
                  PlaybackFailureKind.unknown,
                ),
          );
        }
      }),
    );
    if (native is NativePlayer) {
      _subscriptions.add(
        native.playbackFailures.listen((code) {
          if (_closing) return;
          final hint =
              _hintAt != null &&
                  DateTime.now().difference(_hintAt!) <
                      const Duration(seconds: 30)
              ? _failureHint
              : null;
          _reportFailure(
            hint ??
                PlaybackFailure(
                  code == -13 ? '视频地址无法读取，请刷新重试' : '视频无法播放，请刷新重试或切换软件解码',
                  code == -13
                      ? PlaybackFailureKind.network
                      : PlaybackFailureKind.unknown,
                ),
            origin: 'native',
            nativeCode: code,
          );
        }),
      );
    }
  }
  final Player player;
  final SubtitleFontStore subtitleFonts;
  SubtitleFont? _subtitleFont;
  Future<void>? _subtitleFontTask;
  String _subtitleFontMessage = '';
  bool _subtitleFontLoading = false;
  VideoController? _video;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _closing = false;
  bool _surfaceReady = false, _sampling = false;
  int _sourceBytes = 0;
  Timer? _performanceTimer;
  PlaybackMetrics _metrics = PlaybackMetrics();
  PlaybackBufferPolicy _bufferPolicy = PlaybackBufferPolicy(connectionLimit: 8);
  final Map<String, Object?> _nativeMetrics = {};
  (double, double, double, int?)? _subtitlePresentation;
  Future<void>? _initializing;
  int? _initializedMs;
  Future<void>? _closeFuture;
  int _errorRevision = 0;
  bool _sourceFailure = false;
  bool _networkFile = false, _wantsPlay = false;
  Duration? _seekTarget;
  final _stallMonitor = PlaybackStallMonitor();
  PlaybackFailure? _failure, _failureHint;
  DateTime? _hintAt;
  @override
  PlaybackFailure? get failure => _failure;

  void _onPlayerState() {
    if (_closing) return;
    final state = player.state;
    // mpv briefly reports buffering while draining the final decoded packets,
    // before its completed event arrives. This is not a network underrun.
    const eofMargin = Duration(milliseconds: 250);
    final atEnd =
        state.completed ||
        state.duration > Duration.zero &&
            state.position + eofMargin >= state.duration &&
            state.buffer + eofMargin >= state.duration;
    final elapsed = _openWatch?.elapsed;
    if (elapsed != null) {
      _metrics.observe(
        elapsed: elapsed,
        playing: _wantsPlay && state.playing && !atEnd,
        buffering: state.buffering,
        position: state.position,
      );
      if (_enhancedPrefetch &&
          !atEnd &&
          _performanceTimer?.isActive == true &&
          _bufferPolicy.resumeSeconds(
                rebufferCount: _metrics.bufferingCount,
                rate: state.rate,
              ) !=
              _resumeBufferSeconds) {
        unawaited(_samplePerformance());
      }
      if (_metrics.firstFrame == null &&
          _surfaceReady &&
          (state.width ?? 0) > 1 &&
          (state.height ?? 0) > 1) {
        _metrics.firstFrame = elapsed;
        DiagnosticLog.event('player.first_frame', fields: diagnosticFields);
      }
    }
    final target = _seekTarget;
    if (target != null &&
        (state.position - target).abs() < const Duration(milliseconds: 250)) {
      _seekTarget = null;
    }
    // keep-open can report a clean EOF after a truncated HTTP body instead of
    // MPV_END_FILE_REASON_ERROR. A known VOD ending far before its duration is
    // a source interruption, not a completed episode or a decoder failure.
    final tolerance = Duration(
      seconds: (state.duration.inSeconds ~/ 100).clamp(3, 10),
    );
    if (_networkFile &&
        state.completed &&
        state.duration > Duration.zero &&
        state.position + tolerance < state.duration &&
        (target == null || target + tolerance < state.duration)) {
      _reportFailure(
        const PlaybackFailure('视频连接提前结束，请刷新链接重试', PlaybackFailureKind.network),
        origin: 'premature_eof',
      );
      return;
    }
    notifyListeners();
  }

  void _reportFailure(
    PlaybackFailure value, {
    String origin = 'backend',
    int? nativeCode,
  }) {
    if (_closing || _failure != null) return;
    DiagnosticLog.error(
      'player.terminal_failure',
      value,
      null,
      fields: {
        ...diagnosticFields,
        'origin': origin,
        'kind': value.kind.name,
        'status': ?value.status,
        'nativeCode': ?nativeCode,
      },
    );
    _failure = value;
    _sourceFailure = value.sourceFailure;
    _errorRevision++;
    notifyListeners();
  }

  @override
  bool get canRetryWithSoftware => !_sourceFailure;
  @override
  bool get rendersSubtitlesNatively =>
      player.platform?.configuration.libass == true;
  @override
  String get subtitleFontMessage => _subtitleFontMessage;
  @override
  bool get subtitleFontLoading => _subtitleFontLoading;
  @override
  bool? get hardwareDecodingActive {
    final value = _nativeMetrics['hwdecCurrent'];
    return value is String && value.isNotEmpty ? value != 'no' : null;
  }

  @override
  Future<void> initialize() => _initializing ??= () async {
    final watch = Stopwatch()..start();
    await _video?.platform.future;
    if (!_closing && rendersSubtitlesNatively) {
      SubtitleFont? local;
      try {
        local = await subtitleFonts.local().timeout(const Duration(seconds: 2));
        if (local != null) await _applySubtitleFont(local);
      } catch (error, stack) {
        DiagnosticLog.error('player.subtitle_font_local', error, stack);
      }
      if (!_closing && _subtitleFont == null) {
        // Missing fonts must not delay opening video on an offline device.
        unawaited(retrySubtitleFont());
      }
    }
    _initializedMs = watch.elapsedMilliseconds;
  }();

  Future<void> _applySubtitleFont(SubtitleFont font) =>
      _propertyGate.run(() async {
        if (_closing) return;
        final native = player.platform;
        if (native is! NativePlayer) return;
        // mpv marks sub-fonts-dir UPDATE_SUB_HARD: changing it also recreates
        // libass for an already selected track when a background download ends.
        await native.setProperty('sub-fonts-dir', font.directory);
        if (_closing) return;
        await native.setProperty('sub-font', font.family);
        if (_closing) return;
        _subtitleFont = font;
        _subtitleFontMessage = '';
        DiagnosticLog.event(
          'player.subtitle_font_ready',
          fields: {'source': font.origin.name, 'family': font.family},
        );
        notifyListeners();
      });

  @override
  Future<void> retrySubtitleFont() {
    if (_closing || !rendersSubtitlesNatively) return Future.value();
    return _subtitleFontTask ??= () async {
      _subtitleFontLoading = true;
      _subtitleFontMessage = '正在准备中文字幕字体，可继续播放';
      notifyListeners();
      try {
        final font = await subtitleFonts.ensureAvailable();
        if (!_closing) await _applySubtitleFont(font);
      } catch (error, stack) {
        DiagnosticLog.error('player.subtitle_font', error, stack);
        if (!_closing) {
          _subtitleFontMessage = '中文字幕字体未就绪，请在字幕设置中重试';
        }
      } finally {
        _subtitleFontLoading = false;
        _subtitleFontTask = null;
        if (!_closing) notifyListeners();
      }
    }();
  }

  final _propertyGate = AsyncGate();
  @override
  bool get supportsScreenshot =>
      !_closing && (state.width ?? 0) > 1 && (state.height ?? 0) > 1;

  @override
  Future<Uint8List?> screenshot({bool includeSubtitles = false}) =>
      _propertyGate.run(() async {
        if (!supportsScreenshot) return null;
        final image = await player.screenshot(
          format: 'image/png',
          includeLibassSubtitles: includeSubtitles,
        );
        return _closing ? null : image;
      });
  final Future<Uint8List?> Function(
    DownloadSpec source,
    int start,
    int end,
    RemoteIdentity identity,
  )?
  downloadCache;
  PlaybackStreamProxy? _proxy;
  Map<String, Object?>? _probeDiagnostics;
  Stopwatch? _openWatch;
  String _transport = 'pending';
  int? _networkTimeoutSeconds;
  double _resumeBufferSeconds = 1;
  final _transportChecks = <Timer>[];
  int _connections = 12, _segmentSizeMiB = 4;
  int? _sourceConnectionLimit;
  int get _effectiveConnectionLimit => math.min(
    _connections,
    _sourceConnectionLimit ?? PlaybackPreferences.maxConnections,
  );
  String _streamingDescription = '';
  @override
  String get streamingDescription => _streamingDescription;
  @override
  Map<String, Object?> get diagnosticFields => {
    'transport': _transport,
    'networkTimeoutSeconds': ?_networkTimeoutSeconds,
    'openElapsedMs': ?_openWatch?.elapsedMilliseconds,
    'backendInitializeMs': ?_initializedMs,
    'subtitleFontSource': ?_subtitleFont?.origin.name,
    'subtitleFontLoading': _subtitleFontLoading,
    ..._nativeMetrics,
    ..._metrics.fields(_openWatch?.elapsed ?? Duration.zero),
    'effectiveConnections': _proxy?.connections ?? 1,
    'sourceConnectionLimit': ?_sourceConnectionLimit,
    'packetCacheBytes': _bufferPolicy.forwardBytes,
    'proxyCacheLimit': ?_proxy?.maxCacheBytes,
    'preloadSeconds': _enhancedPrefetch
        ? PlaybackBufferPolicy.readaheadSeconds
        : 30,
    'resumeBufferSeconds': _resumeBufferSeconds,
    'receiveBytesPerSecond': _bufferPolicy.bytesPerSecond.round(),
    'mediaInfoReady': _mediaInfoReady,
    'playing': player.state.playing,
    'buffering': player.state.buffering,
    'completed': player.state.completed,
    'stalledMs': _stallMonitor.stalledFor.inMilliseconds,
    'positionMs': player.state.position.inMilliseconds,
    'durationMs': player.state.duration.inMilliseconds,
    'bufferMs': player.state.buffer.inMilliseconds,
    'decodedWidth': ?player.state.width,
    'decodedHeight': ?player.state.height,
    if (_proxy != null || _probeDiagnostics != null)
      'proxy': _proxy?.diagnosticFields ?? _probeDiagnostics,
  };

  bool get _mediaInfoReady =>
      player.state.duration > Duration.zero ||
      player.state.tracks.video.any((t) => !{'auto', 'no'}.contains(t.id)) ||
      player.state.tracks.audio.any((t) => !{'auto', 'no'}.contains(t.id));

  bool get _enhancedPrefetch => _networkFile && downloadCache == null;

  void _cancelTransportChecks() {
    for (final timer in _transportChecks) {
      timer.cancel();
    }
    _transportChecks.clear();
  }

  void _watchTransport() {
    _cancelTransportChecks();
    for (final seconds in [5, 15, 30]) {
      _transportChecks.add(
        Timer(Duration(seconds: seconds), () {
          if (_closing || _failure != null) return;
          if (!_mediaInfoReady ||
              (player.state.playing && player.state.buffering)) {
            DiagnosticLog.event(
              'player.transport_waiting',
              fields: diagnosticFields,
            );
          }
        }),
      );
    }
    if (_transport == 'segmented') {
      _transportChecks.add(
        Timer.periodic(const Duration(seconds: 5), (_) {
          if (_closing || _failure != null) return;
          final state = player.state, proxy = _proxy;
          final stats = proxy?.diagnosticFields;
          final stalled = _stallMonitor.observe(
            waiting:
                _wantsPlay &&
                state.playing &&
                state.buffering &&
                _mediaInfoReady &&
                proxy?.activeRequests == 0,
            elapsed: _openWatch!.elapsed,
            position: state.position,
            buffer: state.buffer,
            receivedBytes: stats?['receivedBytes'] as int? ?? 0,
            servedBytes: stats?['servedBytes'] as int? ?? 0,
          );
          if (stalled) {
            _reportFailure(
              const PlaybackFailure(
                '视频缓冲连接已中断，请刷新链接重试',
                PlaybackFailureKind.network,
              ),
              origin: 'transport_stall',
            );
          }
        }),
      );
    }
  }

  @override
  Future<void> setConnections(int value) async {
    _connections = value.clamp(
      PlaybackPreferences.minConnections,
      PlaybackPreferences.maxConnections,
    );
    _bufferPolicy.setLimit(_effectiveConnectionLimit);
    _proxy?.connections = downloadCache == null ? _bufferPolicy.connections : 2;
    if (_proxy?.supported == true) {
      _streamingDescription = _proxyDescription;
      if (!_closing) notifyListeners();
    }
  }

  String get _proxyDescription => downloadCache == null
      ? '最多 $_effectiveConnectionLimit 个连接 · $_segmentSizeMiB MiB / 片'
      : '边下边播 · 优先读取已下载片段';
  @override
  Future<void> setSegmentSizeMiB(int value) async {
    if (_proxy != null) {
      throw StateError('Segment size requires a new playback session');
    }
    _segmentSizeMiB = value.clamp(1, 16);
  }

  @override
  PlayerState get state {
    final value = player.state;
    return _sourceFailure && value.completed
        ? value.copyWith(completed: false)
        : value;
  }

  @override
  VideoController? get videoController => _video;
  @override
  int get errorRevision => _errorRevision;
  @override
  Future<void> open(DownloadSpec source, Duration start) async {
    _cancelTransportChecks();
    _performanceTimer?.cancel();
    _openWatch = Stopwatch()..start();
    _nativeMetrics.clear();
    _metrics = PlaybackMetrics();
    final sourceLimit = source.maxPlaybackConnections;
    _sourceConnectionLimit = sourceLimit != null && sourceLimit > 0
        ? sourceLimit
        : null;
    _bufferPolicy = PlaybackBufferPolicy(
      connectionLimit: _effectiveConnectionLimit,
    );
    _sourceBytes = source.expectedSize;
    _transport = 'pending';
    _networkTimeoutSeconds = null;
    _probeDiagnostics = null;
    _sourceFailure = false;
    _networkFile = false;
    _wantsPlay = false;
    _seekTarget = start;
    _stallMonitor.reset();
    _failure = _failureHint = null;
    _hintAt = null;
    await _proxy?.close();
    _proxy = null;
    await initialize();
    if (_closing) return;
    final native = player.platform;
    if (native is NativePlayer) {
      final properties = <String, String>{
        'cache': 'yes',
        'cache-on-disk': 'no',
        'sub-ass-override': 'no',
      };
      for (final entry in properties.entries) {
        if (_closing) return;
        await native.setProperty(entry.key, entry.value);
      }
    }
    if (_closing) return;
    var url = source.url;
    var headers = Map<String, String>.of(source.headers);
    if (!source.isTorrent &&
        {'http', 'https'}.contains(Uri.tryParse(url)?.scheme)) {
      _transport = 'probing';
      final proxy = _proxy = PlaybackStreamProxy(
        source,
        connections: downloadCache == null ? _bufferPolicy.connections : 2,
        chunkBytes: downloadCache == null
            ? _segmentSizeMiB * 1024 * 1024
            : 512 * 1024,
        maxCacheBytes: downloadCache == null
            ? 48 * 1024 * 1024
            : 8 * 1024 * 1024,
        readCache: downloadCache == null
            ? null
            : (start, end, identity) =>
                  downloadCache!(source, start, end, identity),
        onFailure: (failure) => _reportFailure(failure, origin: 'proxy'),
      );
      bool available;
      try {
        available = await proxy.start();
      } on PlaybackFailure catch (failure) {
        _reportFailure(failure, origin: 'proxy');
        rethrow;
      }
      if (_closing) {
        await proxy.close();
        return;
      }
      if (available) {
        _sourceBytes = proxy.length;
        url = proxy.uri.toString();
        headers = {};
        _transport = 'segmented';
        _streamingDescription = _proxyDescription;
      } else {
        _probeDiagnostics = proxy.diagnosticFields;
        await proxy.close();
        _proxy = null;
        _transport = 'direct';
        _streamingDescription = '当前地址不支持并行分段，使用原始播放连接';
      }
    } else {
      _transport = source.isTorrent ? 'torrent' : 'local';
      _streamingDescription = source.isTorrent ? 'BT 按播放位置预读' : '本地文件，无需网络预读';
    }
    _networkFile =
        _transport == 'segmented' ||
        (_transport == 'direct' &&
            source.expectedSize > 0 &&
            _probeDiagnostics?['probeResult'] != 'playlist' &&
            !RegExp(
              r'\.(m3u8|mpd)$',
              caseSensitive: false,
            ).hasMatch(Uri.tryParse(source.url)?.path ?? ''));
    if (_closing) return;
    if (native is NativePlayer) {
      _resumeBufferSeconds = _enhancedPrefetch
          ? _bufferPolicy.resumeSeconds(rebufferCount: 0, rate: 1)
          : 1;
      final readahead = _enhancedPrefetch
          ? PlaybackBufferPolicy.readaheadSeconds
          : 30;
      for (final entry in {
        'cache-secs': '$readahead',
        'demuxer-readahead-secs': '$readahead',
        'demuxer-max-bytes': '${_bufferPolicy.forwardBytes}',
        'demuxer-max-back-bytes': '${PlaybackBufferPolicy.backBytes}',
        'cache-pause': 'yes',
        'cache-pause-initial': _enhancedPrefetch ? 'yes' : 'no',
        'cache-pause-wait': '$_resumeBufferSeconds',
      }.entries) {
        if (_closing) return;
        await native.setProperty(entry.key, entry.value);
      }
      // Upstream headers are validated before streaming packets to mpv. Keep
      // enough time for a bounded upstream retry or paused transport; the proxy
      // still enforces its own shorter response and inactivity deadlines.
      _networkTimeoutSeconds = {'segmented', 'torrent'}.contains(_transport)
          ? 90
          : 30;
      await native.setProperty(
        'network-timeout',
        _networkTimeoutSeconds.toString(),
      );
    }
    if (_closing) return;
    DiagnosticLog.event('player.transport', fields: diagnosticFields);
    notifyListeners();
    await player.open(
      Media(
        url,
        httpHeaders: headers,
        // Let a fresh source read its first packets naturally. An explicit
        // zero makes mpv seek during HLS initialization; for Aliyun's TS
        // timestamps that seek can fail and discard the first video segment.
        start: start > Duration.zero ? start : null,
        extras: {'title': source.fileName},
      ),
      play: false,
    );
    if (!_closing) {
      _watchTransport();
      _performanceTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_samplePerformance()),
      );
    }
  }

  Future<void> _samplePerformance() async {
    if (_closing || _sampling || _openWatch == null || _failure != null) return;
    _sampling = true;
    try {
      final native = player.platform;
      if (native is! NativePlayer) return;
      final state = player.state, proxy = _proxy;
      if (_enhancedPrefetch) {
        final resume = _bufferPolicy.resumeSeconds(
          rebufferCount: _metrics.bufferingCount,
          rate: state.rate,
        );
        if (resume != _resumeBufferSeconds) {
          await native.setProperty('cache-pause-wait', '$resume');
          _resumeBufferSeconds = resume;
        }
      }
      if (_closing) return;
      if (downloadCache == null &&
          {'segmented', 'direct', 'torrent'}.contains(_transport)) {
        final target = _bufferPolicy.forwardTarget(
          size: _sourceBytes,
          duration: state.duration,
          rate: state.rate,
          seconds: _enhancedPrefetch ? PlaybackBufferPolicy.forwardSeconds : 8,
        );
        if (target > _bufferPolicy.forwardBytes &&
            (proxy == null ||
                proxy.resizeCache(_bufferPolicy.proxyBytesFor(target)))) {
          await native.setProperty('demuxer-max-bytes', target.toString());
          _bufferPolicy.forwardBytes = target;
        }
        if (_closing) return;
        if (proxy != null) {
          proxy.connections = _bufferPolicy.observe(
            elapsed: _openWatch!.elapsed,
            receivedBytes: proxy.receivedBytes,
            failures: proxy.segmentFailures,
            status: proxy.lastUpstreamStatus,
            activeRequests: proxy.activeRequests,
            bufferedSeconds:
                math.max(
                  0,
                  (state.buffer - state.position).inMilliseconds / 1000,
                ) /
                math.max(.25, state.rate),
            buffering: state.buffering,
            playing: _wantsPlay && state.playing,
            requiredBytesPerSecond:
                _sourceBytes > 0 && state.duration > Duration.zero
                ? _sourceBytes /
                      (state.duration.inMicroseconds / 1000000) *
                      state.rate
                : 0,
          );
        }
      }
      for (final entry in const {
        'hwdec-current': 'hwdecCurrent',
        'video-format': 'videoCodec',
        'estimated-vf-fps': 'videoFps',
        'video-params/pixelformat': 'videoPixelFormat',
        'decoder-frame-drop-count': 'decoderDroppedFrames',
        'frame-drop-count': 'outputDroppedFrames',
        'avsync': 'avSyncSeconds',
      }.entries) {
        if (_closing) return;
        try {
          final value = await native.getProperty(entry.key);
          if (value.isNotEmpty) {
            _nativeMetrics[entry.value] = num.tryParse(value) ?? value;
          }
        } catch (_) {
          // Properties unavailable for this track or older cores are optional.
        }
      }
      if (!_closing) notifyListeners();
    } catch (e, stack) {
      if (!_closing) DiagnosticLog.error('player.performance_sample', e, stack);
    } finally {
      _sampling = false;
    }
  }

  @override
  Future<void> setSubtitlePresentation({
    required double size,
    required double height,
    required double bottom,
    int? backgroundColor,
  }) => _propertyGate.run(() async {
    if (_closing || !rendersSubtitlesNatively || height <= 0) return;
    final next = (
      size,
      height.roundToDouble(),
      (bottom * 100).roundToDouble(),
      backgroundColor,
    );
    if (_subtitlePresentation == next) return;
    final native = player.platform;
    if (native is! NativePlayer) return;
    for (final entry in {
      'sub-font-size': (22 * 720 / height).clamp(8, 144).toStringAsFixed(2),
      'sub-scale': (size / 22).toStringAsFixed(3),
      // The page already provides the bottom distance. libass's default 34
      // scaled-pixel margin otherwise raises even the user's zero setting.
      'sub-margin-y': '0',
      'sub-pos': (100 - next.$3).clamp(40, 100).toStringAsFixed(0),
      // Keep a thin outline in viewport pixels instead of the core's thick
      // default. With background-box, shadow-offset is symmetric box padding,
      // not an offset copy of the text. ASS-authored styles remain intact.
      'sub-border-size': (720 / height).clamp(.1, 12).toStringAsFixed(2),
      'sub-border-color': '#CC000000',
      'sub-border-style': backgroundColor == null
          ? 'outline-and-shadow'
          : 'background-box',
      'sub-back-color':
          '#${(backgroundColor ?? 0).toRadixString(16).padLeft(8, '0')}',
      'sub-shadow-offset': backgroundColor == null
          ? '0'
          : (3 * 720 / height).clamp(.1, 24).toStringAsFixed(2),
    }.entries) {
      if (_closing) return;
      await native.setProperty(entry.key, entry.value);
    }
    _subtitlePresentation = next;
  });

  @override
  Future<void> play() {
    _wantsPlay = true;
    _stallMonitor.reset();
    _proxy?.setPaused(false);
    return player.play();
  }

  @override
  Future<void> pause() {
    _wantsPlay = false;
    _metrics.pause(_openWatch?.elapsed ?? Duration.zero);
    _stallMonitor.reset();
    _proxy?.setPaused(true);
    return player.pause();
  }

  @override
  Future<void> seek(Duration position) {
    _seekTarget = position;
    _metrics.seek(position, _openWatch?.elapsed ?? Duration.zero);
    _stallMonitor.reset();
    _proxy?.prepareSeek();
    return player.seek(position);
  }

  @override
  Future<void> setRate(double value) => player.setRate(value);
  @override
  Future<void> setVolume(double value) => player.setVolume(value);
  @override
  Future<void> setAudioTrack(AudioTrack track) => player.setAudioTrack(track);
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      player.setSubtitleTrack(track);
  Future<void> _setDelay(String property, double value) =>
      _propertyGate.run(() async {
        if (_closing) return;
        final native = player.platform;
        require(native is NativePlayer, '当前播放环境不支持时间校正');
        await (native as NativePlayer).setProperty(
          property,
          value.toStringAsFixed(2),
        );
        final actual = double.tryParse(await native.getProperty(property));
        require(actual != null && (actual - value).abs() < .02, '时间校正未能生效，请重试');
      });

  @override
  Future<void> setSubtitleDelay(double seconds) =>
      _setDelay('sub-delay', seconds);
  @override
  Future<void> setAudioDelay(double seconds) =>
      _setDelay('audio-delay', seconds);
  @override
  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    if (_openWatch != null) {
      DiagnosticLog.event('player.transport_closed', fields: diagnosticFields);
    }
    _closing = true;
    _performanceTimer?.cancel();
    _cancelTransportChecks();
    _openWatch?.stop();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _propertyGate.run(() async {});
    try {
      try {
        await _proxy?.close();
      } finally {
        await player.dispose();
      }
    } finally {
      super.dispose();
    }
  }
}

/// Known transport failures cannot be repaired by rebuilding a video decoder.
/// Unclassified initialization failures still get the single compatibility try.
bool isPlaybackSourceError(String message) => RegExp(
  r'\b(?:http|server returned)\b[^\r\n]*\b(?:401|403|404|408|410|416|429|5\d\d)\b|'
  r'\b(?:failed to open|connection refused|network is unreachable|'
  r'connection timed out|resolve host|unsupported protocol|permission denied)\b',
  caseSensitive: false,
).hasMatch(message);
