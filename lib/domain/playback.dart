import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import 'models.dart';
import 'playback_source.dart';

enum PlaybackFit { contain, cover, stretch }

enum PlaybackOrientation { system, portrait, landscape }

enum PlaybackPlaylistOrder { source, ascending, descending }

const playbackFolderFields = {
  'rate',
  'skipIntroSeconds',
  'skipOutroSeconds',
  'subtitles',
  'subtitleSize',
  'subtitleBottom',
  'subtitleBackground',
  'subtitleBackgroundColor',
  'subtitleBackgroundOpacity',
  'fit',
  'aspectRatio',
};

const playbackAspectRatios = <String, double>{
  '原始比例': 0,
  '16:9': 16 / 9,
  '4:3': 4 / 3,
  '21:9': 21 / 9,
  '1:1': 1,
  '9:16': 9 / 16,
};

String playbackAspectLabel(double ratio) {
  for (final entry in playbackAspectRatios.entries) {
    if ((entry.value - ratio).abs() < .00001) return entry.key;
  }
  return '${ratio.toStringAsFixed(2)}:1';
}

enum SubtitleBackground { none, black, custom }

/// Display dimensions include pixel aspect ratio and rotation, exactly once.
class VideoGeometry {
  const VideoGeometry(this.width, this.height);
  final int width, height;
  double get aspectRatio => width / height;

  static VideoGeometry? fromMetadata({
    int? width,
    int? height,
    int rotation = 0,
    double pixelAspect = 1,
  }) {
    if (width == null ||
        height == null ||
        width <= 0 ||
        height <= 0 ||
        width > 65536 ||
        height > 65536 ||
        !pixelAspect.isFinite ||
        pixelAspect <= 0 ||
        pixelAspect > 100) {
      return null;
    }
    final angle = ((rotation % 360) + 360) % 360;
    final radians = angle * math.pi / 180;
    final w = width * pixelAspect, h = height.toDouble();
    final displayWidth =
        (w * math.cos(radians).abs() + h * math.sin(radians).abs()).round();
    final displayHeight =
        (w * math.sin(radians).abs() + h * math.cos(radians).abs()).round();
    if (displayWidth <= 0 ||
        displayHeight <= 0 ||
        displayWidth > 65536 ||
        displayHeight > 65536) {
      return null;
    }
    return VideoGeometry(displayWidth, displayHeight);
  }

  static VideoGeometry? fromJson(Json value) => fromMetadata(
    width: value.integer('width'),
    height: value.integer('height'),
  );
  Json toJson() => {'width': width, 'height': height};
  @override
  bool operator ==(Object other) =>
      other is VideoGeometry && width == other.width && height == other.height;
  @override
  int get hashCode => Object.hash(width, height);
}

/// Unknown sizes preserve direction; near-square videos follow the system.
PlaybackOrientation? playbackOrientation({
  required bool video,
  required bool automatic,
  int? width,
  int? height,
}) {
  if (!video || !automatic) return PlaybackOrientation.system;
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  if ((width / height - 1).abs() <= .02) return PlaybackOrientation.system;
  return width > height
      ? PlaybackOrientation.landscape
      : PlaybackOrientation.portrait;
}

double finiteRange(double value, double fallback, double min, double max) =>
    (value.isFinite ? value : fallback).clamp(min, max).toDouble();

class PlaybackPreferences {
  const PlaybackPreferences({
    this.rate = 1,
    this.volume = 100,
    this.autoNext = true,
    this.autoRotate = true,
    this.resume = true,
    this.subtitles = true,
    this.subtitleSize = 22,
    this.subtitleBottom = .04,
    this.subtitleBackground = SubtitleBackground.none,
    this.subtitleBackgroundColor = 0x202020,
    this.subtitleBackgroundOpacity = .5,
    this.fit = PlaybackFit.contain,
    this.aspectRatio = 0,
    this.connections = 8,
    this.driveConnections = const {},
    this.segmentSizeMiB = 4,
    this.hardwareAcceleration = true,
    this.skipIntroSeconds = 0,
    this.skipOutroSeconds = 0,
  });
  final double rate, volume, subtitleSize, subtitleBottom;
  final SubtitleBackground subtitleBackground;
  final int subtitleBackgroundColor;
  final double subtitleBackgroundOpacity;
  int? get subtitleBackgroundArgb =>
      subtitleBackground == SubtitleBackground.none
      ? null
      : ((subtitleBackgroundOpacity * 255).round() << 24) |
            (subtitleBackground == SubtitleBackground.black
                ? 0
                : subtitleBackgroundColor);
  final bool autoNext, autoRotate, resume, subtitles, hardwareAcceleration;
  final PlaybackFit fit;
  final double aspectRatio;
  final int connections;
  final Map<String, int> driveConnections;
  final int segmentSizeMiB, skipIntroSeconds, skipOutroSeconds;
  static const minConnections = 1, maxConnections = 512;
  static const connectionPresets = [1, 2, 4, 8, 12, 16, 32, 64, 128];

  int connectionsFor(CloudPlatform? platform) {
    final saved = platform == null ? null : driveConnections[platform.key];
    if (saved != null) return saved;
    if (platform == null) return connections;
    // Quark commonly rate-limits a single HTTP stream. Start with a higher
    // ceiling there; PlaybackBufferPolicy still ramps active requests and
    // halves them on 429/503 or timeouts.
    if (platform == CloudPlatform.quark) return 128;
    if (platform == CloudPlatform.baidu) return 4;
    return 8;
  }

  static const rates = [.5, .75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
  static const minRate = .25, maxRate = 4.0;
  static const minSubtitleSize = 14.0, maxSubtitleSize = 120.0;
  factory PlaybackPreferences.fromJson(Json value) => PlaybackPreferences(
    rate: finiteRange(value.number('rate', 1), 1, minRate, maxRate),
    volume: finiteRange(value.number('volume', 100), 100, 0, 100),
    connections: value
        .integer('connections', 8)
        .clamp(minConnections, maxConnections),
    // Older versions only stored one setting. Preserve it for every drive
    // during migration instead of silently discarding the user's preference.
    driveConnections: Map.unmodifiable({
      if (!value.containsKey('driveConnections') &&
          value.containsKey('connections'))
        for (final platform in CloudPlatform.values)
          platform.key: value
              .integer('connections', 8)
              .clamp(minConnections, maxConnections),
      for (final entry in value.obj('driveConnections').entries)
        if (CloudPlatform.fromKey(entry.key) != null &&
            int.tryParse('${entry.value}') != null)
          CloudPlatform.fromKey(entry.key)!.key: int.parse(
            '${entry.value}',
          ).clamp(minConnections, maxConnections),
    }),
    segmentSizeMiB: value.integer('segmentSizeMiB', 4).clamp(1, 16),
    hardwareAcceleration: value.boolean('hardwareAcceleration', true),
    skipIntroSeconds: value.integer('skipIntroSeconds').clamp(0, 600),
    skipOutroSeconds: value.integer('skipOutroSeconds').clamp(0, 600),
    subtitleSize: finiteRange(
      value.number('subtitleSize', 22),
      22,
      minSubtitleSize,
      maxSubtitleSize,
    ),
    subtitleBottom: finiteRange(
      value.number('subtitleBottom', .04),
      .04,
      0,
      .4,
    ),
    autoNext: value.boolean('autoNext', true),
    subtitleBackground: SubtitleBackground.values.firstWhere(
      (mode) => mode.name == value.str('subtitleBackground'),
      orElse: () => SubtitleBackground.none,
    ),
    subtitleBackgroundColor: value
        .integer('subtitleBackgroundColor', 0x202020)
        .clamp(0, 0xffffff),
    subtitleBackgroundOpacity: finiteRange(
      value.number('subtitleBackgroundOpacity', .5),
      .5,
      0,
      1,
    ),
    autoRotate: value.boolean('autoRotate', true),
    resume: value.boolean('resume', true),
    subtitles: value.boolean('subtitles', true),
    fit: PlaybackFit.values.firstWhere(
      (fit) => fit.name == value.str('fit'),
      orElse: () => PlaybackFit.contain,
    ),
    aspectRatio:
        value.number('aspectRatio').isFinite &&
            value.number('aspectRatio') >= .1 &&
            value.number('aspectRatio') <= 10
        ? value.number('aspectRatio')
        : 0,
  );
  Json toJson() => {
    'rate': rate,
    'volume': volume,
    'autoNext': autoNext,
    'autoRotate': autoRotate,
    'resume': resume,
    'subtitles': subtitles,
    'subtitleSize': subtitleSize,
    'subtitleBottom': subtitleBottom,
    'subtitleBackground': subtitleBackground.name,
    'subtitleBackgroundColor': subtitleBackgroundColor,
    'subtitleBackgroundOpacity': subtitleBackgroundOpacity,
    'fit': fit.name,
    'aspectRatio': aspectRatio,
    'connections': connections,
    'driveConnections': driveConnections,
    'segmentSizeMiB': segmentSizeMiB,
    'hardwareAcceleration': hardwareAcceleration,
    'skipIntroSeconds': skipIntroSeconds,
    'skipOutroSeconds': skipOutroSeconds,
  };
  PlaybackPreferences copyWith({
    double? rate,
    double? volume,
    double? subtitleSize,
    double? subtitleBottom,
    SubtitleBackground? subtitleBackground,
    int? subtitleBackgroundColor,
    double? subtitleBackgroundOpacity,
    bool? autoNext,
    bool? autoRotate,
    bool? resume,
    bool? subtitles,
    PlaybackFit? fit,
    double? aspectRatio,
    int? connections,
    Map<String, int>? driveConnections,
    int? segmentSizeMiB,
    bool? hardwareAcceleration,
    int? skipIntroSeconds,
    int? skipOutroSeconds,
  }) => PlaybackPreferences.fromJson({
    ...toJson(),
    'rate': rate ?? this.rate,
    'volume': volume ?? this.volume,
    'subtitleSize': subtitleSize ?? this.subtitleSize,
    'subtitleBottom': subtitleBottom ?? this.subtitleBottom,
    'subtitleBackground': (subtitleBackground ?? this.subtitleBackground).name,
    'subtitleBackgroundColor':
        subtitleBackgroundColor ?? this.subtitleBackgroundColor,
    'subtitleBackgroundOpacity':
        subtitleBackgroundOpacity ?? this.subtitleBackgroundOpacity,
    'autoNext': autoNext ?? this.autoNext,
    'autoRotate': autoRotate ?? this.autoRotate,
    'resume': resume ?? this.resume,
    'subtitles': subtitles ?? this.subtitles,
    'fit': (fit ?? this.fit).name,
    'aspectRatio': aspectRatio ?? this.aspectRatio,
    'connections': connections ?? this.connections,
    'driveConnections': driveConnections ?? this.driveConnections,
    'segmentSizeMiB': segmentSizeMiB ?? this.segmentSizeMiB,
    'hardwareAcceleration': hardwareAcceleration ?? this.hardwareAcceleration,
    'skipIntroSeconds': skipIntroSeconds ?? this.skipIntroSeconds,
    'skipOutroSeconds': skipOutroSeconds ?? this.skipOutroSeconds,
  });
}

class PlaybackBookmark {
  const PlaybackBookmark({
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.completed = false,
    this.name = '',
    this.source,
  });
  final Duration position, duration;
  final int updatedAt;
  final bool completed;
  final String name;
  final PlaybackSource? source;
  Duration get resumePosition {
    if (completed || duration <= Duration.zero || position.inSeconds < 5) {
      return Duration.zero;
    }
    final remaining = duration - position;
    final tail = math.max(5, math.min(30, duration.inSeconds * .02));
    return remaining.inSeconds <= tail ? Duration.zero : position;
  }

  factory PlaybackBookmark.fromJson(Json value) => PlaybackBookmark(
    position: Duration(
      milliseconds: value.integer('position').clamp(0, 31536000000),
    ),
    duration: Duration(
      milliseconds: value.integer('duration').clamp(0, 31536000000),
    ),
    updatedAt: value.integer('updatedAt'),
    completed: value.boolean('completed'),
    name: value.str('name'),
    source: PlaybackSource.tryFromJson(value['source']),
  );
  Json toJson() => {
    'position': position.inMilliseconds,
    'duration': duration.inMilliseconds,
    'updatedAt': updatedAt,
    'completed': completed,
    'name': name,
    if (source != null) 'source': source!.toJson(),
  };
}

class PlaybackEntry {
  const PlaybackEntry({
    required this.id,
    required this.key,
    required this.name,
    required this.video,
    this.platform,
    this.torrent = false,
    this.source,
    this.settingsFolder,
  });
  final String id, key, name;
  final bool video, torrent;
  final CloudPlatform? platform;
  final PlaybackSource? source;
  final String? settingsFolder;
}

class PlaybackRecord {
  const PlaybackRecord(this.key, this.bookmark);
  final String key;
  final PlaybackBookmark bookmark;
  String get name => bookmark.name;
  PlaybackSource? get source => bookmark.source;
}

String playbackKey(Object identity) =>
    sha256.convert(utf8.encode(jsonEncode(identity))).toString();

String cloudPlaybackKey(
  BrowseSession session,
  CloudFile file,
  int? accountRevision,
) => playbackKey([
  session.platform.key,
  session.mode.name,
  accountRevision,
  session.sourceLink?.shareId ?? session.rootId,
  file.id,
  file.size,
  file.modifiedAt,
  file.hashType,
  file.hashValue,
  if (session.isFamily) ['family', session.familyId],
  if (session.personalSpaceId.isNotEmpty) ['drive', session.personalSpaceId],
]);

Duration clampPlaybackPosition(Duration position, Duration duration) =>
    Duration(
      milliseconds: position.inMilliseconds.clamp(
        0,
        math.max(0, duration.inMilliseconds),
      ),
    );

String playbackTime(Duration time) {
  final seconds = math.max(0, time.inSeconds), hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60) % 60, remainder = seconds % 60;
  return '${hours > 0 ? '$hours:' : ''}${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
}
