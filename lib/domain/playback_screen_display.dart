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

/// Global viewing preferences, independent of a video's folder and layout.
class PlaybackScreenDisplay {
  const PlaybackScreenDisplay({
    this.enabled = false,
    this.items = const {
      PlaybackScreenItem.time,
      PlaybackScreenItem.network,
      PlaybackScreenItem.resolution,
      PlaybackScreenItem.progress,
      PlaybackScreenItem.title,
    },
  });

  final bool enabled;
  final Set<PlaybackScreenItem> items;
  bool get visible => enabled && items.isNotEmpty;

  factory PlaybackScreenDisplay.fromJson(Json json) {
    final saved = json['items'];
    return PlaybackScreenDisplay(
      enabled: json.boolean('enabled'),
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
    'items': [
      for (final item in PlaybackScreenItem.values)
        if (items.contains(item)) item.name,
    ],
  };

  PlaybackScreenDisplay copyWith({bool? enabled}) =>
      PlaybackScreenDisplay(enabled: enabled ?? this.enabled, items: items);

  PlaybackScreenDisplay withItem(PlaybackScreenItem item, bool show) =>
      PlaybackScreenDisplay(
        enabled: enabled,
        items: Set.unmodifiable({
          for (final value in items)
            if (value != item || show) value,
          if (show) item,
        }),
      );
}
