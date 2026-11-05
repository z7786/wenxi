import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../data/announcement_service.dart';
import '../domain/announcements.dart';
import '../domain/announcement_markdown.dart';
import 'announcement_markdown.dart';
import 'common.dart';
import 'remote_control_dialogs.dart';

class AnnouncementButton extends StatelessWidget {
  const AnnouncementButton(this.service, {super.key, this.linkLauncher});
  final AnnouncementService service;
  final RemoteLinkLauncher? linkLauncher;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) => IconButton(
      key: const Key('parse-announcements'),
      tooltip: '消息公告',
      icon: Badge.count(
        count: service.unreadCount,
        isLabelVisible: service.unreadCount > 0,
        child: const Icon(CupertinoIcons.bell, size: 22),
      ),
      onPressed: () => Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              AnnouncementsPage(service, linkLauncher: linkLauncher),
        ),
      ),
    ),
  );
}

class AnnouncementsPage extends StatefulWidget {
  const AnnouncementsPage(this.service, {super.key, this.linkLauncher});
  final AnnouncementService service;
  final RemoteLinkLauncher? linkLauncher;

  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  AnnouncementService get service => widget.service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(service.refresh(force: true));
    });
  }

  Future<void> _refresh() async {
    await service.refresh(force: true);
  }

  void _open(AnnouncementMessage item) {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AnnouncementDetailPage(item, linkLauncher: widget.linkLauncher),
      ),
    );
    unawaited(service.markRead(item));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final items = service.messages;
      final warning = service.error != null && service.hasCache
          ? '${service.error}，当前显示上次保存的内容'
          : service.saveError ??
                (service.skippedItems > 0 ? '部分公告暂时无法显示，其余内容可正常阅读' : null);
      return Scaffold(
        key: const Key('announcements-page'),
        appBar: AppBar(
          title: const Text('消息公告'),
          actions: [
            IconButton(
              key: const Key('announcements-read-all'),
              tooltip: '全部已读',
              onPressed: service.unreadCount == 0 ? null : service.markAllRead,
              icon: const Icon(CupertinoIcons.checkmark_circle, size: 22),
            ),
            IconButton(
              key: const Key('announcements-refresh'),
              tooltip: '刷新公告',
              onPressed: service.configured && !service.checking
                  ? _refresh
                  : null,
              icon: const Icon(CupertinoIcons.arrow_clockwise, size: 21),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                children: [
                  SizedBox(
                    height: 2,
                    child: service.checking
                        ? const LinearProgressIndicator(minHeight: 2)
                        : null,
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _refresh,
                      child: CustomScrollView(
                        key: const PageStorageKey('announcements-list'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          if (items.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  20,
                                  20,
                                  20,
                                  14,
                                ),
                                child: Wrap(
                                  spacing: 14,
                                  runSpacing: 6,
                                  children: [
                                    Text(
                                      '共 ${items.length} 条公告',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: secondary(context),
                                      ),
                                    ),
                                    Text(
                                      service.unreadCount > 0
                                          ? '${service.unreadCount} 条未读'
                                          : '已全部阅读',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: themeAccent(context),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (warning != null)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  14,
                                  18,
                                  12,
                                ),
                                child: _FeedWarning(warning),
                              ),
                            ),
                          if (items.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: _empty(context),
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                              sliver: SliverList.separated(
                                itemCount: items.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (context, index) =>
                                    _AnnouncementCard(
                                      item: items[index],
                                      unread: !service.isRead(items[index]),
                                      onTap: () => _open(items[index]),
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            service.error == null
                ? CupertinoIcons.bell
                : CupertinoIcons.wifi_exclamationmark,
            size: 40,
            color: secondary(context),
          ),
          const SizedBox(height: 18),
          Text(
            service.checking && !service.hasCache
                ? '正在获取公告…'
                : service.error ?? '暂无公告',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Text(
            service.hasCache && service.error != null
                ? '上次保存的公告列表为空'
                : '软件动态和使用通知会在这里展示',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: secondary(context),
            ),
          ),
          if (service.error != null && service.configured) ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: service.checking ? null : _refresh,
              icon: const Icon(CupertinoIcons.arrow_clockwise, size: 16),
              label: const Text('重新获取'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _FeedWarning extends StatelessWidget {
  const _FeedWarning(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: fill(context),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(CupertinoIcons.info_circle, size: 18, color: secondary(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: secondary(context),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard({
    required this.item,
    required this.unread,
    required this.onTap,
  });
  final AnnouncementMessage item;
  final bool unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: border(context), width: .7),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: ValueKey('announcement-${item.contentKey}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Icon(
                    CupertinoIcons.chevron_right,
                    size: 14,
                    color: secondary(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              announcementExcerpt(item.content),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (item.pinned) const _PinnedLabel(),
                if (item.publishedAt != null)
                  Text(
                    _dateText(item.publishedAt!),
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                Text(
                  unread ? '未读' : '已读',
                  style: TextStyle(
                    fontSize: 12,
                    color: unread ? themeAccent(context) : secondary(context),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _PinnedLabel extends StatelessWidget {
  const _PinnedLabel();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: themeAccent(context).withValues(alpha: .09),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      '置顶',
      style: TextStyle(
        fontSize: 11,
        color: themeAccent(context),
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

String _dateText(DateTime date, {bool withTime = false}) {
  final local = date.toLocal();
  String two(int value) => '$value'.padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}'
      '${withTime ? ' ${two(local.hour)}:${two(local.minute)}' : ''}';
}

class AnnouncementDetailPage extends StatelessWidget {
  const AnnouncementDetailPage(this.message, {super.key, this.linkLauncher});
  final AnnouncementMessage message;
  final RemoteLinkLauncher? linkLauncher;

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('announcement-detail-page'),
    appBar: AppBar(title: const Text('公告详情')),
    body: SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 36),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  message.title,
                  style: const TextStyle(
                    fontSize: 23,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (message.pinned || message.publishedAt != null) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (message.pinned) const _PinnedLabel(),
                      if (message.publishedAt != null)
                        Text(
                          _dateText(message.publishedAt!, withTime: true),
                          style: TextStyle(
                            fontSize: 12,
                            color: secondary(context),
                          ),
                        ),
                    ],
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  child: Divider(height: 1, color: border(context)),
                ),
                AnnouncementMarkdown(
                  message.content,
                  linkLauncher: linkLauncher,
                ),
                if (message.buttonUrl != null) ...[
                  const SizedBox(height: 32),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const Key('announcement-detail-link'),
                      onPressed: () => openAnnouncementLink(
                        context,
                        message.buttonUrl!,
                        launcher: linkLauncher,
                      ),
                      icon: const Icon(
                        CupertinoIcons.arrow_up_right_square,
                        size: 17,
                      ),
                      label: Text(message.buttonText),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
