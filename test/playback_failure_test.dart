import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_failure.dart';

void main() {
  for (final message in [
    'amediacodec: java.lang.IllegalStateException: Invalid to call at Released state; only valid in executing state',
    'amediacodec: java.lang.IllegalStateException: flush() is valid only at Executing states; currently at Released state',
    'hevc_mediacodec: Failed to dequeue output buffer (status=-542398533)',
    'h264_mediacodec: Invalid to call in Uninitialized state',
    'AMediaCodec: state=Released',
  ]) {
    test('An unavailable system decoder is terminal: $message', () {
      final failure = PlaybackFailure.fromLog(message);
      expect(failure, isNotNull);
      expect(failure!.kind, PlaybackFailureKind.decoder);
      expect(failure.decoderUnavailable, isTrue);
      expect(failure.refreshable, isFalse);
      expect(failure.sourceFailure, isFalse);
    });
  }

  for (final message in [
    'hevc_mediacodec: Both surface and native_window are NULL',
    'hevc_mediacodec: Failed to dequeue output buffer (status=-11)',
    'hevc_mediacodec: Failed to flush codec',
    'hevc: Could not find ref with POC 120',
    'Error decoding frame; continuing with the next frame',
    'amediacodec: Started state',
    'MediaCodec output buffer is unavailable, retrying',
    'error: property not found _setProperty(osc, 1)',
    'sub: Subtitle converter is in Released state',
  ]) {
    test('Recoverable or unrelated logs do not stop decoding: $message', () {
      expect(
        PlaybackFailure.fromLog(message)?.decoderUnavailable ?? false,
        isFalse,
      );
    });
  }

  test('HTTP expiration still refreshes without rebuilding the decoder', () {
    final failure = PlaybackFailure.fromLog('http: Server returned 403');
    expect(failure!.refreshable, isTrue);
    expect(failure.decoderUnavailable, isFalse);
    expect(failure.sourceFailure, isTrue);
  });
}
