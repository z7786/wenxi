import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/playback.dart';
import '../domain/playback_screen_display.dart';
import '../playback/media_backend.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_screen_info.dart';
import '../playback/playback_screen_speed.dart';
import '../playback/playback_state.dart';
import 'app_switch.dart';

const _screenItemLabels = {
  PlaybackScreenItem.time: ('时间', '当前系统时间'),
  PlaybackScreenItem.network: ('网速', '实际接收速度，本地文件显示“本地播放”'),
  PlaybackScreenItem.resolution: ('分辨率', '当前视频的显示分辨率'),
  PlaybackScreenItem.progress: ('进度', '已播放时间、总时长和百分比'),
  PlaybackScreenItem.title: ('标题', '当前播放文件的名称'),
  PlaybackScreenItem.parameters: ('播放参数', '倍速、解码方式、缓冲和丢帧数'),
  PlaybackScreenItem.media: ('媒体信息', '视频编码、帧率、像素格式及音频规格'),
};

class PlayerScreenDisplayPanel extends StatelessWidget {
  const PlayerScreenDisplayPanel({
    super.key,
    required this.preferences,
    required this.onChanged,
  });
  final PlaybackScreenDisplay preferences;
  final ValueChanged<PlaybackScreenDisplay> onChanged;

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    children: [
      AppSwitchListTile(
        key: const Key('player-screen-enabled'),
        title: const Text('开启屏显'),
        subtitle: const Text('控制栏隐藏后仍显示；选择会自动记住'),
        value: preferences.enabled,
        onChanged: (value) => onChanged(preferences.copyWith(enabled: value)),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(
          '按锁屏时的视频画面固定四角：左上标题，右上时间和网速，左下媒体信息和进度，右下分辨率和播放参数。',
          style: TextStyle(fontSize: 12, color: Colors.white60),
        ),
      ),
      const Divider(height: 1),
      for (final item in PlaybackScreenItem.values)
        AppSwitchListTile(
          key: Key('player-screen-${item.name}'),
          title: Text(_screenItemLabels[item]!.$1),
          subtitle: Text(_screenItemLabels[item]!.$2),
          value: preferences.items.contains(item),
          onChanged: (value) => onChanged(preferences.withItem(item, value)),
        ),
    ],
  );
}

/// Only this small repaint boundary refreshes. No controller listener runs at
/// video frame rate and all playback information comes from cached snapshots.
class PlayerScreenDisplay extends StatefulWidget {
  const PlayerScreenDisplay({
    super.key,
    required this.controller,
    this.television = false,
    this.now = DateTime.now,
    this.insets = EdgeInsets.zero,
  });
  final PlaybackController controller;
  final bool television;
  final DateTime Function() now;
  final EdgeInsets insets;

  @override
  State<PlayerScreenDisplay> createState() => _PlayerScreenDisplayState();
}

class _PlayerScreenDisplayState extends State<PlayerScreenDisplay>
    with WidgetsBindingObserver {
  final _elapsed = Stopwatch()..start();
  final _speed = PlaybackScreenSpeed();
  Timer? _timer;
  PlaybackBackend? _monitored;
  bool _foreground = true;
  List<(String, String)> _lines = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _sample();
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    if (!_foreground) {
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (widget.controller.closed) {
        _timer?.cancel();
        return;
      }
      final previous = _lines;
      _sample();
      if (!_sameLines(previous, _lines)) setState(() {});
    });
  }

  bool _sameLines(List<(String, String)> a, List<(String, String)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void didUpdateWidget(PlayerScreenDisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sample();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      _sample();
      _startTimer();
      if (mounted) setState(() {});
    } else {
      _timer?.cancel();
      _monitored?.setScreenDisplayMonitoringEnabled(false);
      _monitored = null;
    }
  }

  void _sample() {
    final controller = widget.controller;
    final prefs = controller.preferences.screenDisplay;
    final backend = controller.casting || controller.loading
        ? null
        : controller.backend;
    final monitor =
        _foreground && prefs.items.contains(PlaybackScreenItem.network)
        ? backend
        : null;
    if (!identical(_monitored, monitor)) {
      _monitored?.setScreenDisplayMonitoringEnabled(false);
      _monitored = monitor;
      _monitored?.setScreenDisplayMonitoringEnabled(true);
    }
    final info = backend?.screenInfo ?? const PlaybackScreenInfo();
    final speed = prefs.items.contains(PlaybackScreenItem.network)
        ? _speed.sample(backend, info.receivedBytes, _elapsed.elapsed)
        : null;
    final state = controller.state;
    final video = _videoTrack(state);
    final audio = _audioTrack(state);
    final lines = <(String, String)>[];
    bool show(PlaybackScreenItem item) => prefs.items.contains(item);
    if (show(PlaybackScreenItem.title)) {
      lines.add(('title', controller.current.name));
    }
    if (show(PlaybackScreenItem.time)) {
      final now = widget.now();
      String two(int value) => '$value'.padLeft(2, '0');
      lines.add((
        'time',
        '时间 ${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
      ));
    }
    if (show(PlaybackScreenItem.network)) {
      final measured = speed ?? info.bytesPerSecond;
      final label = controller.casting
          ? '电视端播放'
          : controller.loading
          ? '等待连接'
          : info.transport == 'local'
          ? '本地播放'
          : measured != null && measured.isFinite && measured >= 0
          ? '${_bytes(measured)}/s'
          : '待获取';
      lines.add(('network', '网速 $label'));
    }
    if (show(PlaybackScreenItem.resolution)) {
      final geometry = controller.casting || controller.loading
          ? null
          : controller.videoGeometry;
      lines.add((
        'resolution',
        '分辨率 ${!controller.hasVideo
            ? '纯音频'
            : geometry == null
            ? '待获取'
            : '${geometry.width} × ${geometry.height}'}',
      ));
    }
    if (show(PlaybackScreenItem.progress)) {
      final duration = state.duration;
      final position = duration > Duration.zero
          ? clampPlaybackPosition(state.position, duration)
          : state.position;
      final percent = duration > Duration.zero
          ? ' · ${(position.inMilliseconds / duration.inMilliseconds * 100).toStringAsFixed(1)}%'
          : '';
      lines.add((
        'progress',
        '进度 ${playbackTime(position)} / ${duration > Duration.zero ? playbackTime(duration) : '--:--'}$percent',
      ));
    }
    if (show(PlaybackScreenItem.parameters)) {
      final buffer =
          info.bufferSeconds ??
          (state.buffer - state.position).inMilliseconds / 1000;
      final details = [
        '${_number(state.rate)}×',
        if (controller.casting) '电视投屏' else _decoder(controller, info),
      ];
      lines.add(('parameters', '播放 ${details.join(' · ')}'));
      if (!controller.casting && !controller.loading) {
        lines.add((
          'buffer',
          '缓冲 ${buffer.clamp(0, double.infinity).toStringAsFixed(1)} 秒',
        ));
      }
      final dropped = [
        if (!controller.casting && info.decoderDroppedFrames != null)
          '解码丢帧 ${info.decoderDroppedFrames}',
        if (!controller.casting && info.outputDroppedFrames != null)
          '输出丢帧 ${info.outputDroppedFrames}',
      ];
      if (dropped.isNotEmpty) lines.add(('dropped', dropped.join(' · ')));
    }
    if (show(PlaybackScreenItem.media)) {
      if (controller.casting) {
        lines.add(('media', '媒体信息由电视端解码，暂不可获取'));
      } else {
        if (controller.hasVideo) {
          final fps = video?.fps ?? info.videoFps;
          final videoDetails = [
            video?.codec?.toUpperCase() ??
                info.videoCodec?.toUpperCase() ??
                '编码待获取',
            if (fps != null && fps.isFinite && fps > 0) '${_number(fps)} fps',
            ?state.videoParams.pixelformat ?? info.pixelFormat,
            if (video?.bitrate case final bitrate? when bitrate > 0)
              '${_number(bitrate / 1000000)} Mbps',
          ];
          lines.add(('video', '视频 ${videoDetails.join(' · ')}'));
        }
        final params = state.audioParams;
        final sampleRate = params.sampleRate ?? audio?.samplerate;
        final channels = params.channelCount ?? audio?.channelscount;
        final audioDetails = [
          audio?.codec?.toUpperCase() ?? '编码待获取',
          if (sampleRate != null && sampleRate > 0)
            '${_number(sampleRate / 1000)} kHz',
          if (channels != null && channels > 0) '$channels 声道',
          if (state.audioBitrate ?? audio?.bitrate?.toDouble()
              case final bitrate? when bitrate > 0 && bitrate.isFinite)
            '${_number(bitrate / 1000)} kbps',
        ];
        lines.add((
          'audio',
          state.track.audio.id == 'no'
              ? '音频 已关闭'
              : '音频 ${audioDetails.join(' · ')}',
        ));
      }
    }
    _lines = lines;
  }

  VideoTrack? _videoTrack(PlayerState state) {
    if (state.track.video.id == 'no') {
      return null;
    }
    final tracks = state.tracks.video.where(
      (track) =>
          !{'auto', 'no'}.contains(track.id) &&
          track.albumart != true &&
          track.image != true,
    );
    return tracks
            .where((track) => track.id == state.track.video.id)
            .firstOrNull ??
        (state.track.video.id == 'auto'
            ? tracks.where((track) => track.isDefault == true).firstOrNull ??
                  tracks.firstOrNull
            : state.track.video);
  }

  AudioTrack? _audioTrack(PlayerState state) {
    if (state.track.audio.id == 'no') {
      return null;
    }
    final tracks = state.tracks.audio.where(
      (track) => !{'auto', 'no'}.contains(track.id),
    );
    return tracks
            .where((track) => track.id == state.track.audio.id)
            .firstOrNull ??
        (state.track.audio.id == 'auto'
            ? tracks.where((track) => track.isDefault == true).firstOrNull ??
                  tracks.firstOrNull
            : state.track.audio);
  }

  String _decoder(PlaybackController controller, PlaybackScreenInfo info) {
    final hw = info.hardwareDecoder;
    if (controller.loading) return '等待播放';
    if (controller.usingSoftwareDecoder || hw == 'no') return '软件解码';
    if (hw != null && hw.isNotEmpty) return '硬解 $hw';
    return controller.backend?.hardwareDecodingActive == true
        ? '硬件解码'
        : '解码方式待获取';
  }

  String _number(num value) =>
      value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  String _bytes(double value) {
    if (value >= 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    if (value >= 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KB';
    }
    return '${value.round()} B';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _elapsed.stop();
    _monitored?.setScreenDisplayMonitoringEnabled(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      key: const Key('player-screen-display'),
      child: LayoutBuilder(
        builder: (context, box) {
          if (_lines.isEmpty || box.maxHeight <= 0 || box.maxWidth <= 0) {
            return const SizedBox.shrink();
          }
          final bounds = _videoBounds(box.biggest);
          if (bounds.isEmpty) return const SizedBox.shrink();
          final tv = widget.television;
          final horizontal = tv ? (bounds.width * .05).clamp(16.0, 48.0) : 12.0;
          final vertical = tv ? (bounds.height * .05).clamp(12.0, 27.0) : 12.0;
          final usable = math.max(0.0, bounds.width - horizontal * 2);
          final columnWidth = math.max(0.0, (usable - 12) / 2);
          final contentHeight = math.max(
            0.0,
            bounds.height - vertical * 2 - 12,
          );
          final topHeight = contentHeight * .4;
          final bottomHeight = contentHeight * .6;
          return Stack(
            children: [
              Positioned.fromRect(
                rect: bounds,
                child: Stack(
                  key: const Key('player-screen-video-bounds'),
                  children: [
                    _region(
                      context,
                      'top-left',
                      {'title'},
                      left: horizontal,
                      top: vertical,
                      width: math.min(tv ? 440 : 300, columnWidth),
                      height: topHeight,
                    ),
                    _region(
                      context,
                      'top-right',
                      {'time', 'network'},
                      right: horizontal,
                      top: vertical,
                      width: math.min(tv ? 240 : 170, columnWidth),
                      height: topHeight,
                      alignRight: true,
                    ),
                    _region(
                      context,
                      'bottom-left',
                      {'video', 'audio', 'media', 'progress'},
                      left: horizontal,
                      bottom: vertical,
                      width: math.min(tv ? 480 : 340, columnWidth),
                      height: bottomHeight,
                    ),
                    _region(
                      context,
                      'bottom-right',
                      {'resolution', 'parameters', 'buffer', 'dropped'},
                      right: horizontal,
                      bottom: vertical,
                      width: math.min(tv ? 460 : 320, columnWidth),
                      height: bottomHeight,
                      alignRight: true,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  // Use the same geometry, fit and transforms as the video. The four anchors
  // stay fixed when playback controls appear, disappear or become locked.
  Rect _videoBounds(Size viewport) {
    final controller = widget.controller;
    final prefs = controller.preferences;
    var bounds = Offset.zero & viewport;
    final geometry = controller.videoGeometry;
    if (controller.hasVideo && !controller.casting && geometry != null) {
      final aspect = prefs.aspectRatio > 0
          ? prefs.aspectRatio
          : geometry.aspectRatio;
      final fit = switch (prefs.fit) {
        PlaybackFit.contain => BoxFit.contain,
        PlaybackFit.cover => BoxFit.cover,
        PlaybackFit.stretch => BoxFit.fill,
      };
      final fitted = applyBoxFit(fit, Size(aspect, 1), viewport).destination;
      bounds = Rect.fromCenter(
        center:
            viewport.center(Offset.zero) +
            Offset(
              prefs.videoOffsetX * viewport.width / 2,
              prefs.videoOffsetY * viewport.height / 2,
            ),
        width: fitted.width * prefs.videoScale,
        height: fitted.height * prefs.videoScale,
      );
    }
    final insets = widget.insets;
    return bounds.intersect(
      Rect.fromLTRB(
        insets.left,
        insets.top,
        viewport.width - insets.right,
        viewport.height - insets.bottom,
      ),
    );
  }

  Widget _region(
    BuildContext context,
    String id,
    Set<String> fields, {
    double? left,
    double? right,
    double? top,
    double? bottom,
    required double width,
    required double height,
    bool alignRight = false,
  }) {
    final lines = [
      for (final field in fields) ..._lines.where((line) => line.$1 == field),
    ];
    if (lines.isEmpty || width <= 0 || height <= 0) {
      return const SizedBox.shrink();
    }
    final alignment = Alignment(alignRight ? 1 : -1, bottom == null ? -1 : 1);
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      width: width,
      height: height,
      child: Align(
        alignment: alignment,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignment,
          // FittedBox lays out its child without constraints. Constrain the
          // text here so a long decoder or title cannot spill across the video.
          child: Container(
            key: Key('player-screen-region-$id'),
            constraints: BoxConstraints(maxWidth: width),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0x99000000),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: alignRight
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                for (final line in lines)
                  _line(context, line, alignRight: alignRight),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _line(
    BuildContext context,
    (String, String) line, {
    bool alignRight = false,
  }) {
    final (id, text) = line;
    return Text(
      text,
      textAlign: alignRight ? TextAlign.right : TextAlign.left,
      key: Key('player-screen-line-$id'),
      maxLines: id == 'parameters'
          ? 3
          : id == 'video' || id == 'audio' || id == 'title'
          ? 2
          : id == 'progress' || id == 'dropped' || id == 'resolution'
          ? 2
          : 1,
      overflow: TextOverflow.ellipsis,
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
      style: TextStyle(
        color: id == 'title' ? Colors.white : const Color(0xffe4e4e4),
        fontSize: widget.television ? 16 : 11.5,
        height: 1.5,
        fontWeight: id == 'title' ? FontWeight.w600 : FontWeight.w400,
        fontFeatures: const [FontFeature.tabularFigures()],
        shadows: const [
          Shadow(color: Colors.black54, blurRadius: 1, offset: Offset(0, 1)),
        ],
      ),
    );
  }
}
