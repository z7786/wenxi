import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../download/navigation_transfers.dart';

/// Only this icon listens to queue progress; pages and glass layers stay out of
/// the transfer notification path.
class NavigationTransferIcon extends StatefulWidget {
  const NavigationTransferIcon({
    super.key,
    required this.asset,
    required this.color,
    this.size = 25,
    this.transfers,
  });
  final String asset;
  final Color color;
  final double size;
  final ValueListenable<NavigationTransferStatus>? transfers;

  @override
  State<NavigationTransferIcon> createState() => _NavigationTransferIconState();
}

class _NavigationTransferIconState extends State<NavigationTransferIcon>
    with SingleTickerProviderStateMixin {
  late final _completion = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 1300),
    animationBehavior: AnimationBehavior.preserve,
  );
  int _lastCompletion = 0;
  NavigationTransferStatus get _status =>
      widget.transfers?.value ?? const NavigationTransferStatus();

  @override
  void initState() {
    super.initState();
    _lastCompletion = _status.completion;
    widget.transfers?.addListener(_changed);
  }

  @override
  void didUpdateWidget(NavigationTransferIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transfers != widget.transfers) {
      oldWidget.transfers?.removeListener(_changed);
      _lastCompletion = _status.completion;
      _completion.value = 1;
      widget.transfers?.addListener(_changed);
    }
  }

  void _changed() {
    final status = _status;
    if (status.active > 0) {
      _completion.value = 1;
    } else if (status.completion > _lastCompletion) {
      _completion.forward(from: 0);
    }
    _lastCompletion = status.completion;
    setState(() {});
  }

  @override
  void dispose() {
    widget.transfers?.removeListener(_changed);
    _completion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    final success = dark ? const Color(0xff76d9a5) : const Color(0xff16834a);
    return AnimatedBuilder(
      animation: _completion,
      builder: (context, _) {
        final status = _status;
        final completed = status.active == 0 && _completion.value < 1;
        final pulse = completed && !reduceMotion
            ? math.sin(math.pi * (_completion.value / .3).clamp(0, 1))
            : 0.0;
        return Semantics(
          value: completed ? '本次传输已完成' : status.description,
          child: SizedBox.square(
            dimension: widget.size,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (status.active > 0 || completed)
                  Positioned(
                    left: -4,
                    top: -4,
                    width: widget.size + 8,
                    height: widget.size + 8,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(
                        end: completed
                            ? 1
                            : status.progress < 0
                            ? -1
                            : status.progress / 100,
                      ),
                      duration: reduceMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      builder: (context, progress, _) => CustomPaint(
                        key: const Key('navigation-transfer-progress'),
                        painter: _TransferRingPainter(
                          progress: progress,
                          color: completed ? success : accent,
                          track: accent.withValues(alpha: dark ? .18 : .12),
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Transform.scale(
                    scale: 1 + pulse * .07,
                    child: completed
                        ? Icon(
                            CupertinoIcons.check_mark,
                            key: const Key('navigation-transfer-complete'),
                            size: widget.size - 2,
                            color: success,
                          )
                        : SvgPicture.asset(
                            widget.asset,
                            width: widget.size,
                            height: widget.size,
                            colorFilter: ColorFilter.mode(
                              widget.color,
                              BlendMode.srcIn,
                            ),
                            excludeFromSemantics: true,
                          ),
                  ),
                ),
                if (status.active > 0)
                  Positioned(
                    right: -9,
                    top: -7,
                    child: ExcludeSemantics(
                      child: Container(
                        key: const Key('navigation-transfer-count'),
                        height: 16,
                        constraints: const BoxConstraints(minWidth: 16),
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: Text(
                            status.active > 99 ? '99+' : '${status.active}',
                            textAlign: TextAlign.center,
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 11,
                              height: 1,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TransferRingPainter extends CustomPainter {
  const _TransferRingPainter({
    required this.progress,
    required this.color,
    required this.track,
  });
  final double progress;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawOval(rect, paint);
    paint.color = color;
    // Unknown-length/preparing tasks use a quiet arc, not an endless ticker.
    final fraction = progress < 0 ? .22 : progress.clamp(.012, 1.0);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * fraction, false, paint);
  }

  @override
  bool shouldRepaint(_TransferRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.track != track;
}
