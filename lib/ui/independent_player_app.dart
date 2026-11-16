import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import '../core/json.dart';
import '../domain/playback.dart';
import '../platform/windows_pip.dart';
import 'desktop_pip_surface.dart';
import '../playback/video_output_policy.dart';
import '../playback/windows_player_components.dart';

class IndependentPlayerApp extends StatelessWidget {
  const IndependentPlayerApp({super.key, required this.endpoint});
  final String endpoint;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: _IndependentPlayer(endpoint: endpoint),
  );
}

class _IndependentPlayer extends StatefulWidget {
  const _IndependentPlayer({required this.endpoint});
  final String endpoint;
  @override
  State<_IndependentPlayer> createState() => _IndependentPlayerState();
}

class _IndependentPlayerState extends State<_IndependentPlayer>
    with WindowListener {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  Player? player;
  VideoController? video;
  Timer? heartbeat;
  final subscriptions = <StreamSubscription<Object?>>[];
  Future<void>? _playerDisposal;
  final _windowGate = AsyncGate();
  VideoGeometry? _geometry;
  double? _windowAspect;
  bool closing = false, reporting = false;
  String title = '视频小窗', error = '';
  PlaybackPreferences preferences = const PlaybackPreferences();
  Uri get endpoint => Uri.parse(widget.endpoint);
  @override
  void initState() {
    super.initState();
    unawaited(initialize());
  }

  Future<Json> request(String method, [Json? data]) async {
    final uri = endpoint;
    require(
      uri.scheme == 'http' &&
          uri.host == '127.0.0.1' &&
          uri.hasPort &&
          uri.pathSegments.length == 1 &&
          uri.query.isEmpty &&
          uri.fragment.isEmpty &&
          uri.userInfo.isEmpty,
      '播放窗口连接地址无效',
    );
    final outgoing = await client.openUrl(method, uri);
    outgoing.followRedirects = false;
    if (data != null) {
      outgoing.headers.contentType = ContentType.json;
      outgoing.write(jsonEncode(data));
    }
    final response = await outgoing.close().timeout(const Duration(seconds: 5));
    require(response.statusCode == 200, '主软件已结束小窗播放');
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      require(bytes.length < 128 * 1024, '播放窗口配置过大');
    }
    return asJson(jsonDecode(utf8.decode(bytes)));
  }

  Future<void> initialize() async {
    try {
      await initializeMediaRuntime(independentWindow: true);
      await windowManager.ensureInitialized();
      if (!mounted || closing) return;
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
      if (!mounted || closing) return;
      final data = await request('GET');
      if (!mounted || closing) return;
      title = data.str('title', '视频小窗');
      preferences = PlaybackPreferences.fromJson(data.obj('preferences'));
      _geometry = VideoGeometry.fromJson(data.obj('videoGeometry'));
      final aspect = _geometry?.aspectRatio ?? 16 / 9;
      await windowManager.waitUntilReadyToShow(
        WindowOptions(
          title: title,
          size: desktopPipWindowSize(aspect),
          minimumSize: desktopPipMinimumSize(aspect),
          alwaysOnTop: true,
          titleBarStyle: TitleBarStyle.hidden,
          windowButtonVisibility: false,
        ),
      );
      if (!mounted || closing) return;
      await windowManager.setAsFrameless();
      await windowManager.setMaximizable(false);
      await windowManager.setResizable(true);
      await syncWindowAspect(aspect);
      if (!mounted || closing) return;
      await windowManager.show();
      await windowManager.focus();
      if (!mounted || closing) return;
      final decoder = player = Player(
        configuration: const PlayerConfiguration(
          title: '视频小窗',
          bufferSize: 16 * 1024 * 1024,
        ),
      );
      if (Platform.environment['ASTERLINK_MACOS_SMOKE'] == '1') {
        subscriptions.add(
          decoder.stream.error.listen(
            (error) => debugPrint('Playback error: $error'),
          ),
        );
      }
      for (final stream in <Stream<Object?>>[
        decoder.stream.position,
        decoder.stream.playing,
        decoder.stream.duration,
        decoder.stream.completed,
        decoder.stream.videoParams,
      ]) {
        subscriptions.add(
          stream.listen((_) {
            if (!mounted || closing) return;
            final params = decoder.state.videoParams;
            final geometry =
                VideoGeometry.fromMetadata(
                  width: params.dw,
                  height: params.dh,
                  rotation: params.rotate ?? 0,
                ) ??
                VideoGeometry.fromMetadata(
                  width: params.w,
                  height: params.h,
                  rotation: params.rotate ?? 0,
                  pixelAspect: params.par ?? 1,
                );
            if (geometry != null) {
              _geometry = geometry;
              if (_windowAspect != geometry.aspectRatio) {
                unawaited(
                  syncWindowAspect(
                    geometry.aspectRatio,
                  ).catchError((Object _) {}),
                );
              }
            }
            setState(() {});
          }),
        );
      }
      video = VideoController(
        decoder,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: supportsNativeHardwareRendering,
          hwdec: preferences.hardwareAcceleration
              ? playbackDecoderMode(
                  defaultTargetPlatform,
                  compatible: preferences.decoderCompatibility,
                )
              : 'no',
        ),
      );
      setState(() {});
      await video!.platform.future;
      if (!mounted || closing) return;
      await decoder.setRate(preferences.rate);
      if (!mounted || closing) return;
      await decoder.setVolume(preferences.volume);
      if (!mounted || closing) return;
      await decoder.open(Media(data.str('url')), play: false);
      if (!mounted || closing) return;
      final start = data.integer('positionMs');
      if (start > 0) await decoder.seek(Duration(milliseconds: start));
      if (!mounted || closing) return;
      await decoder.play();
      if (!mounted || closing) return;
      await report(ready: true);
      if (!mounted || closing) return;
      heartbeat = Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(report()),
      );
    } catch (failure, stack) {
      if (Platform.environment['ASTERLINK_MACOS_SMOKE'] == '1') {
        debugPrint(
          'Independent playback initialization failed: $failure\n$stack',
        );
      }
      if (mounted && !closing) setState(() => error = '小窗播放失败，请关闭后重新打开');
    }
  }

  Future<void> syncWindowAspect(double aspect) => _windowGate.run(() async {
    if (!mounted || closing || _windowAspect == aspect) return;
    await windowManager.setMinimumSize(desktopPipMinimumSize(aspect));
    if (!mounted || closing) return;
    await windowManager.setAspectRatio(aspect);
    if (!mounted || closing) return;
    await windowManager.setSize(desktopPipWindowSize(aspect));
    _windowAspect = aspect;
  });

  Future<void> report({bool ready = false}) async {
    if (reporting || player == null) return;
    reporting = true;
    try {
      final state = player!.state;
      await request('POST', {
        'ready': ready,
        'positionMs': state.position.inMilliseconds,
        'durationMs': state.duration.inMilliseconds,
        'completed': state.completed,
      });
    } catch (_) {
      if (!closing && !ready) await closeWindow();
    } finally {
      reporting = false;
    }
  }

  Future<void> closeWindow() async {
    if (closing) return;
    closing = true;
    heartbeat?.cancel();
    try {
      try {
        await player?.pause();
      } catch (_) {}
      if (!reporting) await report();
      await _windowGate.run(() async {});
      await disposePlayer();
    } finally {
      client.close(force: true);
      windowManager.removeListener(this);
      await windowManager.destroy();
    }
  }

  @override
  void onWindowClose() => unawaited(closeWindow());
  Future<void> disposePlayer() => _playerDisposal ??= () async {
    await Future.wait(subscriptions.map((s) => s.cancel()));
    await player?.dispose();
  }();
  @override
  void dispose() {
    closing = true;
    heartbeat?.cancel();
    windowManager.removeListener(this);
    client.close(force: true);
    unawaited(disposePlayer());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final decoder = player;
    final state = decoder?.state;
    return Scaffold(
      backgroundColor: Colors.black,
      body: DesktopPipSurface(
        video: error.isNotEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(error),
                ),
              )
            : video == null
            ? const Center(child: CircularProgressIndicator())
            : Video(
                controller: video!,
                controls: NoVideoControls,
                fit: BoxFit.contain,
                aspectRatio: _geometry?.aspectRatio,
                pauseUponEnteringBackgroundMode: false,
                resumeUponEnteringForegroundMode: false,
              ),
        playing: state?.playing ?? false,
        position: state?.position ?? Duration.zero,
        duration: state?.duration ?? Duration.zero,
        onToggle: () =>
            unawaited(decoder?.playOrPause() ?? Future<void>.value()),
        onSeek: (position) =>
            unawaited(decoder?.seek(position) ?? Future<void>.value()),
        onDrag: () => unawaited(windowManager.startDragging()),
        onResize: (edge) => unawaited(windowManager.startResizing(edge)),
        onPin: () async =>
            windowManager.setAlwaysOnTop(!await windowManager.isAlwaysOnTop()),
        onClose: () => unawaited(closeWindow()),
      ),
    );
  }
}
