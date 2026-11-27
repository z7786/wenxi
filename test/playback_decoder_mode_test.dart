import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/video_output_policy.dart';

void main() {
  test('Windows compatibility only permits copy-back hardware decoders', () {
    expect(
      playbackDecoderMode(TargetPlatform.windows, compatible: true),
      'auto-copy',
    );
    expect(
      playbackDecoderMode(TargetPlatform.windows, compatible: false),
      'auto',
    );
  });

  test(
    'Android keeps its platform decoder and unsupported platforms defer',
    () {
      expect(
        playbackDecoderMode(TargetPlatform.android, compatible: true),
        'mediacodec-copy',
      );
      expect(
        playbackDecoderMode(TargetPlatform.android, compatible: false),
        'mediacodec,mediacodec-copy',
      );
      for (final platform in [
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.fuchsia,
      ]) {
        expect(playbackDecoderMode(platform, compatible: true), isNull);
        expect(playbackDecoderMode(platform, compatible: false), isNull);
      }
    },
  );
}
