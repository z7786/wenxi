import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Native sizing keeps the video aspect ratio and follows Windows cursors.
class PipResizeHandles extends StatelessWidget {
  const PipResizeHandles({
    super.key,
    required this.onResize,
    this.showIndicator = true,
  });
  final void Function(ResizeEdge) onResize;
  final bool showIndicator;

  @override
  Widget build(BuildContext context) =>
      Stack(children: [for (final edge in ResizeEdge.values) _handle(edge)]);

  Widget _handle(ResizeEdge edge) {
    final top = {
      ResizeEdge.top,
      ResizeEdge.topLeft,
      ResizeEdge.topRight,
    }.contains(edge);
    final bottom = {
      ResizeEdge.bottom,
      ResizeEdge.bottomLeft,
      ResizeEdge.bottomRight,
    }.contains(edge);
    final left = {
      ResizeEdge.left,
      ResizeEdge.topLeft,
      ResizeEdge.bottomLeft,
    }.contains(edge);
    final right = {
      ResizeEdge.right,
      ResizeEdge.topRight,
      ResizeEdge.bottomRight,
    }.contains(edge);
    final corner = (top || bottom) && (left || right);
    return Positioned(
      top: top
          ? 0
          : bottom
          ? null
          : 18,
      bottom: bottom
          ? 0
          : top
          ? null
          : 18,
      left: left
          ? 0
          : right
          ? null
          : 18,
      right: right
          ? 0
          : left
          ? null
          : 18,
      width: corner
          ? 18
          : left || right
          ? 6
          : null,
      height: corner
          ? 18
          : top || bottom
          ? 6
          : null,
      child: MouseRegion(
        cursor: corner
            ? top == left
                  ? SystemMouseCursors.resizeUpLeftDownRight
                  : SystemMouseCursors.resizeUpRightDownLeft
            : top || bottom
            ? SystemMouseCursors.resizeUpDown
            : SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          key: ValueKey('pip-resize-${edge.name}'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => onResize(edge),
          child: showIndicator && edge == ResizeEdge.bottomRight
              ? const Tooltip(
                  message: '拖动边缘或角落调整大小',
                  child: Icon(
                    Icons.south_east,
                    size: 13,
                    color: Colors.white54,
                  ),
                )
              : const SizedBox.expand(),
        ),
      ),
    );
  }
}
