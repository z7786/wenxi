import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/playback/cast/cast_network.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'package:asterlink/playback/cast/dlna.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/playback/subtitle_matching.dart';
import 'cast_support.dart';
import 'player_support.dart';
import 'support.dart' show until;

void main() {
  test(
    'automatic next-episode casting waits for its own matching subtitle',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final root = await Directory.systemTemp.createTemp(
        'asterlink-player-cast-auto-caption-',
      );
      addTearDown(() => removePlayerFixture(root));
      final nextRead = Completer<void>();
      var requestedNext = false;
      final fixture = PlaybackFixture(
        subtitlesFor: (entry) => [
          PlaybackSubtitle(
            'caption-${entry.id}',
            p.setExtension(entry.name, '.srt'),
          ),
        ],
        readSubtitle: (entry, _, scope) async {
          if (entry.id == '1') {
            requestedNext = true;
            await nextRead.future;
          }
          require(!scope.token.isCancelled, '字幕请求已取消');
          return File(
            '${root.path}/${entry.id}.srt',
          ).writeAsString('1\n00:00:02,000 --> 00:00:04,000\n字幕-${entry.id}\n');
        },
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      expect(controller.castSession!.subtitleDelivered, isTrue);
      final first = controller.castSession!;
      final advancing = controller.load(1, automaticAdvance: true);
      await until(() => requestedNext);
      expect(tv.metadata, contains(first.subtitleUrl));
      nextRead.complete();
      await advancing;
      expect(controller.casting, isTrue);
      expect(controller.cloudSubtitleId, 'caption-1');
      expect(controller.castSession!.subtitleDelivered, isTrue);
      expect(tv.metadata, contains(controller.castSession!.subtitleUrl));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        Uri.parse(controller.castSession!.subtitleUrl),
      )).close();
      expect(await utf8.decoder.bind(response).join(), contains('字幕-1'));
      expect(fixture.current.state.playing, isFalse);
    },
  );

  test('a slow automatic caption cannot prevent casting the video', () async {
    final tv = TestTv();
    await tv.start();
    addTearDown(tv.close);
    final root = await Directory.systemTemp.createTemp(
      'asterlink-player-cast-slow-caption-',
    );
    addTearDown(() => removePlayerFixture(root));
    final read = Completer<void>();
    final fixture = PlaybackFixture(
      subtitlesFor: (entry) => [
        PlaybackSubtitle('caption', p.setExtension(entry.name, '.srt')),
      ],
      readSubtitle: (entry, _, scope) async {
        await read.future;
        require(!scope.token.isCancelled, '字幕请求已取消');
        return File(
          '${root.path}/late.srt',
        ).writeAsString('1\n00:00:02,000 --> 00:00:04,000\n迟到字幕\n');
      },
    );
    final controller = fixture.controller;
    addTearDown(() async {
      if (!read.isCompleted) read.complete();
      await controller.close();
    });
    await controller.start();
    await controller.castTo(tv.device).timeout(const Duration(seconds: 6));
    expect(controller.casting, isTrue);
    expect(controller.castSession!.subtitleDelivered, isFalse);
    expect(controller.castSession!.subtitleWarning, contains('仍在加载'));
    expect(tv.transport, 'PLAYING');
    read.complete();
    await until(() => !controller.subtitleLoading);
    expect(controller.cloudSubtitleId, 'caption');
    await controller.castTo(tv.device, reconnect: true);
    expect(controller.castSession!.subtitleDelivered, isTrue);
    expect(controller.castSession!.subtitleWarning, isEmpty);
  });

  test(
    'cancelling a pending caption wait does not delay or start the TV',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final root = await Directory.systemTemp.createTemp(
        'asterlink-player-cast-cancel-caption-',
      );
      addTearDown(() => removePlayerFixture(root));
      final read = Completer<void>();
      final fixture = PlaybackFixture(
        subtitlesFor: (entry) => [
          PlaybackSubtitle('caption', p.setExtension(entry.name, '.srt')),
        ],
        readSubtitle: (_, _, scope) async {
          await read.future;
          require(!scope.token.isCancelled, '字幕请求已取消');
          return File(
            '${root.path}/caption.srt',
          ).writeAsString('1\n00:00:02,000 --> 00:00:04,000\n字幕\n');
        },
      );
      final controller = fixture.controller;
      addTearDown(() async {
        if (!read.isCompleted) read.complete();
        await controller.close();
      });
      await controller.start();
      final rejected = expectLater(
        controller.castTo(tv.device),
        throwsA(isA<AppException>()),
      );
      await until(() => controller.connectingCast);
      await controller.disconnectCast().timeout(const Duration(seconds: 1));
      await rejected.timeout(const Duration(seconds: 1));
      expect(controller.casting, isFalse);
      expect(tv.events, isNot(contains('SetAVTransportURI')));
      expect(tv.events, isNot(contains('Play')));
      read.complete();
      await until(() => !controller.subtitleLoading);
      expect(fixture.leases.values, everyElement(1));
    },
  );

  test(
    'selected staged subtitle survives reconnect and is absent after switching episodes',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final root = await Directory.systemTemp.createTemp(
        'asterlink-player-cast-subtitle-',
      );
      addTearDown(() => removePlayerFixture(root));
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      final file = await File('${root.path}/caption.ass').writeAsString(
        '[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n'
        'Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,中文字幕\n',
      );
      await controller.attachSubtitle(file, '中文字幕.ass', controller.generation);
      await controller.setSubtitleDelay(.5);
      await controller.castTo(tv.device);
      final first = controller.castSession!;
      expect(first.subtitleDelivered, isTrue);
      expect(tv.metadata, contains(first.subtitleUrl));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      Future<String> readCaption(String url) async {
        final response = await (await client.getUrl(Uri.parse(url))).close();
        expect(response.statusCode, 200);
        return utf8.decoder.bind(response).join();
      }

      final text = await readCaption(first.subtitleUrl);
      expect(text, contains('00:00:02,500 --> 00:00:04,500\n中文字幕'));
      await controller.castTo(tv.device, reconnect: true);
      expect(controller.castSession!.subtitleUrl, isNot(first.subtitleUrl));
      expect(await readCaption(controller.castSession!.subtitleUrl), text);
      expect(fixture.current.state.playing, isFalse);
      final closedUrl = controller.castSession!.subtitleUrl;
      await controller.next();
      expect(controller.casting, isTrue);
      expect(controller.castSession!.subtitleDelivered, isFalse);
      expect(tv.metadata, isNot(contains('CaptionInfo')));
      expect(await file.exists(), isFalse);
      await expectLater(
        (() async => (await client.getUrl(Uri.parse(closedUrl))).close())(),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test(
    'bad subtitle does not fail the video handoff or resume local audio',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final root = await Directory.systemTemp.createTemp(
        'asterlink-player-cast-subtitle-invalid-',
      );
      addTearDown(() => removePlayerFixture(root));
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      final file = await File(
        '${root.path}/bad.srt',
      ).writeAsString('invalid caption');
      await fixture.controller.attachSubtitle(
        file,
        'bad.srt',
        fixture.controller.generation,
      );
      await fixture.controller.castTo(tv.device);
      expect(fixture.controller.casting, isTrue);
      expect(fixture.current.state.playing, isFalse);
      expect(fixture.controller.castSession!.subtitleDelivered, isFalse);
      expect(fixture.controller.castSession!.subtitleWarning, contains('无法转换'));
      expect(tv.transport, 'PLAYING');
      expect(tv.metadata, isNot(contains('CaptionInfo')));
    },
  );

  test(
    'subtitle-off handoff does not expose a previously attached caption',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final root = await Directory.systemTemp.createTemp(
        'asterlink-player-cast-subtitle-off-',
      );
      addTearDown(() => removePlayerFixture(root));
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      final file = await File(
        '${root.path}/caption.srt',
      ).writeAsString('1\n00:00:02,000 --> 00:00:04,000\n中文字幕\n');
      await fixture.controller.attachSubtitle(
        file,
        'caption.srt',
        fixture.controller.generation,
      );
      await fixture.controller.setSubtitleTrack(SubtitleTrack.no());
      await fixture.controller.castTo(tv.device);
      expect(fixture.controller.castSession!.subtitleDelivered, isFalse);
      expect(tv.metadata, isNot(contains('CaptionInfo')));
    },
  );

  test(
    'cast logs keep audio format and caption availability without titles, URLs or subtitle text',
    () async {
      final log = DiagnosticLog.open(null);
      final previous = DiagnosticLog.active;
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = previous;
        log.close();
      });
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final root = await Directory.systemTemp.createTemp(
        'asterlink-player-cast-log-',
      );
      addTearDown(() => removePlayerFixture(root));
      final fixture = PlaybackFixture();
      fixture.configureBackend = (backend) => backend.emit(
        backend.state.copyWith(
          tracks: const Tracks(
            audio: [
              AudioTrack(
                '1',
                'private-audio-title',
                'zho',
                codec: 'aac',
                channelscount: 2,
                samplerate: 48000,
              ),
            ],
          ),
          track: const Track(
            audio: AudioTrack(
              '1',
              'private-audio-title',
              'zho',
              codec: 'aac',
              channelscount: 2,
              samplerate: 48000,
            ),
          ),
        ),
      );
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      final file = await File('${root.path}/private-caption.srt').writeAsString(
        '1\n00:00:02,000 --> 00:00:04,000\nprivate-subtitle-text\n',
      );
      await fixture.controller.attachSubtitle(
        file,
        'private-subtitle-title',
        fixture.controller.generation,
      );
      await fixture.controller.castTo(tv.device);
      final entry = log.entries().singleWhere(
        (e) => e.event == 'cast.media_tracks',
      );
      final fields = entry.data['fields'] as Map;
      expect(fields['audio_codec'], 'aac');
      expect(fields['audio_channels'], 2);
      expect(fields['audio_sample_rate'], 48000);
      expect(fields['subtitle_delivered'], isTrue);
      expect(fields['subtitle_cues'], 1);
      for (final text in [
        'private-audio-title',
        'private-subtitle-title',
        'private-subtitle-text',
        file.uri.toString(),
        fixture.controller.castSession!.subtitleUrl,
      ]) {
        expect(entry.detail, isNot(contains(text)));
      }
    },
  );

  test(
    'route failure keeps local playback and emits stage plus errno',
    () async {
      final log = DiagnosticLog.open(null);
      final previous = DiagnosticLog.active;
      DiagnosticLog.active = log;
      addTearDown(() {
        DiagnosticLog.active = previous;
        log.close();
      });
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(
        castPlatform: platform,
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          localAddress: (_) async => throw const SocketException(
            'No route to host',
            osError: OSError('No route to host', 113),
          ),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      final local = fixture.current;
      await expectLater(
        controller.castTo(tv.device),
        throwsA(isA<CastNetworkException>()),
      );
      expect(controller.state.playing, isTrue);
      expect(local.closed, isFalse);
      expect(controller.casting, isFalse);
      expect(controller.connectingCast, isFalse);
      expect(tv.events, isEmpty);
      expect(platform.events, ['active:true', 'active:false']);
      final failure = log
          .entries()
          .singleWhere((entry) => entry.event == 'cast.connect_failed')
          .data['fields'];
      expect(failure['stage'], 'route');
      expect(failure['errno'], 113);
      expect(failure['os_error'], 'No route to host');
      expect(failure['error_type'], 'SocketException');
      expect(fixture.leases.values.single, 1);
    },
  );
  test(
    'expired initial source preparation refreshes once without a local backend failure',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      var count = 0;
      final fixture = PlaybackFixture(
        renewable: true,
        castSessionFactory: (device, source) {
          count++;
          return CastSession(
            device,
            source,
            prepareSource: false,
            localAddress: count == 1
                ? (_) async => throw PlaybackFailure.http(403)!
                : null,
            pollInterval: const Duration(days: 1),
          );
        },
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      expect(controller.castSession!.connected, isTrue);
      expect(fixture.preparations, 2);
      expect(fixture.current.failure, isNull);
      expect(fixture.leases.values.reduce((a, b) => a + b), 2);
    },
  );
  test(
    'remote resume after app pause still automatically plays the next episode',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await controller.castSession!.refresh();
      await controller.pause();
      tv.transport = 'PLAYING';
      tv.position = tv.duration - const Duration(seconds: 7);
      await controller.castSession!.refresh();
      tv.transport = 'NO_MEDIA_PRESENT';
      tv.position = Duration.zero;
      await controller.castSession!.refresh();
      await castEventually(
        () =>
            controller.index == 1 &&
            controller.castSession?.connected == true &&
            !controller.connectingCast,
      );
      expect(fixture.current.plays, 0);
    },
  );

  test(
    'failed reconnect before SetMedia keeps the old TV session playing without Stop',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      var count = 0;
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) {
          count++;
          return CastSession(
            device,
            source,
            prepareSource: false,
            pollInterval: const Duration(days: 1),
            localAddress: count == 2
                ? (_) async => throw const AppException('route failed')
                : null,
          );
        },
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      final old = controller.castSession!;
      await old.refresh();
      tv.position = const Duration(seconds: 173);
      await old.refresh();
      final media = tv.media;
      await expectLater(
        controller.castTo(tv.device, reconnect: true),
        throwsA(isA<AppException>()),
      );
      expect(identical(controller.castSession, old), isTrue);
      expect(tv.events.where((e) => e == 'Stop'), isEmpty);
      expect(tv.media, media);
      expect(tv.transport, 'PLAYING');
      expect(controller.state.position, const Duration(seconds: 173));
      expect(fixture.leases.values.single, 2);
    },
  );

  for (final playing in [true, false]) {
    test(
      'failed reconnect after SetMedia restores the old relay, position and $playing intent',
      () async {
        final tv = TestTv();
        await tv.start();
        addTearDown(tv.close);
        final fixture = PlaybackFixture(
          castSessionFactory: (device, source) => CastSession(
            device,
            source,
            prepareSource: false,
            pollInterval: const Duration(days: 1),
          ),
        );
        final controller = fixture.controller;
        addTearDown(controller.close);
        await controller.start();
        await controller.castTo(tv.device);
        final old = controller.castSession!;
        await old.refresh();
        if (!playing) await controller.pause();
        tv.position = const Duration(seconds: 173);
        await old.refresh();
        final media = tv.media;
        tv.faultSequences['Play'] = [714, 0];
        await expectLater(
          controller.castTo(tv.device, reconnect: true),
          throwsA(isA<CastSoapException>()),
        );
        expect(identical(controller.castSession, old), isTrue);
        expect(tv.media, media);
        expect(tv.position, const Duration(seconds: 173));
        expect(tv.transport, playing ? 'PLAYING' : 'PAUSED_PLAYBACK');
        expect(fixture.leases.values.single, 2);
        expect(controller.connectingCast, isFalse);
        await old.refresh();
        expect(old.transportReplaced, isFalse);
      },
    );
  }

  test(
    'cast 403 refreshes the source independently of a healthy paused local decoder',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      ExternalPlaybackStream? relay;
      final platform = TestCastPlatform();
      final fixture = PlaybackFixture(
        renewable: true,
        castPlatform: platform,
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
          streamFactory: (source, address) =>
              relay = ExternalPlaybackStream.lan(source, lanAddress: address),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await controller.castSession!.refresh();
      tv.position = const Duration(seconds: 173);
      await controller.castSession!.refresh();
      final old = controller.castSession!;
      final oldRelay = relay!;
      oldRelay.failure = PlaybackFailure.http(403);
      oldRelay.lastError = 'source expired';
      await old.refresh();
      await castEventually(
        () =>
            !identical(controller.castSession, old) &&
            controller.castSession?.connected == true &&
            !controller.connectingCast,
      );
      expect(fixture.preparations, 2);
      expect(fixture.current.failure, isNull);
      expect(tv.position, const Duration(seconds: 173));
      expect(fixture.leases.values.reduce((a, b) => a + b), 2);
      expect(platform.events.where((e) => e == 'active:false'), isEmpty);
      // A regular reconnect must keep using the refreshed cast source.
      final renewed = relay!.source.url;
      await controller.castTo(tv.device, reconnect: true);
      expect(relay!.source.url, renewed);
    },
  );

  test(
    'long disconnection releases the relay/platform and saves the last TV bookmark',
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
          prepareSource: false,
          pollInterval: const Duration(days: 1),
          connectionGrace: Duration.zero,
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      final cast = controller.castSession!;
      await cast.refresh();
      tv.position = const Duration(seconds: 173);
      await cast.refresh();
      tv.malformed = true;
      for (var i = 0; i < 3; i++) {
        await cast.refresh();
      }
      await castEventually(
        () => !controller.casting && !controller.disconnectingCast,
      );
      expect(
        fixture.history.bookmark(controller.current.key)!.position,
        const Duration(seconds: 173),
      );
      expect(platform.events.last, 'active:false');
      expect(fixture.leases.values.single, 1);
      expect(fixture.current.state.playing, isFalse);
    },
  );
  for (final playing in [true, false]) {
    test(
      'handoff and return preserve $playing playback and fresh receiver progress',
      () async {
        final tv = TestTv();
        await tv.start();
        addTearDown(tv.close);
        final fixture = PlaybackFixture(
          castSessionFactory: (device, source) => CastSession(
            device,
            source,
            prepareSource: false,
            pollInterval: const Duration(days: 1),
          ),
        );
        final controller = fixture.controller;
        addTearDown(controller.close);
        await controller.start();
        await controller.seek(const Duration(seconds: 42));
        if (!playing) await controller.pause();
        await controller.castTo(tv.device);
        await castEventually(() => controller.castSession!.volumeSupported);
        expect(controller.state.playing, playing);
        expect(tv.transport, playing ? 'PLAYING' : 'PAUSED_PLAYBACK');
        expect(tv.position, const Duration(seconds: 42));
        tv.position = const Duration(seconds: 173);
        final poll = Completer<void>();
        tv.barriers['GetPositionInfo'] = poll.future;
        final polling = controller.castSession!.refresh();
        await castEventually(() => tv.events.last == 'GetPositionInfo');
        final returning = controller.disconnectCast(resumeLocally: true);
        expect(controller.disconnectingCast, isTrue);
        poll.complete();
        await polling;
        await returning;
        expect(controller.disconnectingCast, isFalse);
        expect(fixture.current.state.position, const Duration(seconds: 173));
        expect(fixture.current.state.playing, playing);
        expect(tv.transport, 'STOPPED');
      },
    );
  }

  test(
    'reconnecting retains paused progress and selecting the current TV is harmless',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      final first = controller.castSession;
      await controller.castTo(tv.device);
      expect(controller.castSession, same(first));
      tv.position = const Duration(seconds: 190);
      tv.transport = 'PAUSED_PLAYBACK';
      await controller.castTo(tv.device, reconnect: true);
      expect(controller.castSession, isNot(same(first)));
      expect(tv.position, const Duration(seconds: 190));
      expect(tv.transport, 'PAUSED_PLAYBACK');
      expect(fixture.current.state.playing, isFalse);
      expect(fixture.leases.values.single, 2);
    },
  );

  test(
    'return refresh cannot auto-advance at the receiver end of an episode',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      tv.position = tv.duration;
      tv.transport = 'STOPPED';
      await controller.disconnectCast(resumeLocally: true);
      expect(controller.index, 0);
      expect(controller.casting, isFalse);
      expect(fixture.current.state.playing, isFalse);
    },
  );

  test(
    'timer stopping during a pending return prevents local autoplay',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      final poll = Completer<void>();
      tv.barriers['GetPositionInfo'] = poll.future;
      final returning = controller.disconnectCast(resumeLocally: true);
      await castEventually(() => tv.events.last == 'GetPositionInfo');
      controller.sleepTimer.afterEpisode();
      final stopping = controller.sleepTimer.finishEpisode();
      poll.complete();
      await returning;
      await stopping;
      expect(fixture.current.state.playing, isFalse);
      expect(controller.casting, isFalse);
    },
  );

  test(
    'cancelling reconnect during its last status poll cannot restart the TV',
    () async {
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final fixture = PlaybackFixture(
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.castTo(tv.device);
      await castEventually(() => controller.castSession!.volumeSupported);
      final loads = tv.events.where((e) => e == 'SetAVTransportURI').length;
      final poll = Completer<void>();
      tv.barriers['GetPositionInfo'] = poll.future;
      final reconnecting = controller.castTo(tv.device, reconnect: true);
      await castEventually(() => tv.events.last == 'GetPositionInfo');
      final stopping = controller.disconnectCast();
      poll.complete();
      await reconnecting;
      await stopping;
      expect(controller.casting, isFalse);
      expect(controller.connectingCast, isFalse);
      expect(tv.transport, 'STOPPED');
      expect(tv.events.where((e) => e == 'SetAVTransportURI').length, loads);
    },
  );

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
          prepareSource: false,
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
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
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
        castSessionFactory: (device, source) => CastSession(
          device,
          source,
          prepareSource: false,
          pollInterval: const Duration(days: 1),
        ),
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
