import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../transfer/rapid_transfer_task.dart';
import '../domain/models.dart';
import 'app_context_menu.dart';
import 'app_popup_menu.dart';
import 'browser_page.dart';
import 'common.dart';
import 'download_progress.dart';
import 'transfer_widgets.dart';

class CrossTransferRow extends StatefulWidget {
  const CrossTransferRow(
    this.services,
    this.task, {
    super.key,
    this.active = true,
  });
  final RapidTransferTask task;
  final AppServices services;
  final bool active;

  @override
  State<CrossTransferRow> createState() => _CrossTransferRowState();
}

class _CrossTransferRowState extends State<CrossTransferRow> {
  bool locked = false, detailsOpen = false;
  AppServices get services => widget.services;
  Color get accent => themeCompanion(context);

  Color _tint(RapidTransferTask t) => t.active
      ? accent
      : t.status == RapidTaskStatus.cancelled
      ? secondary(context)
      : t.canRetry
      ? const Color(0xffe05a51)
      : const Color(0xff30b866);

  String _amount(RapidTransferTask t) => !t.scanned
      ? '${t.scannedFiles} 个文件 / ${t.scannedFolders} 个目录'
      : '${t.done}/${t.entries.length} 个文件';

  String _accountName(BrowseSession session) {
    for (final p in services.vault.profiles(session.platform)) {
      if (p.id == session.accountId) return p.name;
    }
    return session.accountId?.isNotEmpty == true ? '原账号已移除' : '分享来源';
  }

  Future<void> _work(Future<void> Function() work) async {
    if (!mounted || locked) return;
    setState(() => locked = true);
    try {
      await work();
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => locked = false);
    }
  }

  Future<void> _open(RapidTransferTask task) async {
    final session = await busy(
      context,
      () => services.cloud.reopenSpace(task.target),
      label: '正在打开目标目录…',
    );
    if (session == null || !mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BrowserPage(
          services,
          session,
          initialTrail: [
            (session.rootId, '全部文件'),
            if (task.parent != session.rootId) (task.parent, task.folderName),
          ],
        ),
      ),
    );
  }

  List<AppMenuAction<String>> _actions(String id) {
    final task = services.rapidTransfers.task(id);
    if (task == null || locked) return [];
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
          label: '取消传输',
          icon: CupertinoIcons.stop_circle,
          destructive: true,
        )
      else ...[
        if (task.canRetry)
          const AppMenuAction(
            value: 'retry',
            label: '继续 / 重试',
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
  }

  Future<void> _taskAction(String id, String action) async {
    final task = services.rapidTransfers.task(id);
    if (!mounted || locked || task == null) return;
    switch (action) {
      case 'details':
        await _details(id);
      case 'folder':
        await _work(() => _open(task));
      case 'copy-name':
        await services.copyText(task.name);
        if (mounted) message(context, '文件名已复制');
      case 'cancel':
        if (task.active &&
            await confirm(
              context,
              '取消传输',
              '停止这个跨盘传输任务？目标中已完成的文件会保留，可继续未完成文件。',
            )) {
          if (mounted) await _work(() => services.rapidTransfers.cancel(id));
        }
      case 'retry':
        if (task.canRetry) await _work(() => services.rapidTransfers.retry(id));
      case 'remove':
        if (!task.active) await _work(() => services.rapidTransfers.remove(id));
    }
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
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .82,
            child: AnimatedBuilder(
              animation: services.rapidTransfers,
              builder: (context, _) {
                final task = services.rapidTransfers.task(id);
                if (task == null) return const Center(child: Text('这条传输记录已移除'));
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.name,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '${task.stage} · ${_amount(task)}'
                              '${task.active && task.speed > 0 ? ' · ${formatBytes(task.speed)}/s' : ''}',
                            ),
                            TransferProgress.cross(
                              task,
                              enabled: widget.active,
                            ),
                            const SizedBox(height: 16),
                            _detailLine(
                              context,
                              '来源账号',
                              '${task.source.platform.shortName} · ${_accountName(task.source)}',
                            ),
                            _detailLine(
                              context,
                              '目标账号',
                              '${task.target.platform.shortName} · ${_accountName(task.target)}',
                            ),
                            _detailLine(context, '目标目录', task.folderName),
                            _detailLine(context, '传输方式', task.methodLabel),
                            _detailLine(
                              context,
                              '创建时间',
                              formatDate(task.createdAt),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '秒传 ${task.count(RapidEntryStatus.reused)} · 下载后上传 ${task.count(RapidEntryStatus.uploaded)}'
                              ' · 待重试 ${task.count(RapidEntryStatus.missed) + task.count(RapidEntryStatus.noHash)}'
                              ' · 同名跳过 ${task.count(RapidEntryStatus.duplicate)}'
                              ' · 失败 ${task.count(RapidEntryStatus.failed)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: secondary(context),
                              ),
                            ),
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
                                    color: _tint(task),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            const Divider(height: 1),
                            for (final action in _actions(id).where(
                              (a) =>
                                  a.value != 'details' &&
                                  a.value != 'copy-name',
                            ))
                              ListTile(
                                key: ValueKey('cross-transfer-${action.value}'),
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  action.icon,
                                  color: action.destructive
                                      ? Colors.red
                                      : accent,
                                ),
                                title: Text(action.label),
                                subtitle: action.value == 'remove'
                                    ? const Text('保留目标网盘中的文件')
                                    : null,
                                onTap: () =>
                                    Navigator.pop(context, action.value),
                              ),
                            if (task.entries.isNotEmpty) ...[
                              const Divider(height: 1),
                              const SizedBox(height: 16),
                              const Text(
                                '文件明细',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    SliverList.builder(
                      itemCount: task.entries.length,
                      itemBuilder: (context, i) {
                        final entry = task.entries[i];
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                          ),
                          leading: Icon(
                            entry.succeeded
                                ? CupertinoIcons.checkmark_circle_fill
                                : CupertinoIcons.doc,
                            color: entry.succeeded
                                ? const Color(0xff30b866)
                                : null,
                          ),
                          title: Text(
                            [...entry.path, entry.file.name].join('/'),
                          ),
                          subtitle: Text(
                            entry.message.isEmpty ? '等待传输' : entry.message,
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
    } finally {
      detailsOpen = false;
    }
    if (mounted && selected != null) await _taskAction(id, selected);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    return AppContextMenu<String>(
      enabled: !locked,
      identity: t.id,
      actions: () => _actions(t.id),
      onSelected: (action) => _taskAction(t.id, action),
      child: TransferTaskRow(
        rowKey: ValueKey('cross-transfer-row-${t.id}'),
        name: t.name,
        directory: t.selections.length > 1 || t.selections.first.isDirectory,
        onTap: locked ? null : () => _details(t.id),
        platformMark: PlatformMark(platform: t.target.platform, size: 14),
        badge: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '跨盘传输',
            maxLines: 1,
            style: TextStyle(fontSize: 10, height: 1.3, color: accent),
          ),
        ),
        subtitle: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: t.stage,
                style: TextStyle(color: _tint(t)),
              ),
              TextSpan(text: ' · ${_amount(t)}'),
              if (t.active && t.speed > 0)
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
        progress: TransferProgress.cross(
          t,
          compact: true,
          enabled: widget.active && ModalRoute.of(context)?.isCurrent != false,
        ),
        trailing: TransferActionButton(
          key: ValueKey('cross-transfer-action-${t.id}'),
          color: t.active || t.canRetry ? accent : const Color(0xff30b866),
          icon: t.active
              ? CupertinoIcons.stop
              : t.canRetry
              ? CupertinoIcons.arrow_clockwise
              : CupertinoIcons.folder,
          label: t.active
              ? '取消传输'
              : t.canRetry
              ? '继续 / 重试'
              : '打开目标目录：${t.folderName}',
          onPressed: locked
              ? null
              : () => _taskAction(
                  t.id,
                  t.active
                      ? 'cancel'
                      : t.canRetry
                      ? 'retry'
                      : 'folder',
                ),
        ),
      ),
    );
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
