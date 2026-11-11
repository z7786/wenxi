import 'dart:async';
import 'package:flutter/material.dart';
import '../domain/github_acceleration.dart';
import '../core/json.dart';
import '../playback/windows_player_components.dart';

class PlayerComponentsPage extends StatefulWidget {
  const PlayerComponentsPage({super.key, this.components, this.acceleration});
  final WindowsPlayerComponents? components;
  final GitHubAcceleration Function()? acceleration;
  @override
  State<PlayerComponentsPage> createState() => _PlayerComponentsPageState();
}

class _PlayerComponentsPageState extends State<PlayerComponentsPage> {
  late final components = widget.components ?? WindowsPlayerComponents.shared;
  bool _changing = false;
  @override
  void initState() {
    super.initState();
    if (!components.ready) unawaited(components.refresh());
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_changing) return;
    setState(() => _changing = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error is AppException ? error.message : '操作未能完成，请重试'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _remove() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除完整组件？'),
        content: const Text('释放约 117 MiB 空间，仍可使用精简版播放。以后可再次下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _run(components.remove);
  }

  String get _stageLabel => switch (components.stage) {
    PlayerComponentStage.downloading =>
      '正在下载 ${(components.progress * 100).toStringAsFixed(0)}% · '
          '${(components.receivedBytes / (1024 * 1024)).toStringAsFixed(1)} / '
          '${(components.artifact.archiveBytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
    PlayerComponentStage.verifying => '正在校验下载内容…',
    PlayerComponentStage.extracting => '正在安装完整组件…',
    PlayerComponentStage.idle => '',
  };

  Widget _option(
    WindowsPlayerVariant variant,
    String title,
    String description,
  ) {
    final selected = components.selected == variant;
    final enabled =
        components.ready &&
        !components.busy &&
        !_changing &&
        (variant == WindowsPlayerVariant.compact || components.installed);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        selected: selected,
        button: true,
        child: ListTile(
          key: ValueKey('player-component-${variant.name}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 12,
          ),
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            color: selected ? Theme.of(context).colorScheme.primary : null,
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(description, style: const TextStyle(height: 1.6)),
          ),
          onTap: enabled ? () => _run(() => components.select(variant)) : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('播放器组件')),
    body: AnimatedBuilder(
      animation: components,
      builder: (context, _) => Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 680,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (!components.supported)
                const Text('当前平台使用随软件提供的播放器，完整组件下载目前支持 Windows x64。')
              else ...[
                Text(
                  '当前使用：${components.active == WindowsPlayerVariant.full ? '完整版' : '精简版'}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  '按需要选择，下载完成后再启用。切换组件需要完全退出软件并重新打开。',
                  style: TextStyle(height: 1.6),
                ),
                const SizedBox(height: 20),
                _option(
                  WindowsPlayerVariant.compact,
                  '精简版 · 默认',
                  '随软件提供，无需额外下载。适合常见视频和文本字幕；不支持蓝光 PGS 图形字幕。',
                ),
                _option(
                  WindowsPlayerVariant.full,
                  '完整版${components.installed ? ' · 已下载' : ' · 未下载'}',
                  '增加蓝光 PGS 图形字幕和更多格式支持。\n下载约 31.4 MiB，安装后占用约 117 MiB。',
                ),
                if (components.restartRequired)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      '选择已保存，完全退出软件后重新打开生效。',
                      key: Key('player-component-restart'),
                    ),
                  ),
                if (components.startupNotice case final notice?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(notice),
                  ),
                if (components.error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error,
                      key: const Key('player-component-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (components.stage != PlayerComponentStage.idle) ...[
                  LinearProgressIndicator(
                    value: components.stage == PlayerComponentStage.downloading
                        ? components.progress
                        : null,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _stageLabel,
                    key: const Key('player-component-progress'),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('player-component-cancel'),
                      onPressed: components.cancelDownload,
                      child: const Text('取消下载'),
                    ),
                  ),
                ] else if (components.active != WindowsPlayerVariant.full)
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('player-component-download'),
                        icon: const Icon(Icons.download),
                        label: Text(components.installed ? '重新下载' : '下载完整组件'),
                        onPressed:
                            !components.ready || components.busy || _changing
                            ? null
                            : () {
                                unawaited(
                                  _run(
                                    () => components.download(
                                      acceleration: widget.acceleration?.call(),
                                    ),
                                  ),
                                );
                              },
                      ),
                      if (components.installed)
                        TextButton.icon(
                          key: const Key('player-component-remove'),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除完整组件'),
                          onPressed: components.busy || _changing
                              ? null
                              : _remove,
                        ),
                    ],
                  )
                else
                  const Text('如需重新下载或删除完整组件，请先选择精简版并重启软件。'),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class PlayerComponentsTile extends StatelessWidget {
  const PlayerComponentsTile({super.key, this.acceleration});
  final GitHubAcceleration Function()? acceleration;
  @override
  Widget build(BuildContext context) {
    final components = WindowsPlayerComponents.shared;
    if (!components.supported ||
        Theme.of(context).platform != TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: components,
      builder: (context, _) => ListTile(
        key: const Key('player-components-settings'),
        leading: const Icon(Icons.extension_outlined),
        title: const Text('播放器组件'),
        subtitle: Text(
          '${components.active == WindowsPlayerVariant.full ? '完整版' : '精简版'}'
          '${components.restartRequired ? ' · 重启后切换' : ' · 可按需下载完整版'}',
        ),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => PlayerComponentsPage(acceleration: acceleration),
          ),
        ),
      ),
    );
  }
}
