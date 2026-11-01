import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'cast_support.dart';
import 'player_support.dart';

void main() {
  test(
    'casting holds source, pauses local audio, controls TV and returns at remote progress',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(
        castPlatform: platform,
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          platform: platform,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.seek(const Duration(seconds: 42));
      final source = fixture.current.openedSource!;
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      expect(fixture.current.state.playing, isFalse);
      expect(controller.state.playing, isTrue);
      expect(tv.position, const Duration(seconds: 42));
      expect(fixture.leases[source.url], 2);
      expect(tv.media, isNot(contains('fixture-secret')));
      expect(tv.metadata, isNot(contains('test-cookie')));
      expect(tv.media, isNot(contains('example.invalid')));
      await controller.pause();
      expect(tv.transport, 'PAUSED_PLAYBACK');
      await controller.seek(const Duration(seconds: 225));
      expect(tv.position, const Duration(seconds: 225));
      expect(fixture.current.state.position, const Duration(seconds: 42));
      await controller.play();
      await controller.background(pictureInPicture: false);
      expect(tv.transport, 'PLAYING');
      expect(controller.casting, isTrue);
      controller.foreground();
      final localPlays = fixture.current.plays;
      await controller.disconnectCast(resumeLocally: true);
      expect(tv.transport, 'STOPPED');
      expect(fixture.current.state.position, const Duration(seconds: 225));
      expect(fixture.current.plays, localPlays + 1);
      expect(fixture.leases[source.url], 1);
      fixture.current.emit(
        fixture.current.state.copyWith(position: const Duration(seconds: 240)),
      );
      await controller.saveProgress();
      expect(
        fixture.history.bookmark(controller.current.key)!.position,
        const Duration(seconds: 240),
      );
      await controller.close();
      expect(fixture.leases.values.every((n) => n == 0), isTrue);
      expect(platform.events, ['active:true', 'active:false']);
    },
  );

  for (final playing in [true, false]) {
    test(
      'a failed handoff restores the prior local ${playing ? 'playing' : 'paused'} state and releases the cast source',
      () async {
        final tv = TestTv();
        await tv.start();
        addTearDown(tv.close);
        tv.faults['Play'] = 714;
        final fixture = PlaybackFixture();
        final controller = fixture.controller;
        addTearDown(controller.close);
        await controller.start();
        if (!playing) await controller.pause();
        await expectLater(
          controller.castTo(tv.device),
          throwsA(isA<AppException>()),
        );
        expect(controller.casting, isFalse);
        expect(controller.connectingCast, isFalse);
        expect(fixture.current.state.playing, playing);
        expect(fixture.leases.values.single, 1);
        expect(tv.events, contains('Stop'));
      },
    );
  }

  test(
    'closing during SetAVTransportURI stops late remote setup before releasing source',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final barrier = Completer<void>();
      tv.barriers['SetAVTransportURI'] = barrier.future;
      final fixture = PlaybackFixture();
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      final opening = controller.castTo(tv.device);
      final assertion = expectLater(opening, throwsA(isA<AppException>()));
      await castEventually(() => tv.events.contains('SetAVTransportURI'));
      final closing = controller.close();
      expect(fixture.leases.values.single, 2);
      barrier.complete();
      await assertion;
      await closing;
      expect(tv.events.where((e) => e == 'Play'), isEmpty);
      expect(tv.events.last, 'Stop');
      expect(fixture.leases.values.single, 0);
    },
  );

  test(
    'cancel connecting does not allow a late Play or double-release',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final barrier = Completer<void>();
      tv.barriers['SetAVTransportURI'] = barrier.future;
      final fixture = PlaybackFixture();
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      final opening = controller.castTo(tv.device);
      final assertion = expectLater(opening, throwsA(isA<AppException>()));
      await castEventually(() => tv.events.contains('SetAVTransportURI'));
      final cancellation = controller.disconnectCast();
      barrier.complete();
      await assertion;
      await cancellation;
      expect(tv.events.where((e) => e == 'Play'), isEmpty);
      expect(fixture.leases.values.single, 1);
      expect(fixture.current.state.playing, isFalse);
    },
  );

  test(
    'next episode continues on the same TV without playing local audio',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) =>
            CastSession(device, source, pollInterval: const Duration(days: 1)),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      final oldSource = fixture.current.openedSource!;
      tv.position = const Duration(seconds: 117);
      await controller.castSession!.refresh();
      final firstKey = controller.current.key;
      await controller.next();
      expect(controller.index, 1);
      expect(controller.casting, isTrue);
      expect(fixture.current.plays, 0);
      expect(fixture.leases[oldSource.url], 0);
      expect(fixture.leases[fixture.current.openedSource!.url], 2);
      expect(
        fixture.history.bookmark(firstKey)!.position,
        const Duration(seconds: 117),
      );
      final setIndices = [
        for (var i = 0; i < tv.events.length; i++)
          if (tv.events[i] == 'SetAVTransportURI') i,
      ];
      expect(setIndices.length, 2);
      expect(tv.events.indexOf('Stop'), lessThan(setIndices.last));
    },
  );

  test(
    'sleep timer stops the TV and relay even when Pause is unsupported',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      tv.faults['Pause'] = 401;
      final fixture = PlaybackFixture();
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      controller.sleepTimer.afterEpisode();
      await controller.sleepTimer.finishEpisode();
      expect(tv.transport, 'STOPPED');
      expect(controller.casting, isFalse);
      expect(fixture.current.state.playing, isFalse);
      expect(fixture.leases.values.single, 1);
    },
  );

  test(
    'television completion advances to the next episode even when the TV resets its clock',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) =>
            CastSession(device, source, pollInterval: const Duration(days: 1)),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      final firstKey = controller.current.key;
      tv.position = tv.duration - const Duration(seconds: 1);
      await controller.castSession!.refresh();
      tv.position = Duration.zero;
      tv.transport = 'STOPPED';
      await controller.castSession!.refresh();
      await castEventually(
        () =>
            controller.index == 1 &&
            !controller.loading &&
            !controller.connectingCast &&
            controller.castSession?.connected == true,
      );
      expect(fixture.history.bookmark(firstKey)!.completed, isTrue);
      expect(fixture.current.plays, 0);
    },
  );

  test(
    'another user taking over the TV releases our relay without stopping their video',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture();
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      tv.media = 'http://192.168.1.20/another-movie.mp4';
      await controller.castSession!.refresh();
      await castEventually(
        () => !controller.casting && fixture.leases.values.single == 1,
      );
      expect(tv.events.where((e) => e == 'Stop'), isEmpty);
      expect(fixture.current.state.playing, isFalse);
      expect(controller.notice, contains('其他内容'));
    },
  );
  test(
    'background auto-next retains one foreground-service owner until casting ends',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(castPlatform: platform);
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      expect(platform.events, ['active:true']);
      await controller.background(pictureInPicture: false);
      tv.position = tv.duration;
      tv.transport = 'STOPPED';
      await controller.castSession!.refresh();
      await castEventually(
        () =>
            controller.index == 1 &&
            !controller.loading &&
            !controller.connectingCast &&
            controller.castSession?.connected == true,
      );
      expect(platform.events, ['active:true', 'active:true']);
      expect(fixture.current.plays, 0);
      await controller.close();
      expect(platform.events, ['active:true', 'active:true', 'active:false']);
    },
  );
  test(
    'switching episode during a pending source refresh joins the cancelled handoff and casts the new episode',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(renewable: true, castPlatform: platform);
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      fixture.current.failure = PlaybackFailure.http(403);
      final barrier = Completer<void>();
      fixture.prepareBarrier = (entry, request) async {
        if (request == 2) await barrier.future;
      };
      final opening = controller.castTo(tv.device);
      final cancelled = expectLater(opening, throwsA(isA<AppException>()));
      await castEventually(() => fixture.preparations == 2);
      final next = controller.next();
      try {
        await castEventually(
          () => controller.index == 1 && !controller.loading,
        );
      } finally {
        barrier.complete();
      }
      await cancelled;
      await next;
      expect(controller.castSession?.connected, isTrue);
      expect(tv.metadata, contains('第 2 集'));
      expect(fixture.current.plays, 0);
      expect(fixture.leases.values.where((n) => n != 0), [2]);
      await controller.close();
      expect(platform.events, ['active:true', 'active:false']);
      expect(fixture.leases.values.every((n) => n == 0), isTrue);
    },
  );
  test(
    'a failed next-source preparation releases the retained foreground service',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(castPlatform: platform);
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      fixture.prepareBarrier = (entry, request) async {
        throw const AppException('视频源已失效');
      };
      await controller.next();
      expect(controller.error, contains('视频源已失效'));
      expect(controller.casting, isFalse);
      expect(platform.events, ['active:true', 'active:false']);
      expect(fixture.leases.values.every((n) => n == 0), isTrue);
    },
  );
  test(
    'disconnecting during next-source preparation prevents a later cast or local autoplay',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(castPlatform: platform);
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      final barrier = Completer<void>();
      fixture.prepareBarrier = (entry, request) => barrier.future;
      final next = controller.next();
      try {
        await castEventually(() => fixture.preparations == 2);
        await controller.disconnectCast();
        expect(platform.events, ['active:true', 'active:false']);
      } finally {
        barrier.complete();
      }
      await next;
      expect(controller.casting, isFalse);
      expect(controller.state.playing, isFalse);
      expect(fixture.current.plays, 0);
      expect(tv.events.where((e) => e == 'SetAVTransportURI'), hasLength(1));
    },
  );
  test(
    'closing during source refresh joins cancellation and releases the late source without failing teardown',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(renewable: true, castPlatform: platform);
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      fixture.current.failure = PlaybackFailure.http(403);
      final barrier = Completer<void>();
      fixture.prepareBarrier = (entry, request) => barrier.future;
      final opening = controller.castTo(tv.device);
      final cancelled = expectLater(opening, throwsA(isA<AppException>()));
      await castEventually(() => fixture.preparations == 2);
      final closing = controller.close();
      try {
        await castEventually(() => fixture.current.closed);
      } finally {
        barrier.complete();
      }
      await cancelled;
      await closing;
      expect(fixture.leases.values.every((n) => n == 0), isTrue);
      expect(platform.events, isEmpty);
      expect(tv.events, isEmpty);
    },
  );
}
