import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/json.dart';
import '../data/app_update_service.dart';
import '../data/remote_control_service.dart';
import '../domain/downloads.dart';
import '../domain/remote_control.dart';
import 'common.dart';

class AppUpdatePanel extends StatefulWidget {
  const AppUpdatePanel({
    super.key,
    required this.updater,
    required this.control,
    required this.update,
    required this.openDownloads,
  });
  final AppUpdateService updater;
  final RemoteControlService control;
  final RemoteUpdate update;
  final VoidCallback openDownloads;

  @override
  State<AppUpdatePanel> createState() => _AppUpdatePanelState();
}

class _AppUpdatePanelState extends State<AppUpdatePanel> {
  String? _autoInstallKey;

  @override
  void initState() {
    super.initState();
    widget.updater.addListener(_changed);
  }

  @override
  void didUpdateWidget(AppUpdatePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.updater != widget.updater) {
      oldWidget.updater.removeListener(_changed);
      widget.updater.addListener(_changed);
    }
    if (oldWidget.updater != widget.updater ||
        widget.updater.keyFor(oldWidget.update) !=
            widget.updater.keyFor(widget.update)) {
      _autoInstallKey = null;
    }
  }

  bool _matchesUpdate(AppUpdateService updater, RemoteUpdate update) =>
      mounted &&
      widget.updater == updater &&
      updater.keyFor(widget.update) == updater.keyFor(update);

  bool _canInstall(AppUpdateService updater, RemoteUpdate update) =>
      _matchesUpdate(updater, update) &&
      widget.control.inForeground &&
      ModalRoute.of(context)?.isCurrent == true;

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final updater = widget.updater, update = widget.update;
    final task = updater.taskFor(update);
    if (_autoInstallKey != updater.keyFor(update) ||
        task?.status != DownloadStatus.completed ||
        updater.busy(update)) {
      return;
    }
    // Completion in the background or after dismissal leaves an install button.
    // Returning from the installer must never automatically open it again.
    _autoInstallKey = null;
    if (updater.platform != 'android' || !_canInstall(updater, update)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canInstall(updater, update)) {
        unawaited(
          updater.install(update, canOpen: () => _canInstall(updater, update)),
        );
      }
    });
  }

  Future<void> _start({bool redownload = false}) async {
    final updater = widget.updater, update = widget.update;
    _autoInstallKey = updater.keyFor(update);
    final started = await updater.start(update, redownload: redownload);
    if (!_matchesUpdate(updater, update)) return;
    if (!started) _autoInstallKey = null;
    _changed();
  }

  Future<void> _install() async {
    final updater = widget.updater, update = widget.update;
    _autoInstallKey = null;
    await updater.install(update, canOpen: () => _canInstall(updater, update));
  }

  @override
  void dispose() {
    widget.updater.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final updater = widget.updater, update = widget.update;
    final task = updater.taskFor(update);
    final busy = updater.busy(update);
    final completed = task?.status == DownloadStatus.completed;
    final active = task?.active == true;
    final error =
        updater.error(update) ??
        (task?.status == DownloadStatus.failed ? task!.error : null);
    final zip = completed && task!.spec.fileName.toLowerCase().endsWith('.zip');
    final label = busy
        ? updater.stage(update).ifEmpty('正在处理…')
        : completed
        ? (zip ? '打开所在文件夹' : '立即安装')
        : active
        ? '正在下载更新…'
        : task == null
        ? 'App 内更新'
        : task.status == DownloadStatus.failed
        ? '重试下载'
        : '继续下载';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (task != null || error?.isNotEmpty == true)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: (MediaQuery.sizeOf(context).height * .22).clamp(
                48,
                180,
              ),
            ),
            child: SingleChildScrollView(
              key: const ValueKey('control-update-status-scroll'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (task != null) ...[
                    Text(
                      task.spec.fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: task.total > 0 ? task.progress : 0,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      completed
                          ? (zip ? '下载完成，请打开文件夹解压更新' : '下载完成，可以安装更新')
                          : '${task.total > 0 ? '${(task.progress * 100).toStringAsFixed(1)}% · ' : ''}'
                                '${formatBytes(task.downloaded)} / ${task.total > 0 ? formatBytes(task.total) : '大小待获取'}'
                                '${task.speed > 0 ? ' · ${formatBytes(task.speed)}/s' : ''}',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: secondary(context),
                      ),
                    ),
                    if (!completed && task.phase.isNotEmpty)
                      Text(
                        task.phase,
                        style: TextStyle(
                          fontSize: 12,
                          color: secondary(context),
                        ),
                      ),
                    if (active && task.total > 0)
                      Text(
                        '剩余 ${formatBytes((task.total - task.downloaded).clamp(0, task.total))}',
                        style: TextStyle(
                          fontSize: 12,
                          color: secondary(context),
                        ),
                      ),
                    const SizedBox(height: 10),
                  ],
                  if (error?.isNotEmpty == true) ...[
                    Text(
                      error!,
                      key: const ValueKey('control-in-app-error'),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const ValueKey('control-in-app-update'),
          onPressed: busy || active
              ? null
              : completed
              ? _install
              : _start,
          icon: Icon(
            completed
                ? CupertinoIcons.arrow_down_doc
                : CupertinoIcons.arrow_down_circle,
            size: 18,
          ),
          label: Text(label, textAlign: TextAlign.center),
        ),
        if (task != null)
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            children: [
              if (active)
                TextButton(
                  onPressed: busy
                      ? null
                      : () {
                          _autoInstallKey = null;
                          unawaited(updater.pause(update));
                        },
                  child: const Text('暂停下载'),
                ),
              if (task.status == DownloadStatus.failed ||
                  (completed && error != null))
                TextButton(
                  key: const ValueKey('control-update-redownload'),
                  onPressed: busy ? null : () => _start(redownload: true),
                  child: const Text('重新下载'),
                ),
              if (!update.force)
                TextButton(
                  key: const ValueKey('control-update-downloads'),
                  onPressed: widget.openDownloads,
                  child: const Text('下载管理'),
                ),
            ],
          ),
      ],
    );
  }
}
