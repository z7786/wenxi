import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:asterlink/playback/playback_state.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import 'media_backend.dart';
import 'playback_failure.dart';
import 'playback_screen_info.dart';

/// Transport-specific status belongs outside the platform playback engine.
class DelegatingPlaybackBackend extends PlaybackBackend {
  DelegatingPlaybackBackend(this.delegate) {
    delegate.addListener(_changed);
  }
  final PlaybackBackend delegate;
  bool _closing = false;
  Future<void>? _closeFuture;
  void _changed() {
    if (!_closing) notifyListeners();
  }

  @override
  PlayerState get state => delegate.state;
  @override
  VideoGeometry? get videoGeometry => delegate.videoGeometry;
  @override
  VideoController? get videoController => delegate.videoController;
  @override
  Future<void> setDecoderCompatibility(bool enabled) =>
      delegate.setDecoderCompatibility(enabled);
  @override
  void setRenderViewport(
    Size viewport,
    double pixelRatio,
    BoxFit fit,
    double scale,
  ) => delegate.setRenderViewport(viewport, pixelRatio, fit, scale);
  @override
  Widget? buildVideo({required BoxFit fit, double? aspectRatio}) =>
      delegate.buildVideo(fit: fit, aspectRatio: aspectRatio);
  @override
  Widget? buildSubtitleOverlay() => delegate.buildSubtitleOverlay();
  @override
  bool get usesSubtitleOverlay => delegate.usesSubtitleOverlay;
  @override
  String get engineName => delegate.engineName;
  @override
  int get errorRevision => delegate.errorRevision;
  @override
  PlaybackFailure? get failure => delegate.failure;
  @override
  bool get canRetryWithSoftware => delegate.canRetryWithSoftware;
  @override
  String get streamingDescription => delegate.streamingDescription;
  @override
  Map<String, Object?> get diagnosticFields => delegate.diagnosticFields;
  @override
  PlaybackScreenInfo get screenInfo => delegate.screenInfo;
  @override
  void setScreenDisplayMonitoringEnabled(bool enabled) =>
      delegate.setScreenDisplayMonitoringEnabled(enabled);
  @override
  bool get rendersSubtitlesNatively => delegate.rendersSubtitlesNatively;
  @override
  bool get supportsScreenshot => delegate.supportsScreenshot;
  @override
  Future<Uint8List?> screenshot({bool includeSubtitles = false}) =>
      delegate.screenshot(includeSubtitles: includeSubtitles);
  @override
  String get subtitleFontMessage => delegate.subtitleFontMessage;
  @override
  bool get subtitleFontLoading => delegate.subtitleFontLoading;
  @override
  Future<void> retrySubtitleFont() => delegate.retrySubtitleFont();
  @override
  bool? get hardwareDecodingActive => delegate.hardwareDecodingActive;
  @override
  Future<void> initialize() => delegate.initialize();
  @override
  Future<void> setSubtitlePresentation({
    required double size,
    double? width,
    required double height,
    required double bottom,
    int? backgroundColor,
  }) => delegate.setSubtitlePresentation(
    size: size,
    width: width,
    height: height,
    bottom: bottom,
    backgroundColor: backgroundColor,
  );
  @override
  Future<void> setConnections(int value) => delegate.setConnections(value);
  @override
  Future<void> setSegmentSizeMiB(int value) =>
      delegate.setSegmentSizeMiB(value);
  @override
  Future<void> open(DownloadSpec source, Duration start) =>
      delegate.open(source, start);
  @override
  Future<void> play() => delegate.play();
  @override
  Future<void> pause() => delegate.pause();
  @override
  Future<void> seek(Duration position) => delegate.seek(position);
  @override
  Future<void> setRate(double value) => delegate.setRate(value);
  @override
  Future<void> setVolume(double value) => delegate.setVolume(value);
  @override
  Future<void> setAudioTrack(AudioTrack track) => delegate.setAudioTrack(track);
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      delegate.setSubtitleTrack(track);
  @override
  Future<void> setSubtitleDelay(double seconds) =>
      delegate.setSubtitleDelay(seconds);
  @override
  Future<void> setAudioDelay(double seconds) => delegate.setAudioDelay(seconds);
  @override
  Future<void> close() => _closeFuture ??= () async {
    _closing = true;
    delegate.removeListener(_changed);
    try {
      await delegate.close();
    } finally {
      super.dispose();
    }
  }();
}
