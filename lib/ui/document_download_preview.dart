import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../data/http.dart';
import '../domain/downloads.dart';
import '../domain/models.dart';
import '../platform/file_access.dart';
import 'baidu_download_prompt.dart';
import 'common.dart';
import 'document_preview.dart';
import 'download_location_picker.dart';
import 'download_progress.dart';
import 'transfer_widgets.dart';

/// The viewer observes an ordinary durable download. Leaving this page only
/// removes the observer; users can continue, pause or retry it in Transfers.
class DocumentDownloadPreview extends StatefulWidget {
  const DocumentDownloadPreview({
    super.key,
    required this.services,
    this.session,
    this.file,
    this.taskId,
  }) : assert(taskId != null || session != null && file != null);
  final AppServices services;
  final BrowseSession? session;
  final CloudFile? file;
  final String? taskId;

  @override
  State<DocumentDownloadPreview> createState() =>
      _DocumentDownloadPreviewState();
}

class _DocumentDownloadPreviewState extends State<DocumentDownloadPreview> {
  final _scope = RequestScope();
  String? _id, _path;
  String _error = '';
  bool _preparing = true, _controlling = false, _checking = false;

  @override
  void initState() {
    super.initState();
    widget.services.downloads.addListener(_changed);
    // Inspect existing downloads first; only the explicit button starts work.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start({bool download = false}) async {
    if (!mounted || download && _preparing) return;
    setState(() {
      _preparing = true;
      _error = '';
    });
    try {
      _id = widget.taskId;
      if (_id == null) {
        final source = widget.services.cloud.planDownload(
          widget.session!,
          widget.file!,
        );
        final origin = DownloadOrigin.fromJson(source.source!);
        _id = await _scope.run(
          () => download
              ? widget.services.documentDownloads.resolve(
                  origin,
                  create: () async {
                    RequestScope.checkpoint();
                    if (!mounted ||
                        !await confirmBaiduDownload(
                          context,
                          widget.services,
                          widget.session!.platform,
                          session: widget.session,
                        ) ||
                        !mounted) {
                      return null;
                    }
                    final location = await chooseDownloadLocation(
                      context,
                      widget.services,
                    );
                    if (location == null || !mounted) return null;
                    return widget.services.downloads.enqueue(
                      source,
                      location: location,
                    );
                  },
                )
              : widget.services.documentDownloads.find(origin),
        );
      }
      if (!mounted) return;
      final task = _task;
      if (download && task != null && !task.active && !task.terminal) {
        await _scope.run(() => widget.services.downloads.resume(task.id));
        if (!mounted) return;
      }
      setState(() {
        _preparing = false;
        if (download && _id == null) _error = '已取消下载，可重新开始预览';
        if (_id != null && task == null) _error = '下载任务已移除，请返回文件列表';
      });
      _changed();
    } on DownloadConfirmationCancelled {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = '已取消下载，可重新开始预览';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _preparing = false;
          _error = errorText(error);
        });
      }
    }
  }

  DownloadTask? get _task =>
      _id == null ? null : widget.services.downloads.task(_id!);

  void _changed() {
    if (!mounted || _preparing) return;
    final task = _task;
    if (task?.status == DownloadStatus.completed &&
        _path == null &&
        !_checking) {
      unawaited(_openCompleted(task!));
    }
    setState(() {});
  }

  Future<void> _openCompleted(DownloadTask task) async {
    _checking = true;
    try {
      final state = await widget.services.files.inspect(task.savedPath);
      if (!mounted) return;
      final current = _task;
      if (current?.status != DownloadStatus.completed ||
          current?.savedPath != task.savedPath) {
        return;
      }
      setState(() {
        if (state == FileAvailability.present &&
            task.savedPath?.isNotEmpty == true) {
          _path = task.savedPath;
          _error = '';
        } else {
          _error = state == FileAvailability.missing
              ? '文件已被移动或删除，请重新下载'
              : '无法读取下载文件，请检查保存目录权限';
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      _checking = false;
    }
  }

  Future<void> _control() async {
    final task = _task;
    if (_controlling || task == null) return;
    setState(() {
      _controlling = true;
      _error = '';
    });
    try {
      if (task.active) {
        await widget.services.downloads.pause(task.id);
      } else {
        await widget.services.downloads.resume(task.id);
      }
    } on DownloadConfirmationCancelled {
      // Keep the same task and its pause state when mobile data is declined.
    } catch (error) {
      if (mounted) setState(() => _error = errorText(error));
    } finally {
      if (mounted) setState(() => _controlling = false);
    }
  }

  Future<void> _redownload() async {
    if (_preparing) return;
    _id = null;
    _path = null;
    await _start(download: true);
  }

  @override
  void dispose() {
    _scope.cancel();
    widget.services.downloads.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final name = task?.spec.fileName ?? widget.file?.displayName ?? '文档预览';
    if (_path case final path?) {
      return LocalDocumentPreviewPage(
        key: ValueKey(path),
        services: widget.services,
        path: path,
        name: name,
      );
    }
    return PageFrame(
      title: name,
      actions: [
        IconButton(
          tooltip: '传输管理',
          onPressed: widget.services.requestDownloadManager,
          icon: const Icon(CupertinoIcons.arrow_down_circle),
        ),
      ],
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FileGlyph(name, size: 44),
                const SizedBox(height: 20),
                if (_preparing) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  const Text('正在准备文档预览…'),
                ] else if (task == null && _error.isEmpty) ...[
                  Text(
                    '下载后预览文档',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '此文档尚未下载。确认下载后，将保存文件并自动打开预览。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: secondary(context)),
                  ),
                  if (widget.file?.size case final size? when size > 0) ...[
                    const SizedBox(height: 8),
                    Text(formatBytes(size)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('document-download-confirm'),
                    onPressed: () => _start(download: true),
                    icon: const Icon(CupertinoIcons.arrow_down, size: 17),
                    label: const Text('下载并预览'),
                  ),
                ] else if (task != null && !task.terminal) ...[
                  Text(
                    task.status == DownloadStatus.failed
                        ? '文档下载失败'
                        : task.status == DownloadStatus.paused
                        ? '下载已暂停'
                        : '下载完成后自动预览',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  DownloadProgress(task: task, enabled: task.active),
                  const SizedBox(height: 12),
                  Text(task.phase.isNotEmpty ? task.phase : task.status.label),
                  Text(
                    '${formatBytes(task.downloaded)} / ${formatBytes(task.total)}${task.speed > 0 ? ' · ${formatBytes(task.speed)}/s' : ''}',
                    style: TextStyle(color: secondary(context)),
                  ),
                  if (task.error.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(task.error, textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 20),
                  TransferActionButton(
                    key: const Key('document-download-control'),
                    label: task.active
                        ? '暂停下载'
                        : task.status == DownloadStatus.failed
                        ? '重试下载'
                        : '继续下载',
                    icon: task.active
                        ? CupertinoIcons.pause
                        : CupertinoIcons.play,
                    color: themeAccent(context),
                    onPressed: _controlling ? null : _control,
                  ),
                ] else if (_error.isEmpty &&
                    task?.status == DownloadStatus.completed) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  const Text('正在读取文档…'),
                ],
                if (_error.isNotEmpty ||
                    task?.status == DownloadStatus.cancelled) ...[
                  Text(
                    _error.isEmpty ? '下载任务已移除，请重新开始预览' : _error,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  if (widget.session != null)
                    FilledButton(
                      key: const Key('document-download-retry'),
                      onPressed: _preparing ? null : _redownload,
                      child: const Text('重新下载并预览'),
                    )
                  else
                    TextButton(
                      onPressed: _changed,
                      child: const Text('重新检查文件'),
                    ),
                ],
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('返回文件列表'),
                ),
                if (task?.active == true)
                  Text(
                    '返回后下载会在传输管理中继续',
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                    textAlign: TextAlign.center,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
