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
      selected.addAll(session.info!.files.map((f) => f.index));
    }
    setState(() {});
  }

  @override
  void dispose() {
    session.removeListener(_changed);
    session.dispose();
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
      await controller?.close();
      if (mounted) setState(() => _playing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = session.info;
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
                    leading: Icon(
                      CupertinoIcons.arrow_down_circle,
                      color: themeAccent(context),
                    ),
                    title: Text(
                      info.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${info.files.length} 个文件 · ${formatBytes(info.size)}${info.files.any((file) => file.playable) ? '\n点击播放按钮即可在线播放' : ''}',
                    ),
                  ),
                  Row(
                    children: [
                      TextButton(
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
                        onPressed: _adding
                            ? null
                            : () => setState(selected.clear),
                        child: const Text('清空选择'),
                      ),
                      Expanded(
                        child: Text(
                          '已选 ${selected.length} 个',
                          textAlign: TextAlign.end,
                        ),
                      ),
                      const SizedBox(width: 20),
                    ],
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: info.files.length,
                      itemBuilder: (context, index) {
                        final file = info.files[index];
                        return CheckboxListTile(
                          key: ValueKey('torrent-file-$index'),
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
                          title: Text(file.name),
                          subtitle: Text(
                            '${file.path}\n${formatBytes(file.size)}',
                          ),
                          controlAffinity: ListTileControlAffinity.leading,
                          secondary: file.playable
                              ? IconButton(
                                  key: ValueKey('torrent-play-${file.index}'),
                                  tooltip: '在线播放 ${file.name}',
                                  onPressed: _adding || _playing
                                      ? null
                                      : () => _play(file),
                                  color: themeAccent(context),
                                  icon: const Icon(
                                    CupertinoIcons.play_circle_fill,
                                    size: 30,
                                  ),
                                )
                              : null,
                        );
                      },
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
                      padding: const EdgeInsets.all(18),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const Key('torrent-download'),
                          onPressed: selected.isEmpty || _adding ? null : _add,
                          icon: const Icon(CupertinoIcons.arrow_down),
                          label: Text(
                            _adding ? '正在加入队列…' : '下载选中 ${selected.length} 个文件',
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
}
