import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../platform/theme_frame.dart';

/// Reveals a theme over the existing navigator without mounting a second app.
class ThemeRevealHost extends StatefulWidget {
  const ThemeRevealHost({super.key, required this.child, this.captureFrame});

  final Widget child;
  final ThemeFrameCapture? captureFrame;

  static Future<void> change(
    BuildContext context, {
    BuildContext? origin,
    bool keepOriginVisible = false,
    required bool dark,
    required Future<void> Function() update,
  }) async {
    final host = context
        .getInheritedWidgetOfExactType<_ThemeRevealScope>()
        ?.host;
    if (host == null) {
      await update();
    } else {
      await host._change(origin ?? context, dark, keepOriginVisible, update);
    }
  }

  @override
  State<ThemeRevealHost> createState() => ThemeRevealHostState();
}

class ThemeRevealHostState extends State<ThemeRevealHost>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const duration = Duration(milliseconds: 560);
  final _content = GlobalKey();
  late final _coverage = AnimationController(
    vsync: this,
    duration: duration,
    animationBehavior: AnimationBehavior.preserve,
  )..addStatusListener(_completed);
  Brightness? _brightness;
  _ThemeSnapshot? _pending, _visible;
  Offset? _origin;
  bool _capturing = false, _foreground = true;
  int _captureGeneration = 0;

  /// The app disables its ordinary color crossfade for a prepared reveal.
  bool get isPrepared => _pending != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _change(
    BuildContext source,
    bool dark,
    bool keepOriginVisible,
    Future<void> Function() update,
  ) async {
    final boundary = _content.currentContext?.findRenderObject();
    final box = source.findRenderObject();
    _ThemeSnapshot? snapshot;
    if (!_capturing &&
        _foreground &&
        _pending == null &&
        (_brightness == Brightness.dark) != dark &&
        boundary is RenderRepaintBoundary &&
        boundary.hasSize &&
        !boundary.size.isEmpty &&
        _canCapture(boundary) &&
        box is RenderBox &&
        box.hasSize) {
      try {
        _capturing = true;
        final generation = _captureGeneration;
        final size = boundary.size;
        final offset = boundary.localToGlobal(Offset.zero);
        final point = boundary.globalToLocal(
          box.localToGlobal(box.size.center(Offset.zero)),
        );
        final origin = _visible != null && _origin != null
            ? _origin!
            : Offset(
                point.dx.clamp(0.0, size.width),
                point.dy.clamp(0.0, size.height),
              );
        final liveOrigin = keepOriginVisible
            ? (Path()
                ..fillType = PathFillType.evenOdd
                ..addRect(Offset.zero & size)
                ..addRRect(
                  RRect.fromRectAndRadius(
                    (boundary.globalToLocal(box.localToGlobal(Offset.zero)) &
                            box.size)
                        .deflate(4),
                    const Radius.circular(16),
                  ),
                ))
            : null;
        // Android's offscreen clip replay can corrupt stencil edges even when
        // the onscreen frame is correct. Copy the displayed surface there.
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final ratio = math.min(
          math.min(devicePixelRatio, 2.0),
          math.sqrt(3000000 / (size.width * size.height)),
        );
        final capture =
            widget.captureFrame ??
            (Platform.isAndroid ? captureAndroidThemeFrame : null);
        final image = capture == null
            ? await boundary.toImage(pixelRatio: ratio)
            : await capture(offset & size, devicePixelRatio, ratio);
        if (image != null &&
            mounted &&
            _foreground &&
            generation == _captureGeneration &&
            boundary.attached &&
            boundary.size == size &&
            boundary.localToGlobal(Offset.zero) == offset) {
          snapshot = _ThemeSnapshot(
            image: image,
            size: size,
            origin: origin,
            dark: dark,
            liveOrigin: liveOrigin,
          );
          _pending = snapshot;
        } else {
          image?.dispose();
        }
      } catch (_) {
        // A missing surface must never prevent saving the user's theme.
      } finally {
        _capturing = false;
      }
    }
    try {
      await update();
      if (snapshot != null && mounted) {
        // Let the committed theme consume the snapshot on its first frame.
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      if (snapshot != null && identical(_pending, snapshot)) {
        _pending = null;
        snapshot.dispose();
      }
    }
  }

  bool _canCapture(RenderRepaintBoundary boundary) {
    var ready = true;
    // debugNeedsPaint throws in profile/release; inspect it only in asserts.
    assert(() {
      ready = ready && !boundary.debugNeedsPaint;
      return true;
    }());
    return ready;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_brightness != brightness) {
      final previous = _brightness;
      _brightness = brightness;
      final pending = _pending;
      if (previous != null &&
          pending != null &&
          pending.dark == (brightness == Brightness.dark) &&
          TickerMode.valuesOf(context).enabled) {
        _pending = null;
        _visible?.dispose();
        _visible = pending;
        _origin = pending.origin;
        _coverage.animateTo(pending.dark ? 1 : 0, curve: Curves.easeInOutCubic);
      } else {
        _clear();
      }
    } else if (!TickerMode.valuesOf(context).enabled && _visible != null) {
      _clear();
    }
  }

  void _completed(AnimationStatus status) {
    if (_visible != null &&
        !_coverage.isAnimating &&
        (_coverage.value == 0 || _coverage.value == 1)) {
      setState(() {
        _visible?.dispose();
        _visible = null;
      });
    }
  }

  void _clear() {
    _captureGeneration++;
    _visible?.dispose();
    _visible = null;
    _pending?.dispose();
    _pending = null;
    _coverage.stop();
    _coverage.value = _brightness == Brightness.dark ? 1 : 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      setState(_clear);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _coverage.dispose();
    _visible?.dispose();
    _pending?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_visible != null && _visible!.size != constraints.biggest) {
        // Finish on resize instead of stretching a stale layout over the app.
        _clear();
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            key: _content,
            // Flatten translucent controls over the same opaque app surface.
            // A transparent snapshot would blend them a second time on replay.
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: _ThemeRevealScope(host: this, child: widget.child),
            ),
          ),
          if (_visible case final snapshot?)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      key: const Key('theme-reveal-overlay'),
                      painter: _ThemeRevealPainter(snapshot, _coverage),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _ThemeRevealScope extends InheritedWidget {
  const _ThemeRevealScope({required this.host, required super.child});

  final ThemeRevealHostState host;

  @override
  bool updateShouldNotify(_ThemeRevealScope oldWidget) => false;
}

class _ThemeSnapshot {
  _ThemeSnapshot({
    required this.image,
    required this.size,
    required this.origin,
    required this.dark,
    required this.liveOrigin,
  });

  final ui.Image image;
  final Size size;
  final Offset origin;
  final bool dark;
  final Path? liveOrigin;
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    image.dispose();
  }
}

class _ThemeRevealPainter extends CustomPainter {
  _ThemeRevealPainter(this.snapshot, this.coverage) : super(repaint: coverage);

  final _ThemeSnapshot snapshot;
  final Animation<double> coverage;

  @override
  void paint(Canvas canvas, Size size) {
    final origin = snapshot.origin;
    final farthest = Offset(
      math.max(origin.dx, size.width - origin.dx),
      math.max(origin.dy, size.height - origin.dy),
    ).distance;
    final radius = (farthest + 1) * coverage.value;
    final bounds = Offset.zero & size;
    final circle = Path()
      ..addOval(Rect.fromCircle(center: origin, radius: radius));
    final clip = snapshot.dark
        ? Path.combine(
            PathOperation.difference,
            Path()..addRect(bounds),
            circle,
          )
        : circle;
    canvas.save();
    canvas.clipRect(bounds);
    canvas.clipPath(clip);
    if (snapshot.liveOrigin case final liveOrigin?) {
      canvas.clipPath(liveOrigin);
    }
    canvas.drawImageRect(
      snapshot.image,
      Rect.fromLTWH(
        0,
        0,
        snapshot.image.width.toDouble(),
        snapshot.image.height.toDouble(),
      ),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ThemeRevealPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot || oldDelegate.coverage != coverage;
}
