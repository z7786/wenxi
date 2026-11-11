import 'dart:async';
import 'dart:math' as math;
import '../diagnostics/app_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/downloads.dart';
import '../download/download_playback_cache.dart';
import '../domain/playback.dart';
import 'stream_proxy.dart';
import 'isolated_stream_proxy.dart';
import 'playback_failure.dart';
import 'playback_stall_monitor.dart';
import 'playback_video_monitor.dart';
import 'playback_seek_queue.dart';
import 'playback_buffer_policy.dart';
import 'playback_metrics.dart';
import 'playback_diagnostics.dart';
import 'playback_screen_info.dart';
import 'subtitle_fonts.dart';
import 'video_output_policy.dart';
import 'playback_render_policy.dart';

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

  /// Intended presentation cadence, including playback speed. The display
  /// hint must not depend on the number of frames a struggling decoder emits.
  double? get displayFrameRate {
    if (state.track.video.id == 'no') return null;
    final tracks = state.tracks.video.where(
      (t) =>
          !{'auto', 'no'}.contains(t.id) &&
          t.albumart != true &&
          t.image != true,
    );
    final track =
        tracks.where((t) => t.id == state.track.video.id).firstOrNull ??
        (state.track.video.id == 'auto'
            ? tracks.where((t) => t.isDefault == true).firstOrNull ??
                  tracks.firstOrNull
            : null);
    if (track == null) return null;
    // estimated-vf-fps fluctuates after dropped frames and seeks. Never use
    // that counter to drive display changes; unknown content keeps the default.
    final fps = track.fps;
    if (fps == null ||
        !fps.isFinite ||
        fps < 1 ||
        !state.rate.isFinite ||
        state.rate <= 0) {
      return null;
    }
    final effective = fps * state.rate;
    return effective >= 1 && effective <= 240 ? effective : null;
  }

  Widget? buildVideo({required BoxFit fit, double? aspectRatio}) => null;
  Widget? buildSubtitleOverlay() => null;
  bool get usesSubtitleOverlay => false;
  String get engineName => 'media_kit / libmpv';
  int get errorRevision;
  PlaybackFailure? get failure => null;
  bool get canRetryWithSoftware => true;
  String get streamingDescription => '';
  Map<String, Object?> get diagnosticFields => const {};
  PlaybackScreenInfo get screenInfo => const PlaybackScreenInfo();
  void setScreenDisplayMonitoringEnabled(bool enabled) {}
  bool get rendersSubtitlesNatively => false;
  bool get supportsScreenshot => false;
  Future<Uint8List?> screenshot({bool includeSubtitles = false}) async => null;
  String get subtitleFontMessage => '';
  bool get subtitleFontLoading => false;
  Future<void> retrySubtitleFont() async {}
  bool? get hardwareDecodingActive => null;
  void setVideoMonitoringEnabled(bool enabled) {}
  Future<void> setDecoderCompatibility(bool enabled) async {}
  void setRenderViewport(
    Size viewport,
    double pixelRatio,
    BoxFit fit,
    double scale,
  ) {}
  Future<void> initialize() async {}
  Future<void> setSubtitlePresentation({
    required double size,
    double? width,
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
    this.downloadSnapshot,
  }) : _hardwareAcceleration = hardwareAcceleration,
       subtitleFonts = subtitleFonts ?? SubtitleFontStore.shared,
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
              supportsNativeHardwareRendering &&
              (defaultTargetPlatform == TargetPlatform.windows ||
                  hardwareAcceleration),
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
      this.player.stream.duration,
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
    for (final stream in [
      this.player.stream.position,
      this.player.stream.buffer,
    ]) {
      _subscriptions.add(stream.listen((_) => _onPlayerState(progress: true)));
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
  final bool _hardwareAcceleration;
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
  Duration? _lastDiagnosticSample, _lastProgressNotification;
  Object? _sampledVideoFormat;
  final Map<String, String> _subtitleProperties = {};
  PlaybackDropPolicy _dropPolicy = PlaybackDropPolicy();
  Size? _renderViewport, _renderSize;
  double _renderPixelRatio = 1, _renderScale = 1;
  BoxFit _renderFit = BoxFit.contain;
  Timer? _renderTimer;
  bool _copyDecoder = false;
  final _diagnostics = PlaybackDiagnostics();
  (double, double, double, int?)? _subtitlePresentation;
  Future<void>? _initializing;
  int? _initializedMs;
  Future<void>? _closeFuture;
  int _errorRevision = 0;
  bool _sourceFailure = false;
  bool _networkFile = false, _wantsPlay = false;
  Duration? _seekTarget;
  final _stallMonitor = PlaybackStallMonitor();
  final _videoMonitor = PlaybackVideoMonitor();
  bool _videoMonitoringEnabled = true;
  bool? _videoFrameInfoSupported;
  Duration? _videoCheckAfter;
  int _seekRevision = 0;
  bool _seeking = false;
  late final _seekQueue = PlaybackSeekQueue(_performSeek);
  PlaybackFailure? _failure, _failureHint;
  DateTime? _hintAt;
  @override
  PlaybackFailure? get failure => _failure;

  void _onPlayerState({bool progress = false}) {
    if (_closing) return;
    final state = player.state;
    if (!progress) _scheduleRenderSize();
    // mpv briefly reports buffering while draining the final decoded packets,
    // before its completed event arrives. This is not a network underrun.
    const eofMargin = Duration(milliseconds: 250);
    final atEnd =
        state.completed ||
        state.duration > Duration.zero &&
            state.position + eofMargin >= state.duration &&
            state.buffer + eofMargin >= state.duration;
    final elapsed = _openWatch?.elapsed;
    if (state.buffering || atEnd) _dropPolicy.resetWindow();
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
                awaitingProgress: _metrics.awaitingProgress,
              ) !=
              _resumeBufferSeconds) {
        unawaited(_updateResumeBuffer());
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
    if (progress &&
        elapsed != null &&
        _lastProgressNotification != null &&
        elapsed - _lastProgressNotification! <
            const Duration(milliseconds: 250)) {
      return;
    }
    _lastProgressNotification = elapsed;
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
  bool get canRetryWithSoftware =>
      !_sourceFailure && _failure?.decoderUnavailable != true;
  @override
  void setVideoMonitoringEnabled(bool enabled) {
    if (_videoMonitoringEnabled == enabled) return;
    _videoMonitoringEnabled = enabled;
    _videoMonitor.reset();
    _dropPolicy.resetWindow();
  }

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
  final Future<DownloadReadableState?> Function(DownloadSpec source)?
  downloadSnapshot;
  PlaybackStreamProxy? _proxy;
  Map<String, Object?>? _probeDiagnostics;
  Stopwatch? _openWatch;
  String _transport = 'pending';
  bool _screenDisplayMonitoring = false;
  double? _directReceiveBytesPerSecond;

  @override
  void setScreenDisplayMonitoringEnabled(bool enabled) {
    _screenDisplayMonitoring = enabled;
    if (!enabled) _directReceiveBytesPerSecond = null;
  }

  @override
  PlaybackScreenInfo get screenInfo => PlaybackScreenInfo(
    transport: _transport,
    receivedBytes: _proxy?.receivedBytes,
    bytesPerSecond: _directReceiveBytesPerSecond,
    videoCodec: _nativeMetrics['videoCodec']?.toString(),
    videoFps: _screenMetric('videoFps'),
    pixelFormat: _nativeMetrics['videoPixelFormat']?.toString(),
    hardwareDecoder: _nativeMetrics['hwdecCurrent']?.toString(),
    decoderDroppedFrames: _screenMetric('decoderDroppedFrames')?.toInt(),
    outputDroppedFrames: _screenMetric('outputDroppedFrames')?.toInt(),
    bufferSeconds: _screenMetric('demuxerCacheSeconds'),
  );

  double? _screenMetric(String key) {
    final value = double.tryParse('${_nativeMetrics[key]}');
    return value != null && value.isFinite ? value : null;
  }

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
    'engine': engineName,
    ..._diagnostics.context,
    'transport': _transport,
    'networkTimeoutSeconds': ?_networkTimeoutSeconds,
    'openElapsedMs': ?_openWatch?.elapsedMilliseconds,
    'backendInitializeMs': ?_initializedMs,
    'subtitleFontSource': ?_subtitleFont?.origin.name,
    'subtitleFontLoading': _subtitleFontLoading,
    ..._nativeMetrics,
    ..._metrics.fields(_openWatch?.elapsed ?? Duration.zero),
    'effectiveConnections': _proxy?.connections ?? 1,
    'configuredConnections': _connections,
    'sourceConnectionLimit': ?_sourceConnectionLimit,
    'packetCacheBytes': _bufferPolicy.forwardBytes,
    'playbackCacheBudgetBytes': _bufferPolicy.byteBudget,
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
      ? '最多 $_effectiveConnectionLimit 个连接 · 当前 ${_proxy?.connections ?? _bufferPolicy.connections} 个 · $_segmentSizeMiB MiB / 片'
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
  Future<void> setDecoderCompatibility(bool enabled) async {
    if (_closing ||
        defaultTargetPlatform != TargetPlatform.android ||
        !_hardwareAcceleration ||
        _video == null) {
      return;
    }
    final videoPlatform = await _video!.platform.future;
    if (!videoPlatform.configuration.enableHardwareAcceleration ||
        videoPlatform.configuration.hwdec == 'no') {
      return;
    }
    final native = player.platform;
    if (native is! NativePlayer) return;
    _copyDecoder = enabled;
    await native.setProperty(
      'hwdec',
      enabled ? 'mediacodec-copy' : 'mediacodec,mediacodec-copy',
    );
  }

  @override
  void setRenderViewport(
    Size viewport,
    double pixelRatio,
    BoxFit fit,
    double scale,
  ) {
    _renderViewport = viewport;
    _renderPixelRatio = pixelRatio;
    _renderFit = fit;
    _renderScale = scale;
    _scheduleRenderSize();
  }

  void _scheduleRenderSize() {
    if (_closing ||
        _video == null ||
        _renderViewport == null ||
        !{
          TargetPlatform.android,
          TargetPlatform.windows,
          TargetPlatform.linux,
          TargetPlatform.macOS,
        }.contains(defaultTargetPlatform)) {
      return;
    }
    final geometry = videoGeometry;
    if (geometry == null) return;
    final target = playbackRenderSize(
      source: Size(geometry.width.toDouble(), geometry.height.toDouble()),
      viewport: _renderViewport!,
      pixelRatio: _renderPixelRatio,
      fit: _renderFit,
      scale: _renderScale,
      quality: _dropPolicy.downgraded ? .75 : 1,
    );
    if (target == null || target == _renderSize) return;
    _renderTimer?.cancel();
    _renderTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(
        _propertyGate.run(() async {
          if (_closing) return;
          try {
            await _video!.setSize(
              width: target.width.toInt(),
              height: target.height.toInt(),
            );
            _renderSize = target;
            _nativeMetrics['renderWidth'] = target.width.toInt();
            _nativeMetrics['renderHeight'] = target.height.toInt();
          } catch (e, stack) {
            if (!_closing) DiagnosticLog.error('player.render_size', e, stack);
          }
        }),
      );
    });
  }

  @override
  Widget? buildVideo({required BoxFit fit, double? aspectRatio}) {
    final video = _video;
    if (_closing || video == null) return null;
    return Video(
      controller: video,
      controls: NoVideoControls,
      fit: fit,
      aspectRatio: aspectRatio,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        visible: false,
      ),
    );
  }

  @override
  int get errorRevision => _errorRevision;
  @override
  Future<void> open(DownloadSpec source, Duration start) async {
    _cancelTransportChecks();
    _performanceTimer?.cancel();
    _openWatch = Stopwatch()..start();
    _diagnostics.begin({
      'playbackSource': DiagnosticLog.reference(
        '${source.fileName}|${source.url}',
      ),
    });
    _nativeMetrics.clear();
    _lastDiagnosticSample = _lastProgressNotification = null;
    _sampledVideoFormat = null;
    _dropPolicy = PlaybackDropPolicy();
    _videoMonitor.reset();
    _videoFrameInfoSupported = null;
    _videoCheckAfter = null;
    _metrics = PlaybackMetrics();
    final sourceLimit = source.maxPlaybackConnections;
    _sourceConnectionLimit = sourceLimit != null && sourceLimit > 0
        ? sourceLimit
        : null;
    _bufferPolicy = PlaybackBufferPolicy(
      connectionLimit: _effectiveConnectionLimit,
      desktop: {
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      }.contains(defaultTargetPlatform),
    );
    _sourceBytes = source.expectedSize;
    _directReceiveBytesPerSecond = null;
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
        // Keep exact landing while allowing the decoder to discard pre-target
        // frames. No timestamp-changing video filters are installed by the app.
        'hr-seek-framedrop': 'yes',
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
      final proxy = _proxy = IsolatedPlaybackStreamProxy(
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
        cacheSnapshot: downloadSnapshot == null
            ? null
            : () => downloadSnapshot!(source),
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

  Future<void> _updateResumeBuffer() => _propertyGate.run(() async {
    if (_closing || !_enhancedPrefetch) return;
    final native = player.platform;
    if (native is! NativePlayer) return;
    final resume = _bufferPolicy.resumeSeconds(
      rebufferCount: _metrics.bufferingCount,
      rate: state.rate,
      awaitingProgress: _metrics.awaitingProgress,
    );
    if (resume == _resumeBufferSeconds) return;
    await native.setProperty('cache-pause-wait', '$resume');
    _resumeBufferSeconds = resume;
  });

  // Native getProperty is synchronous FFI even though it returns a Future.
  // Yield an event turn between reads so frame notifications can be serviced.
  Future<String> _readProperty(NativePlayer native, String name) async {
    await Future<void>.delayed(Duration.zero);
    if (_closing) return '';
    return native.getProperty(name);
  }

  Future<void> _samplePerformance() async {
    if (_closing || _sampling || _openWatch == null || _failure != null) return;
    _sampling = true;
    try {
      final native = player.platform;
      if (native is! NativePlayer) return;
      final state = player.state, proxy = _proxy;
      if (_screenDisplayMonitoring &&
          proxy == null &&
          {'direct', 'torrent'}.contains(_transport)) {
        try {
          final speed = double.tryParse(
            await _readProperty(native, 'cache-speed'),
          );
          _directReceiveBytesPerSecond =
              _screenDisplayMonitoring &&
                  speed != null &&
                  speed.isFinite &&
                  speed >= 0
              ? speed
              : null;
        } catch (_) {
          _directReceiveBytesPerSecond = null;
        }
        if (_closing) return;
      }
      await _updateResumeBuffer();
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
                await proxy.resizeCacheAsync(
                  _bufferPolicy.proxyBytesFor(target),
                ))) {
          if (_closing) return;
          await native.setProperty('demuxer-max-bytes', target.toString());
          _bufferPolicy.forwardBytes = target;
        }
        if (_closing) return;
        if (proxy != null) {
          double? nativeBufferedSeconds;
          try {
            nativeBufferedSeconds = double.tryParse(
              await _readProperty(native, 'demuxer-cache-duration'),
            );
            if (nativeBufferedSeconds != null &&
                nativeBufferedSeconds.isFinite &&
                nativeBufferedSeconds >= 0) {
              _nativeMetrics['demuxerCacheSeconds'] = nativeBufferedSeconds;
            } else {
              nativeBufferedSeconds = null;
            }
          } catch (_) {
            // Some demuxers do not expose a cache duration.
          }
          if (_closing) return;
          proxy.connections = _bufferPolicy.observe(
            elapsed: _openWatch!.elapsed,
            receivedBytes: proxy.receivedBytes,
            failures: proxy.segmentFailures,
            status: proxy.lastUpstreamStatus,
            activeRequests: proxy.activeRequests,
            requestCapacity: proxy.requestCapacity,
            bufferedSeconds:
                (nativeBufferedSeconds ??
                    math.max(
                      0,
                      (state.buffer - state.position).inMilliseconds / 1000,
                    )) /
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
          proxy.observeThroughput(
            receivedBytesPerSecond: _bufferPolicy.bytesPerSecond,
            requiredBytesPerSecond:
                _sourceBytes > 0 && state.duration > Duration.zero
                ? _sourceBytes /
                      (state.duration.inMicroseconds / 1000000) *
                      state.rate
                : 0,
            buffering: state.buffering,
          );
          _streamingDescription = _proxyDescription;
        }
      }
      final elapsed = _openWatch!.elapsed;
      final sampleSeekRevision = _seekRevision;
      final format = (
        state.track.video.id,
        state.videoParams.pixelformat,
        state.videoParams.hwPixelformat,
        state.videoParams.w,
        state.videoParams.h,
      );
      if (_sampledVideoFormat != format) {
        _sampledVideoFormat = format;
        _nativeMetrics.remove('videoCodec');
        _nativeMetrics.remove('videoPixelFormat');
        _lastDiagnosticSample = null;
      }
      if (_lastDiagnosticSample == null ||
          elapsed - _lastDiagnosticSample! >= const Duration(seconds: 10)) {
        _lastDiagnosticSample = elapsed;
        for (final entry in {
          'hwdec-current': 'hwdecCurrent',
          if (!_nativeMetrics.containsKey('videoCodec'))
            'video-format': 'videoCodec',
          'estimated-vf-fps': 'videoFps',
          if (!_nativeMetrics.containsKey('videoPixelFormat'))
            'video-params/pixelformat': 'videoPixelFormat',
          'decoder-frame-drop-count': 'decoderDroppedFrames',
          'frame-drop-count': 'outputDroppedFrames',
          'avsync': 'avSyncSeconds',
        }.entries) {
          if (_closing) return;
          try {
            final value = await _readProperty(native, entry.key);
            if (value.isNotEmpty) {
              _nativeMetrics[entry.value] = num.tryParse(value) ?? value;
            }
          } catch (_) {
            // Properties unavailable for this track or older cores are optional.
          }
        }
        final drops = _nativeMetrics['outputDroppedFrames'];
        if (drops is num &&
            _dropPolicy.observe(
              elapsed: elapsed,
              drops: drops.toInt(),
              fps: displayFrameRate,
              eligible:
                  _videoMonitoringEnabled &&
                  _wantsPlay &&
                  state.playing &&
                  !state.buffering &&
                  !state.completed &&
                  !_seeking &&
                  sampleSeekRevision == _seekRevision &&
                  !_metrics.awaitingProgress &&
                  (_videoCheckAfter == null || elapsed >= _videoCheckAfter!),
            )) {
          _scheduleRenderSize();
          // Reduce GPU scaling cost, keep hardware decoding and play intent.
          for (final entry in const {
            'scale': 'bilinear',
            'dscale': 'bilinear',
            'cscale': 'bilinear',
            'deband': 'no',
          }.entries) {
            await Future<void>.delayed(Duration.zero);
            if (_closing) return;
            await native.setProperty(entry.key, entry.value);
          }
          _nativeMetrics['renderPerformanceFallback'] = true;
          DiagnosticLog.event(
            'player.render_fallback',
            fields: diagnosticFields,
          );
        }
      }
      if (!_closing) await _sampleVideoOutput(native);
      if (!_closing) {
        unawaited(
          _diagnostics.sample(_openWatch!.elapsed, () => diagnosticFields),
        );
        notifyListeners();
      }
    } catch (e, stack) {
      if (!_closing) DiagnosticLog.error('player.performance_sample', e, stack);
    } finally {
      _sampling = false;
    }
  }

  Future<void> _sampleVideoOutput(NativePlayer native) async {
    if (_video == null || _closing) return;
    // An unavailable value is also normal before the first output frame. Check
    // support separately so older cores never trigger a false recovery.
    if (_videoFrameInfoSupported == null) {
      final properties = await _readProperty(native, 'property-list');
      _videoFrameInfoSupported = properties
          .split(',')
          .contains('video-frame-info');
    }
    if (_closing || _videoFrameInfoSupported != true) return;
    // This subproperty is available only when VO owns an actual current frame
    // (vo_get_current_frame), even for progressive video where its value is no.
    final frame = await _readProperty(native, 'video-frame-info/interlaced');
    if (_closing) return;
    final hasFrame = frame == 'yes' || frame == 'no';
    final vo = await _readProperty(native, 'vo-configured');
    if (_closing) return;
    final seeking = await _readProperty(native, 'seeking');
    if (_closing) return;
    final state = player.state, elapsed = _openWatch!.elapsed;
    final outputReady = _surfaceReady && vo == 'yes';
    _nativeMetrics['videoOutputReady'] = outputReady;
    _nativeMetrics['videoFrameAvailable'] = hasFrame;
    if (_metrics.firstFrame == null && outputReady && hasFrame) {
      _metrics.firstFrame = elapsed;
      // Core output is measurable here; Flutter compositor presentation is not.
      _nativeMetrics['firstFrameSignal'] = 'mpv-current-frame';
      DiagnosticLog.event('player.first_frame', fields: diagnosticFields);
    }
    final tracks = state.tracks.video.where(
      (t) =>
          !{'auto', 'no'}.contains(t.id) &&
          t.albumart != true &&
          t.image != true,
    );
    final track =
        tracks.where((t) => t.id == state.track.video.id).firstOrNull ??
        (state.track.video.id == 'auto' ? tracks.firstOrNull : null);
    final measuredFps = _nativeMetrics['videoFps'];
    final fps =
        track?.fps ?? (measuredFps is num ? measuredFps.toDouble() : null);
    final stalled = _videoMonitor.observe(
      elapsed: elapsed,
      position: state.position,
      outputReady: outputReady && hasFrame,
      rate: state.rate,
      eligible:
          _videoMonitoringEnabled &&
          _wantsPlay &&
          state.playing &&
          !state.buffering &&
          !state.completed &&
          !_seeking &&
          seeking == 'no' &&
          (_videoCheckAfter == null || elapsed >= _videoCheckAfter!) &&
          track != null &&
          fps != null &&
          fps.isFinite &&
          fps >= 1 &&
          (state.duration == Duration.zero ||
              state.position + const Duration(seconds: 2) < state.duration),
    );
    if (stalled) {
      if (defaultTargetPlatform == TargetPlatform.android &&
          !_copyDecoder &&
          _nativeMetrics['hwdecCurrent'] == 'mediacodec') {
        await setDecoderCompatibility(true);
        _videoMonitor.reset();
        _videoCheckAfter = elapsed + const Duration(seconds: 5);
        _nativeMetrics['decoderCompatibilityFallback'] = true;
        DiagnosticLog.event(
          'player.decoder_copy_fallback',
          fields: diagnosticFields,
        );
        return;
      }
      _reportFailure(
        const PlaybackFailure(
          '视频画面长时间没有输出，播放进度已保留；可重试或切换解码方式',
          PlaybackFailureKind.decoder,
        ),
        origin: 'video_output_stall',
      );
    }
  }

  @override
  Future<void> setSubtitlePresentation({
    required double size,
    double? width,
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
      if (_subtitleProperties[entry.key] == entry.value) continue;
      await Future<void>.delayed(Duration.zero);
      if (_closing) return;
      await native.setProperty(entry.key, entry.value);
      _subtitleProperties[entry.key] = entry.value;
    }
    _subtitlePresentation = next;
  });

  @override
  Future<void> play() {
    _wantsPlay = true;
    _stallMonitor.reset();
    _videoMonitor.reset();
    _proxy?.setPaused(false);
    return player.play();
  }

  @override
  Future<void> pause() {
    _dropPolicy.resetWindow();
    _wantsPlay = false;
    _metrics.pause(_openWatch?.elapsed ?? Duration.zero);
    _stallMonitor.reset();
    _videoMonitor.reset();
    _proxy?.setPaused(true);
    if (_closing) return Future.value();
    final native = player.platform;
    // Do not queue audio pause behind a seek or an external subtitle load.
    // libmpv serializes native commands; only the Dart control queue is bypassed.
    return native is NativePlayer
        ? native.pause(synchronized: false)
        : player.pause();
  }

  @override
  Future<void> seek(Duration position) => _seekQueue.seek(position);

  Future<void> _performSeek(Duration position) async {
    if (_closing) return;
    final revision = ++_seekRevision;
    _seeking = true;
    _dropPolicy.resetWindow();
    _videoMonitor.reset();
    _seekTarget = position;
    _metrics.seek(position, _openWatch?.elapsed ?? Duration.zero);
    _stallMonitor.reset();
    try {
      await _proxy?.prepareSeekAsync();
      await _updateResumeBuffer();
      if (_closing) return;
      await player.seek(position);
    } finally {
      if (revision == _seekRevision) {
        _seeking = false;
        _videoCheckAfter =
            (_openWatch?.elapsed ?? Duration.zero) + const Duration(seconds: 3);
      }
    }
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
    final closeFields = diagnosticFields;
    if (_openWatch != null) {
      DiagnosticLog.event('player.transport_closed', fields: diagnosticFields);
    }
    _closing = true;
    _renderTimer?.cancel();
    _seekQueue.close();
    _diagnostics.stop();
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
        final diagnostics = _diagnostics;
        if (diagnostics.supported && DiagnosticLog.active?.enabled == true) {
          unawaited(diagnostics.afterClose(closeFields));
          // libmpv termination is deferred for five seconds by media_kit. A
          // second process sample distinguishes that grace period from growth
          // that remains after teardown; neither sample delays route dismissal.
          Timer(const Duration(seconds: 8), () {
            unawaited(diagnostics.afterClose(closeFields, phase: 'settled'));
          });
        }
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
