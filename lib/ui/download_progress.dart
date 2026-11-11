import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../domain/downloads.dart';
import '../domain/uploads.dart';
import '../upload/upload_task.dart';
import '../transfer/rapid_transfer_task.dart';

class DownloadProgress extends StatelessWidget {
  const DownloadProgress({
    super.key,
    required this.task,
    this.enabled = true,
    this.compact = false,
  });
  final DownloadTask task;
  final bool enabled, compact;
  @override
  Widget build(BuildContext context) =>
      TransferProgress.download(task, enabled: enabled, compact: compact);
}

enum TransferProgressStatus {
  pending,
  running,
  processing,
  paused,
  failed,
  completed,
}

/// Immutable presentation values also detect changes to mutable upload tasks.
/// Animation never changes the transfer's byte counts.
class TransferProgress extends StatefulWidget {
  const TransferProgress._({
    required this.id,
    required this.total,
    required this.transferred,
    required this.speed,
    required this.status,
    required this.stage,
    required this.direction,
    required this.enabled,
    required this.compact,
    this.processingLabel = '处理中',
  });
  final String id, stage, direction, processingLabel;
  final int total, transferred, speed;
  final TransferProgressStatus status;
  final bool enabled, compact;
  double get progress => total > 0 ? (transferred / total).clamp(0.0, 1.0) : 0;

  factory TransferProgress.download(
    DownloadTask task, {
    bool enabled = true,
    bool compact = false,
  }) {
    final finishing =
        task.status == DownloadStatus.running &&
        (task.payloadReady ||
            const {'等待校验 / 保存', '校验文件', '保存文件'}.contains(task.phase));
    return TransferProgress._(
      id: task.id,
      total: task.total,
      transferred: task.downloaded,
      speed: task.speed,
      enabled: enabled,
      compact: compact,
      direction: 'download',
      stage: task.status.label,
      status: finishing
          ? TransferProgressStatus.processing
          : switch (task.status) {
              DownloadStatus.pending => TransferProgressStatus.pending,
              DownloadStatus.running => TransferProgressStatus.running,
              DownloadStatus.completed => TransferProgressStatus.completed,
              DownloadStatus.failed => TransferProgressStatus.failed,
              _ => TransferProgressStatus.paused,
            },
    );
  }
  factory TransferProgress.upload(
    UploadTask task, {
    bool enabled = true,
    bool compact = false,
  }) => TransferProgress._(
    id: task.id,
    total: task.size,
    transferred: task.status == UploadStatus.completed
        ? task.size
        : task.phase == UploadPhase.preparing && !task.isFolder
        ? 0
        : task.sent,
    speed: task.speed,
    enabled: enabled,
    compact: compact,
    direction: 'upload',
    stage: task.stage,
    processingLabel: task.phase == UploadPhase.preparing
        ? task.isFolder
              ? '准备中'
              : '校验中'
        : '确认中',
    status: switch (task.status) {
      UploadStatus.pending => TransferProgressStatus.pending,
      UploadStatus.running =>
        task.phase == UploadPhase.uploading
            ? TransferProgressStatus.running
            : TransferProgressStatus.processing,
      UploadStatus.completed => TransferProgressStatus.completed,
      UploadStatus.failed => TransferProgressStatus.failed,
      _ => TransferProgressStatus.paused,
    },
  );

  factory TransferProgress.cross(
    RapidTransferTask task, {
    bool enabled = true,
    bool compact = false,
  }) {
    final movingData = task.entries.any(
      (e) =>
          e.status == RapidEntryStatus.downloading ||
          e.status == RapidEntryStatus.uploading,
    );
    // Cross-drive progress includes matching and both relay phases. Use units
    // of work rather than pretend these values are uploaded byte counts.
    final fraction = task.progress;
    final total = fraction == null ? 0 : task.entries.length * 1000000;
    return TransferProgress._(
      id: task.id,
      total: total,
      transferred: ((fraction ?? 0) * total).round(),
      speed: movingData ? task.speed : 0,
      enabled: enabled,
      compact: compact,
      direction: 'cross-transfer',
      stage: task.stage,
      processingLabel: task.scanned ? '匹配中' : '扫描中',
      status: switch (task.status) {
        RapidTaskStatus.pending => TransferProgressStatus.pending,
        RapidTaskStatus.running =>
          movingData
              ? TransferProgressStatus.running
              : TransferProgressStatus.processing,
        RapidTaskStatus.completed =>
          task.canRetry
              ? TransferProgressStatus.failed
              : TransferProgressStatus.completed,
        RapidTaskStatus.failed => TransferProgressStatus.failed,
        _ => TransferProgressStatus.paused,
      },
    );
  }
  factory TransferProgress.crossPhase(
    RapidTransferTask task, {
    required bool upload,
    bool enabled = true,
    bool compact = false,
    List<RapidTransferEntry>? entries,
  }) {
    final relay = (entries ?? task.entries)
        .where(
          (e) =>
              e.method == CrossTransferMethod.relay &&
              e.status != RapidEntryStatus.reused &&
              e.status != RapidEntryStatus.duplicate,
        )
        .toList();
    final total = relay.fold<int>(0, (n, e) => n + e.size);
    final completed =
        relay.isNotEmpty &&
        relay.every(
          (e) => upload
              ? e.status == RapidEntryStatus.uploaded
              : e.payloadReady || e.status == RapidEntryStatus.uploaded,
        );
    final moving = relay.any(
      (e) =>
          e.status ==
          (upload ? RapidEntryStatus.uploading : RapidEntryStatus.downloading),
    );
    final transferred = relay.fold<int>(
      0,
      (n, e) =>
          n +
          (e.status == RapidEntryStatus.uploaded
              ? e.size
              : upload
              ? e.sent.clamp(0, e.size)
              : e.downloaded.clamp(0, e.size)),
    );
    return TransferProgress._(
      id: task.id,
      total: total,
      transferred: transferred,
      speed: moving ? task.speed : 0,
      status: completed
          ? TransferProgressStatus.completed
          : moving && task.active
          ? TransferProgressStatus.running
          : !task.active && task.canRetry
          ? TransferProgressStatus.failed
          : TransferProgressStatus.pending,
      stage: upload ? '上传' : '下载',
      direction: upload ? 'cross-upload' : 'cross-download',
      enabled: enabled,
      compact: compact,
    );
  }
  @override
  State<TransferProgress> createState() => _TransferProgressState();
}

class _TransferProgressState extends State<TransferProgress>
    with TickerProviderStateMixin {
  late final _fill = AnimationController(vsync: this, value: _target);
  late final _light = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2100),
  );
  late final _check = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );
  ScrollPosition? _scroll;
  Timer? _stall, _finish;
  bool _visible = false, _receiving = false, _celebrating = false;
  bool _reduceMotion = false, _tickerEnabled = true;
  bool _visibilityScheduled = false;

  bool get _complete => widget.status == TransferProgressStatus.completed;
  bool get _finishing => widget.status == TransferProgressStatus.processing;
  bool get _canReceive => widget.status == TransferProgressStatus.running;
  bool get _animate =>
      widget.enabled && _visible && _tickerEnabled && !_reduceMotion;
  double get _target => _complete
      ? 1
      : widget.total > 0
      ? widget.progress
      : 0;

  @override
  void initState() {
    super.initState();
    _recordActivity(initial: true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    final scroll = Scrollable.maybeOf(context)?.position;
    if (_scroll != scroll) {
      _scroll?.removeListener(_scheduleVisibility);
      _scroll = scroll;
      _scroll?.addListener(_scheduleVisibility);
    }
    _scheduleVisibility();
    _syncAnimations();
  }

  @override
  void didUpdateWidget(TransferProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    _recordActivity(previous: oldWidget);
    if (_complete && oldWidget.status != TransferProgressStatus.completed) {
      _celebrating = _animate;
      if (_celebrating) {
        _check.forward(from: 0);
        _finish?.cancel();
        _finish = Timer(const Duration(milliseconds: 1100), () {
          if (mounted) setState(() => _celebrating = false);
        });
      }
    } else if (!_complete) {
      _celebrating = false;
      _check.stop();
      _finish?.cancel();
    }
    if (_target !=
        (oldWidget.status == TransferProgressStatus.completed
            ? 1
            : oldWidget.progress)) {
      if (_animate && (_receiving || _complete) && _target > _fill.value) {
        _fill.animateTo(
          _target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      } else {
        _fill.value = _target;
      }
    }
    _syncAnimations();
    _scheduleVisibility();
  }

  void _recordActivity({TransferProgress? previous, bool initial = false}) {
    if (!_canReceive || widget.speed <= 0) {
      _receiving = false;
      _stall?.cancel();
      return;
    }
    if (initial ||
        previous == null ||
        widget.transferred > previous.transferred) {
      _receiving = true;
      _stall?.cancel();
      _stall = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        setState(() => _receiving = false);
        _syncAnimations();
      });
    }
  }

  void _scheduleVisibility() {
    if (_visibilityScheduled) return;
    _visibilityScheduled = true;
    // Scroll notifications precede layout; measure the updated bounds once
    // the current frame has positioned the cached list children.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      _updateVisibility();
    });
  }

  void _updateVisibility() {
    if (!mounted) return;
    final box = context.findRenderObject();
    var visible =
        widget.enabled && box is RenderBox && box.hasSize && box.attached;
    if (visible) {
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport != null) {
        final bounds = MatrixUtils.transformRect(
          box.getTransformTo(viewport),
          Offset.zero & box.size,
        );
        visible = bounds.overlaps(viewport.paintBounds);
      }
    }
    if (_visible != visible) {
      setState(() => _visible = visible);
      _syncAnimations();
    }
  }

  void _syncAnimations() {
    if (_animate && _receiving && _canReceive) {
      if (!_light.isAnimating) _light.repeat();
    } else {
      _light.stop();
      if (!_animate || (!_receiving && !_complete)) _fill.value = _target;
    }
    if (!_animate) {
      _check.stop();
      _celebrating = false;
      _finish?.cancel();
    }
  }

  @override
  void dispose() {
    _scroll?.removeListener(_scheduleVisibility);
    _stall?.cancel();
    _finish?.cancel();
    _fill.dispose();
    _light.dispose();
    _check.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_complete &&
        !_celebrating &&
        widget.direction != 'cross-download' &&
        widget.direction != 'cross-upload') {
      return const SizedBox.shrink();
    }
    final task = widget;
    final failed = task.status == TransferProgressStatus.failed;
    final paused = task.status == TransferProgressStatus.paused;
    final color = _complete
        ? const Color(0xff30b866)
        : failed
        ? const Color(0xffed625a)
        : paused
        ? const Color(0xff98a2b3)
        : task.direction != 'download'
        ? Theme.of(context).colorScheme.secondary
        : Theme.of(context).colorScheme.primary;
    final percent = task.total > 0
        ? '${(task.progress * 100).floor().clamp(0, 99)}%'
        : '大小未知';
    final label = _complete
        ? '已完成'
        : _finishing
        ? task.processingLabel
        : _canReceive && !_receiving
        ? '等待数据'
        : task.status == TransferProgressStatus.pending
        ? '排队中'
        : percent;
    return Semantics(
      label: task.direction == 'cross-transfer'
          ? '跨盘传输进度'
          : task.direction == 'upload' || task.direction == 'cross-upload'
          ? '上传进度'
          : '下载进度',
      value:
          '${task.stage}，${_complete
              ? '100%'
              : task.total > 0
              ? percent
              : '文件大小未知'}${label == '等待数据' ? '，等待数据' : ''}',
      child: Padding(
        padding: EdgeInsets.only(top: task.compact ? 2 : 5),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: task.compact ? 12 : 16),
          child: Row(
            children: [
              Expanded(
                child: RepaintBoundary(
                  child: SizedBox(
                    height: task.compact ? 3 : 5,
                    child: CustomPaint(
                      key: ValueKey(
                        '${task.direction}-progress-paint-${task.id}',
                      ),
                      painter: _ProgressPaint(
                        fill: _fill,
                        light: _light,
                        color: color,
                        track: Theme.of(context).colorScheme.outlineVariant,
                        flowing: _animate && _receiving && _canReceive,
                        unknown: task.total <= 0,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              SizedBox(
                width: task.compact ? 54 : 62,
                child: _complete
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ScaleTransition(
                            scale: _check.drive(
                              CurveTween(curve: Curves.easeOutBack),
                            ),
                            child: Icon(
                              CupertinoIcons.check_mark_circled_solid,
                              color: color,
                              size: 12,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: color,
                                fontSize: task.compact ? 9 : 10,
                              ),
                            ),
                          ),
                        ],
                      )
                    : Text(
                        label,
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: task.compact ? 9 : 10,
                          color: color,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CrossTransferProgress extends StatelessWidget {
  const CrossTransferProgress(
    this.task, {
    super.key,
    this.enabled = true,
    this.compact = false,
    this.entries,
  });
  final RapidTransferTask task;
  final bool enabled, compact;
  final List<RapidTransferEntry>? entries;

  @override
  Widget build(BuildContext context) {
    final relay = (entries ?? task.entries).any(
      (e) =>
          e.method == CrossTransferMethod.relay &&
          e.status != RapidEntryStatus.reused &&
          e.status != RapidEntryStatus.duplicate,
    );
    if (!relay || entries == null && !task.active && !task.canRetry) {
      return TransferProgress.cross(task, enabled: enabled, compact: compact);
    }
    return Column(
      children: [
        for (final upload in [false, true])
          Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 2),
                child: Text(
                  upload ? '上传' : '下载',
                  style: TextStyle(
                    fontSize: compact ? 9 : 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: TransferProgress.crossPhase(
                  task,
                  upload: upload,
                  enabled: enabled,
                  compact: compact,
                  entries: entries,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _ProgressPaint extends CustomPainter {
  _ProgressPaint({
    required this.fill,
    required this.light,
    required this.color,
    required this.track,
    required this.flowing,
    required this.unknown,
  }) : super(repaint: Listenable.merge([fill, light]));
  final Animation<double> fill, light;
  final Color color, track;
  final bool flowing, unknown;
  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final bounds = Offset.zero & size;
    final paint = Paint();
    canvas.drawRRect(
      RRect.fromRectAndRadius(bounds, radius),
      paint..color = track,
    );
    final width = size.width * fill.value.clamp(0, 1);
    final area = Rect.fromLTWH(0, 0, unknown ? size.width : width, size.height);
    if (area.width <= 0) return;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(area, radius));
    if (!unknown) {
      paint.shader = LinearGradient(
        colors: [color.withValues(alpha: .74), color],
      ).createShader(bounds);
      canvas.drawRect(area, paint);
      paint.shader = null;
    }
    if (flowing) {
      final band = size.width * .32;
      final x = (area.width + band * 2) * light.value - band;
      final glow = Rect.fromLTWH(x - band, 0, band * 2, size.height);
      paint.shader = LinearGradient(
        colors: [
          Colors.transparent,
          unknown
              ? color.withValues(alpha: .5)
              : Colors.white.withValues(alpha: .45),
          Colors.transparent,
        ],
      ).createShader(glow);
      canvas.drawRect(glow, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ProgressPaint oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.track != track ||
      oldDelegate.flowing != flowing ||
      oldDelegate.unknown != unknown;
}
