import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'player_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'A final initialization error pauses a backend that already began playback',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.failAtPlay = true;
      await fixture.controller.start();
      expect(fixture.backends, hasLength(2));
      expect(fixture.current.plays, 1);
      expect(fixture.current.state.playing, isFalse);
      expect(fixture.current.pauses, greaterThan(0));
      expect(fixture.controller.error, isNotEmpty);
      expect(fixture.controller.ready, isFalse);
    },
  );

  test(
    'Runtime errors pause once and cannot be resumed by hidden gestures before retry',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      fixture.current.fail();
      final pauses = fixture.current.pauses, plays = fixture.current.plays;
      expect(fixture.current.state.playing, isFalse);
      expect(fixture.controller.ready, isFalse);
      fixture.current.fail();
      await fixture.controller.toggle();
      expect(fixture.current.pauses, pauses);
      expect(fixture.current.plays, plays);
      expect(fixture.backends, hasLength(1));
      await fixture.controller.retry();
      expect(fixture.controller.ready, isTrue);
      expect(fixture.current.state.playing, isTrue);
    },
  );

  test(
    'Transport errors are distinguished from decoder initialization failures',
    () {
      expect(isPlaybackSourceError('HTTP error 403 Forbidden'), isTrue);
      expect(
        isPlaybackSourceError('Failed to open https://example.invalid/video'),
        isTrue,
      );
      expect(isPlaybackSourceError('Connection refused'), isTrue);
      expect(
        isPlaybackSourceError('Could not initialize video decoder'),
        isFalse,
      );
      expect(
        isPlaybackSourceError('Video output initialization failed'),
        isFalse,
      );
    },
  );

  test(
    'A known source failure does not rebuild the decoder or reacquire a share',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) {
        backend.failOpen = true;
        backend.sourceFailure = true;
      };
      await fixture.controller.start();
      expect(fixture.backends, hasLength(1));
      expect(fixture.preparations, 1);
      expect(fixture.controller.error, isNotEmpty);
    },
  );

  test(
    'Playback defaults and legacy preferences preserve per-drive choices',
    () {
      const defaults = PlaybackPreferences();
      expect(defaults.connections, 8);
      expect(defaults.segmentSizeMiB, 4);
      expect(defaults.connectionsFor(CloudPlatform.quark), 128);
      expect(defaults.connectionsFor(CloudPlatform.baidu), 4);
      expect(
        defaults
            .copyWith(driveConnections: {CloudPlatform.uc.key: 32})
            .connectionsFor(CloudPlatform.quark),
        128,
      );
      final custom = defaults.copyWith(
        driveConnections: {CloudPlatform.quark.key: 256},
      );
      expect(
        PlaybackPreferences.fromJson(
          custom.toJson(),
        ).connectionsFor(CloudPlatform.quark),
        256,
      );
      final legacy = PlaybackPreferences.fromJson({
        'connections': 4,
        'rate': 1.5,
      });
      expect(legacy.connectionsFor(CloudPlatform.uc), 4);
      expect(
        legacy.copyWith(subtitles: false).connectionsFor(CloudPlatform.quark),
        4,
      );
      final invalid = PlaybackPreferences.fromJson({
        'connections': 999,
        'segmentSizeMiB': 999,
        'driveConnections': {
          'Uc': -1,
          'Quark': '16',
          'Baidu': 'invalid',
          'unknown': 8,
        },
        'skipIntroSeconds': -1,
        'skipOutroSeconds': 99999,
      });
      expect(invalid.connections, 512);
      expect(invalid.connectionsFor(CloudPlatform.uc), 1);
      expect(invalid.connectionsFor(CloudPlatform.quark), 16);
      expect(invalid.connectionsFor(CloudPlatform.baidu), 4);
      expect(invalid.segmentSizeMiB, 16);
      expect(invalid.skipIntroSeconds, 0);
      expect(invalid.skipOutroSeconds, 600);
      expect(
        PlaybackPreferences.fromJson(invalid.toJson()).toJson(),
        invalid.toJson(),
      );
    },
  );

  test(
    'Changing connections only changes the selected drive and persists across episodes',
    () async {
      final fixture = PlaybackFixture(
        platforms: [CloudPlatform.quark, CloudPlatform.uc, CloudPlatform.quark],
      );
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      expect(fixture.current.connections, 128);
      await fixture.controller.setConnections(96);
      expect(fixture.current.connections, 96);
      expect(
        fixture.history.preferences.connectionsFor(CloudPlatform.quark),
        96,
      );
      await fixture.controller.next();
      expect(fixture.current.connections, 8);
      await fixture.controller.next();
      expect(fixture.current.connections, 96);
    },
  );

  test(
    'Hardware initialization retries once in software using the same leased source',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.failHardwareOpen = true;
      await fixture.controller.start();
      expect(fixture.controller.error, isEmpty);
      expect(fixture.controller.ready, isTrue);
      expect(fixture.controller.usingSoftwareDecoder, isTrue);
      expect(fixture.controller.preferences.hardwareAcceleration, isTrue);
      expect(fixture.preparations, 1);
      expect(fixture.backends, hasLength(2));
      expect(fixture.backends.first.closed, isTrue);
      expect(fixture.current.hardwareAcceleration, isFalse);
      expect(fixture.current.state.playing, isTrue);
      expect(fixture.leases.values, [1]);
      await fixture.controller.close();
      expect(fixture.leases.values, [0]);
    },
  );

  test(
    'Software initialization failure stops after the bounded retry',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.failOpen = true;
      await fixture.controller.start();
      expect(fixture.backends, hasLength(2));
      expect(fixture.controller.loading, isFalse);
      expect(fixture.controller.error, isNotEmpty);
      expect(fixture.current.plays, 0);
      expect(fixture.preparations, 1);
    },
  );

  test(
    'An asynchronous initialization error also triggers the single software retry',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      final openingGate = Completer<void>();
      fixture.configureBackend = (backend) {
        if (backend.hardwareAcceleration) {
          backend.openBarrier = openingGate.future;
        }
      };
      final opening = fixture.controller.start();
      await until(
        () =>
            fixture.backends.isNotEmpty && fixture.current.openedSource != null,
      );
      fixture.current.fail();
      openingGate.complete();
      await opening;
      expect(fixture.controller.error, isEmpty);
      expect(fixture.controller.usingSoftwareDecoder, isTrue);
      expect(fixture.backends, hasLength(2));
      expect(fixture.preparations, 1);
    },
  );

  test(
    'Changing the connection budget during loading reaches the opening backend',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      final openingGate = Completer<void>();
      fixture.configureBackend = (backend) =>
          backend.openBarrier = openingGate.future;
      final opening = fixture.controller.start();
      await until(
        () =>
            fixture.backends.isNotEmpty && fixture.current.openedSource != null,
      );
      expect(fixture.controller.loading, isTrue);
      await fixture.controller.setConnections(16);
      expect(fixture.current.connections, 16);
      openingGate.complete();
      await opening;
      expect(fixture.current.connections, 16);
    },
  );

  test(
    'Choosing software decoding does not attempt an automatic hardware retry',
    () async {
      final fixture = PlaybackFixture(
        data: {
          'playbackPreferences': {'hardwareAcceleration': false},
        },
      );
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.failOpen = true;
      await fixture.controller.start();
      expect(fixture.backends, hasLength(1));
      expect(fixture.current.hardwareAcceleration, isFalse);
      expect(fixture.controller.error, isNotEmpty);
    },
  );

  test(
    'Leaving during hardware reconstruction never opens another backend or leaks its extra lease',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      final closingGate = Completer<void>();
      fixture.configureBackend = (backend) {
        backend.failHardwareOpen = true;
        backend.closeBarrier = closingGate.future;
      };
      final opening = fixture.controller.start();
      await until(
        () => fixture.backends.isNotEmpty && fixture.backends.first.closes > 0,
      );
      final closing = fixture.controller.close();
      closingGate.complete();
      await Future.wait([opening, closing]);
      expect(fixture.backends, hasLength(1));
      expect(fixture.leases.values, [0]);
    },
  );

  test(
    'Decoder and segment changes preserve a paused position even with resume disabled',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(resume: false),
      );
      await fixture.controller.start();
      await fixture.controller.seek(const Duration(seconds: 86));
      await fixture.controller.pause();
      await fixture.controller.setHardwareAcceleration(false);
      expect(fixture.current.openedStart, const Duration(seconds: 86));
      expect(fixture.current.plays, 0);
      expect(fixture.current.hardwareAcceleration, isFalse);
      await fixture.controller.setSegmentSizeMiB(6);
      expect(fixture.current.openedStart, const Duration(seconds: 86));
      expect(fixture.current.segmentSizeMiB, 6);
      expect(fixture.current.plays, 0);
      expect(fixture.history.preferences.segmentSizeMiB, 6);
      expect(fixture.leases.values.where((count) => count != 0), [1]);
    },
  );

  test(
    'Intro and outro skipping use real duration and advance to the next episode once',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(
          skipIntroSeconds: 30,
          skipOutroSeconds: 20,
        ),
      );
      await fixture.controller.start();
      expect(fixture.current.seeks.last, const Duration(seconds: 30));
      final first = fixture.current;
      first.emit(first.state.copyWith(position: const Duration(seconds: 581)));
      first.emit(first.state.copyWith(position: const Duration(seconds: 582)));
      await until(
        () => fixture.controller.index == 1 && fixture.controller.ready,
      );
      expect(fixture.preparations, 2);
      expect(
        fixture.history.bookmark(fixture.entries[0].key)?.completed,
        isTrue,
      );
      expect(fixture.current.seeks.last, const Duration(seconds: 30));
    },
  );

  test(
    'Short clips and disabled auto-next do not get skipped accidentally',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.emit(
        backend.state.copyWith(duration: const Duration(seconds: 20)),
      );
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(
          skipIntroSeconds: 60,
          skipOutroSeconds: 60,
        ),
      );
      await fixture.controller.start();
      expect(fixture.current.seeks, isEmpty);
      fixture.current.emit(
        fixture.current.state.copyWith(position: const Duration(seconds: 19)),
      );
      await fixture.store.flush();
      expect(fixture.preparations, 1);
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(
          autoNext: false,
          skipIntroSeconds: 0,
          skipOutroSeconds: 5,
        ),
      );
      fixture.current.emit(
        fixture.current.state.copyWith(position: const Duration(seconds: 19)),
      );
      await fixture.store.flush();
      expect(fixture.preparations, 1);
    },
  );
}
