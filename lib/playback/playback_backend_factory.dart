import 'dart:typed_data';
import '../domain/downloads.dart';
import '../domain/models.dart';
import '../download/download_playback_cache.dart';
import 'media_backend.dart';

typedef PlaybackCacheReader =
    Future<Uint8List?> Function(
      DownloadSpec source,
      int start,
      int end,
      RemoteIdentity identity,
    );
typedef PlaybackCacheSnapshot =
    Future<DownloadReadableState?> Function(DownloadSpec source);

PlaybackBackend createPlaybackBackend({
  required bool video,
  bool hardwareAcceleration = true,
  PlaybackCacheReader? downloadCache,
  PlaybackCacheSnapshot? downloadSnapshot,
}) => MediaKitBackend(
  video: video,
  hardwareAcceleration: hardwareAcceleration,
  downloadCache: downloadCache,
  downloadSnapshot: downloadSnapshot,
);
