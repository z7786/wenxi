/// Measures aggregate network input, rather than consumption from the cache.
/// A new backend, counter reset or unavailable counter starts a fresh window.
class PlaybackScreenSpeed {
  Object? _source;
  int? _bytes;
  Duration? _at;
  double? value;

  double? sample(Object? source, int? bytes, Duration elapsed) {
    if (!identical(source, _source) ||
        bytes == null ||
        bytes < 0 ||
        _bytes == null ||
        bytes < _bytes! ||
        _at == null ||
        elapsed < _at!) {
      _source = source;
      _bytes = bytes;
      _at = elapsed;
      value = null;
      return value;
    }
    final window = elapsed - _at!;
    if (window >= const Duration(seconds: 1)) {
      value = (bytes - _bytes!) * 1000000 / window.inMicroseconds;
      _bytes = bytes;
      _at = elapsed;
    }
    return value;
  }
}
