/// One reconstruction, then at most one software attempt for modest workloads.
/// This is a conservative ceiling, not a claim about a particular CPU's speed.
class PlaybackDecoderRecovery {
  /// Unknown metadata must not turn a failed 4K hardware open into a CPU load.
  static bool allowsSoftware({
    required int? width,
    required int? height,
    required double? fps,
    required double rate,
  }) =>
      width != null &&
      height != null &&
      width > 0 &&
      height > 0 &&
      width * height <= 1920 * 1080 &&
      fps != null &&
      fps.isFinite &&
      fps >= 1 &&
      rate.isFinite &&
      rate > 0 &&
      rate <= 1 &&
      fps * rate <= 30;

  int attempts = 0;
  bool _allowSoftware = false;
  bool? hardwareOverride;

  void reset() {
    attempts = 0;
    _allowSoftware = false;
    hardwareOverride = null;
  }

  bool? next({
    required bool hardware,
    required int? width,
    required int? height,
    required double? fps,
    required double rate,
  }) {
    if (attempts == 0) {
      _allowSoftware =
          hardware &&
          allowsSoftware(width: width, height: height, fps: fps, rate: rate);
      attempts++;
      return hardwareOverride = hardware;
    }
    if (attempts == 1 && hardware && _allowSoftware && rate <= 1) {
      attempts++;
      return hardwareOverride = false;
    }
    return null;
  }
}
