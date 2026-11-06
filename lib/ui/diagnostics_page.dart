import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import '../diagnostics/app_log.dart';
import '../diagnostics/diagnostic_bundle.dart';
import '../diagnostics/diagnostic_share.dart';
import '../platform/document_actions.dart';
import 'common.dart';
import 'remote_control_dialogs.dart';

class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage(
    this.bundle, {
    super.key,
    this.saveExport,
    this.shareExport,
    this.openExportLocation,
    this.linkLauncher,
  });
  final DiagnosticBundle bundle;
  final Future<String?> Function(Uint8List bytes, String name)? saveExport;
  final Future<ShareResultStatus> Function(Uint8List bytes, String name)?
  shareExport;
  final Future<void> Function(String path)? openExportLocation;
  final RemoteLinkLauncher? linkLauncher;
  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  late final note = TextEditingController();
  late List<LogEntry> entries;
  bool errorsOnly = true, working = false;
  String? lastSavedPath;
  DiagnosticLog get log => widget.bundle.log;
  String get exportName =>
      '文析助手-logs-${applicationVersion.replaceAll('+', '-')}-${DateTime.now().toUtc().microsecondsSinceEpoch}.zip';
  @override
  void initState() {
    super.initState();
    entries = log.entries(errorsOnly: true);
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  void refresh() =>
      setState(() => entries = log.entries(errorsOnly: errorsOnly));

  Future<void> export() async {
    if (working) return;
    setState(() => working = true);
    try {
      final bytes = await busy(
        context,
        () => widget.bundle.build(note: note.text),
        label: '正在整理日志…',
      );
      if (bytes == null || !mounted) return;
      final name = exportName;
      String? saved;
      if (widget.saveExport != null) {
        saved = await widget.saveExport!(bytes, name);
      } else {
        saved = await const DocumentActions().saveBytes(
          bytes,
          name,
          mime: 'application/zip',
          acceptedTypeGroups: const [
            XTypeGroup(label: '日志 ZIP', extensions: ['zip']),
          ],
        );
      }
      if (mounted) {
        if (saved != null) lastSavedPath = saved;
        message(context, saved != null ? '日志已导出，可将 ZIP 发给开发者排查' : '已取消导出');
        refresh();
      }
    } catch (error, stack) {
      DiagnosticLog.error('logging.export_failed', error, stack);
      if (mounted) message(context, '日志导出失败，请检查保存位置和空间后重试');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> share() async {
    if (working) return;
    setState(() => working = true);
    try {
      final bytes = await busy(
        context,
        () => widget.bundle.build(note: note.text),
        label: '正在整理日志…',
      );
      if (bytes == null || !mounted) return;
      final share = widget.shareExport;
      final box = context.findRenderObject() as RenderBox?;
      final result = share != null
          ? await share(bytes, exportName)
          : await shareDiagnosticZip(
              bytes,
              exportName,
              origin: box == null
                  ? null
                  : box.localToGlobal(Offset.zero) & box.size,
            );
      if (mounted) {
        message(context, switch (result) {
          ShareResultStatus.success => '日志已交给所选应用，请在该应用内确认发送',
          ShareResultStatus.dismissed => '已取消分享',
          ShareResultStatus.unavailable => '已打开系统分享窗口',
        });
        refresh();
      }
    } catch (error, stack) {
      DiagnosticLog.error('logging.share_failed', error, stack);
      if (mounted) message(context, '分享未完成，可以重试或保存日志 ZIP');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> feedback() async {
    if (working) return;
    setState(() => working = true);
    try {
      await openRemoteLink(
        context,
        Uri.parse('https://github.com/z7786/wenxi'),
        launcher: widget.linkLauncher,
      );
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> openLocation() async {
    final path = lastSavedPath;
    if (working || path == null) return;
    setState(() => working = true);
    try {
      await (widget.openExportLocation ?? openDiagnosticExportLocation)(path);
    } catch (error, stack) {
      DiagnosticLog.error('logging.open_location_failed', error, stack);
      if (mounted) message(context, '无法打开导出位置，文件可能已被移动');
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('日志与故障排查'),
      actions: [
        IconButton(
          tooltip: '刷新日志',
          onPressed: working ? null : refresh,
          icon: const Icon(CupertinoIcons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          key: const Key('diagnostics-feedback-guide'),
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: themeAccent(context).withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? .16
                  : .08,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: themeAccent(context).withValues(alpha: .25),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                CupertinoIcons.info_circle_fill,
                color: themeAccent(context),
                size: 23,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  '反馈错误建议先清空当前日志再去复现错误导出最新日志',
                  style: TextStyle(fontWeight: FontWeight.w600, height: 1.6),
                ),
              ),
            ],
          ),
        ),
        SwitchListTile.adaptive(
          key: const Key('diagnostics-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text('自动记录日志'),
          subtitle: const Text('仅保存在本机，最近 7 天自动轮换，最多约 6 MB'),
          value: log.enabled,
          onChanged: working
              ? null
              : (value) async {
                  setState(() => working = true);
                  await busy(context, () => widget.bundle.setEnabled(value));
                  if (mounted) setState(() => working = false);
                  if (mounted) refresh();
                },
        ),
        Text(
          '应用运行日志 ${formatBytes(log.sizeBytes)} · 版本 $applicationVersion',
          style: TextStyle(color: secondary(context), fontSize: 12),
        ),
        if (log.storageError != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              log.storageError!,
              style: const TextStyle(color: Colors.orange),
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          controller: note,
          minLines: 2,
          maxLines: 4,
          maxLength: 1000,
          decoration: const InputDecoration(
            labelText: '问题说明（选填）',
            hintText: '例如：下载列表长按删除后闪退；大约发生时间',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('diagnostics-export'),
          onPressed: working ? null : export,
          icon: const Icon(CupertinoIcons.folder),
          label: const Text('导出日志 ZIP'),
        ),
        if (Platform.isAndroid || Platform.isIOS || widget.shareExport != null)
          OutlinedButton.icon(
            key: const Key('diagnostics-share'),
            onPressed: working ? null : share,
            icon: const Icon(CupertinoIcons.square_arrow_up),
            label: const Text('分享日志 ZIP'),
          ),
        OutlinedButton.icon(
          key: const Key('diagnostics-feedback'),
          onPressed: working ? null : feedback,
          icon: const Icon(CupertinoIcons.arrow_up_right_square),
          label: const Text('反馈地址'),
        ),
        if (lastSavedPath != null &&
            (Platform.isWindows ||
                Platform.isMacOS ||
                widget.openExportLocation != null))
          TextButton.icon(
            key: const Key('diagnostics-open-location'),
            onPressed: working ? null : openLocation,
            icon: const Icon(CupertinoIcons.folder_open),
            label: const Text('打开导出位置'),
          ),
        TextButton(
          onPressed: working
              ? null
              : () async {
                  if (!await confirm(
                        context,
                        '清空本机日志',
                        '清除已保存的错误与操作记录，已导出的日志包会保留。',
                        action: '清空',
                      ) ||
                      !context.mounted) {
                    return;
                  }
                  setState(() => working = true);
                  await busy(context, widget.bundle.clear, label: '清理日志…');
                  if (mounted) {
                    setState(() => working = false);
                    refresh();
                  }
                },
          child: const Text('清空日志'),
        ),
        const Divider(),
        Row(
          children: [
            const Expanded(
              child: Text(
                '最近记录（北京时间）',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            FilterChip(
              label: const Text('仅错误'),
              selected: errorsOnly,
              onSelected: (value) {
                errorsOnly = value;
                refresh();
              },
            ),
          ],
        ),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Text('暂无此类运行记录。系统崩溃与退出信息会一并放入导出包。'),
          ),
        for (final entry in entries)
          ListTile(
            contentPadding: EdgeInsets.zero,
            isThreeLine: true,
            leading: Icon(
              entry.level == 'info'
                  ? CupertinoIcons.doc_text
                  : CupertinoIcons.exclamationmark_triangle,
              color: entry.level == 'info'
                  ? themeAccent(context)
                  : Colors.orange,
            ),
            title: Text(
              entry.event,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${entry.displayTime} · ${entry.level}\n${entry.data['message'] ?? ''}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('记录详情'),
                content: SingleChildScrollView(
                  child: SelectableText(
                    entry.displayDetail,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
