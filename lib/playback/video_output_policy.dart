import 'dart:io';

/// Output selection is separate from the decoder's hardware acceleration.
bool get supportsNativeHardwareRendering =>
    !Platform.isMacOS ||
    Platform.environment['ASTERLINK_MACOS_SOFTWARE_RENDERING'] != '1';
