import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'package:asterlink/playback/cast/dlna.dart';
import 'package:asterlink/playback/cast/cast_network.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'cast_support.dart';
import 'player_support.dart';

void main() {
  Future<TestTv> receiver() async {
    final tv = TestTv();
    await tv.start();
    addTearDown(tv.close);
    return tv;
  }

  CastSession sessionFor(TestTv tv) {
    final session = CastSession(
      tv.device,
      const DownloadSpec(
        url: 'https://example.invalid/video.mp4',
        fileName: 'movie.mp4',
      ),
      platform: TestCastPlatform(),
      localAddress: (_) async => InternetAddress.loopbackIPv4,
      prepareSource: false,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(session.close);
    return session;
  }

  Future<void> start(
    CastSession session,
    TestTv tv, {
    Duration position = Duration.zero,
    bool playing = true,
  }) async {
    await session.start(
      title: 'movie',
      position: position,
      duration: tv.duration,
      playWhenReady: playing,
    );
    await session.refresh();
  }

  test(
    'failed resume control keeps a successful TV playback and bookmark',
    () async {
      final tv = await receiver();
      tv.responses['Seek'] = TestTvResponse.disconnectBefore;
      final session = sessionFor(tv);
      await start(session, tv, position: const Duration(seconds: 197));
      expect(session.connected, isTrue);
      expect(tv.transport, 'PLAYING');
      expect(tv.events, isNot(contains('Stop')));
      expect(session.bookmarkState.position, const Duration(seconds: 197));
      expect(session.warning, contains('进度'));
    },
  );

  test(
    'control requests work on receivers rejecting reused HTTP connections',
    () async {
      final tv = await receiver()
        ..rejectReusedConnections = true;
      final client = DlnaClient();
      addTearDown(client.close);
      final device = (await client.describe(tv.location))!;
      await client.setMedia(
        device,
        'http://127.0.0.1:51000/session/video',
        'movie',
        'video/mp4',
        tv.duration,
      );
      await client.transport(device, 'Play', {'Speed': '1'});
      await client.transport(device, 'GetTransportInfo');
      expect(tv.events, isNot(contains('connection_reused')));
      expect(tv.connectionPorts.toSet(), hasLength(tv.connectionPorts.length));
      expect(
        tv.requests.every((r) => r.headers.value('Connection') == 'close'),
        isTrue,
      );
    },
  );

  for (final mode in [
    TestTvResponse.disconnectBefore,
    TestTvResponse.disconnectAfter,
    TestTvResponse.truncated,
    TestTvResponse.empty,
  ]) {
    test('Play $mode is recovered with the same source and bookmark', () async {
      final tv = await receiver();
      tv.responseSequences['Play'] = [mode, TestTvResponse.normal];
      final session = sessionFor(tv);
      await session.start(
        title: 'movie',
        position: const Duration(seconds: 197),
        duration: tv.duration,
      );
      await session.refresh();
      expect(session.connected, isTrue);
      expect(tv.transport, 'PLAYING');
      expect(session.bookmarkState.position, const Duration(seconds: 197));
      expect(tv.events.where((e) => e == 'SetAVTransportURI'), hasLength(1));
      expect(
        tv.events.where((e) => e == 'Play'),
        hasLength(mode == TestTvResponse.disconnectBefore ? 2 : 1),
      );
      expect(tv.events, isNot(contains('Stop')));
    });
  }

  test(
    'repeated missing Play responses confirm successful playback without replay',
    () async {
      final tv = await receiver();
      tv.responses['Play'] = TestTvResponse.disconnectAfter;
      final session = sessionFor(tv);
      await start(session, tv);
      await session.pause();
      await session.play();
      expect(session.state.playing, isTrue);
      expect(tv.events.where((e) => e == 'Play'), hasLength(2));
      expect(tv.events.where((e) => e == 'SetAVTransportURI'), hasLength(1));
    },
  );

  test(
    'paused handoff confirms lost Pause and Seek responses while retaining intent',
    () async {
      final tv = await receiver();
      tv.responses['Pause'] = TestTvResponse.disconnectAfter;
      tv.responses['Seek'] = TestTvResponse.truncated;
      final session = sessionFor(tv);
      await start(
        session,
        tv,
        position: const Duration(seconds: 197),
        playing: false,
      );
      expect(session.connected, isTrue);
      expect(session.state.playing, isFalse);
      expect(session.playWhenReady, isFalse);
      expect(session.bookmarkState.position, const Duration(seconds: 197));
      expect(tv.events.where((e) => e == 'Pause'), hasLength(1));
      expect(tv.events.where((e) => e == 'Seek'), hasLength(1));
      await session.seek(const Duration(seconds: 80));
      expect(session.state.playing, isFalse);
      expect(session.bookmarkState.position, const Duration(seconds: 80));
    },
  );

  test(
    'lost Pause before execution retries once after confirming the relay',
    () async {
      final tv = await receiver();
      final session = sessionFor(tv);
      await start(session, tv);
      tv.responseSequences['Pause'] = [TestTvResponse.disconnectBefore];
      await session.pause();
      expect(tv.transport, 'PAUSED_PLAYBACK');
      expect(session.playWhenReady, isFalse);
      expect(tv.events.where((e) => e == 'Pause'), hasLength(2));
    },
  );

  test(
    'GetMediaInfo confirms ownership when TrackURI is unavailable',
    () async {
      final tv = await receiver();
      tv.transportOverrides['GetPositionInfo'] = {
        'TrackURI': 'NOT_IMPLEMENTED',
      };
      tv.responses['Play'] = TestTvResponse.disconnectAfter;
      final session = sessionFor(tv);
      await start(session, tv);
      expect(session.connected, isTrue);
      expect(tv.events, contains('GetMediaInfo'));
      expect(tv.events.where((e) => e == 'Play'), hasLength(1));
    },
  );

  test(
    'missing ownership telemetry never treats another playing video as success',
    () async {
      final tv = await receiver();
      tv.responses['Play'] = TestTvResponse.disconnectAfter;
      tv.faults['GetPositionInfo'] = 401;
      tv.faults['GetMediaInfo'] = 401;
      final session = sessionFor(tv);
      await expectLater(
        start(session, tv),
        throwsA(isA<CastControlException>()),
      );
      expect(session.connected, isFalse);
      expect(tv.events.where((e) => e == 'Play'), hasLength(1));
      expect(tv.events, isNot(contains('GetTransportInfo')));
    },
  );

  test(
    'a renderer rejecting both Play attempts is bounded and remains failed',
    () async {
      final tv = await receiver();
      tv.responses['Play'] = TestTvResponse.disconnectBefore;
      final session = sessionFor(tv);
      await expectLater(
        start(session, tv),
        throwsA(isA<CastControlException>()),
      );
      expect(session.connected, isFalse);
      expect(tv.events.where((e) => e == 'Play'), hasLength(2));
      await session.close();
      expect(tv.events.last, 'Stop');
    },
  );

  test(
    'an error reported by the renderer is never acknowledged as successful Play',
    () async {
      final tv = await receiver();
      tv.responses['Play'] = TestTvResponse.disconnectAfter;
      tv.transportOverrides['GetTransportInfo'] = {
        'CurrentTransportStatus': 'ERROR_OCCURRED',
      };
      final session = sessionFor(tv);
      await expectLater(
        start(session, tv),
        throwsA(isA<CastControlException>()),
      );
      expect(session.connected, isFalse);
      expect(tv.events.where((e) => e == 'Play'), hasLength(1));
    },
  );

  test(
    'a different TrackURI prevents replay and Stop after a lost response',
    () async {
      final tv = await receiver();
      tv.responses['Play'] = TestTvResponse.disconnectAfter;
      tv.trackOverride = 'http://127.0.0.1:51000/another-user/movie';
      final session = sessionFor(tv);
      await expectLater(start(session, tv), throwsA(isA<AppException>()));
      expect(session.transportReplaced, isTrue);
      expect(session.changedTransport, isFalse);
      await session.close();
      expect(tv.events.where((e) => e == 'Play'), hasLength(1));
      expect(tv.events, isNot(contains('Stop')));
    },
  );

  test(
    'closing during response confirmation prevents retry and joins Stop',
    () async {
      final tv = await receiver();
      tv.responseSequences['Play'] = [TestTvResponse.disconnectBefore];
      final barrier = Completer<void>();
      tv.barriers['GetPositionInfo'] = barrier.future;
      addTearDown(() {
        if (!barrier.isCompleted) barrier.complete();
      });
      final session = sessionFor(tv);
      final pending = start(session, tv);
      final failed = expectLater(pending, throwsA(isA<AppException>()));
      await castEventually(() => tv.events.contains('GetPositionInfo'));
      final closing = session.close();
      barrier.complete();
      await failed;
      await closing;
      expect(tv.events.where((e) => e == 'Play'), hasLength(1));
      expect(tv.events.last, 'Stop');
      expect(tv.transport, 'STOPPED');
    },
  );

  test(
    'a slow response confirmation respects one total budget and never retries blind',
    () async {
      final tv = await receiver();
      tv.responseSequences['Play'] = [TestTvResponse.disconnectBefore];
      final barrier = Completer<void>();
      tv.barriers['GetPositionInfo'] = barrier.future;
      addTearDown(() {
        if (!barrier.isCompleted) barrier.complete();
      });
      final session = sessionFor(tv);
      final pending = start(session, tv);
      final failed = expectLater(pending, throwsA(isA<CastControlException>()));
      await castEventually(() => tv.events.contains('GetPositionInfo'));
      await failed.timeout(const Duration(seconds: 4));
      barrier.complete();
      expect(session.connected, isFalse);
      expect(tv.events.where((e) => e == 'Play'), hasLength(1));
      expect(tv.events, isNot(contains('GetMediaInfo')));
    },
  );

  test(
    'SetAVTransportURI is never blindly resent after an incomplete response',
    () async {
      final tv = await receiver();
      tv.responses['SetAVTransportURI'] = TestTvResponse.truncated;
      final session = sessionFor(tv);
      await expectLater(
        start(session, tv),
        throwsA(isA<CastControlException>()),
      );
      await session.close();
      expect(tv.events.where((e) => e == 'SetAVTransportURI'), hasLength(1));
      expect(tv.events, isNot(contains('Play')));
      expect(tv.events.last, 'Stop');
    },
  );

  test(
    'HTTP rejection keeps action, phase and status and does not retry',
    () async {
      final tv = await receiver();
      tv.httpStatuses['Play'] = HttpStatus.serviceUnavailable;
      final session = sessionFor(tv);
      await expectLater(
        start(session, tv),
        throwsA(
          isA<CastControlException>()
              .having((e) => e.status, 'status', 503)
              .having((e) => e.action, 'action', 'Play')
              .having((e) => e.uncertain, 'uncertain', isFalse),
        ),
      );
      expect(session.connected, isFalse);
      expect(tv.events.where((e) => e == 'Play'), hasLength(1));
      expect(tv.events, isNot(contains('GetPositionInfo')));
    },
  );

  test(
    'HTTP diagnostics preserve the disconnect reason and remove endpoint secrets',
    () async {
      final tv = await receiver();
      tv.responses['Play'] = TestTvResponse.truncated;
      final client = DlnaClient();
      addTearDown(client.close);
      try {
        await client.transport(tv.device, 'Play', {'Speed': '1'});
        fail('truncated response should throw');
      } on CastControlException catch (error) {
        final fields = castFailureFields(error, stage: 'play');
        expect(fields['error_type'], 'HttpException');
        expect(fields['http_status'], 200);
        expect(fields['request_stage'], 'read');
        expect(fields['action'], 'Play');
        expect(fields['http_error'], contains('Connection closed'));
      }
      final log = DiagnosticLog.open(null);
      addTearDown(log.close);
      log.record(
        'cast.connect_failed',
        fields: castFailureFields(
          CastControlException(
            action: 'Play',
            phase: 'response',
            cause: HttpException(
              'Connection closed http://192.168.1.6/control?token=secret-token Cookie=secret-cookie',
              uri: tv.location,
            ),
          ),
          stage: 'play',
        ),
      );
      final fields = log
          .entries()
          .singleWhere((e) => e.event == 'cast.connect_failed')
          .data['fields'];
      expect(fields['action'], 'Play');
      expect(fields['request_stage'], 'response');
      expect(fields['http_error'], contains('Connection closed'));
      for (final secret in [
        '192.168.1.6',
        '127.0.0.1',
        'secret-token',
        'secret-cookie',
      ]) {
        expect(jsonEncode(fields), isNot(contains(secret)));
      }
    },
  );

  for (final mode in [
    TestTvResponse.disconnectBefore,
    TestTvResponse.disconnectAfter,
  ]) {
    test(
      'controller retains the source after successful Play recovery: $mode',
      () async {
        final tv = await receiver();
        tv.responseSequences['Play'] = [mode];
        final fixture = PlaybackFixture(
          castSessionFactory: (device, source) => CastSession(
            device,
            source,
            prepareSource: false,
            managePlatform: false,
            localAddress: (_) async => InternetAddress.loopbackIPv4,
            pollInterval: const Duration(days: 1),
          ),
        );
        final controller = fixture.controller;
        addTearDown(controller.close);
        await controller.start();
        await fixture.current.seek(const Duration(seconds: 197));
        await controller.castTo(tv.device);
        expect(controller.casting, isTrue);
        expect(controller.connectingCast, isFalse);
        expect(controller.castSession!.connected, isTrue);
        expect(fixture.current.state.playing, isFalse);
        expect(fixture.leases.values.single, 2);
        expect(tv.events, isNot(contains('Stop')));
        await controller.disconnectCast();
        expect(fixture.leases.values.single, 1);
        expect(tv.events.last, 'Stop');
      },
    );
  }

  test(
    'failed Play recovery restores local playback and releases the retained source',
    () async {
      final tv = await receiver();
      tv.responses['Play'] = TestTvResponse.disconnectBefore;
      final fixture = PlaybackFixture();
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await expectLater(
        controller.castTo(tv.device),
        throwsA(isA<CastControlException>()),
      );
      expect(controller.casting, isFalse);
      expect(controller.connectingCast, isFalse);
      expect(fixture.current.state.playing, isTrue);
      expect(fixture.leases.values.single, 1);
      expect(tv.events.where((e) => e == 'Play'), hasLength(2));
      expect(tv.events.last, 'Stop');
    },
  );

  test(
    'reconnect recovery failure restores the previous relay with its paused bookmark',
    () async {
      final tv = await receiver();
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          managePlatform: false,
          localAddress: (_) async => InternetAddress.loopbackIPv4,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      final previous = controller.castSession!;
      await previous.refresh();
      await controller.pause();
      tv.position = const Duration(seconds: 197);
      await previous.refresh();
      final originalMedia = tv.media;
      tv.responseSequences['Play'] = [
        TestTvResponse.disconnectBefore,
        TestTvResponse.disconnectBefore,
      ];
      await expectLater(
        controller.castTo(tv.device, reconnect: true),
        throwsA(isA<CastControlException>()),
      );
      expect(controller.castSession, same(previous));
      expect(controller.casting, isTrue);
      expect(controller.connectingCast, isFalse);
      expect(controller.state.playing, isFalse);
      expect(tv.transport, 'PAUSED_PLAYBACK');
      expect(tv.media, originalMedia);
      expect(tv.position, const Duration(seconds: 197));
      expect(fixture.leases.values.single, 2);
    },
  );
}
