import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../diagnostics/app_log.dart';
import '../domain/playback.dart';
import '../playback/online_subtitles.dart';
import '../playback/playback_controller.dart';
import 'loading_indicator.dart';

class PlayerOnlineSubtitlePanel extends StatefulWidget {
  const PlayerOnlineSubtitlePanel({
    super.key,
    required this.controller,
    required this.subtitleDirectory,
    required this.onLoaded,
    this.service,
  });
  final PlaybackController controller;
  final Directory subtitleDirectory;
  final ValueChanged<OnlineSubtitle> onLoaded;
  final OnlineSubtitleService? service;

  @override
  State<PlayerOnlineSubtitlePanel> createState() =>
      _PlayerOnlineSubtitlePanelState();
}

class _PlayerOnlineSubtitlePanelState extends State<PlayerOnlineSubtitlePanel> {
  late final _service = widget.service ?? XunleiOnlineSubtitleService();
  late final int _generation;
  late final _input = TextEditingController(
    text: onlineSubtitleQuery(widget.controller.current.name),
  );
  RequestScope? _scope;
  List<OnlineSubtitle> _results = const [];
  OnlineSubtitle? _loading;
  String? _error;
  bool _searching = false, _stale = false;

  @override
  void initState() {
    super.initState();
    _generation = widget.controller.generation;
    widget.controller.addListener(_onPlayback);
    unawaited(_search());
  }

  void _onPlayback() {
    if (_stale) return;
    if (widget.controller.generation != _generation ||
        widget.controller.closed ||
        widget.controller.casting ||
        widget.controller.connectingCast) {
      _scope?.cancel();
      if (mounted) setState(() => _stale = true);
    }
  }

  bool _current(RequestScope scope) =>
      mounted &&
      !_stale &&
      !scope.token.isCancelled &&
      identical(scope, _scope) &&
      !widget.controller.closed &&
      widget.controller.generation == _generation;

  @override
  void dispose() {
    _scope?.cancel();
    widget.controller.removeListener(_onPlayback);
    if (widget.service == null) _service.close();
    _input.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_stale || _loading != null) return;
    _scope?.cancel();
    final scope = _scope = RequestScope();
    setState(() {
      _searching = true;
      _error = null;
      _results = const [];
    });
    try {
      final results = await _service.search(_input.text, scope);
      if (!_current(scope)) return;
      setState(() => _results = results);
      DiagnosticLog.event(
        'player.online_subtitle_search',
        fields: {'results': results.length},
      );
    } catch (e, stack) {
      if (!_current(scope)) return;
      final error = e is AppException
          ? e
          : const AppException('在线字幕搜索失败，请检查网络后重试');
      setState(() => _error = error.message);
      DiagnosticLog.error('player.online_subtitle_search_failed', error, stack);
    } finally {
      if (_current(scope)) setState(() => _searching = false);
    }
  }

  Future<void> _load(OnlineSubtitle subtitle) async {
    if (_stale || _searching || _loading != null) return;
    _scope?.cancel();
    final scope = _scope = RequestScope();
    setState(() {
      _loading = subtitle;
      _error = null;
    });
    File? pending;
    try {
      pending = await _service.download(
        subtitle,
        widget.subtitleDirectory,
        scope,
      );
      if (!mounted ||
          !_current(scope) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final staged = pending;
      pending = null;
      // The controller owns the file from this point, including failed native
      // attachment and a late video switch, until its native reader is closed.
      await widget.controller.attachSubtitle(
        staged,
        subtitle.title,
        _generation,
      );
      if (!mounted ||
          !_current(scope) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      DiagnosticLog.event(
        'player.online_subtitle_loaded',
        fields: {'format': subtitle.format},
      );
      widget.onLoaded(subtitle);
    } catch (e, stack) {
      if (!_current(scope)) return;
      final error = e is AppException
          ? e
          : const AppException('字幕加载失败，请重新选择或重试');
      setState(() => _error = error.message);
      DiagnosticLog.error(
        'player.online_subtitle_load_failed',
        error,
        stack,
        fields: {'format': subtitle.format},
      );
    } finally {
      if (pending != null && await pending.exists()) await pending.delete();
      if (_current(scope)) setState(() => _loading = null);
    }
  }

  Widget _message(String text, {bool busy = false, bool retry = false}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const Center(child: AppLoadingIndicator()),
              const SizedBox(height: 16),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.5),
            ),
            if (retry) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: _search, child: const Text('重新搜索')),
            ],
          ],
        ),
      );

  Widget _resultsSliver() {
    if (_stale) {
      return SliverToBoxAdapter(child: _message('视频已切换，请为当前视频重新打开在线字幕'));
    }
    if (_searching) {
      return SliverToBoxAdapter(child: _message('正在搜索在线字幕…', busy: true));
    }
    if (_results.isEmpty) {
      return SliverToBoxAdapter(
        child: _message(
          _error ?? '没有找到可用字幕，可以修改视频名称后重新搜索',
          retry: _error != null,
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 20),
      sliver: SliverList.builder(
        itemCount: _results.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                _error ?? '找到 ${_results.length} 个字幕，点击加载',
                style: TextStyle(
                  fontSize: 12,
                  color: _error == null
                      ? Colors.white60
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            );
          }
          final subtitle = _results[index - 1];
          final details = [
            if (subtitle.languages.isNotEmpty) subtitle.languages.join(' / '),
            subtitle.format.toUpperCase(),
            if (subtitle.duration != null)
              '时长 ${playbackTime(subtitle.duration!)}',
          ].join(' · ');
          return ListTile(
            key: ValueKey('online-subtitle-${subtitle.url}'),
            title: Text(
              subtitle.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(details),
            trailing: _loading == subtitle
                ? const AppLoadingIndicator(semanticLabel: '正在加载字幕')
                : const Icon(CupertinoIcons.arrow_down_circle, size: 22),
            onTap: _loading == null ? () => _load(subtitle) : null,
          );
        },
      ),
    );
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 12, 12),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('online-subtitle-query'),
            controller: _input,
            enabled: !_stale && _loading == null,
            maxLength: 512,
            textInputAction: TextInputAction.search,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: '视频名称',
              helperText: '可修改名称或集数，字幕来源：迅雷',
              helperMaxLines: 2,
              counterText: '',
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          key: const Key('online-subtitle-search'),
          tooltip: '搜索在线字幕',
          icon: const Icon(CupertinoIcons.search),
          onPressed: _stale || _loading != null ? null : _search,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const Key('online-subtitle-list'),
    shrinkWrap: true,
    // Keep the input at the same location in the widget tree as the keyboard
    // resizes the panel, preserving its focus and IME composing text.
    slivers: [
      SliverToBoxAdapter(child: _searchField()),
      _resultsSliver(),
    ],
  );
}
