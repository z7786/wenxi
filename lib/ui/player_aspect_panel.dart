import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../domain/playback.dart';
import 'player_theme.dart';

class PlayerAspectPanel extends StatefulWidget {
  const PlayerAspectPanel({
    super.key,
    required this.preferences,
    required this.onChanged,
    this.onTransformChanged,
  });
  final PlaybackPreferences preferences;
  final ValueChanged<PlaybackPreferences> onChanged;
  final void Function(PlaybackPreferences, bool save)? onTransformChanged;
  @override
  State<PlayerAspectPanel> createState() => _PlayerAspectPanelState();
}

class _PlayerAspectPanelState extends State<PlayerAspectPanel> {
  late final _width = TextEditingController(
    text: widget.preferences.aspectRatio > 0
        ? widget.preferences.aspectRatio.toStringAsFixed(4)
        : '16',
  );
  late final _height = TextEditingController(
    text: widget.preferences.aspectRatio > 0 ? '1' : '9',
  );
  String? _error;
  void _transform(PlaybackPreferences preferences, bool save) {
    if (widget.onTransformChanged case final changed?) {
      changed(preferences, save);
    } else {
      widget.onChanged(preferences);
    }
  }

  @override
  void dispose() {
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  void _custom() {
    final width = double.tryParse(_width.text.trim()),
        height = double.tryParse(_height.text.trim());
    final ratio = width == null || height == null || height <= 0
        ? double.nan
        : width / height;
    if (!ratio.isFinite ||
        ratio < .1 ||
        ratio > 10 ||
        width! <= 0 ||
        width > 10000 ||
        height! > 10000) {
      setState(() => _error = '请输入有效宽高，宽高比需在 1:10 至 10:1 之间');
      return;
    }
    setState(() => _error = null);
    widget.onChanged(
      widget.preferences.copyWith(fit: PlaybackFit.contain, aspectRatio: ratio),
    );
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) => ListView(
    shrinkWrap: true,
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
    children: [
      const Text('显示方式', style: TextStyle(color: Colors.white60, fontSize: 12)),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final fit in PlaybackFit.values)
            ChoiceChip(
              key: ValueKey('player-fit-${fit.name}'),
              label: Text(switch (fit) {
                PlaybackFit.contain => '适应画面',
                PlaybackFit.cover => '填充画面',
                PlaybackFit.stretch => '拉伸铺满',
              }),
              selected: widget.preferences.fit == fit,
              onSelected: (_) => widget.onChanged(
                widget.preferences.copyWith(
                  fit: fit,
                  aspectRatio: fit == PlaybackFit.stretch ? 0 : null,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        switch (widget.preferences.fit) {
          PlaybackFit.contain => '完整显示画面，空余区域保留黑边',
          PlaybackFit.cover => '铺满屏幕，可能裁切画面边缘',
          PlaybackFit.stretch => '随屏幕拉伸，不保持视频比例',
        },
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 12,
          height: 1.5,
        ),
      ),
      const SizedBox(height: 24),
      Text(
        '视频比例 · ${playbackAspectLabel(widget.preferences.aspectRatio)}',
        style: const TextStyle(color: Colors.white60, fontSize: 12),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final preset in playbackAspectRatios.entries)
            ChoiceChip(
              key: ValueKey('player-aspect-${preset.key}'),
              label: Text(preset.key),
              selected:
                  (widget.preferences.aspectRatio - preset.value).abs() <
                      .00001 &&
                  widget.preferences.fit != PlaybackFit.stretch,
              onSelected: (_) => widget.onChanged(
                widget.preferences.copyWith(
                  aspectRatio: preset.value,
                  fit: PlaybackFit.contain,
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 24),
      const Text('自定义宽高比', style: TextStyle(fontSize: 14)),
      const SizedBox(height: 12),
      Row(
        children: [
          for (final item in [
            ('width', '宽', _width),
            ('height', '高', _height),
          ]) ...[
            if (item.$1 == 'height')
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(':'),
              ),
            Expanded(
              child: TextField(
                key: ValueKey('player-aspect-${item.$1}'),
                controller: item.$3,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  LengthLimitingTextInputFormatter(9),
                ],
                decoration: InputDecoration(
                  labelText: item.$2,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onSubmitted: (_) => _custom(),
              ),
            ),
          ],
        ],
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            _error!,
            style: TextStyle(color: playerAccent(context), fontSize: 12),
          ),
        ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _custom,
        key: const Key('player-aspect-apply'),
        child: const Text('应用自定义比例'),
      ),
      const SizedBox(height: 24),
      Text(
        '视频缩放 · ${(widget.preferences.videoScale * 100).round()}%',
        style: const TextStyle(color: Colors.white60, fontSize: 12),
      ),
      Slider(
        key: const Key('player-video-scale'),
        min: .5,
        max: 3,
        divisions: 50,
        value: widget.preferences.videoScale,
        label: '${(widget.preferences.videoScale * 100).round()}%',
        onChanged: (value) =>
            _transform(widget.preferences.copyWith(videoScale: value), false),
        onChangeEnd: (value) =>
            _transform(widget.preferences.copyWith(videoScale: value), true),
      ),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final scale in [.5, 1.0, 1.5, 2.0, 3.0])
            ChoiceChip(
              label: Text('${(scale * 100).round()}%'),
              selected: widget.preferences.videoScale == scale,
              onSelected: (_) => widget.onChanged(
                widget.preferences.copyWith(videoScale: scale),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      for (final horizontal in [true, false]) ...[
        Text(
          horizontal ? '水平位置' : '垂直位置',
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
        Slider(
          key: Key(
            horizontal ? 'player-video-offset-x' : 'player-video-offset-y',
          ),
          min: -1,
          max: 1,
          divisions: 40,
          value: horizontal
              ? widget.preferences.videoOffsetX
              : widget.preferences.videoOffsetY,
          onChanged: (value) => _transform(
            widget.preferences.copyWith(
              videoOffsetX: horizontal ? value : null,
              videoOffsetY: horizontal ? null : value,
            ),
            false,
          ),
          onChangeEnd: (value) => _transform(
            widget.preferences.copyWith(
              videoOffsetX: horizontal ? value : null,
              videoOffsetY: horizontal ? null : value,
            ),
            true,
          ),
        ),
      ],
      OutlinedButton(
        key: const Key('player-video-transform-reset'),
        onPressed: () => widget.onChanged(
          widget.preferences.copyWith(
            videoScale: 1,
            videoOffsetX: 0,
            videoOffsetY: 0,
          ),
        ),
        child: const Text('重置缩放与位置'),
      ),
      const SizedBox(height: 24),
    ],
  );
}
