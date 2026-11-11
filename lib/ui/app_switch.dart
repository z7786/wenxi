import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A controlled toggle: only the parent's value commits a settings change.
class AppSwitch extends StatefulWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
    this.focusable = true,
    this.materialTapTargetSize,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  final FocusNode? focusNode;
  final bool autofocus, focusable;
  final MaterialTapTargetSize? materialTapTargetSize;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch>
    with SingleTickerProviderStateMixin {
  static const _travel = 20.0;
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 360),
    animationBehavior: AnimationBehavior.preserve,
    value: 1,
  );
  late double _from = widget.value ? 1 : 0;
  late double _to = _from;
  double _fromWidth = 1, _fromHeight = 1;
  double? _dragPosition;
  double _dragWidth = 1;
  bool _focused = false, _hovered = false, _visible = true;
  bool get _enabled => widget.onChanged != null;

  _SwitchFrame _frame() {
    if (_dragPosition case final position?) {
      return _SwitchFrame(position, _dragWidth, 1);
    }
    final t = _motion.value;
    if (t == 1) return _SwitchFrame(_to, 1, 1);
    final travelTime = (t / .72).clamp(0.0, 1.0);
    final distance = (_to - _from).abs();
    if (t <= .72) {
      final position = lerpDouble(
        _from,
        _to,
        Curves.easeInOutCubic.transform(travelTime),
      )!;
      final stretch = math.sin(math.pi * travelTime) * .46 * distance;
      return _SwitchFrame(
        position,
        lerpDouble(_fromWidth, 1, travelTime)! + stretch,
        lerpDouble(_fromHeight, 1, travelTime)!,
      );
    }
    // Return to a circle on arrival, then settle with a small damped bounce.
    final settle = (t - .72) / .28;
    final bounce = math.sin(settle * math.pi * 2) * math.pow(1 - settle, 2);
    final width = 1 + bounce * .055 * distance;
    return _SwitchFrame(_to + (_to - _from) * bounce * .065, width, 1 / width);
  }

  void _animateTo(bool value) {
    final frame = _frame();
    _motion.stop();
    _dragPosition = null;
    _from = frame.position;
    _fromWidth = frame.width;
    _fromHeight = frame.height;
    _to = value ? 1 : 0;
    if (!_visible || (_from == _to && _fromWidth == 1 && _fromHeight == 1)) {
      _motion.value = 1;
    } else {
      _motion.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    if (!_visible) {
      _dragPosition = null;
      _motion.stop();
      _to = widget.value ? 1 : 0;
      _motion.value = 1;
    }
  }

  @override
  void didUpdateWidget(AppSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value || !_enabled && _dragPosition != null) {
      _animateTo(widget.value);
    }
  }

  void _toggle() {
    if (_enabled) widget.onChanged!(!widget.value);
  }

  void _startDrag(DragStartDetails details) {
    if (!_enabled) return;
    final frame = _frame();
    _motion.stop();
    setState(() {
      _dragPosition = frame.position.clamp(0.0, 1.0);
      _dragWidth = frame.width;
    });
  }

  void _updateDrag(DragUpdateDetails details) {
    if (!_enabled || _dragPosition == null) return;
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    setState(() {
      _dragPosition = (_dragPosition! + details.delta.dx * direction / _travel)
          .clamp(0.0, 1.0);
      _dragWidth = 1.3;
    });
  }

  void _endDrag(DragEndDetails details) {
    if (_dragPosition == null) return;
    final direction = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    final velocity = details.velocity.pixelsPerSecond.dx * direction;
    final target = velocity.abs() >= 250 ? velocity > 0 : _dragPosition! > .5;
    setState(() => _animateTo(widget.value));
    if (_enabled && target != widget.value) widget.onChanged!(target);
  }

  void _cancelDrag() {
    if (_dragPosition != null) setState(() => _animateTo(widget.value));
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final switchTheme = SwitchTheme.of(context);
    final colors = theme.colorScheme;
    Set<WidgetState> states(bool selected) => {
      if (selected) WidgetState.selected,
      if (!_enabled) WidgetState.disabled,
      if (_focused) WidgetState.focused,
      if (_hovered) WidgetState.hovered,
    };
    Color disabled(Color color) =>
        _enabled ? color : Color.lerp(color, colors.surface, .55)!;
    final off = states(false), on = states(true);
    final height =
        (widget.materialTapTargetSize ??
                switchTheme.materialTapTargetSize ??
                theme.materialTapTargetSize) ==
            MaterialTapTargetSize.shrinkWrap
        ? 40.0
        : 48.0;
    return Semantics(
      label: widget.semanticLabel,
      toggled: widget.value,
      enabled: _enabled,
      onTap: _enabled ? _toggle : null,
      child: FocusableActionDetector(
        enabled: _enabled && widget.focusable,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        mouseCursor: _enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focused = value),
        onShowHoverHighlight: (value) => setState(() => _hovered = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          excludeFromSemantics: true,
          onTap: _enabled ? _toggle : null,
          onHorizontalDragStart: _enabled ? _startDrag : null,
          onHorizontalDragUpdate: _enabled ? _updateDrag : null,
          onHorizontalDragEnd: _enabled ? _endDrag : null,
          onHorizontalDragCancel: _enabled ? _cancelDrag : null,
          child: RepaintBoundary(
            child: SizedBox(
              width: 60,
              height: height,
              child: CustomPaint(
                painter: _SwitchPainter(
                  motion: _motion,
                  frame: _frame,
                  rtl: Directionality.of(context) == TextDirection.rtl,
                  inactiveTrack:
                      switchTheme.trackColor?.resolve(off) ??
                      disabled(colors.surfaceContainerHighest),
                  activeTrack:
                      switchTheme.trackColor?.resolve(on) ??
                      disabled(colors.primary),
                  inactiveThumb:
                      switchTheme.thumbColor?.resolve(off) ??
                      disabled(Colors.white),
                  activeThumb:
                      switchTheme.thumbColor?.resolve(on) ??
                      disabled(Colors.white),
                  inactiveOutline:
                      switchTheme.trackOutlineColor?.resolve(off) ??
                      colors.outline.withValues(alpha: _enabled ? .2 : .1),
                  activeOutline:
                      switchTheme.trackOutlineColor?.resolve(on) ??
                      Colors.transparent,
                  highlight: _enabled && (_focused || _hovered)
                      ? colors.primary.withValues(alpha: _focused ? .22 : .08)
                      : Colors.transparent,
                  focused: _enabled && _focused,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchFrame {
  const _SwitchFrame(this.position, this.width, this.height);
  final double position, width, height;
}

class _SwitchPainter extends CustomPainter {
  _SwitchPainter({
    required this.motion,
    required this.frame,
    required this.rtl,
    required this.inactiveTrack,
    required this.activeTrack,
    required this.inactiveThumb,
    required this.activeThumb,
    required this.inactiveOutline,
    required this.activeOutline,
    required this.highlight,
    required this.focused,
  }) : super(repaint: motion);

  final Animation<double> motion;
  final _SwitchFrame Function() frame;
  final bool rtl, focused;
  final Color inactiveTrack, activeTrack, inactiveThumb, activeThumb;
  final Color inactiveOutline, activeOutline, highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final pose = frame();
    final colorT = pose.position.clamp(0.0, 1.0);
    final track = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 52,
      height: 32,
    );
    if (highlight.a > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(track.inflate(3), const Radius.circular(19)),
        Paint()
          ..color = highlight
          ..style = focused ? PaintingStyle.stroke : PaintingStyle.fill
          ..strokeWidth = 1.5,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, const Radius.circular(16)),
      Paint()..color = Color.lerp(inactiveTrack, activeTrack, colorT)!,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, const Radius.circular(16)),
      Paint()
        ..color = Color.lerp(inactiveOutline, activeOutline, colorT)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    final position = rtl ? 1 - pose.position : pose.position;
    final thumb = Rect.fromCenter(
      center: Offset(track.left + 16 + 20 * position, track.center.dy),
      width: 26 * pose.width,
      height: 26 * pose.height,
    );
    final radius = Radius.circular(thumb.shortestSide / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumb.shift(const Offset(0, 1)), radius),
      Paint()..color = Colors.black.withValues(alpha: .1),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumb, radius),
      Paint()..color = Color.lerp(inactiveThumb, activeThumb, colorT)!,
    );
  }

  @override
  bool shouldRepaint(_SwitchPainter oldDelegate) => true;
}

class AppSwitchListTile extends StatelessWidget {
  const AppSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
    this.contentPadding,
    this.controlAffinity,
    this.dense,
    this.selected = false,
    this.autofocus = false,
    this.focusNode,
    this.controlKey,
  });

  final bool value, selected, autofocus;
  final ValueChanged<bool>? onChanged;
  final Widget? title, subtitle, secondary;
  final EdgeInsetsGeometry? contentPadding;
  final ListTileControlAffinity? controlAffinity;
  final bool? dense;
  final FocusNode? focusNode;
  final Key? controlKey;

  @override
  Widget build(BuildContext context) {
    final leading =
        (controlAffinity ?? ListTileTheme.of(context).controlAffinity) ==
        ListTileControlAffinity.leading;
    final control = AppSwitch(
      key: controlKey,
      value: value,
      onChanged: onChanged,
      focusable: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return MergeSemantics(
      child: ListTile(
        leading: leading ? control : secondary,
        trailing: leading ? secondary : control,
        title: title,
        subtitle: subtitle,
        contentPadding: contentPadding,
        dense: dense,
        enabled: onChanged != null,
        selected: selected,
        autofocus: autofocus,
        focusNode: focusNode,
        internalAddSemanticForOnTap: false,
        onTap: onChanged == null ? null : () => onChanged!(!value),
      ),
    );
  }
}
