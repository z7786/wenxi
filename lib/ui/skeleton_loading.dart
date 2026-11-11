import 'dart:math' as math;

import 'package:flutter/material.dart';

enum SkeletonLayout {
  fileList,
  fileGrid,
  searchResults,
  recommendations,
  resourceCatalog,
}

/// A single sweep crosses all placeholders; ticks only repaint this canvas.
class AppSkeleton extends StatefulWidget {
  const AppSkeleton({
    super.key,
    required this.layout,
    this.itemCount = 6,
    this.showSelection = false,
    this.wide,
    this.active = true,
    this.semanticLabel = '正在加载',
  }) : assert(itemCount > 0);

  final SkeletonLayout layout;
  final int itemCount;
  final bool showSelection, active;
  final bool? wide;
  final String semanticLabel;

  @override
  State<AppSkeleton> createState() => _AppSkeletonState();
}

class _AppSkeletonState extends State<AppSkeleton>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
    animationBehavior: AnimationBehavior.preserve,
  );
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _updateAnimation();
  }

  @override
  void didUpdateWidget(AppSkeleton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAnimation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _updateAnimation();

  void _updateAnimation() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (widget.active &&
        _visible &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      if (!_sweep.isAnimating) _sweep.repeat();
    } else {
      _sweep.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final metrics = _SkeletonMetrics(
      widget.layout,
      MediaQuery.textScalerOf(context),
      widget.showSelection,
      widget.wide,
    );
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: LayoutBuilder(
              builder: (context, bounds) {
                final width = bounds.hasBoundedWidth ? bounds.maxWidth : 360.0;
                final height = bounds.hasBoundedHeight
                    ? bounds.maxHeight
                    : metrics.heightFor(width, widget.itemCount);
                return SizedBox(
                  width: width,
                  height: height,
                  child: CustomPaint(
                    painter: _SkeletonPainter(
                      sweep: _sweep,
                      metrics: metrics,
                      base: dark
                          ? const Color(0xff363940)
                          : const Color(0xffe3e5e8),
                      surface: theme.colorScheme.surface,
                      outline: dark
                          ? const Color(0xff41444b)
                          : const Color(0xffe9ebee),
                      light: Colors.white.withValues(alpha: dark ? .16 : .6),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SkeletonMetrics {
  const _SkeletonMetrics(
    this.layout,
    this.scaler,
    this.showSelection,
    this.wide,
  );

  final SkeletonLayout layout;
  final TextScaler scaler;
  final bool showSelection;
  final bool? wide;
  bool isWide(double width) => wide ?? width >= 800;

  double get title => scaler.scale(14);
  double get detail => scaler.scale(11);
  bool get large => title > 23;
  double get fileRowHeight => math.max(76, title * 1.35 + detail * 2.6 + 26);
  double resultHeight(double width) {
    if (large) return math.max(270, title * 5 + detail * 3 + 80);
    if (isWide(width)) return math.max(124, title * 2 + detail * 3 + 63);
    return math.max(width < 378 ? 198 : 174, title * 3 + detail * 3 + 99);
  }

  double get recommendationHeight => math.max(158, title * 3 + detail * 3 + 50);

  int columns(double width) => switch (layout) {
    SkeletonLayout.fileGrid => ((width - 20) / 180).round().clamp(1, 8),
    SkeletonLayout.recommendations => width >= 640 && !large ? 2 : 1,
    _ => 1,
  };

  double fileCardHeight(double width) {
    final count = columns(width);
    final cardWidth = (width - 32 - (count - 1) * 12) / count;
    return math.max(0, cardWidth - 16) * .72 +
        title * 1.35 * 2 +
        detail * 1.3 * 3 +
        34;
  }

  double heightFor(double width, int count) => switch (layout) {
    SkeletonLayout.fileList => fileRowHeight * count,
    SkeletonLayout.fileGrid =>
      (count / columns(width)).ceil() * (fileCardHeight(width) + 12) + 10,
    SkeletonLayout.searchResults => count * (resultHeight(width) + 12),
    SkeletonLayout.recommendations =>
      (count / columns(width)).ceil() * (recommendationHeight + 12),
    SkeletonLayout.resourceCatalog => catalogHeight(width),
  };

  double catalogHeight(double width) {
    final popularColumns = isWide(width) ? 4 : 2;
    final categoryColumns = isWide(width)
        ? 6
        : title / 14 > 1.6
        ? 2
        : 3;
    final popularWidth = (width - (popularColumns - 1) * 12) / popularColumns;
    final categoryWidth =
        (width - (categoryColumns - 1) * 12) / categoryColumns;
    final scale = math.max(1.0, title / 14);
    return 56 +
        popularWidth / 1.85 +
        68 * scale +
        56 +
        (categoryWidth + 48 * scale + 12) * 2;
  }
}

class _SkeletonPainter extends CustomPainter {
  _SkeletonPainter({
    required this.sweep,
    required this.metrics,
    required this.base,
    required this.surface,
    required this.outline,
    required this.light,
  }) : super(repaint: sweep);

  final Animation<double> sweep;
  final _SkeletonMetrics metrics;
  final Color base, surface, outline, light;
  final _blocks = Path();
  final _cards = <RRect>[];
  Size? _cachedSize;

  void _block(
    double x,
    double y,
    double width,
    double height, [
    double radius = 4,
  ]) {
    if (width <= 0 || height <= 0) return;
    _blocks.addRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, width, height),
        Radius.circular(radius),
      ),
    );
  }

  void _line(
    double x,
    double y,
    double available,
    double fraction,
    double height,
  ) => _block(x, y, available * fraction, height, height / 3);

  void _card(double x, double y, double width, double height, double radius) {
    _cards.add(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, width, height),
        Radius.circular(radius),
      ),
    );
  }

  void _fileRows(Size size) {
    final rowHeight = metrics.fileRowHeight;
    final selection = metrics.showSelection ? 40.0 : 0.0;
    for (var index = 0; index * rowHeight < size.height; index++) {
      final y = index * rowHeight;
      if (selection > 0) _block(28, y + 27, 18, 18, 4);
      _block(16 + selection, y + 15, 44, 44, 8);
      final x = 76 + selection;
      final available = math.max(0.0, size.width - x - 48);
      _line(x, y + 17, available, _nameWidths[index % 5], metrics.title);
      _line(x, y + 23 + metrics.title, available, .42, metrics.detail);
      _line(
        x,
        y + 28 + metrics.title + metrics.detail,
        available,
        .58,
        metrics.detail * .75,
      );
      _block(size.width - 32, y + 32, 16, 4, 2);
    }
  }

  void _fileGrid(Size size) {
    final columns = metrics.columns(size.width);
    final width = (size.width - 32 - (columns - 1) * 12) / columns;
    final height = metrics.fileCardHeight(size.width);
    final media = math.max(0.0, width - 16) * .72;
    for (var row = 0; 2 + row * (height + 12) < size.height; row++) {
      final y = 2 + row * (height + 12);
      for (var column = 0; column < columns; column++) {
        final x = 16 + column * (width + 12);
        _card(x, y, width, height, 14);
        _block(x + 8, y + 8, width - 16, media, 10);
        final textY = y + media + 16;
        _line(x + 8, textY, width - 16, .86, metrics.title);
        _line(
          x + 8,
          textY + metrics.title * 1.35,
          width - 16,
          .62,
          metrics.title,
        );
        _line(
          x + 8,
          textY + metrics.title * 2.7 + 4,
          width - 16,
          .38,
          metrics.detail,
        );
        _line(
          x + 8,
          textY + metrics.title * 2.7 + metrics.detail * 1.3 + 8,
          width - 16,
          .7,
          metrics.detail,
        );
      }
    }
  }

  void _searchResults(Size size) {
    final height = metrics.resultHeight(size.width);
    final inline = metrics.isWide(size.width) && !metrics.large;
    final stacked = size.width < 378 || metrics.large;
    for (var row = 0; row * (height + 12) < size.height; row++) {
      final y = row * (height + 12);
      final available = math.max(0.0, size.width - (inline ? 198 : 32));
      _card(0, y, size.width, height, 16);
      _block(16, y + 13, 20, 20, 5);
      _line(43, y + 18, available * .45, .3, metrics.detail);
      _block(size.width - (inline ? 288 : 126), y + 13, 98, 24, 7);
      _line(16, y + 44, available, _nameWidths[row % 5], metrics.title);
      if (!inline) {
        _line(16, y + 49 + metrics.title, available, .6, metrics.title);
      }
      _line(
        16,
        y + (inline ? 58 + metrics.title : 63 + metrics.title * 2),
        available,
        .9,
        metrics.detail,
      );
      if (metrics.large) {
        _line(
          16,
          y + 73 + metrics.title * 2 + metrics.detail,
          available,
          .65,
          metrics.detail,
        );
      }
      final metaY =
          y +
          height -
          (stacked && !inline
              ? 67
              : inline
              ? 23
              : 34);
      _line(16, metaY, available, .3, metrics.detail * .8);
      _line(16 + available * .35, metaY, available, .28, metrics.detail * .8);
      final actionY = inline ? y + (height - 40) / 2 : y + height - 50;
      _block(size.width - 103, actionY, 91, 40, 10);
      _block(size.width - 139, actionY + 12, 16, 16, 4);
    }
  }

  void _results(Size size, {bool recommendations = false}) {
    final columns = recommendations ? metrics.columns(size.width) : 1;
    final gap = recommendations ? 12.0 : 10.0;
    final width = (size.width - (columns - 1) * 12) / columns;
    final height = recommendations
        ? metrics.recommendationHeight
        : metrics.resultHeight(size.width);
    final iconWidth = recommendations
        ? 48.0
        : metrics.isWide(size.width)
        ? 66.0
        : 54.0;
    final iconHeight = recommendations
        ? 48.0
        : metrics.isWide(size.width)
        ? 78.0
        : 68.0;
    for (var row = 0; row * (height + gap) < size.height; row++) {
      final y = row * (height + gap);
      for (var column = 0; column < columns; column++) {
        final left = column * (width + 12);
        _card(left, y, width, height, recommendations ? 14 : 16);
        if (!metrics.large) {
          _block(left + 15, y + 16, iconWidth, iconHeight, 13);
        }
        final x = left + 15 + (metrics.large ? 0 : iconWidth + 13);
        final available = math.max(0.0, left + width - 15 - x);
        _line(x, y + 18, available, _nameWidths[row % 5], metrics.title);
        _line(x, y + 24 + metrics.title, available, .65, metrics.title);
        _line(x, y + 34 + metrics.title * 2, available, .88, metrics.detail);
        final badgeY = y + 44 + metrics.title * 2 + metrics.detail;
        _block(x, badgeY, math.min(66, available * .35), 17, 6);
        _block(
          x + available * .42,
          badgeY + 3,
          available * .4,
          metrics.detail * .8,
        );
        _block(left + width - 79, y + height - 39, 64, 26, 13);
        if (!recommendations) {
          _block(left + width - 111, y + height - 32, 16, 16, 4);
        }
      }
    }
  }

  void _catalog(Size size) {
    final width = size.width;
    final scale = math.max(1.0, metrics.title / 14);
    final popularColumns = metrics.isWide(width) ? 4 : 2;
    final categoryColumns = metrics.isWide(width)
        ? 6
        : metrics.title / 14 > 1.6
        ? 2
        : 3;
    final popularWidth = (width - (popularColumns - 1) * 12) / popularColumns;
    final categoryWidth =
        (width - (categoryColumns - 1) * 12) / categoryColumns;
    _block(0, 24, math.min(112, width * .4), 19, 5);
    _block(math.max(0, width - 48), 27, 48, 12);
    final coverY = 56.0;
    final coverHeight = popularWidth / 1.85;
    for (var column = 0; column < popularColumns; column++) {
      final x = column * (popularWidth + 12);
      _block(x, coverY, popularWidth, coverHeight, 12);
      _line(x, coverY + coverHeight + 10, popularWidth, .86, metrics.title);
      _line(
        x,
        coverY + coverHeight + 15 + metrics.title,
        popularWidth,
        .5,
        metrics.detail,
      );
    }
    final headingY = coverY + coverHeight + 68 * scale + 24;
    _block(0, headingY, math.min(96, width * .35), 19, 5);
    final categoryY = headingY + 32;
    final cardHeight = categoryWidth + 48 * scale;
    for (var row = 0; row < 2; row++) {
      final y = categoryY + row * (cardHeight + 12);
      for (var column = 0; column < categoryColumns; column++) {
        final x = column * (categoryWidth + 12);
        _block(x, y, categoryWidth, categoryWidth, 12);
        _line(x, y + categoryWidth + 10, categoryWidth, .9, metrics.title);
        _line(
          x,
          y + categoryWidth + 15 + metrics.title,
          categoryWidth,
          .55,
          metrics.detail,
        );
      }
    }
  }

  static const _nameWidths = [.78, .56, .9, .64, .82];

  void _layout(Size size) {
    if (_cachedSize == size) return;
    _cachedSize = size;
    _blocks.reset();
    _cards.clear();
    switch (metrics.layout) {
      case SkeletonLayout.fileList:
        _fileRows(size);
      case SkeletonLayout.fileGrid:
        _fileGrid(size);
      case SkeletonLayout.searchResults:
        _searchResults(size);
      case SkeletonLayout.recommendations:
        _results(size, recommendations: true);
      case SkeletonLayout.resourceCatalog:
        _catalog(size);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _layout(size);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final cardPaint = Paint()..color = surface;
    final borderPaint = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = .6;
    for (final card in _cards) {
      canvas.drawRRect(card, cardPaint);
      canvas.drawRRect(card, borderPaint);
    }
    canvas.drawPath(_blocks, Paint()..color = base);
    final bandWidth = (size.width * .4).clamp(100.0, 280.0);
    final left = -bandWidth + (size.width + bandWidth) * sweep.value;
    final band = Rect.fromLTWH(left, 0, bandWidth, size.height);
    canvas.clipPath(_blocks);
    canvas.drawRect(
      band,
      Paint()
        ..shader = LinearGradient(
          colors: [
            light.withValues(alpha: 0),
            light,
            light.withValues(alpha: 0),
          ],
          stops: const [0, .5, 1],
        ).createShader(band),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SkeletonPainter oldDelegate) =>
      sweep != oldDelegate.sweep ||
      metrics.layout != oldDelegate.metrics.layout ||
      metrics.scaler != oldDelegate.metrics.scaler ||
      metrics.showSelection != oldDelegate.metrics.showSelection ||
      metrics.wide != oldDelegate.metrics.wide ||
      base != oldDelegate.base ||
      surface != oldDelegate.surface ||
      outline != oldDelegate.outline ||
      light != oldDelegate.light;
}
