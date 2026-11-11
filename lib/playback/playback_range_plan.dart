import 'dart:math' as math;

/// Each new media read ramps up in connection-sized waves. Small chunks let
/// later connections contribute sequential bytes before the first 4 MiB fills.
class PlaybackRangePlan {
  PlaybackRangePlan(
    this.start,
    this.end,
    this.chunkBytes, {
    this.metadata = false,
  });
  final int start, end, chunkBytes;
  final bool metadata;
  static const initialBytes = 512 * 1024;
  static const wave = 8;

  (int, int) range(int index) {
    if (metadata || chunkBytes <= initialBytes) {
      final aligned = (start ~/ chunkBytes + index) * chunkBytes;
      return (
        math.max(start, aligned),
        math.min(end, aligned + chunkBytes - 1),
      );
    }
    var offset = start, size = initialBytes, remaining = index;
    while (size < chunkBytes) {
      if (remaining < wave) break;
      offset += wave * size;
      remaining -= wave;
      size = math.min(chunkBytes, size * 2);
    }
    final first = offset + remaining * size;
    return (first, math.min(end, first + size - 1));
  }

  int get last {
    if (metadata || chunkBytes <= initialBytes) {
      return end ~/ chunkBytes - start ~/ chunkBytes;
    }
    var bytes = end - start, size = initialBytes, index = 0;
    while (size < chunkBytes && bytes >= wave * size) {
      bytes -= wave * size;
      index += wave;
      size = math.min(chunkBytes, size * 2);
    }
    return index + bytes ~/ size;
  }
}
