import 'dart:typed_data';
import '../domain/downloads.dart';
import '../domain/models.dart';
import 'media_backend.dart';

typedef PlaybackCacheReader =
    Future<Uint8List?> Function(
      DownloadSpec source,
      int start,
      int end,
      RemoteIdentity identity,
    );

PlaybackBackend createPlaybackBackend({
  required bool video,
  bool hardwareAcceleration = true,
  PlaybackCacheReader? downloadCache,
}) => MediaKitBackend(
  video: video,
  hardwareAcceleration: hardwareAcceleration,
  downloadCache: downloadCache,
);
