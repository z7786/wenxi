import 'dart:io';
import 'package:flutter/foundation.dart';

/// Output selection is separate from the decoder's hardware acceleration.
bool get supportsNativeHardwareRendering =>
    !Platform.isMacOS ||
    Platform.environment['ASTERLINK_MACOS_SOFTWARE_RENDERING'] != '1';

/// Copy-back hardware decoding avoids importing decoder surfaces into the
/// renderer. Do not change GPU rendering or crop the video's visible pixels.
String? playbackDecoderMode(
  TargetPlatform platform, {
  required bool compatible,
}) => switch (platform) {
  TargetPlatform.android =>
    compatible ? 'mediacodec-copy' : 'mediacodec,mediacodec-copy',
  TargetPlatform.windows => compatible ? 'auto-copy' : 'auto',
  _ => null,
};
