import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'player_support.dart';

void main() {
  for (final (label, width, height, fps, rate) in [
    ('4K', 3840, 2160, 24.0, 1.0),
    ('60fps', 1920, 1080, 60.0, 1.0),
    ('unknown fps', 1920, 1080, null, 1.0),
    ('unknown size', 0, 0, 24.0, 1.0),
    ('double speed', 1920, 1080, 24.0, 2.0),
  ]) {
    test(
      'Initial $label failure never automatically starts software',
      () async {
        final fixture = PlaybackFixture(
          data: {
            'playbackPreferences': {'rate': rate},
          },
        );
        addTearDown(fixture.controller.close);
        fixture.configureBackend = (backend) => backend
          ..describeVideo(width: width, height: height, fps: fps)
          ..failHardwareOpen = true;
        await fixture.controller.start();
        expect(fixture.backends, hasLength(1));
        expect(fixture.controller.error, isNotEmpty);
        expect(fixture.current.hardwareAcceleration, isTrue);
        expect(fixture.current.state.playing, isFalse);
      },
    );
  }

  test('Unknown container metadata does not silently retry software', () async {
    final fixture = PlaybackFixture();
    addTearDown(fixture.controller.close);
    fixture.configureBackend = (backend) => backend.failHardwareOpen = true;
    await fixture.controller.start();
    expect(fixture.backends, hasLength(1));
    expect(fixture.controller.error, isNotEmpty);
  });

  test(
    'Presentation errors do not rebuild an otherwise working decoder',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.describeVideo();
      fixture.controller.beforePlay = () async =>
          throw StateError('presentation');
      await fixture.controller.start();
      expect(fixture.backends, hasLength(1));
      expect(fixture.current.plays, 0);
      expect(fixture.controller.error, isNotEmpty);
    },
  );

  test(
    'Native initialization timeout does not trigger another decoder',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend
        ..describeVideo()
        ..openBarrier = Future<void>.delayed(Duration.zero, () {
          throw TimeoutException('native reply');
        });
      await fixture.controller.start();
      expect(fixture.backends, hasLength(1));
      expect(fixture.controller.error, isNotEmpty);
    },
  );

  test('Manual software selection still permits 4K', () async {
    final fixture = PlaybackFixture(
      data: {
        'playbackPreferences': {'hardwareAcceleration': false},
      },
    );
    addTearDown(fixture.controller.close);
    fixture.configureBackend = (backend) =>
        backend.describeVideo(width: 3840, height: 2160, fps: 60);
    await fixture.controller.start();
    expect(fixture.backends, hasLength(1));
    expect(fixture.controller.ready, isTrue);
    expect(fixture.current.hardwareAcceleration, isFalse);
  });
}
