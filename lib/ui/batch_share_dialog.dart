import 'dart:async';
import 'package:flutter/material.dart';
import '../data/batch_share.dart';
import '../domain/models.dart';
import 'common.dart';

class BatchShareDialog extends StatefulWidget {
  const BatchShareDialog({
    super.key,
    required this.files,
    required this.options,
    required this.create,
    required this.guard,
    required this.copy,
  });
  final List<CloudFile> files;
  final ShareOptions options;
  final Future<ShareCreation> Function(CloudFile, ShareOptions) create;
  final void Function() guard;
  final Future<void> Function(String) copy;

  @override
  State<BatchShareDialog> createState() => _BatchShareDialogState();
}

class _BatchShareDialogState extends State<BatchShareDialog> {
  late final _job = BatchShareJob(widget.files, widget.options);
  late final Future<void> _running;
  bool _stopping = false;
  @override
  void initState() {
    super.initState();
    _running = _job.run(widget.create, guard: widget.guard);
  }

  @override
  void dispose() {
    _job.stop();
    unawaited(_running.whenComplete(_job.dispose));
    // Cancellation releases an outstanding HTTP wait before disposing its
    // notifier; no late response may update a removed dialog.
    super.dispose();
  }

  Future<void> _copy(String text) async {
    try {
      await widget.copy(text);
      if (mounted) message(context, '分享链接已复制');
    } catch (error) {
      if (mounted) message(context, errorText(error));
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<BatchShareReport>(
    valueListenable: _job,
    builder: (context, report, _) => PopScope(
      canPop: report.finished,
      child: AlertDialog(
        title: Text(report.finished ? '批量分享结果' : '正在逐个创建分享'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '已处理 ${report.entries.length}/${report.total} 项 · 成功 ${report.succeeded} · 失败 ${report.failed}',
              ),
              if (!report.finished) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: report.total == 0
                      ? 0
                      : report.entries.length / report.total,
                ),
              ],
              if (report.reason != null) ...[
                const SizedBox(height: 12),
                Text(report.reason!),
              ],
              if (report.entries.isNotEmpty) ...[
                const SizedBox(height: 12),
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * .45,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: report.entries.length,
                      itemBuilder: (context, index) {
                        final entry = report.entries[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: SelectableText(
                                  entry.share?.text ??
                                      '${entry.file.displayName}\n${entry.error}',
                                ),
                              ),
                              if (entry.share != null)
                                IconButton(
                                  tooltip: '复制 ${entry.file.displayName} 的分享',
                                  onPressed: () => _copy(entry.share!.text),
                                  icon: const Icon(Icons.copy, size: 18),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (report.finished)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            )
          else
            TextButton(
              onPressed: _stopping
                  ? null
                  : () {
                      setState(() => _stopping = true);
                      _job.stop();
                    },
              child: Text(_stopping ? '正在停止…' : '停止'),
            ),
          TextButton(
            onPressed: report.succeeded == 0 ? null : () => _copy(report.text),
            child: const Text('复制全部分享'),
          ),
        ],
      ),
    ),
  );
}
