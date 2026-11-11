import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'app_switch.dart';
import '../core/json.dart';
import '../platform/player_screenshot.dart';
import 'player_theme.dart';

class PlayerScreenshotPanel extends StatefulWidget {
  const PlayerScreenshotPanel({
    super.key,
    required this.capture,
    required this.actions,
    required this.name,
    required this.subtitlesAvailable,
  });
  final Future<Uint8List> Function(bool) capture;
  final PlayerScreenshotActions actions;
  final String name;
  final bool subtitlesAvailable;
  @override
  State<PlayerScreenshotPanel> createState() => _PlayerScreenshotPanelState();
}

class _PlayerScreenshotPanelState extends State<PlayerScreenshotPanel> {
  Uint8List? _image;
  bool _include = false, _capturing = true, _exporting = false;
  String _message = '', _error = '';
  @override
  void initState() {
    super.initState();
    _capture();
  }

  Future<void> _capture() async {
    setState(() {
      _capturing = true;
      _error = '';
      _message = '';
      _image = null;
    });
    try {
      final bytes = await widget.capture(_include);
      if (mounted) setState(() => _image = bytes);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AppException ? error.message : '截图失败，请稍后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _export(String action) async {
    final bytes = _image;
    if (bytes == null || _capturing || _exporting) return;
    setState(() {
      _exporting = true;
      _message = '';
      _error = '';
    });
    try {
      String message = '';
      switch (action) {
        case 'save':
          final location = await widget.actions.save(bytes, widget.name);
          if (location != null) message = '已保存到 $location';
        case 'copy':
          await widget.actions.copy(bytes);
          message = '图片已复制';
        case 'share':
          final box = context.findRenderObject() as RenderBox;
          await widget.actions.share(
            bytes,
            widget.name,
            box.localToGlobal(Offset.zero) & box.size,
          );
      }
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AppException
              ? error.message
              : '截图导出失败，请检查可用空间后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _image != null && !_capturing && !_exporting;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            key: const Key('player-screenshot-preview'),
            height: 170,
            color: Colors.black,
            child: _capturing
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _image == null
                ? const Center(
                    child: Icon(
                      CupertinoIcons.photo,
                      color: Colors.white38,
                      size: 40,
                    ),
                  )
                : Image.memory(
                    _image!,
                    fit: BoxFit.contain,
                    cacheWidth: 800,
                    gaplessPlayback: true,
                  ),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '保存原始视频画面，不含播放控制按钮',
          style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
        ),
        AppSwitchListTile(
          contentPadding: EdgeInsets.zero,
          key: const Key('player-screenshot-subtitles'),
          title: const Text('包含字幕'),
          subtitle: widget.subtitlesAvailable
              ? null
              : const Text(
                  '当前未开启字幕',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
          value: _include,
          onChanged: _capturing || _exporting || !widget.subtitlesAvailable
              ? null
              : (value) {
                  _include = value;
                  _capture();
                },
        ),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _error,
              style: TextStyle(
                color: playerAccent(context),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        if (_message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _message,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        if (_exporting)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        FilledButton.icon(
          key: const Key('player-screenshot-save'),
          onPressed: ready ? () => _export('save') : null,
          icon: const Icon(CupertinoIcons.arrow_down_to_line, size: 18),
          label: const Text('保存截图'),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (widget.actions.canShare)
              OutlinedButton.icon(
                key: const Key('player-screenshot-share'),
                onPressed: ready ? () => _export('share') : null,
                icon: const Icon(CupertinoIcons.share, size: 18),
                label: const Text('分享图片'),
              ),
            if (widget.actions.canCopy)
              OutlinedButton.icon(
                key: const Key('player-screenshot-copy'),
                onPressed: ready ? () => _export('copy') : null,
                icon: const Icon(CupertinoIcons.doc_on_doc, size: 18),
                label: const Text('复制图片'),
              ),
            if (!_capturing && _image == null)
              TextButton(onPressed: _capture, child: const Text('重新截图')),
          ],
        ),
      ],
    );
  }
}
