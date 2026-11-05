import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'pip_resize_handles.dart';

/// Controls overlay the full video viewport and disappear when left idle.
class DesktopPipSurface extends StatefulWidget {
  const DesktopPipSurface({
    super.key,
    required this.video,
    required this.playing,
    required this.position,
    required this.duration,
    required this.onToggle,
    required this.onSeek,
    required this.onDrag,
    required this.onResize,
    required this.onClose,
    this.onRestore,
    this.onPin,
  });
  final Widget video;
  final bool playing;
  final Duration position, duration;
  final VoidCallback onToggle, onDrag, onClose;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<ResizeEdge> onResize;
  final VoidCallback? onRestore, onPin;

  @override
  State<DesktopPipSurface> createState() => _DesktopPipSurfaceState();
}

class _DesktopPipSurfaceState extends State<DesktopPipSurface> {
  Timer? _timer;
  bool _visible = true, _seeking = false;
  double? _preview;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  void _scheduleHide() {
    _timer?.cancel();
    if (_seeking) return;
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _show() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _button(
    String tooltip,
    IconData icon,
    VoidCallback action, {
    Key? key,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    icon: Icon(icon, size: 19),
    color: Colors.white,
    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
    padding: EdgeInsets.zero,
    onPressed: () {
      _show();
      action();
    },
  );

  @override
  Widget build(BuildContext context) {
    final duration = widget.duration.inMilliseconds.toDouble();
    return MediaQuery.withNoTextScaling(
      child: MouseRegion(
        onEnter: (_) => _show(),
        onHover: (_) => _show(),
        child: Listener(
          onPointerDown: (_) => _show(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                key: const Key('desktop-pip-video'),
                child: widget.video,
              ),
              GestureDetector(
                key: const Key('player-pip-drag'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => widget.onDrag(),
                onTap: () {
                  _show();
                  widget.onToggle();
                },
                onDoubleTap: widget.onRestore,
                child: const SizedBox.expand(),
              ),
              if (_visible) ...[
                Positioned(
                  top: 6,
                  right: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.onPin case final pin?)
                          _button('置顶', CupertinoIcons.pin, pin),
                        if (widget.onRestore case final restore?)
                          _button(
                            '还原窗口',
                            CupertinoIcons.arrow_up_left_arrow_down_right,
                            restore,
                          ),
                        _button('关闭画中画', CupertinoIcons.xmark, widget.onClose),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: ColoredBox(
                    color: Colors.black54,
                    child: SizedBox(
                      height: 40,
                      child: Row(
                        children: [
                          _button(
                            widget.playing ? '暂停' : '播放',
                            widget.playing
                                ? CupertinoIcons.pause_fill
                                : CupertinoIcons.play_fill,
                            widget.onToggle,
                            key: const Key('player-pip-toggle'),
                          ),
                          Expanded(
                            child: Slider(
                              key: const Key('player-pip-seek'),
                              value:
                                  (_preview ??
                                          widget.position.inMilliseconds
                                              .toDouble())
                                      .clamp(0, duration > 0 ? duration : 1),
                              max: duration > 0 ? duration : 1,
                              onChangeStart: duration > 0
                                  ? (_) {
                                      _seeking = true;
                                      _timer?.cancel();
                                    }
                                  : null,
                              onChanged: duration > 0
                                  ? (value) => setState(() => _preview = value)
                                  : null,
                              onChangeEnd: duration > 0
                                  ? (value) {
                                      setState(() {
                                        _seeking = false;
                                        _preview = null;
                                      });
                                      widget.onSeek(
                                        Duration(milliseconds: value.round()),
                                      );
                                      _scheduleHide();
                                    }
                                  : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              Positioned.fill(
                child: PipResizeHandles(
                  onResize: widget.onResize,
                  showIndicator: _visible,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
