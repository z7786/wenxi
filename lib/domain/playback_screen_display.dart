import '../core/json.dart';

enum PlaybackScreenItem {
  time,
  network,
  resolution,
  progress,
  title,
  parameters,
  media,
}

enum PlaybackScreenStyle { outline, background }

/// Global viewing preferences, independent of a video's folder and layout.
class PlaybackScreenDisplay {
  const PlaybackScreenDisplay({
    this.enabled = false,
    this.style = PlaybackScreenStyle.outline,
    this.items = const {
      PlaybackScreenItem.time,
      PlaybackScreenItem.network,
      PlaybackScreenItem.resolution,
      PlaybackScreenItem.progress,
      PlaybackScreenItem.title,
    },
  });

  final bool enabled;
  final PlaybackScreenStyle style;
  final Set<PlaybackScreenItem> items;
  bool get visible => enabled && items.isNotEmpty;

  factory PlaybackScreenDisplay.fromJson(Json json) {
    final saved = json['items'];
    return PlaybackScreenDisplay(
      enabled: json.boolean('enabled'),
      style: PlaybackScreenStyle.values.firstWhere(
        (style) => style.name == json.str('style'),
        orElse: () => PlaybackScreenStyle.outline,
      ),
      items: saved is List
          ? Set.unmodifiable(
              PlaybackScreenItem.values.where(
                (item) => saved.contains(item.name),
              ),
            )
          : const PlaybackScreenDisplay().items,
    );
  }

  Json toJson() => {
    'enabled': enabled,
    'style': style.name,
    'items': [
      for (final item in PlaybackScreenItem.values)
        if (items.contains(item)) item.name,
    ],
  };

  PlaybackScreenDisplay copyWith({bool? enabled, PlaybackScreenStyle? style}) =>
      PlaybackScreenDisplay(
        enabled: enabled ?? this.enabled,
        style: style ?? this.style,
        items: items,
      );

  PlaybackScreenDisplay withItem(PlaybackScreenItem item, bool show) =>
      PlaybackScreenDisplay(
        enabled: enabled,
        style: style,
        items: Set.unmodifiable({
          for (final value in items)
            if (value != item || show) value,
          if (show) item,
        }),
      );
}
