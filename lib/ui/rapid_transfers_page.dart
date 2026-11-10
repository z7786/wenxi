import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../transfer/rapid_transfer_task.dart';
import '../domain/models.dart';
import 'browser_page.dart';
import 'common.dart';

class CrossTransferCard extends StatelessWidget {
  const CrossTransferCard(this.services, this.task, {super.key});
  final RapidTransferTask task;
  final AppServices services;

  Future<void> _open(BuildContext context, RapidTransferTask task) async {
    final session = await busy(
      context,
      () => services.cloud.reopenSpace(task.target),
      label: '正在打开目标目录…',
    );
    if (session == null || !context.mounted) return;
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

  void _details(BuildContext context, RapidTransferTask task) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: AnimatedBuilder(
            animation: services.rapidTransfers,
            builder: (context, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    task.name,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: task.entries.isEmpty
                      ? Center(child: Text(task.stage))
                      : ListView.builder(
                          itemCount: task.entries.length,
                          itemBuilder: (context, i) {
                            final e = task.entries[i];
                            return ListTile(
                              dense: true,
                              leading: Icon(
                                e.succeeded
                                    ? CupertinoIcons.checkmark_circle_fill
                                    : CupertinoIcons.doc,
                                color: e.succeeded ? Colors.green : null,
                              ),
                              title: Text([...e.path, e.file.name].join('/')),
                              subtitle: Text(
                                e.message.isEmpty ? '等待传输' : e.message,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = task;
    String accountName(BrowseSession session) {
      for (final p in services.vault.profiles(session.platform)) {
        if (p.id == session.accountId) return p.name;
      }
      return session.accountId?.isNotEmpty == true ? '原账号已移除' : '分享来源';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(CupertinoIcons.arrow_right_arrow_left),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.name,
                    maxLines: 2,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _badge(context, '跨盘传输'),
                _badge(context, t.methodLabel),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${t.source.platform.shortName} → ${t.target.platform.shortName} · ${t.folderName}',
            ),
            Text(
              '${accountName(t.source)} → ${accountName(t.target)}',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
            const SizedBox(height: 8),
            Text(
              t.active && !t.scanned
                  ? '${t.stage} · ${t.scannedFiles} 个文件 / ${t.scannedFolders} 个目录'
                  : '${t.stage} · ${t.done}/${t.entries.length} 个文件${t.speed > 0 ? ' · ${formatBytes(t.speed)}/s' : ''}',
            ),
            if (t.active)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(value: t.progress),
              ),
            Text(
              '秒传 ${t.count(RapidEntryStatus.reused)} · 下载后上传 ${t.count(RapidEntryStatus.uploaded)}'
              ' · 待重试 ${t.count(RapidEntryStatus.missed) + t.count(RapidEntryStatus.noHash)}'
              ' · 同名跳过 ${t.count(RapidEntryStatus.duplicate)}'
              ' · 失败 ${t.count(RapidEntryStatus.failed)}',
              style: const TextStyle(fontSize: 12),
            ),
            if (t.error.isNotEmpty)
              Text(
                t.error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => _details(context, t),
                  child: const Text('详情'),
                ),
                TextButton(
                  onPressed: () => _open(context, t),
                  child: const Text('目标目录'),
                ),
                if (t.active)
                  TextButton(
                    onPressed: () => busy(
                      context,
                      () => services.rapidTransfers.cancel(t.id),
                    ),
                    child: const Text('取消'),
                  ),
                if (t.canRetry)
                  TextButton(
                    onPressed: () => busy(
                      context,
                      () => services.rapidTransfers.retry(t.id),
                    ),
                    child: const Text('继续 / 重试'),
                  ),
                if (!t.active)
                  TextButton(
                    onPressed: () => busy(
                      context,
                      () => services.rapidTransfers.remove(t.id),
                    ),
                    child: const Text('移除记录'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(BuildContext context, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: themeCompanion(context).withValues(alpha: .1),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, color: themeCompanion(context)),
    ),
  );
}
