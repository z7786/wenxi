import '../core/json.dart';

class DownloadSpaceException extends AppException {
  const DownloadSpaceException({
    this.volume,
    this.freeBytes,
    this.requiredBytes,
    this.reservedBytes,
    this.marginBytes,
  }) : super('存储空间不足，进度已保留，请释放空间后继续');
  final String? volume;
  final int? freeBytes, requiredBytes, reservedBytes, marginBytes;
}

class SpaceBudget {
  SpaceBudget(
    this.available, {
    this.margin = 32 * 1024 * 1024,
    this.availableOnVolume,
  });
  final Future<int> Function() available;
  final Future<int> Function(String volume)? availableOnVolume;
  final int margin;
  final _reservations = <String, Map<String, int>>{};
  final _gate = AsyncGate();
  static int required(int total, int downloaded, {bool copy = true}) =>
      (total - downloaded.clamp(0, total)).clamp(0, total) + (copy ? total : 0);
  Future<void> reserve(String id, int remaining) =>
      reserveVolumes(id, {'cache': remaining});
  Future<void> reserveVolumes(
    String id,
    Map<String, int> remaining,
  ) => _gate.run(() async {
    for (final entry in remaining.entries) {
      require(entry.value >= 0, '下载空间计算错误');
      // Finished payloads only need room for their destination copy. A full
      // cache volume must not block reading bytes that are already on disk.
      if (entry.value == 0) continue;
      final free = await (availableOnVolume?.call(entry.key) ?? available());
      final others = _reservations.entries
          .where((e) => e.key != id)
          .fold(0, (sum, e) => sum + (e.value[entry.key] ?? 0));
      // Some document providers do not expose capacity. The writer reports
      // storage errors while retaining the task's existing bytes/checkpoint.
      if (free >= 0 && free < others + entry.value + margin) {
        throw DownloadSpaceException(
          volume: entry.key,
          freeBytes: free,
          requiredBytes: entry.value,
          reservedBytes: others,
          marginBytes: margin,
        );
      }
    }
    _reservations[id] = {
      for (final e in remaining.entries)
        if (e.value > 0) e.key: e.value + margin,
    };
  });
  void consume(String id, String volume, int bytes) {
    final reservation = _reservations[id];
    final value = reservation?[volume];
    if (value != null && bytes > 0) {
      reservation![volume] = (value - bytes).clamp(margin, value);
    }
  }

  void release(String id) => _reservations.remove(id);
}
