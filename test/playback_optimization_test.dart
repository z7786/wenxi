import 'dart:async';
import 'dart:io';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/playback/playback_buffer_policy.dart';
import 'package:asterlink/playback/playback_metrics.dart';
import 'package:asterlink/playback/subtitle_matching.dart';
import 'player_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Decoder reconstruction preserves selected audio, captions, sync, position and pause',
    () async {
      final f = PlaybackFixture(renewable: true);
      addTearDown(f.controller.close);
      await f.controller.start();
      await f.controller.setAudioTrack(const AudioTrack('2', 'English', 'eng'));
      await f.controller.setSubtitleTrack(
        const SubtitleTrack('1', '简体中文', 'zho'),
      );
      await f.controller.setSubtitleDelay(1.25);
      await f.controller.setAudioDelay(-.5);
      await f.controller.setRate(1.5);
      await f.controller.seek(const Duration(seconds: 47));
      await f.controller.pause();
      await f.controller.setHardwareAcceleration(false);
      expect(f.current.state.track.audio.id, '2');
      expect(f.current.state.track.subtitle.id, '1');
      expect(f.current.subtitleDelay, 1.25);
      expect(f.current.audioDelay, -.5);
      expect(f.current.openedStart, const Duration(seconds: 47));
      expect(f.current.state.rate, 1.5);
      expect(f.current.state.playing, isFalse);
      await f.controller.next();
      expect(f.current.subtitleDelay, 0);
      expect(f.current.audioDelay, 0);
    },
  );

  test(
    'A refreshed track id resolves by language and title instead of selecting another language',
    () async {
      final f = PlaybackFixture(renewable: true);
      addTearDown(f.controller.close);
      await f.controller.start();
      await f.controller.setAudioTrack(const AudioTrack('2', 'English', 'eng'));
      f.configureBackend = (backend) => backend.emit(
        backend.state.copyWith(
          tracks: const Tracks(
            audio: [
              AudioTrack('2', '普通话', 'zho'),
              AudioTrack('7', 'English', 'eng'),
            ],
          ),
        ),
      );
      await f.controller.retry();
      expect(f.current.state.track.audio.id, '7');
    },
  );

  test(
    'External captions survive repeated same-video reconnects and are deleted after the final reader closes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-player-selection-',
      );
      addTearDown(() => removePlayerFixture(directory));
      final f = PlaybackFixture(renewable: true);
      addTearDown(f.controller.close);
      await f.controller.start();
      final file = await File(
        '${directory.path}/captions.ass',
      ).writeAsString('[Script Info]');
      await f.controller.attachSubtitle(
        file,
        'captions.ass',
        f.controller.generation,
      );
      for (var i = 0; i < 2; i++) {
        await f.controller.retry();
        expect(await file.exists(), isTrue);
        expect(f.current.state.track.subtitle.id, file.uri.toString());
      }
      final gate = Completer<void>();
      f.current.closeBarrier = gate.future;
      final next = f.controller.next();
      await Future<void>.delayed(Duration.zero);
      expect(await file.exists(), isTrue);
      gate.complete();
      await next;
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'Source resolution overlaps native initialization but open waits for both',
    () async {
      final f = PlaybackFixture();
      addTearDown(f.controller.close);
      final native = Completer<void>(), source = Completer<void>();
      f.configureBackend = (backend) =>
          backend.initializeBarrier = native.future;
      f.prepareBarrier = (_, _) => source.future;
      final opening = f.controller.start();
      await until(() => f.preparations == 1);
      expect(f.events, contains('initialize:0:0'));
      expect(f.current.openedSource, isNull);
      source.complete();
      await Future<void>.delayed(Duration.zero);
      expect(f.current.openedSource, isNull);
      native.complete();
      await opening;
      expect(f.controller.ready, isTrue);
      expect(f.current.plays, 1);
    },
  );

  test(
    'Next-episode preparation owns a separate lease and is consumed without a second resolution',
    () async {
      final f = PlaybackFixture(prepareAhead: true);
      addTearDown(f.controller.close);
      await f.controller.start();
      f.current.emit(
        f.current.state.copyWith(
          position: const Duration(minutes: 9, seconds: 40),
        ),
      );
      await until(() => f.leases.length == 2);
      await Future<void>.delayed(Duration.zero);
      expect(f.controller.current.id, '0');
      expect(f.backends, hasLength(1));
      await f.controller.next();
      expect(f.preparations, 2);
      expect(f.controller.current.id, '1');
      expect(f.leases.values.where((value) => value == 1), hasLength(1));
      await f.controller.close();
      expect(f.leases.values, everyElement(0));
    },
  );

  for (final consume in [false, true]) {
    test(
      'Prepared source expiry releases only unused leases: consumed=$consume',
      () {
        fakeAsync((time) {
          final f = PlaybackFixture(prepareAhead: true);
          try {
            unawaited(f.controller.start());
            time.flushMicrotasks();
            f.current.emit(
              f.current.state.copyWith(
                position: const Duration(minutes: 9, seconds: 40),
              ),
            );
            time.flushMicrotasks();
            expect(f.preparations, 2);
            expect(f.leases.values, everyElement(1));
            if (consume) {
              unawaited(f.controller.next());
              time.flushMicrotasks();
              expect(f.preparations, 2);
            }
            time.elapse(const Duration(seconds: 46));
            expect(f.leases.values.where((count) => count == 1), hasLength(1));
            expect(f.leases.values, everyElement(inInclusiveRange(0, 1)));
            expect(f.controller.ready, isTrue);
            if (!consume) {
              unawaited(f.controller.next());
              time.flushMicrotasks();
              expect(f.preparations, 3);
            }
          } finally {
            unawaited(f.controller.close());
            time.flushMicrotasks();
            expect(f.leases.values, everyElement(0));
            expect(time.pendingTimers, isEmpty);
            f.store.dispose();
          }
        });
      },
    );
  }

  test(
    'Pausing cancels a late next-episode source and releases it without disturbing the active source',
    () async {
      final f = PlaybackFixture(prepareAhead: true);
      addTearDown(f.controller.close);
      final gate = Completer<void>();
      f.prepareBarrier = (_, number) =>
          number == 2 ? gate.future : Future.value();
      await f.controller.start();
      f.current.emit(
        f.current.state.copyWith(
          position: const Duration(minutes: 9, seconds: 40),
        ),
      );
      await until(() => f.preparations == 2);
      await f.controller.pause();
      gate.complete();
      await until(() => f.leases.length == 2 && f.leases.values.contains(0));
      expect(f.controller.current.id, '0');
      expect(f.current.state.playing, isFalse);
      expect(f.leases.values.where((value) => value == 1), hasLength(1));
    },
  );

  test(
    'Pausing during speed boost cannot restart next-episode preparation from the rate event',
    () async {
      final f = PlaybackFixture(prepareAhead: true);
      addTearDown(f.controller.close);
      await f.controller.start();
      f.current.emit(
        f.current.state.copyWith(
          position: const Duration(minutes: 9, seconds: 40),
        ),
      );
      await until(() => f.leases.length == 2);
      await f.controller.beginBoost();
      await f.controller.pause();
      await Future<void>.delayed(Duration.zero);
      expect(f.preparations, 2);
      expect(f.controller.boosting, isFalse);
      expect(f.current.state.playing, isFalse);
      expect(f.leases.values.where((count) => count == 1), hasLength(1));
    },
  );

  test(
    'Automatic cloud subtitles cannot replace a manual choice made while their download is pending',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-player-auto-subtitle-',
      );
      addTearDown(() => removePlayerFixture(directory));
      final gate = Completer<void>();
      File? staged;
      final f = PlaybackFixture(
        subtitlesFor: (entry) => [
          PlaybackSubtitle(
            'caption',
            entry.name.replaceFirst('.mkv', '.chs.ass'),
          ),
        ],
        readSubtitle: (_, _, _) async {
          await gate.future;
          return staged = await File(
            '${directory.path}/downloaded.ass',
          ).writeAsString('[Script Info]');
        },
      );
      addTearDown(f.controller.close);
      await f.controller.start();
      await until(() => f.controller.subtitleLoading);
      await f.controller.setSubtitleTrack(SubtitleTrack.no());
      gate.complete();
      await until(() => !f.controller.subtitleLoading);
      expect(f.current.state.track.subtitle.id, 'no');
      expect(staged, isNotNull);
      expect(await staged!.exists(), isFalse);
    },
  );

  test(
    'A manual subtitle choice wins while native attachment of an automatic subtitle is pending',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-player-subtitle-race-',
      );
      addTearDown(() => removePlayerFixture(directory));
      final file = await File(
        '${directory.path}/downloaded.ass',
      ).writeAsString('[Script Info]');
      final gate = Completer<void>();
      final f = PlaybackFixture(
        renewable: true,
        subtitlesFor: (entry) => [
          PlaybackSubtitle(
            'caption',
            entry.name.replaceFirst('.mkv', '.chs.ass'),
          ),
        ],
        readSubtitle: (_, _, _) async => file,
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await f.controller.close();
      });
      f.configureBackend = (backend) => backend.subtitleBarrier = gate.future;
      await f.controller.start();
      await until(() => f.current.subtitleChanges == 1);
      final manual = f.controller.setSubtitleTrack(SubtitleTrack.no());
      gate.complete();
      await manual;
      await until(() => !f.controller.subtitleLoading);
      expect(f.current.state.track.subtitle.id, 'no');
      expect(f.controller.cloudSubtitleId, isNull);
      expect(f.controller.preferences.subtitles, isFalse);
      await f.controller.retry();
      expect(f.current.state.track.subtitle.id, 'no');
      expect(f.controller.cloudSubtitleId, isNull);
      await f.controller.close();
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'An explicitly selected cloud subtitle reports a native attachment failure without stopping playback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-player-subtitle-error-',
      );
      addTearDown(() => removePlayerFixture(directory));
      final file = await File(
        '${directory.path}/caption.ass',
      ).writeAsString('[Script Info]');
      const subtitle = PlaybackSubtitle('caption', 'alternative.ass');
      final f = PlaybackFixture(
        subtitlesFor: (_) => const [subtitle],
        readSubtitle: (_, _, _) async => file,
      );
      addTearDown(f.controller.close);
      await f.controller.start();
      f.current.failSubtitle = true;
      await f.controller.loadCloudSubtitle(subtitle);
      expect(f.controller.notice, contains('字幕加载失败'));
      expect(f.controller.cloudSubtitleId, isNull);
      expect(f.controller.subtitleLoading, isFalse);
      expect(f.controller.error, isEmpty);
      expect(f.current.state.playing, isTrue);
      await f.controller.close();
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'Subtitle matching requires the same episode and avoids ambiguous versions',
    () {
      expect(
        matchingSubtitle('Show.S01E02.1080p.mkv', const [
          PlaybackSubtitle('wrong', 'Show.S01E01.chs.ass'),
          PlaybackSubtitle('right', 'Show.S01E02.chs.ass'),
          PlaybackSubtitle('english', 'Show.S01E02.en.srt'),
        ])?.id,
        'right',
      );
      expect(
        matchingSubtitle('Show.02.mkv', const [
          PlaybackSubtitle('wrong', 'Show.01.srt'),
        ]),
        isNull,
      );
      expect(
        matchingSubtitle('Film.mkv', const [
          PlaybackSubtitle('one', 'Film.chs.ass'),
          PlaybackSubtitle('two', 'Film.chs.srt'),
        ]),
        isNull,
      );
    },
  );

  test(
    'High bitrate and accelerated playback rebalance caches within the same byte ceiling',
    () {
      final policy = PlaybackBufferPolicy(connectionLimit: 8);
      final forward = policy.forwardTarget(
        size: 8 * 1024 * 1024 * 1024,
        duration: const Duration(minutes: 90),
        rate: 2,
      );
      expect(forward, greaterThan(8 * PlaybackBufferPolicy.mib));
      expect(
        forward +
            policy.proxyBytesFor(forward) +
            PlaybackBufferPolicy.backBytes,
        PlaybackBufferPolicy.totalBytes,
      );
      policy.forwardBytes = forward;
      expect(
        policy.forwardTarget(
          size: 1000000,
          duration: const Duration(hours: 2),
          rate: 1,
        ),
        forward,
      );
    },
  );

  test(
    'Normal bitrate playback reserves a minute within the shared memory budget',
    () {
      final policy = PlaybackBufferPolicy(connectionLimit: 8);
      // 2 Mibit/s: 90 seconds need about 22 MiB, within the expanded cache.
      final forward = policy.forwardTarget(
        size: 900 * PlaybackBufferPolicy.mib,
        duration: const Duration(hours: 1),
        rate: 1,
      );
      expect(forward, greaterThanOrEqualTo(16 * PlaybackBufferPolicy.mib));
      expect(forward, lessThanOrEqualTo(48 * PlaybackBufferPolicy.mib));
      expect(
        forward +
            policy.proxyBytesFor(forward) +
            PlaybackBufferPolicy.backBytes,
        PlaybackBufferPolicy.totalBytes,
      );
    },
  );

  test('Limited sources ramp before underrun and keep steady connections', () {
    final policy = PlaybackBufferPolicy(connectionLimit: 8);
    for (var second = 0; second <= 30; second += 2) {
      policy.observe(
        elapsed: Duration(seconds: second),
        receivedBytes: second * 512 * 1024,
        failures: 0,
        status: 206,
        activeRequests: policy.connections,
        bufferedSeconds: second < 6 ? 12 : 35,
        buffering: false,
        playing: true,
      );
      if (second >= 4) expect(policy.connections, 8);
    }
  });

  test(
    'Adequate throughput keeps four connections while a seek fills its cache',
    () {
      final policy = PlaybackBufferPolicy(connectionLimit: 16);
      for (var second = 0; second <= 20; second += 2) {
        policy.observe(
          elapsed: Duration(seconds: second),
          receivedBytes: second * 6 * 1024 * 1024,
          failures: 0,
          status: 206,
          activeRequests: policy.connections,
          bufferedSeconds: 1,
          buffering: true,
          playing: true,
          requiredBytesPerSecond: 1.3 * 1024 * 1024,
        );
        expect(policy.connections, 4);
      }
    },
  );

  test('A limited high bitrate stream still grows toward the user ceiling', () {
    final policy = PlaybackBufferPolicy(connectionLimit: 8);
    for (var second = 0; second <= 6; second += 2) {
      policy.observe(
        elapsed: Duration(seconds: second),
        receivedBytes: second * 512 * 1024,
        failures: 0,
        status: 206,
        activeRequests: policy.connections,
        bufferedSeconds: 12,
        buffering: false,
        playing: true,
        requiredBytesPerSecond: 2 * 1024 * 1024,
      );
    }
    expect(policy.connections, 8);
  });

  test(
    'High connection limits ramp beyond 32 and respect runtime reductions',
    () {
      final policy = PlaybackBufferPolicy(connectionLimit: 128);
      expect(policy.limit, 128);
      for (var second = 0; second <= 124; second += 2) {
        policy.observe(
          elapsed: Duration(seconds: second),
          receivedBytes: second * 512 * 1024,
          failures: 0,
          status: 206,
          activeRequests: policy.connections,
          bufferedSeconds: 1,
          buffering: true,
          playing: true,
        );
      }
      expect(policy.connections, 128);
      policy.setLimit(96);
      expect(policy.limit, 96);
      expect(policy.connections, 96);
      policy.setLimit(999);
      expect(policy.limit, 512);
      policy.setLimit(0);
      expect(policy.connections, 1);
    },
  );

  test('One throttled response cannot repeatedly halve concurrency', () {
    final policy = PlaybackBufferPolicy(connectionLimit: 8);
    for (var second = 0; second <= 10; second += 2) {
      policy.observe(
        elapsed: Duration(seconds: second),
        receivedBytes: second * 8192,
        failures: 1,
        status: 429,
        activeRequests: policy.connections,
        bufferedSeconds: 0,
        buffering: true,
        playing: true,
      );
      expect(policy.connections, 2);
    }
  });

  test(
    'Repeated underruns build a bounded reserve measured at playback speed',
    () {
      final policy = PlaybackBufferPolicy(connectionLimit: 8);
      expect(policy.resumeSeconds(rebufferCount: 0, rate: 1), 6);
      expect(policy.resumeSeconds(rebufferCount: 1, rate: 1), 8);
      expect(policy.resumeSeconds(rebufferCount: 2, rate: 1), 10);
      expect(policy.resumeSeconds(rebufferCount: 20, rate: 1), 12);
      expect(policy.resumeSeconds(rebufferCount: 1, rate: 2), 16);
      expect(policy.resumeSeconds(rebufferCount: 20, rate: 4), 48);
    },
  );

  test(
    'Congestion reduces concurrency and recovery respects the user ceiling',
    () {
      final policy = PlaybackBufferPolicy(connectionLimit: 4);
      int observe(
        int second,
        int bytes,
        int failures,
        int status,
        bool buffering,
      ) => policy.observe(
        elapsed: Duration(seconds: second),
        receivedBytes: bytes,
        failures: failures,
        status: status,
        activeRequests: policy.connections,
        bufferedSeconds: 1,
        buffering: buffering,
        playing: true,
      );
      observe(2, 100000, 0, 206, true);
      observe(4, 200000, 1, 429, true);
      expect(policy.connections, lessThan(4));
      final reduced = policy.connections;
      observe(6, 300000, 1, 206, true);
      expect(policy.connections, reduced);
      observe(20, 900000, 1, 206, true);
      expect(policy.connections, inInclusiveRange(reduced, 4));
      policy.setLimit(1);
      expect(policy.connections, 1);
    },
  );

  test(
    'Playback metrics separate startup, rebuffering, pauses and paused seeking',
    () {
      final metrics = PlaybackMetrics();
      void sample(
        int second, {
        bool playing = true,
        bool buffering = false,
        int position = 0,
      }) => metrics.observe(
        elapsed: Duration(seconds: second),
        playing: playing,
        buffering: buffering,
        position: Duration(seconds: position),
      );
      sample(0, buffering: true);
      sample(2, position: 1);
      sample(4, buffering: true, position: 3);
      sample(7, playing: false, buffering: true, position: 3);
      sample(10, playing: false, position: 3);
      metrics.seek(const Duration(seconds: 30), const Duration(seconds: 10));
      sample(11, playing: false, position: 30);
      expect(metrics.bufferingCount, 1);
      expect(metrics.bufferingTime, const Duration(seconds: 3));
      expect(metrics.lastSeekTime, const Duration(seconds: 1));
    },
  );
}
