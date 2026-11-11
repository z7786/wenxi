import 'package:flutter/material.dart';
import '../domain/playback.dart' show playbackTime;
import '../playback/playback_state.dart';

/// A remote-friendly layout: media fills the screen, controls stay inside the
/// overscan area, and every action exposes a visible directional focus target.
class PlayerTvControls extends StatelessWidget {
  const PlayerTvControls({
    super.key,
    required this.title,
    required this.state,
    required this.playFocus,
    required this.ready,
    required this.canSeek,
    required this.onToggle,
    required this.onSeek,
    required this.onBack,
    required this.onSettings,
    required this.onPlaylist,
    required this.onSubtitles,
    required this.onCast,
    required this.onActivity,
    this.onPrevious,
    this.onNext,
  });

  final String title;
  final PlayerState state;
  final FocusNode playFocus;
  final bool ready, canSeek;
  final VoidCallback onToggle, onBack, onSettings, onPlaylist, onActivity;
  final VoidCallback? onPrevious, onNext, onSubtitles, onCast;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final horizontal = (box.maxWidth * .05).clamp(16.0, 48.0);
      final vertical = (box.maxHeight * .05).clamp(12.0, 27.0);
      return FocusTraversalGroup(
        child: Stack(
          key: const Key('player-tv-controls'),
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  horizontal,
                  vertical,
                  horizontal,
                  36,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    _button('返回', Icons.arrow_back, onBack),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  horizontal,
                  40,
                  horizontal,
                  vertical,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _TvTimeline(
                      state: state,
                      enabled:
                          ready && canSeek && state.duration > Duration.zero,
                      onSeek: onSeek,
                      onActivity: onActivity,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _button('上一集', Icons.skip_previous, onPrevious),
                        _button(
                          '后退 15 秒',
                          Icons.fast_rewind,
                          ready && canSeek
                              ? () => onSeek(
                                  state.position - const Duration(seconds: 15),
                                )
                              : null,
                        ),
                        _button(
                          state.playing ? '暂停' : '播放',
                          state.playing ? Icons.pause : Icons.play_arrow,
                          ready ? onToggle : null,
                          focusNode: playFocus,
                          key: const Key('player-tv-play'),
                        ),
                        _button(
                          '前进 15 秒',
                          Icons.fast_forward,
                          ready && canSeek
                              ? () => onSeek(
                                  state.position + const Duration(seconds: 15),
                                )
                              : null,
                        ),
                        _button('下一集', Icons.skip_next, onNext),
                        _button('选集', Icons.video_library_outlined, onPlaylist),
                        if (onSubtitles != null)
                          _button('字幕', Icons.subtitles_outlined, onSubtitles),
                        if (onCast != null) _button('投屏', Icons.cast, onCast),
                        _button('设置', Icons.settings_outlined, onSettings),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '方向键选择 · 确认键操作 · 返回键收起控件',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.white70),
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

  Widget _button(
    String label,
    IconData icon,
    VoidCallback? action, {
    FocusNode? focusNode,
    Key? key,
  }) => IconButton.filledTonal(
    key: key,
    focusNode: focusNode,
    tooltip: label,
    iconSize: 28,
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(52, 52)),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? Colors.white30
            : Colors.white,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? const Color(0xff3f669b)
            : Colors.white12,
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.focused)
              ? Colors.white
              : Colors.transparent,
          width: 2,
        ),
      ),
    ),
    onPressed: action == null
        ? null
        : () {
            onActivity();
            action();
          },
    icon: Icon(icon),
  );
}

class _TvTimeline extends StatefulWidget {
  const _TvTimeline({
    required this.state,
    required this.enabled,
    required this.onSeek,
    required this.onActivity,
  });
  final PlayerState state;
  final bool enabled;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onActivity;
  @override
  State<_TvTimeline> createState() => _TvTimelineState();
}

class _TvTimelineState extends State<_TvTimeline> {
  final focus = FocusNode(debugLabel: 'TV timeline');
  double? preview;
  bool focused = false;
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final max = widget.state.duration.inMilliseconds.toDouble();
    final position =
        (preview ?? widget.state.position.inMilliseconds.toDouble()).clamp(
          0.0,
          max > 0 ? max : 1.0,
        );
    return Focus(
      canRequestFocus: false,
      onFocusChange: (value) {
        setState(() => focused = value);
        widget.onActivity();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(
              context,
            ).copyWith(trackHeight: focused ? 8 : 4),
            child: Slider(
              key: const Key('player-tv-timeline'),
              focusNode: focus,
              value: position,
              max: max > 0 ? max : 1,
              onChanged: widget.enabled
                  ? (value) {
                      widget.onActivity();
                      setState(() => preview = value);
                    }
                  : null,
              onChangeStart: (_) => widget.onActivity(),
              onChangeEnd: widget.enabled
                  ? (value) {
                      setState(() => preview = null);
                      widget.onSeek(Duration(milliseconds: value.round()));
                    }
                  : null,
            ),
          ),
          Text(
            '${playbackTime(Duration(milliseconds: position.round()))} / ${playbackTime(widget.state.duration)}',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }
}
