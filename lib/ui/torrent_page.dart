import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../download/torrent_session.dart';
import '../domain/torrent.dart';
import '../playback/playback_controller.dart';
import '../playback/torrent_playback.dart';
import 'common.dart';
import 'loading_indicator.dart';
import 'player_page.dart';
import 'torrent_file_tree.dart';

class TorrentPage extends StatefulWidget {
  const TorrentPage(this.services, this.source, {super.key});
  final AppServices services;
  final String source;
  @override
  State<TorrentPage> createState() => _TorrentPageState();
}

class _TorrentPageState extends State<TorrentPage> {
  late TorrentSession session;
  final selected = <int>{};
  final _filesScroll = ScrollController();
  final _collapsed = <String>{};
  TorrentFileTree? _tree;
  bool _initialized = false, _adding = false, _playing = false;
  String _error = '';
  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    session = TorrentSession(widget.services.engine, widget.services.transfer);
    session.addListener(_changed);
    unawaited(session.resolve(widget.source));
  }

  void _changed() {
    if (!mounted) return;
    if (!_initialized && session.info != null) {
      _initialized = true;
      _tree = TorrentFileTree(session.info!.files);
      selected.addAll(session.info!.files.map((f) => f.index));
    }
    setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    session.dispose();
    _filesScroll.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_adding || selected.isEmpty || session.info == null) return;
    setState(() {
      _adding = true;
      _error = '';
    });
    try {
      final ids = await widget.services.downloads.enqueueTorrent(
        session.info!,
        selected.toList()..sort(),
      );
      if (!mounted) return;
      message(
        context,
        '已添加 ${ids.length} 个 BT 文件到下载队列',
        onTap: widget.services.requestDownloadManager,
      );
      Navigator.pop(context, true);
    } on DownloadConfirmationCancelled {
      // Keep the selection available for a later download.
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is AppException ? e.message : '添加下载失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _play(TorrentFile file) async {
    final info = session.info;
    if (_adding || _playing || info == null || !file.playable) return;
    setState(() {
      _playing = true;
      _error = '';
    });
    PlaybackController? controller;
    try {
      final playback = torrentPlayback(widget.services, info, file);
      controller = playback;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            playback,
            subtitleDirectory: Directory(
              '${widget.services.cacheDirectory.path}/playback-subtitles',
            ),
            onDownload: (source) async {
              await widget.services.downloads.enqueueTorrent(info, [
                source.torrent!.integer('index'),
              ]);
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is AppException ? e.message : '无法开始播放，请重试');
      }
    } finally {
      if (controller != null) {
        widget.services.finishPlaybackInBackground(controller.close());
      }
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = session.info;
    final rows = _tree?.visible(_collapsed) ?? [];
    final rowIndices = {
      for (var i = 0; i < rows.length; i++) _nodeKey(rows[i].node): i,
    };
    return PopScope(
      canPop: !_adding,
      child: PageFrame(
        title: 'BT 文件解析',
        child: info == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (session.error.isEmpty)
                        const AppLoadingEmblem(size: 64),
                      const SizedBox(height: 20),
                      Text(
                        session.error.isEmpty ? session.stage : session.error,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      if (session.error.isNotEmpty)
                        FilledButton(
                          onPressed: () {
                            session.removeListener(_changed);
                            session.dispose();
                            setState(() {
                              _initialized = false;
                              _tree = null;
                              _collapsed.clear();
                              selected.clear();
                              _start();
                            });
                          },
                          child: const Text('重试'),
                        ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  ListTile(
                    dense: true,
                    minTileHeight: 64,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    horizontalTitleGap: 12,
                    leading: Icon(
                      CupertinoIcons.arrow_down_circle,
                      color: themeAccent(context),
                    ),
                    title: Tooltip(
                      message: info.name,
                      child: Text(
                        info.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    subtitle: Text(
                      '${info.files.length} 个文件 · ${formatBytes(info.size)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        style: _selectionButtonStyle,
                        onPressed: _adding
                            ? null
                            : () => setState(
                                () => selected.addAll(
                                  info.files.map((f) => f.index),
                                ),
                              ),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        style: _selectionButtonStyle,
                        onPressed: _adding
                            ? null
                            : () => setState(selected.clear),
                        child: const Text('清空选择'),
                      ),
                      if (_tree!.root.folders.isNotEmpty)
                        TextButton(
                          style: _selectionButtonStyle,
                          onPressed: () => setState(() {
                            if (_collapsed.isEmpty) {
                              void collapse(TorrentFileNode node) {
                                for (final folder in node.folders.values) {
                                  _collapsed.add(folder.path);
                                  collapse(folder);
                                }
                              }

                              collapse(_tree!.root);
                            } else {
                              _collapsed.clear();
                            }
                          }),
                          child: Text(_collapsed.isEmpty ? '收起文件夹' : '展开文件夹'),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          '已选 ${selected.length} 个',
                          style: TextStyle(
                            fontSize: 12,
                            color: secondary(context),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: ScrollConfiguration.of(
                        context,
                      ).copyWith(scrollbars: false),
                      child: Scrollbar(
                        controller: _filesScroll,
                        child: ListView.builder(
                          key: const PageStorageKey('torrent-files'),
                          controller: _filesScroll,
                          padding: const EdgeInsets.only(bottom: 4),
                          itemCount: rows.length,
                          findChildIndexCallback: (key) => rowIndices[key],
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return row.node.directory
                                ? _folderRow(row.node, row.depth)
                                : _fileRow(row.node.file!, row.depth);
                          },
                        ),
                      ),
                    ),
                  ),
                  if (_error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('torrent-download'),
                          onPressed: selected.isEmpty || _adding ? null : _add,
                          icon: const Icon(CupertinoIcons.arrow_down),
                          label: Text(
                            _adding
                                ? '正在加入队列…'
                                : MediaQuery.sizeOf(context).width < 400 &&
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(14) >
                                          20
                                ? '下载 ${selected.length} 个文件'
                                : '下载选中 ${selected.length} 个文件',
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  ButtonStyle get _selectionButtonStyle => TextButton.styleFrom(
    textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 12),
    padding: const EdgeInsets.symmetric(horizontal: 10),
    minimumSize: const Size(48, 48),
  );

  Key _nodeKey(TorrentFileNode node) => node.directory
      ? ValueKey('torrent-folder-${node.path}')
      : ValueKey('torrent-file-${node.file!.index}');

  double _indent(int depth) => (depth * 12.0).clamp(0, 48);

  Widget _folderRow(TorrentFileNode node, int depth) {
    final count = node.indices.where(selected.contains).length;
    final checked = count == node.indices.length
        ? true
        : count == 0
        ? false
        : null;
    final expanded = !_collapsed.contains(node.path);
    return ListTile(
      key: _nodeKey(node),
      dense: true,
      minTileHeight: 60,
      minVerticalPadding: 6,
      horizontalTitleGap: 8,
      contentPadding: EdgeInsets.only(left: 12 + _indent(depth), right: 12),
      leading: Checkbox(
        tristate: true,
        value: checked,
        semanticLabel: '选择文件夹 ${node.name}',
        onChanged: _adding
            ? null
            : (_) => setState(() {
                if (checked == true) {
                  selected.removeAll(node.indices);
                } else {
                  selected.addAll(node.indices);
                }
              }),
      ),
      title: Row(
        children: [
          Icon(
            expanded ? CupertinoIcons.folder_open : CupertinoIcons.folder,
            size: 20,
            color: themeAccent(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: node.path,
              child: Text(
                node.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${node.indices.length} 个文件 · ${formatBytes(node.size)} · 已选 $count',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: secondary(context)),
      ),
      trailing: Icon(
        expanded ? CupertinoIcons.chevron_down : CupertinoIcons.chevron_right,
        size: 14,
        color: secondary(context),
      ),
      onTap: () => setState(() {
        if (expanded) {
          _collapsed.add(node.path);
        } else {
          _collapsed.remove(node.path);
        }
      }),
    );
  }

  Widget _fileRow(TorrentFile file, int depth) => CheckboxListTile(
    key: ValueKey('torrent-file-${file.index}'),
    dense: true,
    minTileHeight: 60,
    minVerticalPadding: 6,
    horizontalTitleGap: 8,
    contentPadding: EdgeInsets.only(left: 12 + _indent(depth), right: 12),
    value: selected.contains(file.index),
    onChanged: _adding
        ? null
        : (value) => setState(() {
            if (value == true) {
              selected.add(file.index);
            } else {
              selected.remove(file.index);
            }
          }),
    title: Tooltip(
      message: file.path,
      excludeFromSemantics: true,
      child: Text(
        file.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        semanticsLabel: file.path,
        style: const TextStyle(fontSize: 14, height: 1.3),
      ),
    ),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Text(
            formatBytes(file.size),
            style: TextStyle(fontSize: 12, color: secondary(context)),
          ),
          if (file.directory.isNotEmpty) ...[
            Text(
              ' · ',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
            Expanded(
              child: Text(
                file.directory,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
            ),
          ],
        ],
      ),
    ),
    controlAffinity: ListTileControlAffinity.leading,
    secondary: file.playable
        ? IconButton(
            key: ValueKey('torrent-play-${file.index}'),
            tooltip: '在线播放 ${file.name}',
            onPressed: _adding || _playing ? null : () => _play(file),
            color: themeAccent(context),
            icon: const Icon(CupertinoIcons.play_circle_fill, size: 26),
          )
        : null,
  );
}
