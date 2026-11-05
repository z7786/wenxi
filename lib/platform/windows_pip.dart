import 'dart:math' as math;
import 'dart:ui';
import 'package:window_manager/window_manager.dart';
import '../core/json.dart';

const appWindowMinimumSize = Size(720, 520);

Size desktopPipWindowSize(double aspectRatio) {
  final ratio = aspectRatio.isFinite && aspectRatio > 0
      ? aspectRatio.clamp(.25, 4).toDouble()
      : 16 / 9;
  final width = math.min(ratio < 1 ? 270.0 : 480.0, 540 * ratio);
  return Size(width, width / ratio);
}

Size desktopPipMinimumSize(double aspectRatio) {
  final size = desktopPipWindowSize(aspectRatio);
  return Size(math.min(240, size.width), math.min(135, size.height));
}

class _WindowSnapshot {
  _WindowSnapshot({
    required this.fullscreen,
    required this.maximized,
    required this.alwaysOnTop,
    required this.maximizable,
    required this.resizable,
    required this.bounds,
  });
  final bool fullscreen, alwaysOnTop, maximizable, resizable;
  bool maximized;
  Rect bounds;
}

/// Reuses the existing player window so decoding and download leases continue.
/// Geometry and window flags are restored before returning to the main app.
class WindowsPipWindow {
  final _gate = AsyncGate();
  _WindowSnapshot? _previous;
  bool _active = false;
  double _aspectRatio = 16 / 9;
  bool get active => _active;

  void videoSize(int? width, int? height) {
    if (width != null && height != null && width > 0 && height > 0) {
      _aspectRatio = (width / height).clamp(.5, 2.4).toDouble();
    }
  }

  Future<bool> enter() => _gate.run(() async {
    if (_active) return true;
    if (_previous != null) await _restore();
    final previous = _WindowSnapshot(
      fullscreen: await windowManager.isFullScreen(),
      maximized: await windowManager.isMaximized(),
      alwaysOnTop: await windowManager.isAlwaysOnTop(),
      maximizable: await windowManager.isMaximizable(),
      resizable: await windowManager.isResizable(),
      bounds: await windowManager.getBounds(),
    );
    _previous = previous;
    try {
      if (previous.fullscreen) await windowManager.setFullScreen(false);
      if (await windowManager.isMaximized()) {
        previous.maximized = true;
        await windowManager.unmaximize();
      }
      // After unmaximizing, these are the user's normal window bounds.
      previous.bounds = await windowManager.getBounds();
      await windowManager.setMinimumSize(desktopPipMinimumSize(_aspectRatio));
      await windowManager.setAsFrameless();
      await windowManager.setMaximizable(false);
      await windowManager.setResizable(true);
      await windowManager.setAspectRatio(_aspectRatio);
      final availableWidth = math.max(240.0, previous.bounds.width - 32);
      final availableHeight = math.max(160.0, previous.bounds.height - 32);
      final width = math.min(
        _aspectRatio < 1 ? 270.0 : 480.0,
        math.min(availableWidth, availableHeight * _aspectRatio),
      );
      final height = width / _aspectRatio;
      await windowManager.setBounds(
        Rect.fromLTWH(
          previous.bounds.right - width - 16,
          previous.bounds.bottom - height - 16,
          width,
          height,
        ),
      );
      await windowManager.setAlwaysOnTop(true);
      await windowManager.show();
      await windowManager.focus();
      _active = true;
      return true;
    } catch (_) {
      await _restore();
      rethrow;
    }
  });

  Future<void> exit() => _gate.run(_restore);

  Future<void> _restore() async {
    final previous = _previous;
    if (previous == null) return;
    // Continue restoring other flags even if one native operation fails.
    Object? failure;
    for (final restore in <Future<void> Function()>[
      () => windowManager.setFullScreen(false),
      () => windowManager.setAspectRatio(0),
      () => windowManager.setTitleBarStyle(TitleBarStyle.normal),
      () => windowManager.setMaximizable(previous.maximizable),
      () => windowManager.setMinimumSize(appWindowMinimumSize),
      () => windowManager.setBounds(previous.bounds),
      () => windowManager.setResizable(previous.resizable),
      () => windowManager.setAlwaysOnTop(previous.alwaysOnTop),
      if (previous.maximized) () => windowManager.maximize(),
      if (previous.fullscreen) () => windowManager.setFullScreen(true),
    ]) {
      try {
        await restore();
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) throw failure;
    _previous = null;
    _active = false;
  }

  Future<void> drag() async {
    if (_active) await windowManager.startDragging();
  }

  Future<void> resize(ResizeEdge edge) async {
    if (_active) await windowManager.startResizing(edge);
  }
}
