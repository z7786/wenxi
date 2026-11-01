import 'dart:async';
import 'package:flutter/material.dart';
import '../core/json.dart';
import '../domain/playback.dart' show playbackTime;
import '../playback/cast/cast_discovery.dart';
import '../playback/playback_controller.dart';

class PlayerCastPanel extends StatefulWidget {
  const PlayerCastPanel({
    super.key,
    required this.controller,
    this.discoveryFactory = CastDiscovery.new,
    required this.onResumeLocal,
  });
  final PlaybackController controller;
  final CastDiscovery Function() discoveryFactory;
  final VoidCallback onResumeLocal;
  @override
  State<PlayerCastPanel> createState() => _PlayerCastPanelState();
}

class _PlayerCastPanelState extends State<PlayerCastPanel> {
  late final discovery = widget.discoveryFactory();
  String error = '';
  bool busy = false;
  double? preview;
  @override
  void initState() {
    super.initState();
    discovery.addListener(_changed);
    widget.controller.addListener(_changed);
    unawaited(discovery.scan());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    discovery.removeListener(_changed);
    widget.controller.removeListener(_changed);
    discovery.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        error = e is AppException ? e.message : '连接或控制电视失败，请确认电视已开启 DLNA 投屏后重试';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller, cast = controller.castSession;
    final active = cast?.connected == true;
    final state = controller.state;
    final max = state.duration.inMilliseconds.toDouble();
    final enabled = active && !busy && !controller.connectingCast;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      children: [
        const Text(
          '手机或电脑与电视连接同一局域网，在电视上打开 DLNA 投屏或媒体接收功能。',
          style: TextStyle(fontSize: 13, color: Colors.white70),
        ),
        const SizedBox(height: 8),
        const Text(
          '投屏期间请保持应用运行。视频格式、内嵌字幕和音轨由电视支持情况决定。',
          style: TextStyle(fontSize: 12, color: Colors.white54),
        ),
        if (cast != null) ...[
          const SizedBox(height: 18),
          Text(
            cast.device.name,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            controller.connectingCast
                ? '正在连接电视…'
                : state.buffering
                ? '电视正在加载视频…'
                : state.completed
                ? '电视播放已结束'
                : state.playing
                ? '正在电视上播放'
                : '电视已暂停或停止',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          if (cast.error.isNotEmpty) _message(cast.error),
          if (cast.warning.isNotEmpty) _message(cast.warning),
          if (active && max > 0) ...[
            Slider(
              value: (preview ?? state.position.inMilliseconds.toDouble())
                  .clamp(0, max),
              min: 0,
              max: max,
              label: playbackTime(
                Duration(
                  milliseconds:
                      (preview ?? state.position.inMilliseconds.toDouble())
                          .round(),
                ),
              ),
              onChanged: enabled && cast.seekSupported
                  ? (value) => setState(() => preview = value)
                  : null,
              onChangeEnd: enabled && cast.seekSupported
                  ? (value) {
                      setState(() => preview = null);
                      unawaited(
                        _run(
                          () => controller.seek(
                            Duration(milliseconds: value.round()),
                          ),
                        ),
                      );
                    }
                  : null,
            ),
            Text(
              '${playbackTime(state.position)} / ${playbackTime(state.duration)}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
          if (active) ...[
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: enabled
                      ? () => _run(() => controller.skip(-15))
                      : null,
                  icon: const Icon(Icons.fast_rewind),
                  label: const Text('后退 15 秒'),
                ),
                TextButton.icon(
                  onPressed: enabled ? () => _run(controller.toggle) : null,
                  icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                  label: Text(state.playing ? '暂停' : '播放'),
                ),
                TextButton.icon(
                  onPressed: enabled
                      ? () => _run(() => controller.skip(15))
                      : null,
                  icon: const Icon(Icons.fast_forward),
                  label: const Text('前进 15 秒'),
                ),
              ],
            ),
            if (cast.volumeSupported)
              Row(
                children: [
                  const Icon(Icons.volume_up_outlined, size: 20),
                  Expanded(
                    child: Text(
                      '电视音量 ${state.volume.round()}%',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    tooltip: '减小电视音量',
                    onPressed: enabled
                        ? () =>
                              _run(() => controller.setVolume(state.volume - 5))
                        : null,
                    icon: const Icon(Icons.remove),
                  ),
                  IconButton(
                    tooltip: '增大电视音量',
                    onPressed: enabled
                        ? () =>
                              _run(() => controller.setVolume(state.volume + 5))
                        : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('cast-resume-local'),
              onPressed: busy ? null : widget.onResumeLocal,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('返回本机播放'),
            ),
          ],
          TextButton(
            key: const Key('cast-disconnect'),
            onPressed: controller.connectingCast
                ? () => controller.disconnectCast()
                : () => _run(controller.disconnectCast),
            child: Text(controller.connectingCast ? '取消连接' : '结束投屏'),
          ),
          const Divider(height: 24),
        ],
        if (error.isNotEmpty) _message(error),
        Row(
          children: [
            const Expanded(
              child: Text(
                '选择电视',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              key: const Key('cast-refresh'),
              onPressed: discovery.scanning ? null : () => discovery.scan(),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(discovery.scanning ? '搜索中' : '重新搜索'),
            ),
          ],
        ),
        if (discovery.scanning) const LinearProgressIndicator(minHeight: 2),
        if (discovery.error.isNotEmpty) _message(discovery.error),
        for (final device in discovery.devices)
          ListTile(
            key: ValueKey('cast-device-${device.id}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              cast?.device.id == device.id ? Icons.cast_connected : Icons.tv,
            ),
            title: Text(device.name),
            subtitle: Text(
              [
                if (device.model.isNotEmpty) device.model,
                device.description.host,
              ].join(' · '),
            ),
            trailing: cast?.device.id == device.id
                ? const Icon(Icons.check, size: 20)
                : null,
            enabled: !busy && !controller.connectingCast && !controller.loading,
            onTap: () => _run(() => controller.castTo(device)),
          ),
        if (discovery.devices.isEmpty && !discovery.scanning)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '未找到电视。请打开电视的投屏接收界面，确认未使用访客 Wi-Fi，并检查路由器的设备隔离设置。电脑端还需允许应用通过专用网络防火墙。',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _message(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      text,
      style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
    ),
  );
}
