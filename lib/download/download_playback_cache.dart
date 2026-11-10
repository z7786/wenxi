import 'dart:typed_data';
import '../domain/downloads.dart';
import '../domain/models.dart';

/// A playback reader holds the task's downloaded bytes and any open target.
/// Releasing it never pauses or deletes an unfinished download.
class DownloadPlaybackCache {
  DownloadPlaybackCache({
    required this.source,
    required this.read,
    required this.readAvailable,
    required this.snapshot,
    required Future<void> Function() onRelease,
  }) : _onRelease = onRelease;

  final DownloadSpec source;
  final Future<Uint8List?> Function(int start, int end, RemoteIdentity identity)
  read;
  final Future<Uint8List?> Function(int start, int end, RemoteIdentity identity)
  readAvailable;
  final Future<DownloadReadableState?> Function() snapshot;
  final Future<void> Function() _onRelease;
  Future<void>? _released;
  Future<void> release() => _released ??= _onRelease();
}

class DownloadReadableState {
  DownloadReadableState(this.identity, this.ranges);
  final RemoteIdentity identity;
  final List<(int, int)> ranges;

  bool contains(int start, int end) =>
      ranges.any((range) => range.$1 <= start && range.$2 > end);
}
