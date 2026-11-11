import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_video_monitor.dart';

void main() {
  late PlaybackVideoMonitor monitor;
  setUp(() => monitor = PlaybackVideoMonitor());
  bool sample(
    int second, {
    bool eligible = true,
    bool ready = true,
    int? position,
  }) => monitor.observe(
    elapsed: Duration(seconds: second),
    position: Duration(seconds: position ?? second),
    outputReady: ready,
    eligible: eligible,
    rate: 1,
  );

  test('Missing output or stalled video progress triggers recovery', () {
    for (final ready in [false, true]) {
      monitor.reset();
      for (var i = 0; i < 15; i++) {
        expect(sample(i, ready: ready, position: ready ? 7 : i), isFalse);
      }
      expect(sample(15, ready: ready, position: ready ? 7 : 15), isTrue);
    }
  });
  test('Video progress keeps static-looking footage healthy', () {
    for (var i = 0; i < 60; i++) {
      expect(sample(i), isFalse);
    }
  });
  test('Absent surface cannot be hidden by advancing playback position', () {
    for (var i = 0; i < 15; i++) {
      expect(sample(i, ready: false), isFalse);
    }
    expect(sample(15, ready: false), isTrue);
  });
  test(
    'Pause, buffering, background, seek and unsupported tracks reset the deadline',
    () {
      for (var i = 0; i < 14; i++) {
        sample(i, position: 1);
      }
      expect(sample(14, eligible: false), isFalse);
      for (var i = 15; i < 30; i++) {
        expect(sample(i, position: 1), isFalse);
      }
      expect(sample(30, position: 1), isTrue);
    },
  );
  test('Seek jumps and delayed timers start a new window', () {
    for (var i = 0; i < 14; i++) {
      sample(i, position: 1);
    }
    expect(sample(14, position: 100), isFalse);
    expect(sample(100, position: 100), isFalse);
  });
}
