import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../download/navigation_transfers.dart';
import 'navigation_transfer_icon.dart';
import '../domain/appearance.dart';
import 'app_theme.dart';
import 'liquid_glass.dart';

enum _NavigationGesture { drag, longPress }

class LiquidBottomNavigation extends StatefulWidget {
  const LiquidBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.destinations,
    this.destinationIds,
    this.allowReselect = false,
    this.transfers,
  }) : assert(destinations.length > 1),
       assert(
         destinationIds == null || destinationIds.length == destinations.length,
       ),
       assert(selectedIndex >= 0 && selectedIndex < destinations.length);

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final List<(String, String)> destinations;
  final List<int>? destinationIds;
  final bool allowReselect;
  final ValueListenable<NavigationTransferStatus>? transfers;

  @override
  State<LiquidBottomNavigation> createState() => _LiquidBottomNavigationState();
}

class _LiquidBottomNavigationState extends State<LiquidBottomNavigation>
    with TickerProviderStateMixin {
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );
  late final _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );
  late final _glow = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  late final _dragEmphasis = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 260),
  );
  final _touch = ValueNotifier<Offset?>(null);
  double? _dragIndex;
  _NavigationGesture? _gesture;
  int? _pressedIndex, _pointer;
  bool _cancelled = false, _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _position.value =
          _dragIndex ?? (_pressedIndex ?? widget.selectedIndex).toDouble();
      _press.value = _pressedIndex != null || _dragIndex != null ? 1 : 0;
      _dragEmphasis.value = 0;
    }
  }

  @override
  void didUpdateWidget(LiquidBottomNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex &&
        _pressedIndex == null &&
        _dragIndex == null) {
      _move(widget.selectedIndex.toDouble());
    }
  }

  void _move(double target, {bool following = false}) {
    if (_reduceMotion || following) {
      // Follow the pointer in this frame. Restarting a tween on every move
      // leaves the lens behind the finger, especially on high refresh displays.
      _position.value = target;
    } else {
      final velocity = _position.velocity.clamp(-16.0, 16.0);
      _position.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 550, damping: 38),
          _position.value,
          target,
          velocity,
          tolerance: const Tolerance(distance: .0005, velocity: .005),
        ),
      );
    }
  }

  void _finish({int? target}) {
    setState(() {
      _pressedIndex = null;
      _dragIndex = null;
      _gesture = null;
    });
    if (_reduceMotion) {
      _press.value = 0;
      _glow.value = 0;
      _dragEmphasis.value = 0;
    } else {
      _press.reverse();
      _glow.reverse();
      _dragEmphasis.reverse();
    }
    _move((target ?? widget.selectedIndex).toDouble());
  }

  void _choose(int index) {
    if (_cancelled) return;
    _finish(target: index);
    if (index == widget.selectedIndex && !widget.allowReselect) return;
    final platform = Theme.of(context).platform;
    if (!_reduceMotion &&
        (platform == TargetPlatform.android ||
            platform == TargetPlatform.iOS)) {
      unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
    }
    widget.onSelected(index);
  }

  @override
  void dispose() {
    _position.dispose();
    _press.dispose();
    _glow.dispose();
    _dragEmphasis.dispose();
    _touch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final highContrast = MediaQuery.highContrastOf(context);
    final appearance = AppAppearance.of(context);
    final solid = highContrast || appearance.glassStyle == GlassStyle.solid;
    final glassColor = appearance.glassColor.withValues(
      alpha: solid ? 1 : appearance.glassOpacity,
    );
    final shadowColor = Color.lerp(
      dark ? Colors.black : colors.onSurface,
      colors.primary,
      dark ? .08 : .16,
    )!;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final count = widget.destinations.length;
    final active = themeAccent(context);
    final foreground = highContrast || appearance.glassStyle == GlassStyle.clear
        ? colors.onSurface
        : colors.onSurfaceVariant;
    final height =
        64.0 +
        (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(0.0, 24.0);
    final preview =
        _dragIndex?.round() ?? _pressedIndex ?? widget.selectedIndex;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tabWidth = (constraints.maxWidth - 8) / count;
              double positionAt(Offset point, {bool snap = false}) {
                final physical = snap
                    ? ((point.dx - 4) / tabWidth).floor().toDouble()
                    : (point.dx - 4) / tabWidth - .5;
                final bounded = physical.clamp(0.0, count - 1.0);
                return rtl ? count - 1 - bounded : bounded;
              }

              void track(Offset point) {
                if (_cancelled) return;
                final value = positionAt(point);
                if (_dragIndex?.round() != value.round()) {
                  setState(() => _dragIndex = value);
                } else {
                  _dragIndex = value;
                }
                _touch.value = point;
                _move(value, following: true);
                if (_reduceMotion) {
                  _press.value = 1;
                } else {
                  _press.forward();
                }
              }

              void startTracking(_NavigationGesture gesture, Offset point) {
                if (_cancelled || _pointer == null) return;
                _gesture = gesture;
                track(point);
                if (!_reduceMotion && !solid) _dragEmphasis.forward();
              }

              void finishTracking(_NavigationGesture gesture) {
                if (_gesture != gesture) return;
                final index = _dragIndex?.round();
                if (!_cancelled && index != null) {
                  _choose(index);
                } else {
                  _finish();
                }
              }

              void cancelTracking(_NavigationGesture gesture) {
                // The other recognizer is cancelled when a drag or long press
                // wins. Only the active gesture may roll back its preview.
                if (_gesture == gesture) _finish();
              }

              return MouseRegion(
                onHover: (event) {
                  if (_pointer != null) return;
                  _touch.value = event.localPosition;
                  _glow.animateTo(
                    .55,
                    duration: _reduceMotion ? Duration.zero : null,
                  );
                },
                onExit: (_) {
                  if (_pointer == null) _glow.reverse();
                },
                child: Listener(
                  onPointerDown: (event) {
                    if (_pointer != null ||
                        event.buttons & kPrimaryButton == 0) {
                      return;
                    }
                    _pointer = event.pointer;
                    _cancelled = false;
                    final index = positionAt(
                      event.localPosition,
                      snap: true,
                    ).round();
                    setState(() => _pressedIndex = index);
                    _touch.value = event.localPosition;
                    if (_reduceMotion) {
                      _press.value = 1;
                      _glow.value = 1;
                    } else {
                      _press.forward();
                      _glow.forward();
                    }
                    _move(index.toDouble());
                  },
                  onPointerMove: (event) {
                    if (_pointer == event.pointer) {
                      _touch.value = event.localPosition;
                    }
                  },
                  onPointerUp: (event) {
                    if (_pointer != event.pointer) return;
                    _pointer = null;
                    if (_dragIndex == null) _finish();
                  },
                  onPointerCancel: (event) {
                    if (_pointer != event.pointer) return;
                    _pointer = null;
                    _cancelled = true;
                    _finish();
                  },
                  child: GestureDetector(
                    excludeFromSemantics: true,
                    onHorizontalDragStart: (details) => startTracking(
                      _NavigationGesture.drag,
                      details.localPosition,
                    ),
                    onHorizontalDragUpdate: (details) {
                      if (_gesture == _NavigationGesture.drag) {
                        track(details.localPosition);
                      }
                    },
                    onHorizontalDragEnd: (_) =>
                        finishTracking(_NavigationGesture.drag),
                    onHorizontalDragCancel: () =>
                        cancelTracking(_NavigationGesture.drag),
                    onLongPressStart: (details) => startTracking(
                      _NavigationGesture.longPress,
                      details.localPosition,
                    ),
                    onLongPressMoveUpdate: (details) {
                      if (_gesture == _NavigationGesture.longPress) {
                        track(details.localPosition);
                      }
                    },
                    onLongPressEnd: (_) =>
                        finishTracking(_NavigationGesture.longPress),
                    onLongPressCancel: () =>
                        cancelTracking(_NavigationGesture.longPress),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(height),
                        boxShadow: [
                          BoxShadow(
                            color: shadowColor.withValues(
                              alpha: dark ? .14 : .055,
                            ),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                            blurStyle: BlurStyle.outer,
                          ),
                        ],
                      ),
                      child: SizedBox(
                        height: height,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned.fill(
                              child: AnimatedBuilder(
                                animation: _press,
                                builder: (context, _) => LiquidGlassSurface(
                                  borderRadius: BorderRadius.circular(height),
                                  opacity: solid ? 1 : appearance.glassOpacity,
                                  refractionHeight: 24,
                                  refractionAmount: 24,
                                  highlight: 1 + _press.value * .2,
                                  shadow: 0,
                                  child: DecoratedBox(
                                    key: const Key('floating-navigation'),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(
                                        height,
                                      ),
                                      border: highContrast
                                          ? Border.all(
                                              color: colors.outlineVariant,
                                              width: .8,
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    key: const Key(
                                      'navigation-touch-highlight',
                                    ),
                                    painter: _NavigationHighlightPainter(
                                      _touch,
                                      _glow,
                                      dark,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                children: [
                                  for (var i = 0; i < count; i++)
                                    Expanded(
                                      child: Semantics(
                                        key: ValueKey(
                                          'navigation-${widget.destinationIds?[i] ?? i}',
                                        ),
                                        label: widget.destinations[i].$1,
                                        selected: i == widget.selectedIndex,
                                        button: true,
                                        onTap: () {
                                          _cancelled = false;
                                          _choose(i);
                                        },
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            customBorder: const StadiumBorder(),
                                            excludeFromSemantics: true,
                                            onTap: () {
                                              _cancelled = false;
                                              _choose(i);
                                            },
                                            splashColor: Colors.transparent,
                                            highlightColor: Colors.transparent,
                                            focusColor: active.withValues(
                                              alpha: .14,
                                            ),
                                            child: _NavigationTabContent(
                                              label: widget.destinations[i].$1,
                                              asset: widget.destinations[i].$2,
                                              color: preview == i
                                                  ? active
                                                  : foreground,
                                              selected:
                                                  widget.selectedIndex == i,
                                              pressed:
                                                  (_pressedIndex != null ||
                                                      _dragIndex != null) &&
                                                  preview == i,
                                              transfers:
                                                  widget.destinations[i].$1 ==
                                                      '传输'
                                                  ? widget.transfers
                                                  : null,
                                              transfer:
                                                  widget.destinations[i].$1 ==
                                                  '传输',
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            AnimatedBuilder(
                              animation: Listenable.merge([
                                _position,
                                _press,
                                _dragEmphasis,
                              ]),
                              builder: (context, _) {
                                // Paint the moving lens after the tabs so the
                                // backdrop includes their actual icons/labels.
                                // The optical layer never owns pointer events.
                                final position = _position.value.clamp(
                                  -.035,
                                  count - 1 + .035,
                                );
                                final physical = rtl
                                    ? count - 1 - position
                                    : position;
                                final stretch = _reduceMotion || solid
                                    ? 0.0
                                    : (_position.velocity.abs() * .003).clamp(
                                        0.0,
                                        .055,
                                      );
                                final pressed = _reduceMotion || solid
                                    ? 0.0
                                    : _press.value * .035;
                                final drag = _reduceMotion || solid
                                    ? 0.0
                                    : Curves.easeOutCubic.transform(
                                        _dragEmphasis.value,
                                      );
                                final lensScale = 1 + drag * (78 / 56 - 1);
                                final progress = solid ? 0.0 : _press.value;
                                return Positioned(
                                  left: 4 + physical * tabWidth,
                                  top: 4,
                                  bottom: 4,
                                  width: tabWidth,
                                  child: IgnorePointer(
                                    child: Transform(
                                      key: const Key(
                                        'navigation-lens-transform',
                                      ),
                                      alignment: Alignment.center,
                                      transform: Matrix4.diagonal3Values(
                                        lensScale + pressed + stretch,
                                        lensScale + pressed - stretch * .4,
                                        1,
                                      ),
                                      child: LiquidGlassSurface(
                                        borderRadius: BorderRadius.circular(
                                          height,
                                        ),
                                        tint: solid
                                            ? glassColor
                                            : appearance.lensColor,
                                        opacity: solid
                                            ? 1
                                            : .10 * (1 - progress) +
                                                  .03 * progress,
                                        blurSigma: 0,
                                        refractionHeight: 10 * progress,
                                        refractionAmount: 14 * progress,
                                        dispersion: .20 * progress,
                                        highlight: progress,
                                        shadow: progress * .65,
                                        child: DecoratedBox(
                                          key: const Key('navigation-lens'),
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              height,
                                            ),
                                            color: solid
                                                ? appearance.lensColor
                                                      .withValues(alpha: 1)
                                                : null,
                                            border: highContrast
                                                ? Border.all(
                                                    color: active.withValues(
                                                      alpha: .5,
                                                    ),
                                                    width: .8,
                                                  )
                                                : null,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NavigationTabContent extends StatefulWidget {
  const _NavigationTabContent({
    required this.label,
    required this.asset,
    required this.color,
    required this.selected,
    required this.pressed,
    required this.transfer,
    this.transfers,
  });
  final String label, asset;
  final Color color;
  final bool selected, pressed, transfer;
  final ValueListenable<NavigationTransferStatus>? transfers;
  @override
  State<_NavigationTabContent> createState() => _NavigationTabContentState();
}

class _NavigationTabContentState extends State<_NavigationTabContent>
    with SingleTickerProviderStateMixin {
  late final _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );
  @override
  void didUpdateWidget(_NavigationTabContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected &&
        !oldWidget.selected &&
        !MediaQuery.disableAnimationsOf(context)) {
      _lift.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: widget.color),
      duration: reduce ? Duration.zero : const Duration(milliseconds: 180),
      builder: (context, color, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: widget.pressed && !reduce ? 1.04 : 1,
              duration: reduce
                  ? Duration.zero
                  : const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              child: AnimatedBuilder(
                animation: _lift,
                builder: (context, child) => Transform.translate(
                  offset: Offset(
                    0,
                    reduce ? 0 : -math.sin(_lift.value * math.pi) * 1.8,
                  ),
                  child: child,
                ),
                child: widget.transfer
                    ? NavigationTransferIcon(
                        asset: widget.asset,
                        color: color!,
                        transfers: widget.transfers,
                      )
                    : SvgPicture.asset(
                        widget.asset,
                        width: 25,
                        height: 25,
                        colorFilter: ColorFilter.mode(color!, BlendMode.srcIn),
                        excludeFromSemantics: true,
                      ),
              ),
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationHighlightPainter extends CustomPainter {
  _NavigationHighlightPainter(this.touch, this.visibility, this.dark)
    : super(repaint: Listenable.merge([touch, visibility]));
  final ValueListenable<Offset?> touch;
  final Animation<double> visibility;
  final bool dark;
  @override
  void paint(Canvas canvas, Size size) {
    final point = touch.value;
    if (point == null || visibility.value <= 0) return;
    final shape = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(.5),
      Radius.circular(size.height / 2),
    );
    final highlight = Colors.white.withValues(
      alpha: visibility.value * (dark ? .09 : .26),
    );
    final paint = Paint()
      ..shader = ui.Gradient.radial(point, size.height * 1.45, [
        highlight,
        Colors.white.withValues(alpha: 0),
      ]);
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRRect(shape, paint);
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    canvas.drawRRect(shape, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NavigationHighlightPainter oldDelegate) =>
      oldDelegate.dark != dark ||
      oldDelegate.touch != touch ||
      oldDelegate.visibility != visibility;
}
