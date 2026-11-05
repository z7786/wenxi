import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../data/state_store.dart';
import '../playback/floating_playback.dart';
import '../playback/playback_controller.dart';
import '../domain/playback.dart';
import 'subtitle_appearance.dart';
import 'player_theme.dart';

class FloatingPlaybackHost extends StatefulWidget {
  const FloatingPlaybackHost({
    super.key,
    required this.store,
    required this.child,
  });
  final StateStore store;
  final Widget child;
  @override
  State<FloatingPlaybackHost> createState() => _FloatingPlaybackHostState();
}

class _FloatingPlaybackHostState extends State<FloatingPlaybackHost>
    with WidgetsBindingObserver {
  late final manager = FloatingPlaybackManager.of(widget.store);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      for (final session in manager.sessions.where((s) => s.window == null)) {
        unawaited(session.controller.background(pictureInPicture: false));
      }
    } else if (state == AppLifecycleState.resumed) {
      for (final session in manager.sessions.where((s) => s.window == null)) {
        session.controller.foreground();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(manager.close().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    child: AnimatedBuilder(
      animation: manager,
      builder: (_, _) => LayoutBuilder(
        builder: (_, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            for (final session in manager.sessions.where(
              (s) => s.window == null && s.attached,
            ))
              _FloatingVideo(
                key: ValueKey(session.id),
                session: session,
                manager: manager,
                index: manager.sessions.indexOf(session),
                available: constraints.biggest,
              ),
          ],
        ),
      ),
    ),
  );
}

class _FloatingVideo extends StatefulWidget {
  const _FloatingVideo({
    super.key,
    required this.session,
    required this.manager,
    required this.index,
    required this.available,
  });
  final FloatingPlaybackSession session;
  final FloatingPlaybackManager manager;
  final int index;
  final Size available;
  @override
  State<_FloatingVideo> createState() => _FloatingVideoState();
}

class _FloatingVideoState extends State<_FloatingVideo> {
  Offset? offset;
  late final _placementIndex = widget.index;
  double width = 280;
  bool _restoring = false;
  final _navigator = GlobalKey<NavigatorState>();
  Future<void> restore() async {
    if (_restoring || widget.session.closing) return;
    _restoring = true;
    final root = widget.manager.navigatorKey.currentState;
    final controller = widget.session.controller;
    final restorePage = widget.session.restorePage;
    if (root == null || restorePage == null) {
      _restoring = false;
      return;
    }
    widget.manager.restore(widget.session);
    // Remove the old small surface before attaching a full-screen video widget.
    await WidgetsBinding.instance.endOfFrame;
    if (root.mounted && !controller.closed) {
      await root.push(MaterialPageRoute<void>(builder: restorePage));
      await controller.close();
    } else {
      await controller.close();
    }
  }

  void run(Future<void> Function() action) {
    unawaited(action().catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    final available = widget.available;
    final controller = widget.session.controller;
    if (available.width < 160 || available.height < 120) {
      return const SizedBox.shrink();
    }
    final w = width
        .clamp(160.0, math.max(160, available.width - 16))
        .toDouble();
    final ratio = (controller.videoGeometry?.aspectRatio ?? 16 / 9).clamp(
      .5,
      2.4,
    );
    final height = math.min(w / ratio + 80, available.height - 16);
    final position =
        offset ??
        Offset(
          available.width - w - 8,
          math.max(8, available.height - height - 90 - _placementIndex * 30),
        );
    final x = position.dx
        .clamp(0.0, math.max(0, available.width - w))
        .toDouble();
    final y = position.dy
        .clamp(0.0, math.max(0, available.height - height))
        .toDouble();
    return Positioned(
      left: x,
      top: y,
      width: w,
      height: height,
      child: Listener(
        onPointerDown: (_) => widget.manager.raise(widget.session),
        child: Theme(
          data: playerTheme(Theme.of(context)),
          child: Material(
            key: ValueKey('floating-window-${widget.session.id}'),
            color: Colors.black,
            elevation: 12,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(10),
            child: Column(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) =>
                      setState(() => offset = Offset(x, y) + d.delta),
                  child: SizedBox(
                    height: 36,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        Expanded(
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
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          tooltip: '还原播放器',
                          color: Colors.white,
                          icon: const Icon(
                            CupertinoIcons.arrow_up_left_arrow_down_right,
                            size: 17,
                          ),
                          onPressed: () => run(restore),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          tooltip: '关闭小窗',
                          color: Colors.white,
                          icon: const Icon(CupertinoIcons.xmark, size: 17),
                          onPressed: () => run(
                            () => widget.manager.closeSession(widget.session),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: HeroControllerScope.none(
                    child: Navigator(
                      key: _navigator,
                      onGenerateRoute: (_) => PageRouteBuilder<void>(
                        pageBuilder: (_, _, _) =>
                            _FloatingSurface(controller: controller),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 44,
                  child: AnimatedBuilder(
                    animation: controller,
                    builder: (_, _) => Row(
                      children: [
                        IconButton(
                          tooltip: controller.state.playing ? '暂停小窗' : '播放小窗',
                          color: Colors.white,
                          onPressed: () => run(controller.toggle),
                          icon: Icon(
                            controller.state.playing
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            size: 18,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: controller.state.position.inMilliseconds
                                .toDouble()
                                .clamp(
                                  0,
                                  math
                                      .max(
                                        1,
                                        controller
                                            .state
                                            .duration
                                            .inMilliseconds,
                                      )
                                      .toDouble(),
                                ),
                            max: math
                                .max(
                                  1,
                                  controller.state.duration.inMilliseconds,
                                )
                                .toDouble(),
                            onChanged: controller.ready
                                ? (v) => run(
                                    () => controller.seek(
                                      Duration(milliseconds: v.round()),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanUpdate: (d) =>
                              setState(() => width = w + d.delta.dx),
                          child: const SizedBox(
                            width: 30,
                            height: 44,
                            child: Icon(
                              CupertinoIcons.arrow_down_right_arrow_up_left,
                              size: 15,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingSurface extends StatefulWidget {
  const _FloatingSurface({required this.controller});
  final PlaybackController controller;
  @override
  State<_FloatingSurface> createState() => _FloatingSurfaceState();
}

class _FloatingSurfaceState extends State<_FloatingSurface> {
  PlaybackController get controller => widget.controller;
  Timer? _subtitleTimer;
  Object? _subtitleLayout;

  void _syncSubtitles(BoxConstraints box) {
    final backend = controller.backend;
    if (backend == null ||
        !backend.rendersSubtitlesNatively ||
        box.maxHeight <= 0 ||
        !box.biggest.isFinite) {
      return;
    }
    final color = controller.preferences.subtitleBackgroundArgb;
    final layout = (backend, box.biggest, color);
    if (_subtitleLayout == layout) return;
    _subtitleLayout = layout;
    _subtitleTimer?.cancel();
    _subtitleTimer = Timer(const Duration(milliseconds: 32), () {
      _subtitleTimer = null;
      if (!mounted || !identical(backend, controller.backend)) return;
      unawaited(
        backend
            .setSubtitlePresentation(
              size: 12,
              width: box.maxWidth,
              height: box.maxHeight,
              bottom: (6 / box.maxHeight).clamp(0, .6),
              backgroundColor: color,
            )
            .catchError((Object _) {}),
      );
    });
  }

  @override
  void dispose() {
    _subtitleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (_, _) => LayoutBuilder(
      builder: (_, box) {
        _syncSubtitles(box);
        final backend = controller.backend;
        final nativeSubtitles = backend?.buildSubtitleOverlay();
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            Transform.translate(
              offset: Offset(
                controller.preferences.videoOffsetX * box.maxWidth / 2,
                controller.preferences.videoOffsetY * box.maxHeight / 2,
              ),
              child: Transform.scale(
                scale: controller.preferences.videoScale,
                child:
                    controller.backend?.buildVideo(
                      fit: switch (controller.preferences.fit) {
                        PlaybackFit.contain => BoxFit.contain,
                        PlaybackFit.cover => BoxFit.cover,
                        PlaybackFit.stretch => BoxFit.fill,
                      },
                      aspectRatio: controller.preferences.aspectRatio > 0
                          ? controller.preferences.aspectRatio
                          : controller.videoGeometry?.aspectRatio,
                    ) ??
                    const SizedBox.expand(),
              ),
            ),
            if (controller.preferences.subtitles)
              if (nativeSubtitles != null)
                Positioned.fill(child: nativeSubtitles)
              else if ((backend?.rendersSubtitlesNatively != true ||
                      backend?.usesSubtitleOverlay == true) &&
                  controller.state.subtitle.any((line) => line.isNotEmpty))
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: SubtitleCaption(
                      text: controller.state.subtitle
                          .where((line) => line.isNotEmpty)
                          .join('\n'),
                      size: 12,
                      backgroundColor:
                          controller.preferences.subtitleBackgroundArgb,
                    ),
                  ),
                ),
            if (controller.state.buffering)
              const Center(
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (controller.error.isNotEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '播放中断，请还原窗口重试',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
