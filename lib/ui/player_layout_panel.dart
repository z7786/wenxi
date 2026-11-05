import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../domain/playback.dart';

/// Edits the chrome over the existing video surface without attaching a second
/// video view. Changes remain a draft until the user finishes editing.
class PlayerLayoutEditor extends StatelessWidget {
  const PlayerLayoutEditor({
    super.key,
    required this.preferences,
    required this.onChanged,
    required this.onCancel,
    required this.onDone,
  });
  final PlaybackPreferences preferences;
  final ValueChanged<PlaybackPreferences> onChanged;
  final VoidCallback onCancel, onDone;

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('player-layout-editor'),
    color: const Color(0xff15171c),
    borderRadius: BorderRadius.circular(14),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('播放器布局', style: TextStyle(fontSize: 14)),
                      ),
                      IconButton(
                        key: const Key('player-layout-reset'),
                        tooltip: '恢复默认布局',
                        onPressed: () => onChanged(
                          preferences.withLayout(const PlaybackPreferences()),
                        ),
                        icon: const Icon(Icons.restart_alt, size: 20),
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    '点画面上的勾选框显示或隐藏按钮',
                    style: TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  Row(
                    children: [
                      Text(
                        '${(preferences.controlsScale * 100).round()}%',
                        style: const TextStyle(fontSize: 12),
                      ),
                      Expanded(
                        child: Slider(
                          key: const Key('player-controls-scale'),
                          value: preferences.controlsScale,
                          min: .8,
                          max: 1.4,
                          divisions: 12,
                          label:
                              '控制栏 ${(preferences.controlsScale * 100).round()}%',
                          onChanged: (v) =>
                              onChanged(preferences.copyWith(controlsScale: v)),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final item in [
                        ('auto', '自动'),
                        ('bottom', '底部'),
                        ('side', '侧边'),
                      ])
                        ChoiceChip(
                          label: Text(
                            item.$2,
                            style: const TextStyle(fontSize: 12),
                          ),
                          selected: preferences.panelLayout == item.$1,
                          onSelected: (_) => onChanged(
                            preferences.copyWith(panelLayout: item.$1),
                          ),
                        ),
                    ],
                  ),
                  const Text(
                    '面板位置',
                    style: TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const Key('player-layout-cancel'),
                  onPressed: onCancel,
                  child: const Text('取消', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  key: const Key('player-layout-done'),
                  onPressed: onDone,
                  child: const Text('完成编辑', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class PlayerLayoutToggle extends StatelessWidget {
  const PlayerLayoutToggle({
    super.key,
    required this.label,
    required this.selected,
    required this.onChanged,
    required this.child,
  });
  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    button: true,
    toggled: selected,
    onTap: () => onChanged(!selected),
    excludeSemantics: true,
    child: Tooltip(
      message: '${selected ? '隐藏' : '显示'}$label',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!selected),
        child: CustomPaint(
          foregroundPainter: _ToggleBorder(
            selected,
            Theme.of(context).colorScheme.primary,
          ),
          child: IgnorePointer(
            child: Opacity(opacity: selected ? 1 : .35, child: child),
          ),
        ),
      ),
    ),
  );
}

class _ToggleBorder extends CustomPainter {
  const _ToggleBorder(this.selected, this.accent);
  final bool selected;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..color = Colors.white54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(7)),
      );
    for (final metric in path.computeMetrics()) {
      for (double offset = 0; offset < metric.length; offset += 6) {
        canvas.drawPath(
          metric.extractPath(offset, math.min(offset + 2.5, metric.length)),
          border,
        );
      }
    }
    final center = Offset(size.width - 7, 7);
    canvas.drawCircle(
      center,
      8,
      Paint()..color = selected ? accent : const Color(0xff44464e),
    );
    if (selected) {
      final tick = Path()
        ..moveTo(center.dx - 3.5, center.dy)
        ..lineTo(center.dx - 1, center.dy + 2.5)
        ..lineTo(center.dx + 4, center.dy - 3);
      canvas.drawPath(
        tick,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
    }
  }

  @override
  bool shouldRepaint(_ToggleBorder oldDelegate) =>
      selected != oldDelegate.selected || accent != oldDelegate.accent;
}
