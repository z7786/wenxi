import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../domain/uploads.dart';
import '../upload/upload_task.dart';
import 'browser_page.dart';
import 'common.dart';
import 'app_context_menu.dart';
import 'app_popup_menu.dart';
import 'download_progress.dart';
import 'transfer_widgets.dart';

class UploadsPage extends StatefulWidget {
  const UploadsPage(this.services, {super.key, this.active = true});
  final AppServices services;
  final bool active;
  @override
  State<UploadsPage> createState() => _UploadsPageState();
}

class _UploadsPageState extends State<UploadsPage> with WidgetsBindingObserver {
  int filter = 0;
  bool foreground = true, detailsOpen = false;
  final busyIds = <String>{};
  Color get accent => themeCompanion(context);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => foreground = state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool accepts(UploadTask t, int value) => switch (value) {
    1 => t.active,
    2 => t.status == UploadStatus.completed,
    3 => t.canRetry,
    _ => true,
  };

  Future<void> action(UploadTask t, Future<void> Function() work) async {
    if (!mounted || !busyIds.add(t.id)) return;
    setState(() {});
    try {
      await work();
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => busyIds.remove(t.id));
    }
  }

  Future<void> cancel(UploadTask t) async {
    if (await confirm(
      context,
      '取消上传',
      t.isFolder ? '停止这个文件夹的上传？已完成的文件会保留，继续时只上传未完成文件。' : '停止这个文件的上传？重新上传会从头开始。',
    )) {
      if (mounted) await action(t, () => widget.services.uploads.cancel(t.id));
    }
  }

  Future<void> openFolder(UploadTask t) async {
    final session = await busy(
      context,
      () => widget.services.cloud.reopenSpace(t.session),
      label: '正在打开目标目录…',
    );
    if (!mounted || session == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          widget.services,
          session,
          initialTrail: [
            (session.rootId, '全部文件'),
            if (t.parent != session.rootId) (t.parent, t.folderName),
          ],
          highlightedFileId: t.fileId.isEmpty ? null : t.fileId,
        ),
      ),
    );
  }

  Color _tint(UploadTask t) => switch (t.status) {
    UploadStatus.completed => const Color(0xff30b866),
    UploadStatus.failed || UploadStatus.interrupted => const Color(0xffe05a51),
    UploadStatus.pending || UploadStatus.running => accent,
    _ => secondary(context),
  };

  String _amount(UploadTask t) => t.isFolder
      ? '${t.folder!.completedFiles}/${t.folder!.files.length} 个文件 · ${t.folder!.directories.length} 个目录 · ${formatBytes(t.sent.clamp(0, t.size))} / ${formatBytes(t.size)}'
      : t.status == UploadStatus.running && t.phase == UploadPhase.uploading
      ? '${formatBytes(t.sent.clamp(0, t.size))} / ${formatBytes(t.size)}'
      : formatBytes(t.size);

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.services.uploads,
    builder: (context, _) {
      final all = widget.services.uploads.tasks;
      final tasks = all.where((t) => accepts(t, filter)).toList()
        ..sort((a, b) {
          int rank(UploadTask t) => t.status == UploadStatus.running
              ? 0
              : t.active
              ? 1
              : t.canRetry
              ? 2
              : 3;
          final order = rank(a).compareTo(rank(b));
          return order != 0 ? order : b.createdAt.compareTo(a.createdAt);
        });
      final indices = {
        for (var i = 0; i < tasks.length; i++) ValueKey(tasks[i].id): i,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TransferFilterBar(
            entries: [
              for (var i = 0; i < 4; i++)
                (
                  ['全部', '进行中', '已完成', '待处理'][i],
                  all.where((t) => accepts(t, i)).length,
                ),
            ],
            selected: filter,
            onSelected: (value) => setState(() => filter = value),
            accent: accent,
            keyPrefix: 'upload-filter',
          ),
          _summary(all),
          Expanded(
            child: tasks.isEmpty
                ? EmptyPanel(
                    filter == 0
                        ? '暂无上传任务'
                        : '暂无${['', '进行中', '已完成', '待处理'][filter]}任务',
                    filter == 0
                        ? '在网盘文件列表中选择「上传文件」或「上传文件夹」\n离开页面后，上传仍会继续'
                        : '切换其他分类查看上传记录',
                    icon: CupertinoIcons.cloud_upload,
                  )
                : ListView.builder(
                    key: const PageStorageKey('uploads'),
                    padding: EdgeInsets.only(
                      bottom: 20 + MediaQuery.paddingOf(context).bottom,
                    ),
                    itemCount: tasks.length,
                    findChildIndexCallback: (key) => indices[key],
                    itemBuilder: (context, index) => _task(tasks[index]),
                  ),
          ),
        ],
      );
    },
  );

  Widget _summary(List<UploadTask> all) {
    final active = all.where((t) => t.active).length;
    final pending = all.where((t) => t.status == UploadStatus.pending).length;
    final speed = all
        .where(
          (t) =>
              t.status == UploadStatus.running &&
              t.phase == UploadPhase.uploading,
        )
        .fold<int>(0, (n, t) => n + t.speed);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        border: Border.symmetric(
          horizontal: BorderSide(color: border(context), width: .5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              active > 0
                  ? '传输 ${active - pending} · 等待 $pending'
                  : all.any((t) => t.isFolder)
                  ? '共 ${all.length} 个任务'
                  : '共 ${all.length} 个文件',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: secondary(context)),
            ),
          ),
          if (active > 0) ...[
            const SizedBox(width: 8),
            Icon(CupertinoIcons.arrow_up, size: 12, color: accent),
            const SizedBox(width: 4),
            Text(
              speed > 0 ? '${formatBytes(speed)}/s' : '准备中',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: accent,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _task(UploadTask t) {
    return AppContextMenu<String>(
      key: ValueKey(t.id),
      enabled: !busyIds.contains(t.id),
      identity: t.id,
      actions: () {
        final task = widget.services.uploads.task(t.id);
        if (task == null || busyIds.contains(t.id)) return [];
        return [
          const AppMenuAction(
            value: 'details',
            label: '任务详情',
            icon: CupertinoIcons.info_circle,
          ),
          const AppMenuAction(
            value: 'folder',
            label: '打开目标目录',
            icon: CupertinoIcons.folder_open,
          ),
          const AppMenuAction(
            value: 'copy-name',
            label: '复制文件名',
            icon: CupertinoIcons.doc_on_doc,
          ),
          if (task.active)
            const AppMenuAction(
              value: 'cancel',
              label: '取消上传',
              icon: CupertinoIcons.stop_circle,
              destructive: true,
            )
          else ...[
            if (task.canRetry)
              AppMenuAction(
                value: 'retry',
                label: task.isFolder ? '继续上传' : '重新上传',
                icon: CupertinoIcons.arrow_clockwise,
              ),
            const AppMenuAction(
              value: 'remove',
              label: '删除记录',
              icon: CupertinoIcons.trash,
              destructive: true,
            ),
          ],
        ];
      },
      onSelected: (selected) => _taskAction(t.id, selected),
      child: _taskContent(t),
    );
  }

  Widget _taskContent(UploadTask t) {
    final manager = widget.services.uploads;
    final locked = busyIds.contains(t.id);
    final tint = _tint(t);
    return Material(
      key: ValueKey(t.id),
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('upload-row-${t.id}'),
        onTap: () => _details(t.id),
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: border(context), width: .5),
            ),
          ),
          child: Row(
            children: [
              FileGlyph(t.name, directory: t.isFolder, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            t.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        PlatformMark(platform: t.session.platform, size: 14),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: t.stage,
                            style: TextStyle(color: tint),
                          ),
                          TextSpan(text: ' · ${_amount(t)}'),
                          if (t.active &&
                              t.phase == UploadPhase.uploading &&
                              t.speed > 0)
                            TextSpan(
                              text: ' · ${formatBytes(t.speed)}/s',
                              style: TextStyle(color: accent),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: secondary(context),
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    TransferProgress.upload(
                      t,
                      compact: true,
                      enabled:
                          widget.active &&
                          foreground &&
                          ModalRoute.of(context)?.isCurrent != false,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              TransferActionButton(
                key: ValueKey('upload-action-${t.id}'),
                color: t.active || t.canRetry
                    ? accent
                    : const Color(0xff30b866),
                icon: t.active
                    ? CupertinoIcons.stop
                    : t.canRetry
                    ? CupertinoIcons.arrow_clockwise
                    : CupertinoIcons.folder,
                label: t.active
                    ? '取消上传'
                    : t.canRetry
                    ? t.isFolder
                          ? '继续上传'
                          : '重新上传'
                    : '打开目标目录：${t.folderName}',
                onPressed: locked
                    ? null
                    : () {
                        if (t.active) {
                          cancel(t);
                        } else if (t.canRetry) {
                          action(t, () => manager.retry(t.id));
                        } else {
                          action(t, () => openFolder(t));
                        }
                      },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _details(String id) async {
    if (detailsOpen) return;
    detailsOpen = true;
    String? selected;
    try {
      selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 640),
        builder: (context) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .82,
            ),
            child: AnimatedBuilder(
              animation: widget.services.uploads,
              builder: (context, _) {
                final task = widget.services.uploads.task(id);
                if (task == null) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('这条上传记录已移除'),
                  );
                }
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          FileGlyph(
                            task.name,
                            directory: task.isFolder,
                            size: 34,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              task.name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '${task.stage} · ${_amount(task)}',
                        style: TextStyle(color: _tint(task), fontSize: 13),
                      ),
                      TransferProgress.upload(task, enabled: foreground),
                      const SizedBox(height: 16),
                      _detailLine(
                        context,
                        '上传账号',
                        '${task.session.platform.shortName} · ${task.accountName}',
                      ),
                      _detailLine(context, '目标目录', task.folderName),
                      if (task.isFolder && task.folder!.currentItem.isNotEmpty)
                        _detailLine(context, '当前文件', task.folder!.currentItem),
                      _detailLine(context, '创建时间', formatDate(task.createdAt)),
                      if (task.error.isNotEmpty)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(top: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _tint(task).withValues(alpha: .07),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: SelectableText(
                            task.error,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.5,
                              color: _tint(task),
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      const Divider(height: 1),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(CupertinoIcons.folder, color: accent),
                        title: const Text('打开目标目录'),
                        onTap: () => Navigator.pop(context, 'folder'),
                      ),
                      if (task.active)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            CupertinoIcons.stop_circle,
                            color: Colors.red,
                          ),
                          title: const Text('取消上传'),
                          subtitle: Text(
                            task.isFolder ? '已完成的文件保留，可继续未完成文件' : '重新上传会从头开始',
                          ),
                          onTap: () => Navigator.pop(context, 'cancel'),
                        )
                      else ...[
                        if (task.canRetry)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              CupertinoIcons.arrow_clockwise,
                              color: accent,
                            ),
                            title: Text(task.isFolder ? '继续上传' : '重新上传'),
                            onTap: () => Navigator.pop(context, 'retry'),
                          ),
                        ListTile(
                          key: const Key('uploads-remove-record'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(
                            CupertinoIcons.trash,
                            color: Colors.red,
                          ),
                          title: const Text('删除记录'),
                          subtitle: const Text('保留网盘中的文件'),
                          onTap: () => Navigator.pop(context, 'remove'),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
    } finally {
      detailsOpen = false;
    }
    if (!mounted || selected == null) return;
    await _taskAction(id, selected);
  }

  Future<void> _taskAction(String id, String selected) async {
    if (!mounted || busyIds.contains(id)) return;
    final task = widget.services.uploads.task(id);
    if (task == null) return;
    switch (selected) {
      case 'details':
        await _details(id);
      case 'copy-name':
        await widget.services.copyText(task.name);
        if (mounted) message(context, '文件名已复制');
      case 'folder':
        await action(task, () => openFolder(task));
      case 'cancel':
        if (task.active) await cancel(task);
      case 'retry':
        if (task.canRetry) {
          await action(task, () => widget.services.uploads.retry(id));
        }
      case 'remove':
        if (!task.active) {
          await action(task, () => widget.services.uploads.remove(id));
        }
    }
  }

  Widget _detailLine(
    BuildContext context,
    String label,
    String value,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: secondary(context))),
        const SizedBox(width: 18),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 12, height: 1.5)),
        ),
      ],
    ),
  );
}
