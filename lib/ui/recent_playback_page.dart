import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/playback_store.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import '../platform/file_access.dart';
import '../playback/playback_controller.dart';
import '../playback/recent_playback.dart';
import 'common.dart';
import 'app_context_menu.dart';
import 'app_popup_menu.dart';
import 'baidu_download_prompt.dart';
import 'player_page.dart';
import 'uc_tv_authorization_page.dart';

List<PlaybackRecord> recentPlayback(AppServices services) =>
    PlaybackStore(services.store).recent;

Future<void> openRecentPlayback(
  BuildContext context,
  AppServices services,
  PlaybackRecord record,
) async {
  PlaybackController? candidate;
  final controller = await busy(context, () async {
    candidate = await restoreRecentPlayback(services, record);
    return candidate!;
  }, label: '正在恢复播放…');
  if (controller == null || !context.mounted) {
    if (candidate != null) {
      services.finishPlaybackInBackground(candidate!.close());
    }
    return;
  }
  try {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          controller,
          confirmDownload: (playerContext) => confirmBaiduDownload(
            playerContext,
            services,
            controller.current.platform,
            session: controller.current.source?.cloud?.session,
          ),
          onAuthorizeUcTv: controller.current.platform == CloudPlatform.uc
              ? (playerContext) => openUcTvAuthorization(
                  playerContext,
                  services,
                  accountId:
                      controller.current.source?.cloud?.session.accountId,
                )
              : null,
          subtitleDirectory: Directory(
            '${services.cacheDirectory.path}/playback-subtitles',
          ),
          onDownload:
              {
                PlaybackSourceKind.local,
                PlaybackSourceKind.download,
              }.contains(record.source?.kind)
              ? null
              : (DownloadSpec source) async {
                  await services.downloads.enqueue(source);
                },
        ),
      ),
    );
  } finally {
    services.finishPlaybackInBackground(controller.close());
  }
}

class RecentPlaybackPage extends StatefulWidget {
  const RecentPlaybackPage(this.services, {super.key, this.onOpen});
  final AppServices services;
  final Future<void> Function(PlaybackRecord)? onOpen;
  @override
  State<RecentPlaybackPage> createState() => _RecentPlaybackPageState();
}

class _RecentPlaybackPageState extends State<RecentPlaybackPage>
    with WidgetsBindingObserver {
  bool _opening = false;
  final _availability = <String, Future<FileAvailability>>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(_availability.clear);
    }
  }

  Future<void> _open(PlaybackRecord record) async {
    if (_opening || PlaybackStore(widget.services.store).historyHidden) return;
    setState(() => _opening = true);
    try {
      if (widget.onOpen != null) {
        await widget.onOpen!(record);
      } else {
        await openRecentPlayback(context, widget.services, record);
      }
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
          _availability.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.services.store,
    builder: (context, _) {
      final hidden = PlaybackStore(widget.services.store).historyHidden;
      final entries = hidden
          ? const <PlaybackRecord>[]
          : recentPlayback(widget.services);
      return PageFrame(
        title: '最近播放',
        actions: [
          _RecentPlaybackVisibilityButton(widget.services, enabled: !_opening),
          if (entries.isNotEmpty)
            TextButton(
              onPressed: _opening
                  ? null
                  : () async {
                      if (await confirm(
                            context,
                            '清空播放记录',
                            '将清除播放进度和播放记录，已下载文件会保留。',
                          ) &&
                          context.mounted) {
                        await PlaybackStore(
                          widget.services.store,
                        ).clearHistory();
                      }
                    },
              child: const Text('清空'),
            ),
        ],
        child: hidden
            ? const EmptyPanel(
                '播放记录已隐藏',
                '点击右上角眼睛图标可恢复显示',
                icon: CupertinoIcons.eye_slash,
              )
            : entries.isEmpty
            ? const EmptyPanel(
                '暂无播放记录',
                '播放过的音视频会显示在这里',
                icon: CupertinoIcons.play_rectangle,
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    itemCount: entries.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final source = entry.source;
                      if (source?.kind == PlaybackSourceKind.local) {
                        return FutureBuilder<FileAvailability>(
                          future: _availability.putIfAbsent(
                            entry.key,
                            () => widget.services.files.inspect(source!.path),
                          ),
                          builder: (context, snapshot) => _tile(
                            context,
                            entry,
                            availability:
                                snapshot.data ?? FileAvailability.unknown,
                          ),
                        );
                      }
                      return _tile(context, entry);
                    },
                  ),
                ),
              ),
      );
    },
  );

  Widget _tile(
    BuildContext context,
    PlaybackRecord record, {
    FileAvailability? availability,
  }) {
    return AppContextMenu<String>(
      key: ValueKey(record.key),
      identity: record.key,
      actions: () =>
          recentPlayback(widget.services).any((r) => r.key == record.key)
          ? [
              AppMenuAction(
                value: 'open',
                label: '继续播放',
                icon: CupertinoIcons.play_rectangle,
                enabled:
                    !_opening &&
                    record.source != null &&
                    availability != FileAvailability.missing &&
                    availability != FileAvailability.inaccessible,
              ),
              const AppMenuAction(
                value: 'copy-name',
                label: '复制名称',
                icon: CupertinoIcons.doc_on_doc,
              ),
              const AppMenuAction(
                value: 'remove',
                label: '移除记录',
                icon: CupertinoIcons.trash,
                destructive: true,
              ),
            ]
          : [],
      onSelected: (action) async {
        switch (action) {
          case 'open':
            await _open(record);
          case 'copy-name':
            await widget.services.copyText(record.name);
            if (context.mounted) message(context, '名称已复制');
          case 'remove':
            await PlaybackStore(widget.services.store).remove(record.key);
        }
      },
      child: _tileContent(context, record, availability: availability),
    );
  }

  Widget _tileContent(
    BuildContext context,
    PlaybackRecord record, {
    FileAvailability? availability,
  }) {
    final bookmark = record.bookmark;
    final unavailable =
        availability == FileAvailability.missing ||
        availability == FileAvailability.inaccessible;
    final status = record.source == null
        ? '旧版记录 · 请从原文件列表打开一次'
        : unavailable
        ? availability!.label
        : record.source!.label;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: ValueKey('recent-play-${record.key}'),
        contentPadding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        leading: FileGlyph(record.name.ifEmpty('video.mp4')),
        title: Text(
          record.name.ifEmpty('已播放的媒体'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                status,
                style: TextStyle(
                  fontSize: 12,
                  color: unavailable
                      ? Theme.of(context).colorScheme.error
                      : secondary(context),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                _progressLabel(bookmark),
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
              if (bookmark.duration > Duration.zero) ...[
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    value:
                        (bookmark.position.inMilliseconds /
                                bookmark.duration.inMilliseconds)
                            .clamp(0, 1),
                    backgroundColor: fill(context),
                    color: themeAccent(context),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                formatDate(bookmark.updatedAt),
                style: TextStyle(fontSize: 11, color: secondary(context)),
              ),
            ],
          ),
        ),
        onTap: _opening ? null : () => _open(record),
        trailing: PopupMenuButton<String>(
          tooltip: '管理播放记录',
          onSelected: (_) =>
              PlaybackStore(widget.services.store).remove(record.key),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'remove', child: Text('移除记录')),
          ],
          icon: const Icon(CupertinoIcons.ellipsis, size: 20),
        ),
      ),
    );
  }
}

String _progressLabel(PlaybackBookmark bookmark) => bookmark.completed
    ? '已播完'
    : bookmark.duration > Duration.zero
    ? '已播放 ${playbackTime(bookmark.position)} / ${playbackTime(bookmark.duration)}'
    : '点击开始播放';

class RecentPlaybackSummary extends StatefulWidget {
  const RecentPlaybackSummary(
    this.services, {
    super.key,
    required this.desktop,
    this.enabled = true,
  });
  final AppServices services;
  final bool desktop, enabled;
  @override
  State<RecentPlaybackSummary> createState() => _RecentPlaybackSummaryState();
}

class _RecentPlaybackSummaryState extends State<RecentPlaybackSummary> {
  bool _opening = false;
  Future<void> _open(PlaybackRecord record) async {
    if (_opening ||
        !widget.enabled ||
        PlaybackStore(widget.services.store).historyHidden) {
      return;
    }
    setState(() => _opening = true);
    try {
      await openRecentPlayback(context, widget.services, record);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.services.store,
    builder: (context, _) {
      final hidden = PlaybackStore(widget.services.store).historyHidden;
      final record = hidden
          ? null
          : recentPlayback(widget.services).firstOrNull;
      final enabled = widget.enabled && !_opening;
      void history() => Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => RecentPlaybackPage(widget.services)),
      );
      return Padding(
        padding: EdgeInsets.all(widget.desktop ? 20 : 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: const Key('parse-recent'),
                    onTap: enabled ? history : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '最近播放',
                              style: TextStyle(
                                fontSize: widget.desktop ? 14 : 18,
                                fontWeight: widget.desktop
                                    ? FontWeight.w600
                                    : FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            '全部',
                            style: TextStyle(
                              fontSize: 12,
                              color: secondary(context),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            CupertinoIcons.chevron_right,
                            size: 14,
                            color: themeAccent(context),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                _RecentPlaybackVisibilityButton(
                  widget.services,
                  enabled: enabled,
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (hidden)
              Text(
                '播放记录已隐藏',
                style: TextStyle(fontSize: 13, color: secondary(context)),
              )
            else if (record == null)
              Text(
                '暂无播放记录',
                style: TextStyle(fontSize: 13, color: secondary(context)),
              )
            else
              InkWell(
                key: const Key('parse-recent-resume'),
                onTap: enabled ? () => _open(record) : null,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              record.name.ifEmpty('已播放的媒体'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              record.source == null
                                  ? '旧版记录 · 需从原文件打开'
                                  : '${record.source!.label} · ${_progressLabel(record.bookmark)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                color: secondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(
                        record.source == null
                            ? CupertinoIcons.info_circle
                            : CupertinoIcons.play_circle_fill,
                        color: themeAccent(context),
                        size: 32,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}

class _RecentPlaybackVisibilityButton extends StatefulWidget {
  const _RecentPlaybackVisibilityButton(this.services, {required this.enabled});
  final AppServices services;
  final bool enabled;

  @override
  State<_RecentPlaybackVisibilityButton> createState() =>
      _RecentPlaybackVisibilityButtonState();
}

class _RecentPlaybackVisibilityButtonState
    extends State<_RecentPlaybackVisibilityButton> {
  bool _saving = false;

  Future<void> _toggle() async {
    if (_saving || !widget.enabled) return;
    setState(() => _saving = true);
    try {
      final history = PlaybackStore(widget.services.store);
      await history.setHistoryHidden(!history.historyHidden);
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = PlaybackStore(widget.services.store).historyHidden;
    return IconButton(
      key: const Key('recent-playback-visibility'),
      tooltip: hidden ? '显示最近播放' : '隐藏最近播放',
      onPressed: widget.enabled && !_saving ? _toggle : null,
      icon: Icon(
        hidden ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
        size: 19,
        color: secondary(context),
      ),
    );
  }
}
