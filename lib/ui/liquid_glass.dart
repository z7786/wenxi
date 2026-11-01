import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../domain/appearance.dart';
import 'app_theme.dart';

const liquidGlassShaderAsset = 'assets/shaders/liquid_glass.frag';
Future<ui.FragmentProgram>? _glassProgram;

/// A live backdrop lens adapted from Kyant's AndroidLiquidGlass (Backdrop).
/// Each surface owns its shader; only the compiled program is shared. There
/// are no screen captures or continuous animation tickers in the material.
class LiquidGlassSurface extends StatefulWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(32)),
    this.tint,
    this.opacity,
    this.blurSigma,
    this.refractionHeight = 24,
    this.refractionAmount = 24,
    this.dispersion = 0,
    this.depth = 0,
    this.saturation = 1.12,
    this.highlight = 1,
    this.shadow = 1,
    this.enabled = true,
    this.lightPosition,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? tint;
  final double? opacity, blurSigma;
  final double refractionHeight, refractionAmount, dispersion, depth;
  final double saturation, highlight, shadow;
  final bool enabled;
  final ValueListenable<Offset?>? lightPosition;

  @override
  State<LiquidGlassSurface> createState() => _LiquidGlassSurfaceState();
}

class _LiquidGlassSurfaceState extends State<LiquidGlassSurface> {
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    unawaited(_loadShader());
  }

  Future<void> _loadShader() async {
    if (!ui.ImageFilter.isShaderFilterSupported) return;
    try {
      final program = await (_glassProgram ??= ui.FragmentProgram.fromAsset(
        liquidGlassShaderAsset,
      ));
      if (mounted) setState(() => _shader = program.fragmentShader());
    } catch (_) {
      // Skia and older GPUs keep the same controls, with blur and edge light.
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = AppAppearance.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final opaque =
        !widget.enabled ||
        MediaQuery.highContrastOf(context) ||
        appearance.glassStyle == GlassStyle.solid;
    final tint = (widget.tint ?? appearance.glassColor).withValues(
      alpha: opaque ? 1 : widget.opacity ?? appearance.glassOpacity,
    );
    final sigma = opaque ? 0.0 : widget.blurSigma ?? appearance.blurSigma;
    final radius = widget.borderRadius;
    final decoration = BoxDecoration(
      borderRadius: radius,
      color: tint,
      boxShadow: [
        if (!opaque && widget.shadow > 0)
          BoxShadow(
            color: Colors.black.withValues(
              alpha: (dark ? .22 : .10) * widget.shadow.clamp(0.0, 1.0),
            ),
            blurRadius: 12,
            offset: const Offset(0, 3),
            blurStyle: BlurStyle.outer,
          ),
      ],
    );
    return DecoratedBox(
      // The shadow stays outside the clip; the tint belongs after the filter.
      decoration: decoration.copyWith(color: Colors.transparent),
      child: ClipRRect(
        borderRadius: radius,
        child: CustomPaint(
          foregroundPainter: opaque || widget.highlight <= 0
              ? null
              : _GlassEdgePainter(
                  radius,
                  dark,
                  widget.highlight,
                  widget.lightPosition,
                ),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    ui.ImageFilter filter = ui.ImageFilter.blur(
                      sigmaX: sigma,
                      sigmaY: sigma,
                    );
                    final shader = _shader;
                    final refract =
                        !opaque &&
                        appearance.glassStyle == GlassStyle.clear &&
                        widget.refractionHeight > 0 &&
                        widget.refractionAmount > 0 &&
                        shader != null &&
                        constraints.hasBoundedWidth &&
                        constraints.hasBoundedHeight;
                    if (refract) {
                      final shortest = math.max(
                        1.0,
                        math.min(constraints.maxWidth, constraints.maxHeight),
                      );
                      shader
                        ..setFloat(2, radius.topLeft.x / shortest)
                        ..setFloat(3, widget.refractionHeight / shortest)
                        ..setFloat(4, widget.refractionAmount / shortest)
                        ..setFloat(5, widget.depth)
                        ..setFloat(6, widget.dispersion)
                        ..setFloat(7, widget.saturation);
                      filter = sigma > 0
                          ? ui.ImageFilter.compose(
                              outer: ui.ImageFilter.shader(shader),
                              inner: filter,
                            )
                          : ui.ImageFilter.shader(shader);
                    }
                    return BackdropFilter(
                      enabled: !opaque && (sigma > 0 || refract),
                      filter: filter,
                      child: DecoratedBox(
                        decoration: decoration.copyWith(boxShadow: const []),
                        child: const SizedBox.expand(),
                      ),
                    );
                  },
                ),
              ),
              widget.child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Retains FilledButton's focus, semantics, disabled behavior and tap target.
/// The material alone changes; callers retain their existing callbacks/styles.
class LiquidGlassButton extends StatefulWidget {
  const LiquidGlassButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
    this.tonal = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;
  final bool tonal;

  @override
  State<LiquidGlassButton> createState() => _LiquidGlassButtonState();
}

class _LiquidGlassButtonState extends State<LiquidGlassButton> {
  final _states = WidgetStatesController();
  final _touch = ValueNotifier<Offset?>(null);
  bool _updateScheduled = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    // FilledButton updates its disabled state while its child is rebuilding.
    // Defer only that notification; pointer events still update this frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_updateScheduled) return;
      _updateScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateScheduled = false;
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _states
      ..removeListener(_changed)
      ..dispose();
    _touch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final appearance = AppAppearance.of(context);
    final enabled = widget.onPressed != null;
    final states = _states.value;
    final pressed = states.contains(WidgetState.pressed);
    final solid =
        !enabled ||
        MediaQuery.highContrastOf(context) ||
        appearance.glassStyle == GlassStyle.solid;
    final tint =
        widget.style?.backgroundColor?.resolve(states) ??
        (enabled
            ? widget.tonal
                  ? colors.primaryContainer
                  : colors.primary
            : Color.alphaBlend(
                colors.onSurface.withValues(alpha: .12),
                colors.surface,
              ));
    final foreground =
        widget.style?.foregroundColor?.resolve(states) ??
        (enabled
            ? widget.tonal
                  ? colors.onPrimaryContainer
                  : colors.onPrimary
            : colors.onSurface.withValues(alpha: .38));
    final shape = widget.style?.shape?.resolve(states);
    final radius = shape is RoundedRectangleBorder
        ? shape.borderRadius.resolve(Directionality.of(context))
        : const BorderRadius.all(Radius.circular(48));
    final style = (widget.style ?? const ButtonStyle()).copyWith(
      backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
      foregroundColor: WidgetStatePropertyAll(foreground),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shadowColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: radius),
      ),
      splashFactory: NoSplash.splashFactory,
      backgroundBuilder: (context, states, child) => Stack(
        // Keep the button's constraints on its padded, aligned content.
        // A loose Stack places short labels at the top left of wide buttons.
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: LiquidGlassSurface(
                borderRadius: radius,
                tint: tint,
                opacity: widget.tonal ? .80 : .94,
                blurSigma: appearance.glassStyle == GlassStyle.frosted ? 12 : 2,
                refractionHeight: 8,
                refractionAmount: 12,
                saturation: 1.03,
                highlight: pressed ? .85 : .45,
                shadow: 0,
                enabled: enabled,
                lightPosition: _touch,
                child: const SizedBox.expand(),
              ),
            ),
          ),
          ?child,
        ],
      ),
    );
    final button = widget.tonal
        ? FilledButton.tonal(
            onPressed: widget.onPressed,
            statesController: _states,
            style: style,
            child: widget.child,
          )
        : FilledButton(
            onPressed: widget.onPressed,
            statesController: _states,
            style: style,
            child: widget.child,
          );
    return Listener(
      onPointerDown: enabled
          ? (event) => _touch.value = event.localPosition
          : null,
      onPointerMove: enabled
          ? (event) => _touch.value = event.localPosition
          : null,
      onPointerUp: (_) => _touch.value = null,
      onPointerCancel: (_) => _touch.value = null,
      child: AnimatedScale(
        scale: pressed && !solid && !MediaQuery.disableAnimationsOf(context)
            ? 1.045
            : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOutBack,
        child: button,
      ),
    );
  }
}

class _GlassEdgePainter extends CustomPainter {
  _GlassEdgePainter(this.radius, this.dark, this.intensity, this.lightPosition)
    : super(repaint: lightPosition);
  final BorderRadius radius;
  final bool dark;
  final double intensity;
  final ValueListenable<Offset?>? lightPosition;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(.6);
    final edge = radius.toRRect(rect);
    final strength = intensity.clamp(0.0, 1.5);
    final bright = Colors.white.withValues(alpha: .55 * strength);
    final dim = Colors.white.withValues(alpha: .10 * strength);
    final shade = Colors.black.withValues(alpha: (dark ? .12 : .10) * strength);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = SweepGradient(
        colors: [bright, dim, shade, bright, dim, shade, bright],
        stops: const [0, .17, .33, .50, .67, .83, 1],
        transform: const GradientRotation(math.pi / 4),
      ).createShader(rect);
    canvas.drawRRect(edge, paint);
    paint
      ..shader = null
      ..strokeWidth = 1
      ..color = Colors.white.withValues(alpha: (dark ? .035 : .10) * strength);
    canvas.drawRRect(radius.toRRect(rect.deflate(1.1)), paint);
    final touch = lightPosition?.value;
    if (touch != null) {
      paint
        ..style = PaintingStyle.fill
        ..shader = ui.Gradient.radial(touch, size.height * 1.2, [
          Colors.white.withValues(alpha: .14 * strength),
          Colors.white.withValues(alpha: 0),
        ]);
      canvas.save();
      canvas.clipRRect(edge);
      canvas.drawRRect(edge, paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_GlassEdgePainter oldDelegate) =>
      radius != oldDelegate.radius ||
      dark != oldDelegate.dark ||
      intensity != oldDelegate.intensity ||
      lightPosition != oldDelegate.lightPosition;
}
