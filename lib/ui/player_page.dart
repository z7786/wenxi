import 'dart:async';
import '../download/mobile_data_download_guard.dart';
import 'subtitle_appearance.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/auth.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import '../platform/playback_device.dart';
import '../platform/player_screenshot.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_sleep_timer.dart';
import '../playback/subtitle_files.dart';
import '../diagnostics/app_log.dart';
import 'player_theme.dart';
import 'player_rate_input.dart';
import 'player_connections_input.dart';
import 'player_playlist_panel.dart';
import 'player_aspect_panel.dart';
import 'player_sleep_panel.dart';
import 'player_screenshot_panel.dart';
import 'player_cast_panel.dart';
import '../playback/cast/cast_discovery.dart';
import 'pip_resize_handles.dart';
import 'loading_indicator.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage(
    this.controller, {
    super.key,
    required this.subtitleDirectory,
    this.device,
    this.onDownload,
    this.confirmDownload,
    this.chooseSubtitle,
    this.chooseExternalPlayer,
    this.onAuthorizeUcTv,
    this.screenshotActions = const PlayerScreenshotActions(),
    this.castDiscoveryFactory = CastDiscovery.new,
  });
  final PlaybackController controller;
  final Directory subtitleDirectory;
  final PlaybackDevice? device;
  final Future<void> Function(DownloadSpec source)? onDownload;
  final Future<bool> Function()? confirmDownload;
  final Future<XFile?> Function()? chooseSubtitle;
  final Future<XFile?> Function()? chooseExternalPlayer;
  final Future<bool> Function()? onAuthorizeUcTv;
  final PlayerScreenshotActions screenshotActions;
  final CastDiscovery Function() castDiscoveryFactory;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  PlaybackController get controller => widget.controller;
  late final device = widget.device ?? NativePlaybackDevice();
  final focus = FocusNode(debugLabel: 'AsterLink player');
  Timer? _hideTimer, _hudTimer, _volumeTimer, _layoutDeadline, _layoutQuiet;
  Timer? _lockTimer;
  Timer? _nativeSubtitleTimer;
  double _nativeSubtitleHeight = 0,
      _nativeSubtitleBottom = 0,
      _nativeSubtitleLift = 0,
      _nativeSubtitleSize = 22;
  bool _lockVisible = false;
  late final AnimationController _chrome;
  bool _disableAnimations = false;
  Object? _presentationState, _deviceState;
  final _safeInsets = <Orientation, EdgeInsets>{};
  Completer<void>? _layoutReady;
  Future<void> _layoutWork = Future.value();
  Future<void> _deviceWork = Future.value();
  int _layoutRevision = 0;
  String _layoutSignature = '';
  bool _rotationPending = false;
  PlaybackOrientation? _layoutTarget, _orientationOverride;
  StreamSubscription<String>? _actions;
  bool visible = true,
      locked = false,
      fullscreen = false,
      _fullscreenBusy = false;
  bool _adding = false,
      _subtitleBusy = false,
      _leaving = false,
      _pipBusy = false;
  bool _authorizing = false;
  bool _screenshotBusy = false;
  int _authorizationGeneration = -1;
  bool get _needsUcTv =>
      controller.sourceError is UcTvAuthorizationRequired &&
      widget.onAuthorizeUcTv != null;
  bool _wasPlaying = false, _pauseWithoutControls = false;
  int _modalDepth = 0, _seenGeneration = -1;
  String hud = '', _seenNotice = '';
  String _seenFontMessage = '';
  Duration? _seekPreview;
  Duration? _hoverSeekPreview;
  double _hoverSeekX = 0;
  Duration _seekStart = Duration.zero;
  double _dragX = 0, _dragY = 0, _viewportWidth = 1, _viewportHeight = 1;
  double _verticalInitial = 0, _verticalTarget = 0;
  bool _brightnessDrag = false, _verticalActive = false;
  double _lastAudibleVolume = 100;
  RawDialogRoute<void>? _activePanel;
  Color get _chromeForeground => Colors.white;
  bool _sidePanel(Size size) => size.width >= 600 || size.width > size.height;
  PlaybackOrientation get _screenOrientation =>
      _orientationOverride ??
      (MediaQuery.orientationOf(context) == Orientation.landscape
          ? PlaybackOrientation.landscape
          : PlaybackOrientation.portrait);

  @override
  void initState() {
    super.initState();
    _chrome = AnimationController(vsync: this, value: 1);
    _chrome.addListener(_syncNativeSubtitles);
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_onController);
    controller.beforePlay = _preparePresentation;
    device.addListener(_onDevice);
    _actions = device.actions.listen(
      (action) => _run(() async {
        switch (action) {
          case 'toggle':
            await controller.toggle();
          case 'rewind':
            await controller.skip(-15);
          case 'forward':
            await controller.skip(15);
          case 'hidden':
            await controller.background(pictureInPicture: false);
        }
      }),
    );
    unawaited(_initialize());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
    if (_disableAnimations) _chrome.value = visible && !locked ? 1 : 0;
  }

  Future<void> _initialize() async {
    try {
      await device.start(video: controller.hasVideo);
    } catch (_) {
      if (mounted) _showHud('系统播放控制暂不可用');
    }
    if (!mounted) return;
    await controller.start();
    if (mounted) {
      _onController();
      _touch();
    }
  }

  void _onController() {
    if (!mounted) return;
    if (_needsUcTv &&
        !_authorizing &&
        _authorizationGeneration != controller.generation) {
      _authorizationGeneration = controller.generation;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _needsUcTv) _run(_authorizeUcTv);
      });
    }
    final wasVisible = visible;
    final playing = controller.state.playing;
    if (_wasPlaying != playing) {
      _wasPlaying = playing;
      if (playing) {
        _pauseWithoutControls = false;
        _touch(show: false);
      } else {
        _hideTimer?.cancel();
        if (!locked && !_pauseWithoutControls) visible = true;
      }
    }
    if (_seenGeneration != controller.generation) {
      _seenGeneration = controller.generation;
      _seekPreview = null;
      _hoverSeekPreview = null;
      _pauseWithoutControls = false;
      locked = false;
      visible = true;
    }
    if (controller.notice.isNotEmpty && controller.notice != _seenNotice) {
      _seenNotice = controller.notice;
      _showHud(controller.notice);
    }
    final fontMessage = controller.backend?.subtitleFontMessage ?? '';
    if (fontMessage != _seenFontMessage) {
      _seenFontMessage = fontMessage;
      if (fontMessage.isNotEmpty) _showHud(fontMessage);
    }
    if (wasVisible != visible) _animateChrome();
    final state = controller.state;
    // Position and buffer updates only rebuild the bottom progress controls.
    // They must not rebuild the video surface, captions and page overlays.
    final presentation = (
      controller.backend,
      controller.generation,
      controller.loading,
      controller.openingExternalPlayer,
      controller.castSession,
      controller.connectingCast,
      controller.castSession?.error,
      controller.castSession?.warning,
      controller.error,
      controller.preferences,
      controller.boosting,
      controller.videoGeometry,
      controller.resumedFrom,
      controller.subtitleLoading,
      fontMessage,
      controller.backend?.subtitleFontLoading,
      controller.cloudSubtitleId,
      controller.usingSoftwareDecoder,
      state.playing,
      state.completed,
      state.buffering,
      state.duration,
      state.volume,
      state.rate,
      state.tracks,
      state.track,
      controller.backend?.rendersSubtitlesNatively == true
          ? 0
          : Object.hashAll(state.subtitle),
    );
    if (_presentationState != presentation) {
      _presentationState = presentation;
      unawaited(_syncDevice());
      setState(() {});
    }
  }

  void _syncNativeSubtitles() {
    final backend = controller.backend;
    if (!mounted ||
        _screenshotBusy ||
        backend == null ||
        !backend.rendersSubtitlesNatively ||
        _nativeSubtitleHeight <= 0 ||
        _nativeSubtitleTimer != null) {
      return;
    }
    _nativeSubtitleTimer = Timer(const Duration(milliseconds: 32), () {
      _nativeSubtitleTimer = null;
      if (!mounted ||
          _screenshotBusy ||
          !identical(backend, controller.backend)) {
        return;
      }
      unawaited(
        backend
            .setSubtitlePresentation(
              size: _nativeSubtitleSize,
              height: _nativeSubtitleHeight,
              backgroundColor: controller.preferences.subtitleBackgroundArgb,
              bottom:
                  ((_nativeSubtitleBottom +
                              _nativeSubtitleLift * _chrome.value) /
                          _nativeSubtitleHeight)
                      .clamp(0, .6),
            )
            .catchError((Object error, StackTrace stack) {
              DiagnosticLog.error('player.subtitle_layout', error, stack);
            }),
      );
    });
  }

  Future<void> _preparePresentation() async {
    while (mounted && !_leaving) {
      final revision = _layoutRevision;
      await _syncDevice();
      if (revision == _layoutRevision && !_rotationPending) return;
    }
  }

  Future<void> _syncDevice() {
    final geometry = controller.videoGeometry;
    final deviceState = (
      controller.generation,
      geometry,
      controller.preferences.autoRotate,
      _orientationOverride,
      controller.state.playing && !controller.loading && !controller.casting,
      locked,
      visible,
      _modalDepth > 0,
      device.inPip,
    );
    if (_deviceState == deviceState) {
      return Future.wait([_deviceWork, _layoutWork]).then((_) {});
    }
    _deviceState = deviceState;
    final target = controller.hasVideo && _orientationOverride != null
        ? _orientationOverride
        : playbackOrientation(
            video: controller.hasVideo,
            automatic: controller.preferences.autoRotate,
            width: geometry?.width,
            height: geometry?.height,
          );
    final signature =
        '${controller.generation}/${target?.name}/$locked/${device.inPip}';
    final newLayout = signature != _layoutSignature;
    if (newLayout) {
      _layoutSignature = signature;
      _finishLayout(_layoutRevision);
      _layoutRevision++;
      _layoutTarget = target;
      if (device.supportsOrientation &&
          !device.inPip &&
          !locked &&
          target != null &&
          target != PlaybackOrientation.system &&
          !_layoutMatches(target)) {
        _layoutReady = Completer<void>();
        _layoutWork = _layoutReady!.future;
        _rotationPending = true;
        final revision = _layoutRevision;
        // Android multi-window or large screens can decline orientation requests.
        // Keep playback usable there instead of waiting indefinitely.
        _layoutDeadline = Timer(
          const Duration(milliseconds: 1200),
          () => _finishLayout(revision),
        );
      }
    }
    final revision = _layoutRevision;
    final update = device
        .update(
          playing:
              controller.state.playing &&
              !controller.loading &&
              !controller.casting,
          width: geometry?.width,
          height: geometry?.height,
          autoRotate: controller.preferences.autoRotate,
          orientation: _orientationOverride,
          locked: locked,
          controlsVisible: !locked && (visible || _modalDepth > 0),
        )
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            if (_deviceState == deviceState) _deviceState = null;
          },
        )
        .catchError((Object _) {
          if (_deviceState == deviceState) _deviceState = null;
        });
    _deviceWork = update;
    if (newLayout && _rotationPending) {
      unawaited(
        update.then((_) {
          if (mounted && revision == _layoutRevision) _checkLayout();
        }),
      );
    }
    return Future.wait([update, _layoutWork]).then((_) {});
  }

  bool _layoutMatches(PlaybackOrientation target) {
    final size = MediaQuery.sizeOf(context);
    return target == PlaybackOrientation.landscape
        ? size.width > size.height
        : size.height >= size.width;
  }

  void _checkLayout() {
    if (!mounted || !_rotationPending) return;
    final revision = _layoutRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _layoutRevision || !_rotationPending) return;
      _layoutQuiet?.cancel();
      if (!_layoutMatches(_layoutTarget!)) return;
      _layoutQuiet = Timer(const Duration(milliseconds: 100), () {
        if (!mounted || revision != _layoutRevision) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              revision == _layoutRevision &&
              _layoutMatches(_layoutTarget!)) {
            _finishLayout(revision);
          }
        });
        WidgetsBinding.instance.scheduleFrame();
      });
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _finishLayout(int revision) {
    if (revision != _layoutRevision) return;
    _layoutDeadline?.cancel();
    _layoutQuiet?.cancel();
    final ready = _layoutReady;
    _layoutReady = null;
    if (ready != null && !ready.isCompleted) ready.complete();
    if (_rotationPending) {
      _rotationPending = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeMetrics() => _checkLayout();

  void _onDevice() {
    if (mounted) {
      final panel = _activePanel;
      if (device.inPip && panel != null && panel.isActive) {
        _activePanel = null;
        panel.navigator?.removeRoute(panel);
      }
      unawaited(_syncDevice());
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      controller.foreground();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _run(() async {
        final pip =
            state != AppLifecycleState.detached && await device.queryPip();
        await controller.background(pictureInPicture: pip);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _volumeTimer?.cancel();
    _chrome.dispose();
    _nativeSubtitleTimer?.cancel();
    _lockTimer?.cancel();
    _layoutRevision++;
    _layoutDeadline?.cancel();
    _layoutQuiet?.cancel();
    if (_layoutReady?.isCompleted == false) _layoutReady!.complete();
    if (controller.beforePlay == _preparePresentation) {
      controller.beforePlay = null;
    }
    unawaited(_actions?.cancel());
    controller.removeListener(_onController);
    device.removeListener(_onDevice);
    focus.dispose();
    unawaited(controller.close().catchError((Object _) {}));
    unawaited(device.finish().catchError((Object _) {}));
    super.dispose();
  }

  void _run(Future<void> Function() operation) {
    unawaited(() async {
      try {
        await operation();
      } catch (e) {
        if (mounted) _showHud(e is AppException ? e.message : '操作未能完成，请重试');
      }
    }());
  }

  Future<void> _authorizeUcTv() async {
    if (_authorizing || !_needsUcTv || _leaving) return;
    final generation = controller.generation;
    setState(() => _authorizing = true);
    _modalDepth++;
    _hideTimer?.cancel();
    try {
      final authorized = await widget.onAuthorizeUcTv!();
      if (mounted &&
          !_leaving &&
          authorized &&
          generation == controller.generation) {
        await controller.retry();
      }
    } finally {
      _modalDepth--;
      if (mounted) setState(() => _authorizing = false);
    }
  }

  void _touch({bool show = true}) {
    if (!mounted || locked) return;
    if (show) _setControlsVisible(true);
    _hideTimer?.cancel();
    if (_modalDepth == 0 &&
        controller.state.playing &&
        _seekPreview == null &&
        _hoverSeekPreview == null) {
      _hideTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _modalDepth == 0 && !locked) {
          _setControlsVisible(false);
        }
      });
    }
  }

  void _animateChrome() {
    final target = visible && !locked ? 1.0 : 0.0;
    if (_disableAnimations) {
      _chrome.value = target;
    } else {
      _chrome.animateTo(
        target,
        duration: Duration(milliseconds: target == 0 ? 160 : 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _setControlsVisible(bool value) {
    if (value) _pauseWithoutControls = false;
    if (visible != value) {
      setState(() {
        visible = value;
        if (!value) _hoverSeekPreview = null;
      });
      _animateChrome();
    }
    unawaited(_syncDevice());
  }

  void _clearTapSequence() {}

  void _updateSeekHover(PointerEvent event, double width) {
    final duration = controller.state.duration;
    if (width <= 0 || duration <= Duration.zero || !controller.ready) return;
    _hideTimer?.cancel();
    final x = event.localPosition.dx.clamp(0.0, width).toDouble();
    final milliseconds = (duration.inMilliseconds * (x / width)).round().clamp(
      0,
      duration.inMilliseconds,
    );
    final preview = Duration(milliseconds: milliseconds);
    if (_hoverSeekPreview == preview && (_hoverSeekX - x).abs() < .5) return;
    setState(() {
      _hoverSeekX = x;
      _hoverSeekPreview = preview;
    });
  }

  void _clearSeekHover() {
    if (_hoverSeekPreview == null) return;
    setState(() => _hoverSeekPreview = null);
    if (visible && !locked) _touch(show: false);
  }

  void _surfaceTap(TapUpDetails details) {
    if (locked) {
      _clearTapSequence();
      _showLock();
      return;
    }
    _toggleControls();
  }

  void _surfaceDoubleTap() {
    if (locked || !controller.ready) return;
    _pauseWithoutControls = true;
    _hideTimer?.cancel();
    _setControlsVisible(false);
    _run(controller.toggle);
  }

  void _showHud(String text) {
    if (!mounted) return;
    _hudTimer?.cancel();
    setState(() => hud = text);
    _hudTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => hud = '');
    });
  }

  void _toggleControls() {
    if (locked) {
      _showLock();
      return;
    }
    _setControlsVisible(!visible);
    if (!visible) _hideTimer?.cancel();
    if (visible) _touch();
  }

  Future<void> _back() async {
    if (device.supportsDesktopPip && device.inPip) {
      await _restorePip();
      return;
    }
    if (locked) {
      _showLock();
      return;
    }
    if (fullscreen) {
      await _toggleFullscreen();
      return;
    }
    if (_leaving) return;
    _leaving = true;
    await controller.pause();
    if (mounted) await Navigator.maybePop(context);
    _leaving = false;
  }

  Future<void> _toggleOrientation() async {
    if (locked || !controller.hasVideo || !device.supportsOrientation) return;
    final next = _screenOrientation == PlaybackOrientation.landscape
        ? PlaybackOrientation.portrait
        : PlaybackOrientation.landscape;
    setState(() => _orientationOverride = next);
    _touch();
    await _syncDevice();
  }

  Future<void> _toggleFullscreen() async {
    if (_fullscreenBusy || locked) return;
    _fullscreenBusy = true;
    try {
      final next = !fullscreen;
      await device.fullscreen(next);
      if (mounted) setState(() => fullscreen = next);
    } finally {
      _fullscreenBusy = false;
    }
    _touch();
  }

  void _toggleLock() {
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _lockTimer?.cancel();
    _run(controller.endBoost);
    setState(() {
      locked = !locked;
      visible = !locked;
      _hoverSeekPreview = null;
      hud = '';
      _lockVisible = false;
    });
    _clearTapSequence();
    _animateChrome();
    unawaited(_syncDevice());
    if (locked) {
      _showLock();
    } else {
      _touch();
    }
  }

  void _showLock() {
    if (!mounted || !locked) return;
    _lockTimer?.cancel();
    _hudTimer?.cancel();
    setState(() {
      _lockVisible = true;
      hud = '';
    });
    _lockTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _lockVisible = false);
    });
  }

  Future<void> _pip() async {
    if (controller.casting || controller.connectingCast) {
      _showHud('请先断开电视投屏');
      return;
    }
    if (_pipBusy) return;
    _pipBusy = true;
    try {
      await controller.endBoost();
      if (!await device.enterPip() && mounted) _showHud('当前设备暂时无法进入画中画');
    } finally {
      _pipBusy = false;
    }
  }

  Future<void> _restorePip() async {
    await device.exitPip();
    _touch();
  }

  Future<void> _closePip() async {
    if (_leaving) return;
    final route = ModalRoute.of(context);
    final navigator = Navigator.of(context);
    _leaving = true;
    try {
      await controller.pause();
      await _restorePip();
      if (fullscreen) {
        await device.fullscreen(false);
        if (mounted) setState(() => fullscreen = false);
      }
      // The explicit close action is allowed to leave even while PopScope is
      // still reflecting the previous PiP frame. Never pop another dialog.
      if (mounted && route != null && route.isActive) {
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      }
    } finally {
      _leaving = false;
    }
  }

  void _horizontalStart(DragStartDetails details) {
    _clearTapSequence();
    if (locked ||
        !controller.ready ||
        controller.casting && !controller.castSession!.seekSupported ||
        controller.state.duration <= Duration.zero) {
      return;
    }
    _hideTimer?.cancel();
    _seekStart = controller.state.position;
    _dragX = 0;
    setState(() => _seekPreview = _seekStart);
  }

  void _horizontalUpdate(DragUpdateDetails details) {
    if (locked || _seekPreview == null) return;
    _dragX += details.primaryDelta ?? 0;
    final window = (controller.state.duration.inSeconds * .1).clamp(30, 300);
    final target = clampPlaybackPosition(
      _seekStart +
          Duration(
            milliseconds: (_dragX / _viewportWidth * window * 1000).round(),
          ),
      controller.state.duration,
    );
    setState(() => _seekPreview = target);
    final delta = (target - _seekStart).inSeconds;
    _showHud('${delta >= 0 ? '+' : ''}$delta 秒  ·  ${playbackTime(target)}');
  }

  void _horizontalEnd() {
    final target = _seekPreview;
    if (target == null) return;
    setState(() => _seekPreview = null);
    _run(() => controller.seek(target));
    _touch();
  }

  void _verticalStart(DragStartDetails details) {
    _clearTapSequence();
    if (locked || !controller.ready) return;
    _verticalActive = true;
    _brightnessDrag = details.localPosition.dx < _viewportWidth / 2;
    _verticalInitial = _brightnessDrag
        ? device.brightness
        : controller.state.volume / 100;
    _verticalTarget = _verticalInitial;
    _dragY = 0;
  }

  void _verticalUpdate(DragUpdateDetails details) {
    if (locked || !controller.ready || !_verticalActive) return;
    if (_brightnessDrag && !device.supportsBrightness) {
      _showHud('请在系统中调整屏幕亮度');
      return;
    }
    _dragY += details.primaryDelta ?? 0;
    _verticalTarget =
        (_verticalInitial - _dragY / math.max(80, _viewportHeight * .7))
            .clamp(_brightnessDrag ? .05 : 0, 1)
            .toDouble();
    _showHud(
      '${_brightnessDrag ? '亮度' : '音量'}  ${(_verticalTarget * 100).round()}%',
    );
    if (_volumeTimer == null) {
      _applyVertical();
      _volumeTimer = Timer(const Duration(milliseconds: 60), () {
        _volumeTimer = null;
        _applyVertical();
      });
    }
  }

  void _applyVertical() {
    if (!mounted || locked) return;
    final brightness = _brightnessDrag, value = _verticalTarget;
    _run(
      () => brightness
          ? device.setBrightness(value)
          : controller.setVolume(value * 100, save: false),
    );
  }

  void _verticalEnd() {
    _volumeTimer?.cancel();
    _volumeTimer = null;
    if (locked || !controller.ready || !_verticalActive) return;
    _verticalActive = false;
    _applyVertical();
    if (!_brightnessDrag) {
      _run(() => controller.updatePreferences(controller.preferences));
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (locked) {
      if (key == LogicalKeyboardKey.escape) {
        _showLock();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      _run(controller.toggle);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _run(() => controller.skip(-15));
      _showHud('后退 15 秒');
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _run(() => controller.skip(15));
      _showHud('前进 15 秒');
    } else if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final value =
          (controller.state.volume +
                  (key == LogicalKeyboardKey.arrowUp ? 5 : -5))
              .clamp(0, 100)
              .toDouble();
      _run(() => controller.setVolume(value));
      _showHud('音量 ${value.round()}%');
    } else if (key == LogicalKeyboardKey.keyF) {
      _run(_toggleFullscreen);
    } else if (key == LogicalKeyboardKey.escape) {
      _run(_back);
    } else if (key == LogicalKeyboardKey.keyM) {
      if (controller.state.volume > 0) {
        _lastAudibleVolume = controller.state.volume;
        _run(() => controller.setVolume(0));
      } else {
        _run(() => controller.setVolume(_lastAudibleVolume));
      }
    } else {
      return KeyEventResult.ignored;
    }
    _touch();
    return KeyEventResult.handled;
  }

  Future<void> _panel(
    String title,
    Widget Function(BuildContext) content, {
    bool previewSubtitles = false,
  }) async {
    if (_activePanel != null || device.inPip) return;
    _modalDepth++;
    _hideTimer?.cancel();
    // Show the selected subtitle position while the side panel is open, rather
    // than lifting every low position above the playback controls.
    if (previewSubtitles) _setControlsVisible(false);
    final theme = playerTheme(Theme.of(context));
    final route = RawDialogRoute<void>(
      settings: const RouteSettings(name: 'player-panel'),
      requestFocus: true,
      barrierDismissible: true,
      barrierColor: const Color(0x33000000),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final size = MediaQuery.sizeOf(context);
        final side = _sidePanel(size);
        return SlideTransition(
          position:
              Tween<Offset>(
                begin: side
                    ? Offset(math.min(360, size.width * .46) / size.width, 0)
                    : const Offset(0, .85),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
          child: child,
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) => Theme(
        data: theme,
        child: Builder(
          builder: (panelContext) {
            final size = MediaQuery.sizeOf(panelContext);
            final side = _sidePanel(size);
            final keyboard = MediaQuery.viewInsetsOf(panelContext).bottom;
            return Padding(
              padding: EdgeInsets.only(bottom: keyboard),
              child: Align(
                alignment: side
                    ? Alignment.centerRight
                    : Alignment.bottomCenter,
                child: SizedBox(
                  width: side ? math.min(360, size.width * .46) : size.width,
                  height: side ? size.height - keyboard : null,
                  child: Material(
                    key: const Key('player-panel'),
                    color: playerPanelColor,
                    clipBehavior: Clip.antiAlias,
                    borderRadius: side
                        ? BorderRadius.zero
                        : const BorderRadius.vertical(top: Radius.circular(18)),
                    child: SafeArea(
                      top: side,
                      left: !side,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight:
                              (size.height - keyboard) * (side ? 1 : .82),
                        ),
                        child: Column(
                          mainAxisSize: side
                              ? MainAxisSize.max
                              : MainAxisSize.min,
                          children: [
                            if (!side)
                              Container(
                                width: 28,
                                height: 3,
                                margin: const EdgeInsets.only(top: 10),
                                decoration: BoxDecoration(
                                  color: Colors.white24,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      title,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '关闭面板',
                                    onPressed: () =>
                                        Navigator.pop(panelContext),
                                    icon: const Icon(
                                      CupertinoIcons.xmark,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Flexible(
                              child: AnimatedBuilder(
                                animation: controller,
                                builder: (_, _) => content(panelContext),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    _activePanel = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      if (identical(_activePanel, route)) _activePanel = null;
      _modalDepth--;
      if (mounted) _touch();
    }
  }

  Widget _choice(
    String title,
    String? subtitle,
    bool selected,
    VoidCallback action, {
    Key? key,
  }) => ListTile(
    key: key,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    selected: selected,
    selectedColor: playerAccent(context),
    selectedTileColor: playerAccent(context).withValues(alpha: .08),
    trailing: selected
        ? Icon(CupertinoIcons.check_mark, color: playerAccent(context))
        : null,
    onTap: action,
  );
  String _trackName(String id, String? title, String? language, String noun) {
    if (id == 'auto') return '自动选择';
    if (id == 'no') return noun == '字幕' ? '关闭字幕' : '关闭音轨';
    final lang = switch (language?.toLowerCase()) {
      'zh' || 'zho' || 'chi' => '中文',
      'en' || 'eng' => '英语',
      'ja' || 'jpn' => '日语',
      'ko' || 'kor' => '韩语',
      _ => language ?? '',
    };
    return [
      if (title?.trim().isNotEmpty == true) title!.trim() else '$noun $id',
      if (lang.isNotEmpty && lang != 'und') lang,
    ].join(' · ');
  }

  Future<void> _rates() => _panel(
    '播放速度',
    (context) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final columns = MediaQuery.textScalerOf(context).scale(14) > 20
                  ? 2
                  : 3;
              final width = (box.maxWidth - (columns - 1) * 10) / columns;
              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final rate in PlaybackPreferences.rates)
                    SizedBox(
                      width: width,
                      child: OutlinedButton(
                        key: ValueKey('player-rate-$rate'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: controller.preferences.rate == rate
                              ? playerAccent(context)
                              : Colors.white,
                          backgroundColor: controller.preferences.rate == rate
                              ? playerAccent(context).withValues(alpha: .12)
                              : Colors.white.withValues(alpha: .04),
                          side: BorderSide(
                            color: controller.preferences.rate == rate
                                ? playerAccent(context)
                                : Colors.white12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 14,
                          ),
                        ),
                        onPressed: () {
                          _run(() => controller.setRate(rate));
                          Navigator.pop(context);
                        },
                        child: Text('$rate×'),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          PlayerRateInput(
            rate: controller.preferences.rate,
            onApply: (rate) async {
              await controller.setRate(rate);
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(height: 12),
          const Text(
            '长按画面可临时加速，松手恢复原速度。',
            style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.6),
          ),
        ],
      ),
    ),
  );

  Future<void> _audio() => _panel('音轨与同步', (context) {
    final tracks = <String, AudioTrack>{
      for (final track in controller.state.tracks.audio) track.id: track,
    };
    return ListView(
      shrinkWrap: true,
      children: [
        for (final track in tracks.values)
          _choice(
            _trackName(track.id, track.title, track.language, '音轨'),
            track.codec == null
                ? null
                : [
                    track.codec!,
                    if (track.channels != null) track.channels!,
                  ].join(' · '),
            controller.state.track.audio.id == track.id,
            () => _run(() => controller.setAudioTrack(track)),
          ),
        if (tracks.keys.every((id) => id == 'no' || id == 'auto'))
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('尚未检测到可切换的音轨'),
          ),
        _delaySlider(
          '音频时间校正',
          controller.audioDelay,
          -5,
          5,
          controller.setAudioDelay,
        ),
      ],
    );
  });
  Widget _delaySlider(
    String title,
    double value,
    double min,
    double max,
    Future<void> Function(double) update,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title  ${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)} 秒'),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: ((max - min) * 10).round(),
          onChanged: (value) => _run(() => update(value)),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: () => _run(() => update(value - .5)),
              child: const Text('提前 0.5 秒'),
            ),
            TextButton(
              onPressed: () => _run(() => update(0)),
              child: const Text('重置'),
            ),
            TextButton(
              onPressed: () => _run(() => update(value + .5)),
              child: const Text('延后 0.5 秒'),
            ),
          ],
        ),
      ],
    ),
  );
  Future<void> _subtitles() => _panel('字幕', (context) {
    final current = controller.state.track.subtitle;
    final tracks = <String, SubtitleTrack>{
      for (final track in controller.state.tracks.subtitle) track.id: track,
      if (current.uri || current.data) current.id: current,
    };
    return ListView(
      shrinkWrap: true,
      children: [
        for (final track in tracks.values)
          _choice(
            _trackName(track.id, track.title, track.language, '字幕'),
            track.uri || track.data
                ? '外挂字幕'
                : track.id == 'auto' || track.id == 'no'
                ? null
                : '内嵌字幕',
            current.id == track.id,
            () => _run(() => controller.setSubtitleTrack(track)),
          ),
        for (final subtitle in controller.availableSubtitles)
          _choice(
            subtitle.name,
            '同目录字幕',
            controller.cloudSubtitleId == subtitle.id,
            () => _run(() => controller.loadCloudSubtitle(subtitle)),
          ),
        if (controller.subtitleLoading) const ListTile(title: Text('正在加载字幕…')),
        if (controller.backend?.subtitleFontMessage.isNotEmpty == true)
          ListTile(
            title: Text(controller.backend!.subtitleFontMessage),
            subtitle: controller.backend!.subtitleFontLoading
                ? null
                : const Text('点此重试下载中文字幕字体'),
            onTap: controller.backend!.subtitleFontLoading
                ? null
                : () => _run(controller.backend!.retrySubtitleFont),
          ),
        ListTile(
          leading: const Icon(CupertinoIcons.folder),
          title: const Text('加载字幕文件'),
          subtitle: const Text('SRT / VTT / ASS / SSA，最大 8 MB'),
          onTap: () {
            Navigator.pop(context);
            _run(_importSubtitle);
          },
        ),
        _delaySlider(
          '字幕时间校正',
          controller.subtitleDelay,
          -10,
          10,
          controller.setSubtitleDelay,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('字幕字号  ${controller.preferences.subtitleSize.round()}'),
              Slider(
                key: const Key('player-subtitle-size'),
                value: controller.preferences.subtitleSize,
                min: PlaybackPreferences.minSubtitleSize,
                max: PlaybackPreferences.maxSubtitleSize,
                divisions:
                    (PlaybackPreferences.maxSubtitleSize -
                            PlaybackPreferences.minSubtitleSize)
                        .round(),
                label: '${controller.preferences.subtitleSize.round()}',
                onChanged: (value) => _run(
                  () => controller.updatePreferences(
                    controller.preferences.copyWith(subtitleSize: value),
                    save: false,
                  ),
                ),
                onChangeEnd: (_) => _run(
                  () => controller.updatePreferences(controller.preferences),
                ),
              ),
              Text(
                '字幕位置  距底部 ${(controller.preferences.subtitleBottom * 100).round()}%',
              ),
              Slider(
                key: const Key('player-subtitle-position'),
                value: controller.preferences.subtitleBottom,
                min: 0,
                max: .4,
                divisions: 40,
                onChanged: (value) => _run(
                  () => controller.updatePreferences(
                    controller.preferences.copyWith(subtitleBottom: value),
                    save: false,
                  ),
                ),
                onChangeEnd: (_) => _run(
                  () => controller.updatePreferences(controller.preferences),
                ),
              ),
              SubtitleAppearanceSettings(
                preferences: controller.preferences,
                onChanged: (value, save) =>
                    _run(() => controller.updatePreferences(value, save: save)),
              ),
            ],
          ),
        ),
      ],
    );
  }, previewSubtitles: true);
  Future<void> _importSubtitle() async {
    if (_subtitleBusy) return;
    _subtitleBusy = true;
    _modalDepth++;
    _hideTimer?.cancel();
    final generation = controller.generation,
        wasPlaying = controller.state.playing,
        stopRevision = controller.sleepTimer.stopRevision;
    File? pending;
    try {
      final file =
          await (widget.chooseSubtitle?.call() ??
              openFile(
                acceptedTypeGroups: [
                  XTypeGroup(
                    label: '字幕文件',
                    extensions: SubtitleFiles.extensions,
                  ),
                ],
              ));
      if (file == null || !mounted) return;
      require(
        await file.length() <= SubtitleFiles.maximumBytes,
        '字幕文件不能超过 8 MB',
      );
      pending = await SubtitleFiles(
        widget.subtitleDirectory,
      ).stage(file.name, file.openRead());
      final staged = pending;
      pending = null;
      await controller.attachSubtitle(staged, file.name, generation);
      if (mounted) _showHud('已加载字幕：${file.name}');
    } finally {
      if (pending != null && await pending.exists()) await pending.delete();
      _subtitleBusy = false;
      _modalDepth--;
      if (mounted) {
        if (wasPlaying &&
            controller.canResumeAfterPanel(generation, stopRevision)) {
          await controller.play();
        }
        _touch();
      }
    }
  }

  Future<void> _playlist() => _panel(
    '选集',
    (context) => PlayerPlaylistPanel(
      controller: controller,
      onOrder: (order) => _run(() => controller.setPlaylistOrder(order)),
      onSelect: (index) {
        Navigator.pop(context);
        _run(() => controller.load(index));
      },
    ),
  );
  Future<void> _fit() => _panel(
    '画面比例',
    (context) => PlayerAspectPanel(
      preferences: controller.preferences,
      onChanged: (value) => _run(() => controller.updatePreferences(value)),
    ),
    previewSubtitles: true,
  );

  Future<void> _sleep() =>
      _panel('定时停止', (_) => PlayerSleepPanel(timer: controller.sleepTimer));

  Future<void> _screenshot() async {
    if (_screenshotBusy ||
        !controller.ready ||
        _activePanel != null ||
        controller.casting) {
      return;
    }
    _screenshotBusy = true;
    _nativeSubtitleTimer?.cancel();
    _nativeSubtitleTimer = null;
    final generation = controller.generation,
        stopRevision = controller.sleepTimer.stopRevision;
    final wasPlaying = controller.state.playing;
    final name = playerScreenshotName(
      controller.current.name,
      controller.state.position,
      DateTime.now(),
    );
    try {
      await controller.pause();
      if (!mounted || generation != controller.generation) return;
      await _panel(
        '视频截图',
        (_) => PlayerScreenshotPanel(
          actions: widget.screenshotActions,
          name: name,
          subtitlesAvailable:
              controller.preferences.subtitles &&
              controller.backend?.rendersSubtitlesNatively == true,
          capture: (include) async {
            require(generation == controller.generation, '视频已切换，请重新截图');
            if (include && _nativeSubtitleHeight > 0) {
              await controller.backend?.setSubtitlePresentation(
                size: _nativeSubtitleSize,
                height: _nativeSubtitleHeight,
                bottom: (_nativeSubtitleBottom / _nativeSubtitleHeight).clamp(
                  0,
                  .6,
                ),
                backgroundColor: controller.preferences.subtitleBackgroundArgb,
              );
            }
            return controller.screenshot(includeSubtitles: include);
          },
        ),
        previewSubtitles: true,
      );
    } finally {
      if (mounted) {
        setState(() => _screenshotBusy = false);
      } else {
        _screenshotBusy = false;
      }
      if (mounted &&
          wasPlaying &&
          controller.canResumeAfterPanel(generation, stopRevision)) {
        await controller.play();
      }
      if (mounted) _syncNativeSubtitles();
    }
  }

  Future<void> _customConnections() => _panel(
    '${controller.current.platform?.shortName ?? '默认'}播放连接数',
    (context) => ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        PlayerConnectionsInput(
          connections: controller.connections,
          onApply: (value) async {
            await controller.setConnections(value);
            if (context.mounted) Navigator.pop(context);
          },
        ),
        const SizedBox(height: 12),
        const Text(
          '按网盘分别保存，立即生效。实际连接数会根据缓冲需求和网络状况自动调整。',
          style: TextStyle(color: Colors.white60, fontSize: 12, height: 1.6),
        ),
      ],
    ),
  );

  Future<void> _settings() async {
    Future<void> Function()? next;
    await _panel(
      '播放设置',
      (context) => ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
            child: LayoutBuilder(
              builder: (context, box) {
                final actions = <(String, IconData, Future<void> Function())>[
                  ('音轨', CupertinoIcons.speaker_2, _audio),
                  if (controller.hasVideo)
                    ('字幕', CupertinoIcons.captions_bubble, _subtitles),
                  if (controller.hasVideo)
                    ('画面', CupertinoIcons.rectangle, _fit),
                ];
                final columns = MediaQuery.textScalerOf(context).scale(13) > 19
                    ? 2
                    : actions.length;
                return Wrap(
                  spacing: 4,
                  runSpacing: 12,
                  children: [
                    for (final action in actions)
                      SizedBox(
                        width: (box.maxWidth - (columns - 1) * 4) / columns,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: controller.casting
                              ? null
                              : () {
                                  next = action.$3;
                                  Navigator.pop(context);
                                },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: .06),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    action.$2,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  action.$1,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const Divider(height: 1),
          if (controller.hasVideo)
            ListTile(
              key: const Key('player-cast-settings'),
              leading: Icon(
                controller.casting ? Icons.cast_connected : Icons.cast,
              ),
              title: const Text('电视投屏'),
              subtitle: Text(
                controller.castSession?.device.name ?? '连接同一局域网的 DLNA 电视',
              ),
              onTap: () {
                next = _castPanel;
                Navigator.pop(context);
              },
            ),
          AnimatedBuilder(
            animation: controller.sleepTimer,
            builder: (context, _) => ListTile(
              key: const Key('player-sleep'),
              leading: const Icon(CupertinoIcons.moon_zzz),
              title: const Text('定时停止'),
              subtitle: Text(playerSleepLabel(controller.sleepTimer)),
              trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
              onTap: () {
                next = _sleep;
                Navigator.pop(context);
              },
            ),
          ),
          if (controller.hasVideo)
            ListTile(
              key: const Key('player-screenshot-settings'),
              leading: const Icon(CupertinoIcons.camera),
              title: const Text('视频截图'),
              subtitle: const Text('保存画面，可选择包含字幕'),
              enabled:
                  controller.ready &&
                  !controller.casting &&
                  controller.backend?.supportsScreenshot == true,
              trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
              onTap: () {
                next = _screenshot;
                Navigator.pop(context);
              },
            ),
          SwitchListTile(
            key: const Key('player-folder-memory'),
            title: const Text('记住此文件夹的设置'),
            subtitle: Text(
              controller.folderKey == null
                  ? '当前来源无法确定文件夹，使用通用设置'
                  : '分别保存倍速、片头片尾、字幕样式和画面比例',
            ),
            value: controller.remembersFolder,
            onChanged: controller.folderKey == null || controller.loading
                ? null
                : (value) => _run(() => controller.setRememberFolder(value)),
          ),
          if (controller.hasVideo && device.supportsExternalPlayer)
            ListTile(
              leading: const Icon(CupertinoIcons.arrow_up_right_square),
              title: const Text('第三方播放器'),
              subtitle: const Text('选择手机上已安装的播放器'),
              enabled:
                  !controller.loading &&
                  !controller.openingExternalPlayer &&
                  !controller.casting &&
                  !controller.connectingCast,
              onTap: () {
                next = _openExternalPlayer;
                Navigator.pop(context);
              },
            ),
          if (controller.hasVideo)
            SwitchListTile(
              key: const Key('player-hardware-decoding'),
              title: const Text('硬件解码'),
              subtitle: Text(
                controller.usingSoftwareDecoder &&
                        controller.preferences.hardwareAcceleration
                    ? '当前使用软件解码，设备或视频格式可能不支持硬件解码'
                    : '初始化失败时自动切换软件解码重试',
              ),
              value: controller.preferences.hardwareAcceleration,
              onChanged: controller.loading || controller.casting
                  ? null
                  : (value) =>
                        _run(() => controller.setHardwareAcceleration(value)),
            ),
          if (controller.hasVideo)
            SwitchListTile(
              title: const Text('自动适配视频方向'),
              subtitle: const Text('横向视频横屏，竖向视频竖屏'),
              value: controller.preferences.autoRotate,
              onChanged: (value) => _run(() async {
                setState(() => _orientationOverride = null);
                await controller.updatePreferences(
                  controller.preferences.copyWith(autoRotate: value),
                );
              }),
            ),
          SwitchListTile(
            title: const Text('记住播放进度'),
            subtitle: const Text('再次打开时从上次位置继续'),
            value: controller.preferences.resume,
            onChanged: (value) => _run(
              () => controller.updatePreferences(
                controller.preferences.copyWith(resume: value),
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('自动播放下一集'),
            subtitle: const Text('按选集面板中的顺序播放'),
            value: controller.preferences.autoNext,
            onChanged: (value) => _run(
              () => controller.updatePreferences(
                controller.preferences.copyWith(autoNext: value),
              ),
            ),
          ),
          if (controller.current.torrent)
            ListTile(
              title: const Text('BT 在线播放'),
              subtitle: Text(
                '${controller.backend?.streamingDescription ?? '正在准备连接…'}\n优先缓冲当前播放位置，拖动后重新安排片段。在线播放期间后台 BT 下载排队等待，退出后自动继续；本次播放缓存会清理。',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          if (controller.current.source?.kind == PlaybackSourceKind.download)
            ListTile(
              title: const Text('边下边播'),
              subtitle: Text(
                '${controller.backend?.streamingDescription ?? '正在准备…'}\n暂停播放或退出播放器后，下载任务会继续。拖到尚未下载的位置时，需要等待网络缓冲。',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          if (!controller.current.torrent &&
              controller.current.source?.kind != PlaybackSourceKind.download)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${controller.current.platform?.shortName ?? '默认'}播放连接数',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final count in PlaybackPreferences.connectionPresets)
                        ChoiceChip(
                          key: ValueKey('player-connections-$count'),
                          label: Text('$count'),
                          selected: controller.connections == count,
                          onSelected: (_) =>
                              _run(() => controller.setConnections(count)),
                          color: WidgetStateProperty.resolveWith(
                            (states) => states.contains(WidgetState.selected)
                                ? const Color(0xff4a2c38)
                                : const Color(0xff26272b),
                          ),
                          selectedColor: const Color(0xff4a2c38),
                          backgroundColor: const Color(0xff26272b),
                          surfaceTintColor: Colors.transparent,
                          side: const BorderSide(color: Colors.white24),
                          checkmarkColor: playerAccent(context),
                          labelStyle: TextStyle(
                            color: controller.connections == count
                                ? playerAccent(context)
                                : Colors.white70,
                          ),
                        ),
                      ActionChip(
                        key: const Key('player-connections-custom'),
                        avatar: const Icon(
                          CupertinoIcons.pencil,
                          size: 14,
                          color: Colors.white70,
                        ),
                        label: Text(
                          PlaybackPreferences.connectionPresets.contains(
                                controller.connections,
                              )
                              ? '自定义'
                              : '自定义 · ${controller.connections}',
                        ),
                        onPressed: () {
                          next = _customConnections;
                          Navigator.pop(context);
                        },
                        backgroundColor: const Color(0xff26272b),
                        surfaceTintColor: Colors.transparent,
                        side: const BorderSide(color: Colors.white24),
                        labelStyle: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('播放分片大小')),
                      DropdownButton<int>(
                        key: const Key('player-segment-size'),
                        value: controller.preferences.segmentSizeMiB,
                        dropdownColor: playerPanelColor,
                        items: [
                          for (var size = 1; size <= 16; size++)
                            DropdownMenuItem(
                              value: size,
                              child: Text('$size MiB'),
                            ),
                        ],
                        onChanged: controller.loading
                            ? null
                            : (value) {
                                if (value != null &&
                                    value !=
                                        controller.preferences.segmentSizeMiB) {
                                  _run(
                                    () => controller.setSegmentSizeMiB(value),
                                  );
                                }
                              },
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    controller.backend?.streamingDescription ?? '',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '播放器按码率尽量预存约 90 秒，实际时长受缓存大小限制。起播先缓冲约 6 秒，反复卡顿时逐步增加；按需增加连接，缓存与在途数据预算合计 96 MiB。暂停停止新分片，修改分片大小会保留进度重新连接。',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ExpansionTile(
            key: const Key('player-skip-settings'),
            title: const Text('跳过片头片尾'),
            subtitle: Text(
              '片头 ${controller.preferences.skipIntroSeconds} 秒 · 片尾 ${controller.preferences.skipOutroSeconds} 秒',
            ),
            children: [
              _skipSetting(intro: true),
              _skipSetting(intro: false),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: Text(
                  '使用当前进度：片头取当前时间，片尾取到结束的剩余时长，最多 600 秒。跳过片尾配合自动下一集生效；短视频不会套用超过自身长度的跳过设置。',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ],
          ),
          ListTile(
            title: const Text('从头播放'),
            leading: const Icon(CupertinoIcons.restart),
            onTap: () {
              Navigator.pop(context);
              _run(controller.fromBeginning);
            },
          ),
          ListTile(
            title: const Text('刷新链接重试'),
            leading: const Icon(CupertinoIcons.refresh),
            onTap: () {
              Navigator.pop(context);
              _run(controller.retry);
            },
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              [
                '拖动进度条可快速定位播放位置。',
                '横向滑动调整进度，左侧上下滑动调亮度，右侧调音量；长按临时加速。',
                if (Platform.isWindows)
                  '键盘：空格播放/暂停，←/→跳转，↑/↓音量，F 全屏，Esc 返回，M 静音。',
              ].join('\n\n'),
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
    if (mounted && !_leaving && !device.inPip && next != null) await next!();
  }

  Widget _castCover() => IgnorePointer(
    child: ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, box) => Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 480,
              maxHeight: math.max(60, box.maxHeight - 180),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.cast_connected,
                    size: 40,
                    color: Colors.white70,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    controller.connectingCast
                        ? '正在连接电视…'
                        : '正在投屏到 ${controller.castSession!.device.name}',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    controller.castSession!.error.ifEmpty(
                      '点击右上角投屏按钮管理连接\n下方可控制电视播放与进度',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _castPanel() => _panel(
    '电视投屏',
    (_) => PlayerCastPanel(
      key: const Key('player-cast-panel'),
      controller: controller,
      discoveryFactory: widget.castDiscoveryFactory,
      onResumeLocal: () {
        Navigator.of(context).pop();
        _run(() => controller.disconnectCast(resumeLocally: true));
      },
    ),
  );

  Future<void> _captureSkipTime({required bool intro}) async {
    final state = controller.state;
    if (!controller.ready ||
        state.duration <= Duration.zero ||
        state.position < Duration.zero) {
      return;
    }
    final position = clampPlaybackPosition(state.position, state.duration);
    final seconds = (intro ? position : state.duration - position).inSeconds;
    if (seconds > 600) {
      _showHud('${intro ? '片头' : '片尾'}最多支持 600 秒，请调整播放位置后再捕获');
      return;
    }
    await controller.updatePreferences(
      controller.preferences.copyWith(
        skipIntroSeconds: intro ? seconds : null,
        skipOutroSeconds: intro ? null : seconds,
      ),
    );
  }

  Widget _skipSetting({required bool intro}) {
    final seconds = intro
        ? controller.preferences.skipIntroSeconds
        : controller.preferences.skipOutroSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text('${intro ? '片头' : '片尾'} $seconds 秒'),
              TextButton.icon(
                key: Key(
                  intro
                      ? 'player-capture-skip-intro'
                      : 'player-capture-skip-outro',
                ),
                onPressed:
                    controller.ready &&
                        controller.state.duration > Duration.zero &&
                        controller.state.position >= Duration.zero
                    ? () => _run(() => _captureSkipTime(intro: intro))
                    : null,
                icon: const Icon(CupertinoIcons.time, size: 16),
                label: const Text('使用当前进度'),
              ),
            ],
          ),
          Slider(
            key: Key(intro ? 'player-skip-intro' : 'player-skip-outro'),
            value: seconds.toDouble(),
            max: 600,
            divisions: 120,
            label: '$seconds 秒',
            onChanged: (value) => _run(
              () => controller.updatePreferences(
                controller.preferences.copyWith(
                  skipIntroSeconds: intro ? value.round() : null,
                  skipOutroSeconds: intro ? null : value.round(),
                ),
                save: false,
              ),
            ),
            onChangeEnd: (_) => _run(
              () => controller.updatePreferences(controller.preferences),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _download() async {
    if (_adding || widget.onDownload == null) return;
    setState(() => _adding = true);
    try {
      if (!(await widget.confirmDownload?.call() ?? true) || !mounted) return;
      await controller.enqueueDownload(widget.onDownload!);
      if (mounted) _showHud('已添加到下载队列');
    } on DownloadConfirmationCancelled {
      // Declining a download does not interrupt the current playback.
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _openExternalPlayer() async {
    if (_leaving || controller.openingExternalPlayer || controller.loading) {
      return;
    }
    _modalDepth++;
    _hideTimer?.cancel();
    try {
      await controller.openExternalPlayer((url, title, position) async {
        if (!mounted || _leaving) return false;
        final windows = device.windowsExternalPlayer;
        String? executable;
        if (windows != null) {
          executable = await _chooseWindowsPlayer();
          if (executable == null || !mounted || _leaving) return false;
          windows.executable = executable;
        }
        // Disable Android's automatic PiP before another app takes the screen.
        await _syncDevice();
        if (!mounted || _leaving) return false;
        final opened = await device.openExternalPlayer(
          url: url,
          title: title,
          position: position,
        );
        if (opened && executable != null) {
          try {
            await controller.history.store.put(
              'windowsExternalPlayer',
              executable,
            );
          } catch (_) {
            // A launched player already owns the stream. A failed preference
            // write must not close that stream or restart internal audio.
            DiagnosticLog.event('player.external_preference_save_failed');
          }
        }
        return opened;
      });
    } finally {
      _modalDepth--;
      if (mounted) _touch();
    }
  }

  Future<String?> _chooseWindowsPlayer() async {
    final saved = controller.history.store.data.str('windowsExternalPlayer');
    if (saved.isNotEmpty) {
      final selected = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择外部播放器'),
          content: const Text('在线播放时请保留此播放页面。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'choose'),
              child: const Text('选择其他播放器'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'saved'),
              child: Text(p.basename(saved)),
            ),
          ],
        ),
      );
      if (selected == null || !mounted || _leaving) return null;
      if (selected == 'saved') return saved;
    }
    final selected =
        await (widget.chooseExternalPlayer?.call() ??
            openFile(
              acceptedTypeGroups: const [
                XTypeGroup(label: '播放器程序', extensions: ['exe']),
              ],
              initialDirectory: saved.isNotEmpty ? p.dirname(saved) : null,
              confirmButtonText: '选择播放器',
            ));
    if (!mounted || _leaving) return null;
    return selected?.path;
  }

  Widget _icon(
    String label,
    IconData icon,
    VoidCallback? action, {
    double size = 23,
    Key? key,
    Color? color,
  }) => IconButton(
    key: key,
    tooltip: label,
    onPressed: action,
    icon: Icon(icon, size: size),
    color: color ?? _chromeForeground,
    disabledColor: Colors.white30,
    style: IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );

  Widget _desktopPipControls() {
    final state = controller.state;
    final duration = state.duration.inMilliseconds.toDouble();
    return Positioned.fill(
      child: MediaQuery.withNoTextScaling(
        child: Column(
          key: const Key('player-desktop-pip'),
          children: [
            ColoredBox(
              color: Colors.black54,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => _run(device.dragPip),
                      onDoubleTap: () => _run(_restorePip),
                      child: SizedBox(
                        height: 44,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            controller.current.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  _icon(
                    '还原窗口',
                    CupertinoIcons.arrow_up_left_arrow_down_right,
                    () => _run(_restorePip),
                    size: 18,
                  ),
                  _icon(
                    '关闭画中画',
                    CupertinoIcons.xmark,
                    () => _run(_closePip),
                    size: 18,
                  ),
                ],
              ),
            ),
            Expanded(
              child: GestureDetector(
                key: const Key('player-pip-drag'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => _run(device.dragPip),
                onTap: () => _run(controller.toggle),
                onDoubleTap: () => _run(_restorePip),
                child: controller.error.isEmpty
                    ? const SizedBox.expand()
                    : Center(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '播放中断，请还原窗口重试',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            ColoredBox(
              color: Colors.black54,
              child: Row(
                children: [
                  _icon(
                    state.playing ? '暂停' : '播放',
                    state.playing
                        ? CupertinoIcons.pause_fill
                        : CupertinoIcons.play_fill,
                    () => _run(controller.toggle),
                    size: 20,
                    key: const Key('player-pip-toggle'),
                  ),
                  Expanded(
                    child: Slider(
                      key: const Key('player-pip-seek'),
                      value: (_seekPreview ?? state.position).inMilliseconds
                          .toDouble()
                          .clamp(0, duration > 0 ? duration : 1)
                          .toDouble(),
                      max: duration > 0 ? duration : 1,
                      onChanged: duration > 0 && controller.ready
                          ? (value) => setState(() {
                              _seekPreview = Duration(
                                milliseconds: value.round(),
                              );
                            })
                          : null,
                      onChangeEnd: (value) => _run(() async {
                        await controller.seek(
                          Duration(milliseconds: value.round()),
                        );
                        if (mounted) setState(() => _seekPreview = null);
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = controller.state, pip = device.inPip;
    final desktopPip = pip && device.supportsDesktopPip;
    final media = MediaQuery.of(context);
    final orientation = media.orientation;
    final previousInsets = _safeInsets[orientation] ?? EdgeInsets.zero;
    // Android reports smaller padding while system bars animate away. Retain
    // the safe bounds for this orientation so the controls never jump with it.
    final insets = EdgeInsets.fromLTRB(
      math.max(
        previousInsets.left,
        math.max(media.viewPadding.left, media.padding.left),
      ),
      math.max(
        previousInsets.top,
        math.max(media.viewPadding.top, media.padding.top),
      ),
      math.max(
        previousInsets.right,
        math.max(media.viewPadding.right, media.padding.right),
      ),
      math.max(
        previousInsets.bottom,
        math.max(media.viewPadding.bottom, media.padding.bottom),
      ),
    );
    _safeInsets[orientation] = insets;
    final chromeMedia = media.copyWith(padding: insets, viewPadding: insets);
    return Theme(
      data: playerTheme(Theme.of(context)),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: PopScope(
          canPop: !fullscreen && !locked && !desktopPip,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _run(_back);
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            resizeToAvoidBottomInset: false,
            body: Focus(
              focusNode: focus,
              autofocus: true,
              onKeyEvent: _key,
              child: LayoutBuilder(
                builder: (context, box) {
                  _viewportWidth = math.max(1, box.maxWidth);
                  _viewportHeight = math.max(1, box.maxHeight);
                  final backend = controller.backend;
                  final captions = state.subtitle
                      .where((line) => line.trim().isNotEmpty)
                      .join('\n');
                  final captionBottom = pip
                      ? desktopPip
                            ? 54.0
                            : 8.0
                      : math.min(
                          box.maxHeight * .55,
                          math.max(
                            0.0,
                            box.maxHeight *
                                    controller.preferences.subtitleBottom +
                                insets.bottom,
                          ),
                        );
                  final captionLift = pip
                      ? 0.0
                      : math.max(
                          0.0,
                          math.min(box.maxHeight * .55, 100.0 + insets.bottom) -
                              captionBottom,
                        );
                  _nativeSubtitleHeight = box.maxHeight;
                  _nativeSubtitleBottom = captionBottom;
                  _nativeSubtitleLift = captionLift;
                  _nativeSubtitleSize = pip
                      ? 12
                      : controller.preferences.subtitleSize;
                  _syncNativeSubtitles();
                  return Stack(
                    fit: StackFit.expand,
                    clipBehavior: Clip.hardEdge,
                    children: [
                      if (backend?.videoController != null)
                        ClipRect(
                          child: RepaintBoundary(
                            key: const Key('player-video-surface'),
                            child: Video(
                              key: ObjectKey(backend),
                              aspectRatio:
                                  controller.preferences.aspectRatio > 0
                                  ? controller.preferences.aspectRatio
                                  : controller.videoGeometry?.aspectRatio,
                              controller: backend!.videoController!,
                              controls: NoVideoControls,
                              pauseUponEnteringBackgroundMode: false,
                              resumeUponEnteringForegroundMode: false,
                              subtitleViewConfiguration:
                                  const SubtitleViewConfiguration(
                                    visible: false,
                                  ),
                              fit: switch (controller.preferences.fit) {
                                PlaybackFit.contain => BoxFit.contain,
                                PlaybackFit.cover => BoxFit.cover,
                                PlaybackFit.stretch => BoxFit.fill,
                              },
                            ),
                          ),
                        )
                      else if (!controller.hasVideo && !controller.loading)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  CupertinoIcons.music_note_2,
                                  size: 84,
                                  color: Color(0xff7fa5ff),
                                ),
                                const SizedBox(height: 24),
                                Text(
                                  controller.current.name,
                                  textAlign: TextAlign.center,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 17,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (controller.hasVideo &&
                          (controller.loading || _rotationPending))
                        const Positioned.fill(
                          child: IgnorePointer(
                            child: ColoredBox(
                              key: Key('player-layout-cover'),
                              color: Colors.black,
                            ),
                          ),
                        ),
                      if (!controller.casting &&
                          backend?.rendersSubtitlesNatively != true &&
                          captions.isNotEmpty &&
                          controller.preferences.subtitles &&
                          !controller.loading &&
                          !_rotationPending)
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: captionBottom,
                          child: IgnorePointer(
                            child: AnimatedBuilder(
                              animation: _chrome,
                              builder: (_, child) => Transform.translate(
                                offset: Offset(0, -captionLift * _chrome.value),
                                child: child,
                              ),
                              child: SubtitleCaption(
                                text: captions,
                                textKey: const Key('player-captions'),
                                size: pip
                                    ? 12
                                    : controller.preferences.subtitleSize,
                                backgroundColor: controller
                                    .preferences
                                    .subtitleBackgroundArgb,
                              ),
                            ),
                          ),
                        ),
                      if (!pip)
                        Positioned.fill(
                          child: GestureDetector(
                            key: const Key('player-gesture-surface'),
                            behavior: HitTestBehavior.opaque,
                            onTapUp: _surfaceTap,
                            onDoubleTap: locked ? null : _surfaceDoubleTap,
                            onHorizontalDragStart: _horizontalStart,
                            onHorizontalDragUpdate: _horizontalUpdate,
                            onHorizontalDragEnd: (_) => _horizontalEnd(),
                            onHorizontalDragCancel: () {
                              if (mounted) setState(() => _seekPreview = null);
                            },
                            onVerticalDragStart: _verticalStart,
                            onVerticalDragUpdate: _verticalUpdate,
                            onVerticalDragEnd: (_) => _verticalEnd(),
                            onVerticalDragCancel: _verticalEnd,
                            onLongPressStart: (_) {
                              _clearTapSequence();
                              if (locked) {
                                _showLock();
                              } else if (controller.ready &&
                                  !controller.casting) {
                                _run(controller.beginBoost);
                                _showHud(
                                  '${math.max(2.0, controller.preferences.rate)} 倍速播放中',
                                );
                              }
                            },
                            onLongPressEnd: (_) {
                              if (controller.boosting) {
                                _run(controller.endBoost);
                                if (!locked) {
                                  _showHud(
                                    '已恢复 ${controller.preferences.rate} 倍速',
                                  );
                                }
                              }
                            },
                            onLongPressCancel: () => _run(controller.endBoost),
                          ),
                        ),
                      if (controller.casting) _castCover(),
                      if (!controller.casting &&
                          (controller.loading ||
                              state.buffering ||
                              _rotationPending) &&
                          controller.error.isEmpty)
                        const IgnorePointer(
                          child: Center(
                            child: AppLoadingIndicator(
                              size: 40,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      if (!controller.casting &&
                          controller.error.isNotEmpty &&
                          !pip)
                        _errorPanel(),
                      if (desktopPip) _desktopPipControls(),
                      if (desktopPip)
                        Positioned.fill(
                          child: PipResizeHandles(
                            onResize: (edge) =>
                                _run(() => device.resizePip(edge)),
                          ),
                        ),
                      if (!pip)
                        Positioned.fill(
                          child: MediaQuery(
                            data: chromeMedia,
                            child: ExcludeSemantics(
                              excluding: !visible || locked,
                              child: IgnorePointer(
                                ignoring: !visible || locked,
                                child: AnimatedBuilder(
                                  animation: _chrome,
                                  builder: (_, child) => Offstage(
                                    offstage:
                                        _chrome.value == 0 &&
                                        (!visible || locked),
                                    child: FadeTransition(
                                      key: const Key('player-controls-fade'),
                                      opacity: _chrome,
                                      child: child,
                                    ),
                                  ),
                                  child: RepaintBoundary(
                                    child: Stack(
                                      key: const Key('player-visible-controls'),
                                      children: [
                                        _topControls(),
                                        if (controller.error.isEmpty) ...[
                                          ListenableBuilder(
                                            listenable: visible && !locked
                                                ? controller
                                                : const AlwaysStoppedAnimation<
                                                    double
                                                  >(0),
                                            builder: (_, _) =>
                                                _bottomControls(),
                                          ),
                                          _lockControl(false),
                                          if (controller.hasVideo)
                                            _screenshotControl(),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (locked && !pip)
                        MediaQuery(
                          data: chromeMedia,
                          child: IgnorePointer(
                            ignoring: !_lockVisible,
                            child: ExcludeSemantics(
                              excluding: !_lockVisible,
                              child: AnimatedOpacity(
                                key: const Key('player-lock-visibility'),
                                opacity: _lockVisible ? 1 : 0,
                                duration: Duration(
                                  milliseconds: _disableAnimations ? 0 : 160,
                                ),
                                child: _lockControl(true),
                              ),
                            ),
                          ),
                        ),
                      if (hud.isNotEmpty && !pip)
                        Center(
                          child: IgnorePointer(
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xdd20232a),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                hud,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lockControl(bool isLocked) => SafeArea(
    top: false,
    bottom: false,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Material(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(28),
          child: _icon(
            isLocked ? '解除锁定' : '锁定画面',
            isLocked ? CupertinoIcons.lock_fill : CupertinoIcons.lock,
            _toggleLock,
            color: Colors.white,
            key: Key(isLocked ? 'player-unlock' : 'player-lock'),
          ),
        ),
      ),
    ),
  );

  Widget _screenshotControl() => SafeArea(
    top: false,
    bottom: false,
    child: Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Material(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(28),
          child: _icon(
            '视频截图',
            CupertinoIcons.camera,
            controller.ready &&
                    controller.backend?.supportsScreenshot == true &&
                    !controller.casting &&
                    !_screenshotBusy
                ? () => _run(_screenshot)
                : null,
            color: Colors.white,
            key: const Key('player-screenshot'),
          ),
        ),
      ),
    ),
  );

  Widget _topControls() => Align(
    alignment: Alignment.topCenter,
    child: Container(
      key: const Key('player-top-controls'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xa6000000), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _icon('返回', CupertinoIcons.chevron_left, () => _run(_back)),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    controller.current.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.onDownload != null)
                  _icon(
                    controller.current.platform == CloudPlatform.uc
                        ? '下载原文件'
                        : '下载文件',
                    CupertinoIcons.arrow_down_to_line,
                    _adding ? null : () => _run(_download),
                  ),
                if (controller.hasVideo)
                  _icon(
                    '电视投屏',
                    controller.casting ? Icons.cast_connected : Icons.cast,
                    () => _run(_castPanel),
                    key: const Key('player-cast'),
                  ),
                if (device.supportsPip && !controller.casting)
                  _icon(
                    '画中画',
                    CupertinoIcons.rectangle_on_rectangle,
                    () => _run(_pip),
                  ),
                if (controller.hasVideo &&
                    device.supportsExternalPlayer &&
                    !controller.casting)
                  _icon(
                    '第三方播放器',
                    CupertinoIcons.arrow_up_right_square,
                    controller.loading || controller.openingExternalPlayer
                        ? null
                        : () => _run(_openExternalPlayer),
                    key: const Key('player-external-player'),
                  ),
                _icon('播放设置', CupertinoIcons.ellipsis, () => _run(_settings)),
              ],
            ),
            if (_resolutionLabel case final resolution?)
              Padding(
                padding: const EdgeInsets.only(left: 48, right: 8, top: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    label: '视频分辨率：$resolution',
                    excludeSemantics: true,
                    child: Container(
                      key: const Key('player-resolution'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x1affffff),
                        border: Border.all(color: const Color(0x1fffffff)),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            CupertinoIcons.tv,
                            size: 13,
                            color: Colors.white70,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              resolution,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            AnimatedBuilder(
              animation: controller.sleepTimer,
              builder: (context, _) {
                if (controller.sleepTimer.mode == PlaybackSleepMode.off) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 48),
                    child: TextButton.icon(
                      key: const Key('player-sleep-badge'),
                      onPressed: () => _run(_sleep),
                      icon: const Icon(CupertinoIcons.moon_zzz, size: 14),
                      label: Text(
                        playerSleepLabel(controller.sleepTimer),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                );
              },
            ),
            if (controller.resumedFrom > Duration.zero)
              Padding(
                padding: const EdgeInsets.only(left: 48, right: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已从 ${playbackTime(controller.resumedFrom)} 继续播放',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _run(controller.fromBeginning),
                      child: const Text('从头播放'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  String? get _resolutionLabel {
    final geometry = controller.videoGeometry;
    if (geometry == null || !controller.hasVideo) return null;
    return '${geometry.width} × ${geometry.height}';
  }

  Widget _bottomControls() {
    final state = controller.state;
    final position = clampPlaybackPosition(
      _seekPreview ?? state.position,
      state.duration,
    );
    final maximum = math.max(1, state.duration.inMilliseconds).toDouble();
    final canSeek =
        controller.ready &&
        state.duration > Duration.zero &&
        (!controller.casting || controller.castSession!.seekSupported);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        key: const Key('player-bottom-controls'),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Color(0xb3000000)],
          ),
        ),
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 600;
              final showNext = box.maxWidth >= 350;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: 36,
                    child: LayoutBuilder(
                      builder: (context, seekBox) {
                        final width = seekBox.maxWidth;
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            MouseRegion(
                              key: const Key('player-seek-hover-region'),
                              onEnter: canSeek
                                  ? (event) => _updateSeekHover(event, width)
                                  : null,
                              onHover: canSeek
                                  ? (event) => _updateSeekHover(event, width)
                                  : null,
                              onExit: (_) => _clearSeekHover(),
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  trackShape:
                                      const RectangularSliderTrackShape(),
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 4,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                ),
                                child: Slider(
                                  key: const Key('player-seek'),
                                  padding: EdgeInsets.zero,
                                  value: position.inMilliseconds.toDouble(),
                                  max: maximum,
                                  label: playbackTime(position),
                                  semanticFormatterCallback: (value) =>
                                      playbackTime(
                                        Duration(milliseconds: value.round()),
                                      ),
                                  secondaryTrackValue: math.max(
                                    position.inMilliseconds.toDouble(),
                                    state.buffer.inMilliseconds
                                        .clamp(0, maximum)
                                        .toDouble(),
                                  ),
                                  activeColor: playerAccent(context),
                                  inactiveColor: Colors.white24,
                                  secondaryActiveColor: Colors.white54,
                                  thumbColor: Colors.white,
                                  onChangeStart: canSeek
                                      ? (_) => _hideTimer?.cancel()
                                      : null,
                                  onChanged: canSeek
                                      ? (value) => setState(
                                          () => _seekPreview = Duration(
                                            milliseconds: value.round(),
                                          ),
                                        )
                                      : null,
                                  onChangeEnd: canSeek
                                      ? (_) => _horizontalEnd()
                                      : null,
                                ),
                              ),
                            ),
                            if (_hoverSeekPreview case final hover?
                                when canSeek && _seekPreview == null)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomSingleChildLayout(
                                    delegate: _SeekHoverLayout(_hoverSeekX),
                                    child: DecoratedBox(
                                      key: const Key('player-seek-hover-time'),
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: Colors.white24,
                                        ),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        child: Text(
                                          playbackTime(hover),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            height: 1.2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  Row(
                    children: [
                      _icon(
                        state.playing ? '暂停' : '播放',
                        state.playing
                            ? CupertinoIcons.pause_fill
                            : CupertinoIcons.play_fill,
                        controller.ready
                            ? () {
                                _run(controller.toggle);
                                _touch();
                              }
                            : null,
                        size: 27,
                        key: const Key('player-play-pause'),
                      ),
                      if (wide)
                        _icon(
                          '上一集',
                          CupertinoIcons.backward_end_fill,
                          controller.canPrevious
                              ? () => _run(controller.previous)
                              : null,
                          size: 22,
                        ),
                      if (showNext)
                        _icon(
                          '下一集',
                          CupertinoIcons.forward_end_fill,
                          controller.canNext
                              ? () => _run(controller.next)
                              : null,
                          size: 22,
                        ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(text: playbackTime(position)),
                                  TextSpan(
                                    text:
                                        ' / ${state.duration > Duration.zero ? playbackTime(state.duration) : '--:--'}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                    ),
                                  ),
                                ],
                              ),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('player-speed'),
                        onPressed: controller.casting
                            ? null
                            : () => _run(_rates),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          minimumSize: const Size(56, 44),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        child: Text(
                          controller.casting
                              ? '电视播放'
                              : controller.preferences.rate == 1
                              ? '倍速'
                              : '${controller.preferences.rate}×',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (box.maxWidth < 340 ||
                          MediaQuery.textScalerOf(context).scale(13) > 19)
                        _icon(
                          '\u9009\u96c6',
                          CupertinoIcons.list_bullet,
                          () => _run(_playlist),
                          key: const Key('player-playlist'),
                        )
                      else
                        TextButton(
                          key: const Key('player-playlist'),
                          onPressed: () => _run(_playlist),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            minimumSize: const Size(52, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text(
                            '\u9009\u96c6',
                            style: TextStyle(fontSize: 13),
                          ),
                        ),
                      if (controller.hasVideo && device.supportsOrientation)
                        _icon(
                          _screenOrientation == PlaybackOrientation.landscape
                              ? '切换竖屏'
                              : '切换横屏',
                          Icons.screen_rotation,
                          () => _run(_toggleOrientation),
                          size: 22,
                          key: const Key('player-orientation'),
                        ),
                      _icon(
                        fullscreen ? '退出全屏' : '全屏',
                        fullscreen
                            ? CupertinoIcons.arrow_down_right_arrow_up_left
                            : CupertinoIcons.arrow_up_left_arrow_down_right,
                        () => _run(_toggleFullscreen),
                        size: 22,
                        key: const Key('player-fullscreen'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _errorPanel() => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Material(
            color: playerPanelColor,
            borderRadius: BorderRadius.circular(14),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.exclamationmark_circle,
                    color: Colors.white60,
                    size: 32,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    controller.error,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, height: 1.5),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: _authorizing
                            ? null
                            : () => _run(
                                _needsUcTv ? _authorizeUcTv : controller.retry,
                              ),
                        child: Text(_needsUcTv ? '扫码授权播放' : '刷新重试'),
                      ),
                      if (widget.onDownload != null)
                        OutlinedButton(
                          onPressed: _adding ? null : () => _run(_download),
                          child: Text(
                            controller.current.platform == CloudPlatform.uc
                                ? '下载原文件'
                                : '下载文件',
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _SeekHoverLayout extends SingleChildLayoutDelegate {
  const _SeekHoverLayout(this.x);
  final double x;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: constraints.maxWidth);

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (x - childSize.width / 2)
        .clamp(0.0, math.max(0.0, size.width - childSize.width))
        .toDouble(),
    -childSize.height,
  );

  @override
  bool shouldRelayout(_SeekHoverLayout oldDelegate) => x != oldDelegate.x;
}
