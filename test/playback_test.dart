import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/playback/subtitle_files.dart';
import 'player_support.dart';
import 'support.dart';

class _DelayedPlaybackStore extends PlaybackStore {
  _DelayedPlaybackStore(super.store);
  Future<void>? saveBarrier;
  int saves = 0;

  @override
  Future<void> save(String key, PlaybackBookmark bookmark) async {
    saves++;
    await saveBarrier;
    await super.save(key, bookmark);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Playback preferences reject nonfinite and out-of-range persisted values',
    () {
      final preferences = PlaybackPreferences.fromJson({
        'rate': double.nan,
        'boostRate': double.infinity,
        'volume': 500,
        'subtitleSize': -5,
        'subtitleBottom': double.infinity,
        'subtitleBackground': 'unknown',
        'subtitleBackgroundColor': -1,
        'subtitleBackgroundOpacity': double.nan,
        'fit': 'unknown',
      });
      expect(preferences.rate, 1);
      expect(preferences.boostRate, 2);
      expect(preferences.showScreenshotButton, isTrue);
      expect(preferences.volume, 100);
      expect(preferences.subtitleSize, 14);
      expect(preferences.subtitleBottom, .04);
      expect(preferences.subtitleBackground, SubtitleBackground.none);
      expect(preferences.subtitleBackgroundColor, 0);
      expect(preferences.subtitleBackgroundOpacity, .5);
      expect(preferences.subtitleBackgroundArgb, isNull);
      expect(preferences.fit, PlaybackFit.contain);
      expect(preferences.copyWith(rate: .1, volume: -4).rate, .25);
      expect(preferences.copyWith(rate: 8).rate, 4);
      expect(preferences.copyWith(volume: -4).volume, 0);
    },
  );
  test('Subtitle appearance survives store reload and mode changes', () async {
    final history = PlaybackStore(StateStore.memory());
    expect(history.preferences.subtitleBackgroundArgb, isNull);
    await history.savePreferences(
      history.preferences.copyWith(
        subtitleBackground: SubtitleBackground.custom,
        subtitleBackgroundColor: 0x245a80,
        subtitleBackgroundOpacity: .5,
      ),
    );
    final reloaded = PlaybackStore(history.store).preferences;
    expect(reloaded.subtitleBackgroundArgb, 0x80245a80);
    final black = reloaded.copyWith(
      subtitleBackground: SubtitleBackground.black,
    );
    expect(black.subtitleBackgroundArgb, 0x80000000);
    expect(
      black
          .copyWith(subtitleBackground: SubtitleBackground.custom)
          .subtitleBackgroundArgb,
      0x80245a80,
    );
    expect(
      reloaded.copyWith(subtitleBackgroundOpacity: 2).subtitleBackgroundOpacity,
      1,
    );
    expect(
      reloaded
          .copyWith(subtitleBackgroundOpacity: -1)
          .subtitleBackgroundOpacity,
      0,
    );
    expect(
      reloaded
          .copyWith(subtitleBackground: SubtitleBackground.none)
          .subtitleBackgroundArgb,
      isNull,
    );
  });
  test(
    'Large-screen subtitle sizes persist without changing existing sizes',
    () async {
      for (final size in [22.0, 40.0, 80.0, 120.0]) {
        final history = PlaybackStore(StateStore.memory());
        await history.savePreferences(
          history.preferences.copyWith(subtitleSize: size),
        );
        expect(PlaybackStore(history.store).preferences.subtitleSize, size);
      }
      expect(PlaybackPreferences.fromJson({}).subtitleSize, 22);
      expect(
        PlaybackPreferences.fromJson({'subtitleSize': 999}).subtitleSize,
        120,
      );
      expect(
        PlaybackPreferences.fromJson({'subtitleSize': double.nan}).subtitleSize,
        22,
      );
    },
  );
  test('Resume ignores completed tails and clamps invalid positions', () {
    PlaybackBookmark bookmark(int seconds, {bool done = false}) =>
        PlaybackBookmark(
          position: Duration(seconds: seconds),
          duration: const Duration(minutes: 10),
          updatedAt: 1,
          completed: done,
        );
    expect(bookmark(120).resumePosition, const Duration(minutes: 2));
    expect(bookmark(120, done: true).resumePosition, Duration.zero);
    expect(bookmark(599).resumePosition, Duration.zero);
    expect(bookmark(900).resumePosition, Duration.zero);
    expect(bookmark(3).resumePosition, Duration.zero);
    expect(
      clampPlaybackPosition(
        const Duration(seconds: -5),
        const Duration(seconds: 20),
      ),
      Duration.zero,
    );
    expect(
      playbackTime(const Duration(hours: 3, minutes: 2, seconds: 4)),
      '3:02:04',
    );
  });
  test(
    'History identity ignores expiring session tokens but isolates accounts and file changes',
    () {
      BrowseSession session(String token) => BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.share,
        title: '共享',
        rootId: '0',
        metadata: {'token': token},
        sourceLink: ParsedLink(
          source: '',
          url: 'https://example.invalid/share',
          kind: LinkKind.cloudShare,
          shareId: 'share-1',
        ),
      );
      const file = CloudFile(id: 'file-1', name: 'a.mkv', size: 100);
      final key = cloudPlaybackKey(session('one'), file, 1);
      expect(cloudPlaybackKey(session('two'), file, 1), key);
      expect(cloudPlaybackKey(session('one'), file, 2), isNot(key));
      expect(
        cloudPlaybackKey(
          session('one'),
          const CloudFile(id: 'file-1', name: 'a.mkv', size: 101),
          1,
        ),
        isNot(key),
      );
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    },
  );
  test(
    'Playback history is bounded and contains only hashed keys and positions',
    () async {
      final history = PlaybackStore(StateStore.memory());
      for (var i = 0; i < PlaybackStore.historyLimit + 2; i++) {
        await history.save(
          playbackKey(i),
          PlaybackBookmark(
            position: const Duration(seconds: 30),
            duration: const Duration(minutes: 3),
            updatedAt: i,
          ),
        );
      }
      expect(
        history.store.data.obj('playbackHistory').length,
        PlaybackStore.historyLimit,
      );
      expect(history.bookmark(playbackKey(0)), isNull);
      expect(
        history.bookmark(playbackKey(201))?.position,
        const Duration(seconds: 30),
      );
      await history.clearHistory();
      expect(history.store.data.obj('playbackHistory'), isEmpty);
    },
  );

  group('Playback lifetime', () {
    late PlaybackFixture fixture;
    setUp(() {
      fixture = PlaybackFixture();
    });
    tearDown(() async {
      await fixture.controller.close();
    });
    test(
      'Open retains HTTP authentication and restores saved position, speed and volume',
      () async {
        await fixture.history.savePreferences(
          const PlaybackPreferences(rate: 1.5, volume: 65),
        );
        fixture.controller.preferences = fixture.history.preferences;
        await fixture.history.save(
          fixture.entries[0].key,
          PlaybackBookmark(
            position: const Duration(seconds: 80),
            duration: const Duration(minutes: 10),
            updatedAt: 1,
          ),
        );
        await fixture.controller.start();
        expect(
          fixture.current.openedSource!.headers['Cookie'],
          'test-cookie=fixture',
        );
        expect(fixture.current.openedStart, const Duration(seconds: 80));
        expect(fixture.current.rates.last, 1.5);
        expect(fixture.current.volumes.last, 65);
        expect(fixture.current.plays, 1);
        await fixture.controller.saveProgress();
        expect(
          jsonEncode(fixture.store.data),
          isNot(contains('fixture-secret')),
        );
        expect(jsonEncode(fixture.store.data), isNot(contains('Cookie')));
      },
    );
    test(
      'A late source resolution cannot replace the selected episode and releases its lease',
      () async {
        final first = Completer<void>();
        fixture.prepareBarrier = (_, request) =>
            request == 1 ? first.future : Future.value();
        final opening = fixture.controller.start();
        await until(() => fixture.preparations == 1);
        await fixture.controller.load(1);
        first.complete();
        await opening;
        expect(fixture.controller.index, 1);
        expect(fixture.backends.length, 2);
        expect(fixture.backends.first.closed, isTrue);
        expect(fixture.backends.first.openedSource, isNull);
        expect(fixture.current.openedSource!.fileName, fixture.entries[1].name);
        expect(fixture.leases.values.where((count) => count == 0).length, 1);
      },
    );
    test(
      'Closing while a source is unresolved never starts playback afterwards',
      () async {
        final gate = Completer<void>();
        fixture.prepareBarrier = (_, _) => gate.future;
        final opening = fixture.controller.start();
        await until(() => fixture.preparations == 1);
        final closing = fixture.controller.close();
        gate.complete();
        await opening;
        await closing;
        expect(fixture.backends.single.closed, isTrue);
        expect(fixture.backends.single.openedSource, isNull);
        expect(fixture.leases.values, everyElement(0));
      },
    );
    test(
      'Native close finishes before cloud leases or external subtitle files are released',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'asterlink-player-lease-',
        );
        addTearDown(() => removePlayerFixture(directory));
        await fixture.controller.start();
        final subtitle = await File(
          '${directory.path}/subtitle.srt',
        ).writeAsString('caption');
        await fixture.controller.attachSubtitle(
          subtitle,
          '字幕.srt',
          fixture.controller.generation,
        );
        final gate = Completer<void>();
        fixture.current.closeBarrier = gate.future;
        final next = fixture.controller.next();
        await until(() => fixture.current.closes == 1);
        expect(await subtitle.exists(), isTrue);
        expect(fixture.leases.values, everyElement(1));
        gate.complete();
        await next;
        expect(await subtitle.exists(), isFalse);
        expect(
          fixture.events.indexOf('closed:0:0'),
          lessThan(
            fixture.events.indexOf('release:${fixture.entries[0].name}'),
          ),
        );
      },
    );
    test(
      'Account change during resolution rejects the source and releases it',
      () async {
        final gate = Completer<void>();
        fixture.prepareBarrier = (_, _) => gate.future;
        final opening = fixture.controller.start();
        await until(() => fixture.preparations == 1);
        fixture.accountValid = false;
        gate.complete();
        await opening;
        expect(fixture.controller.error, contains('账号已变化'));
        expect(fixture.backends.single.closed, isTrue);
        expect(fixture.backends.single.openedSource, isNull);
        expect(fixture.leases.values, everyElement(0));
      },
    );
    test('Completion advances once and records a completed bookmark', () async {
      await fixture.controller.start();
      final first = fixture.current;
      first.emit(
        first.state.copyWith(
          position: const Duration(minutes: 10),
          completed: true,
          playing: false,
        ),
      );
      first.emit(first.state.copyWith(completed: true));
      await until(
        () => fixture.controller.index == 1 && fixture.controller.ready,
      );
      expect(fixture.preparations, 2);
      expect(fixture.backends.length, 2);
      expect(
        fixture.history.bookmark(fixture.entries[0].key)?.completed,
        isTrue,
      );
      expect(
        fixture.history.bookmark(fixture.entries[0].key)?.resumePosition,
        Duration.zero,
      );
    });
    test('Auto-next can be disabled and replay starts at zero', () async {
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(autoNext: false),
      );
      await fixture.controller.start();
      fixture.current.emit(
        fixture.current.state.copyWith(
          position: const Duration(minutes: 10),
          completed: true,
          playing: false,
        ),
      );
      await fixture.store.flush();
      expect(fixture.controller.index, 0);
      await fixture.controller.play();
      expect(fixture.current.seeks.last, Duration.zero);
      expect(fixture.current.state.playing, isTrue);
    });
    test(
      'Seeking after completion cancels the pending automatic episode change',
      () async {
        await fixture.controller.start();
        fixture.current.emit(
          fixture.current.state.copyWith(
            position: const Duration(minutes: 10),
            completed: true,
            playing: false,
          ),
        );
        await fixture.controller.seek(const Duration(seconds: 30));
        await fixture.store.flush();
        expect(fixture.controller.index, 0);
        expect(fixture.preparations, 1);
        expect(
          fixture.history.bookmark(fixture.entries[0].key)?.completed,
          isFalse,
        );
        expect(fixture.current.state.position, const Duration(seconds: 30));
      },
    );
    test(
      'A failed native close pauses playback and preserves files still potentially in use',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'asterlink-player-close-failure-',
        );
        addTearDown(() => removePlayerFixture(directory));
        await fixture.controller.start();
        final first = fixture.current;
        final subtitle = await File(
          '${directory.path}/subtitle.srt',
        ).writeAsString('caption');
        await fixture.controller.attachSubtitle(
          subtitle,
          '字幕.srt',
          fixture.controller.generation,
        );
        first.failClose = true;
        await fixture.controller.next();
        expect(first.state.playing, isFalse);
        expect(fixture.leases[first.openedSource!.url], 1);
        expect(await subtitle.exists(), isTrue);
        expect(fixture.controller.notice, contains('临时文件已保留'));
        // Release the fake backend after verifying the failure path.
        first.failClose = false;
        await first.close();
      },
    );
    test(
      'Background state also prevents a still-loading video from autoplaying',
      () async {
        final gate = Completer<void>();
        fixture.prepareBarrier = (_, _) => gate.future;
        final opening = fixture.controller.start();
        await until(() => fixture.preparations == 1);
        await fixture.controller.background(pictureInPicture: false);
        gate.complete();
        await opening;
        expect(fixture.current.plays, 0);
        fixture.controller.foreground();
        await fixture.controller.play();
        final pauses = fixture.current.pauses;
        await fixture.controller.background(pictureInPicture: true);
        expect(fixture.current.pauses, pauses);
        expect(fixture.current.state.playing, isTrue);
      },
    );
    for (final switching in [false, true]) {
      test(
        switching
            ? 'Next pauses the old audio before a pending progress write completes'
            : 'Background pauses audio before a pending progress write completes',
        () async {
          fixture = PlaybackFixture(historyFactory: _DelayedPlaybackStore.new);
          await fixture.controller.start();
          final backend = fixture.current;
          const position = Duration(seconds: 123);
          backend.emit(backend.state.copyWith(position: position));
          final history = fixture.history as _DelayedPlaybackStore;
          final gate = Completer<void>();
          history.saveBarrier = gate.future;
          final action = switching
              ? fixture.controller.next()
              : fixture.controller.background(pictureInPicture: false);
          try {
            await until(() => history.saves > 0);
            expect(backend.state.playing, isFalse);
            expect(backend.pauses, greaterThan(0));
            expect(backend.state.position, position);
            expect(backend.state.volume, 100);
            // A retiring native backend can now release its source while disk
            // persistence continues; foreground backgrounding keeps its lease.
            expect(
              fixture.leases[backend.openedSource!.url],
              switching ? 0 : 1,
            );
            expect(fixture.preparations, 1);
          } finally {
            gate.complete();
            await action;
          }
          expect(history.bookmark(fixture.entries[0].key)?.position, position);
          if (switching) {
            expect(backend.closed, isTrue);
            expect(fixture.current.state.playing, isTrue);
          }
        },
      );
    }
    test(
      'Close releases native buffers while a bookmark is waiting for disk',
      () async {
        fixture = PlaybackFixture(historyFactory: _DelayedPlaybackStore.new);
        await fixture.controller.start();
        fixture.current.emit(
          fixture.current.state.copyWith(position: const Duration(seconds: 84)),
        );
        final history = fixture.history as _DelayedPlaybackStore;
        final gate = Completer<void>();
        history.saveBarrier = gate.future;
        final closing = fixture.controller.close();
        var complete = false;
        closing.then((_) => complete = true);
        try {
          await until(() => fixture.current.closed);
          expect(fixture.current.state.playing, isFalse);
          expect(complete, isFalse);
          expect(history.saves, greaterThan(0));
        } finally {
          gate.complete();
          await closing;
        }
        expect(
          fixture.history.bookmark(fixture.entries.first.key)!.position,
          const Duration(seconds: 84),
        );
        expect(fixture.leases.values.every((count) => count == 0), isTrue);
      },
    );

    test(
      'A delayed background bookmark cannot pause a later foreground play',
      () async {
        fixture = PlaybackFixture(historyFactory: _DelayedPlaybackStore.new);
        await fixture.controller.start();
        fixture.current.emit(
          fixture.current.state.copyWith(position: const Duration(seconds: 80)),
        );
        final history = fixture.history as _DelayedPlaybackStore;
        final gate = Completer<void>();
        history.saveBarrier = gate.future;
        final background = fixture.controller.background(
          pictureInPicture: false,
        );
        try {
          await until(() => history.saves > 0);
          fixture.controller.foreground();
          await fixture.controller.play();
          expect(fixture.current.state.playing, isTrue);
        } finally {
          gate.complete();
          await background;
        }
        expect(fixture.current.state.playing, isTrue);
      },
    );
    test(
      'Next pauses audio while an old subtitle command is still pending',
      () async {
        await fixture.controller.start();
        final backend = fixture.current;
        final gate = Completer<void>();
        backend.subtitleBarrier = gate.future;
        final changes = backend.subtitleChanges;
        final subtitle = fixture.controller.setSubtitleTrack(
          SubtitleTrack.no(),
        );
        await until(() => backend.subtitleChanges > changes);
        final next = fixture.controller.next();
        try {
          await until(() => fixture.controller.loading);
          await Future<void>.delayed(Duration.zero);
          expect(backend.state.playing, isFalse);
          expect(backend.pauses, greaterThan(0));
          expect(backend.closed, isFalse);
          expect(fixture.leases[backend.openedSource!.url], 1);
        } finally {
          gate.complete();
          await subtitle;
          await next;
        }
        expect(backend.closed, isTrue);
        expect(fixture.current.state.playing, isTrue);
      },
    );
    test(
      'Retry resolves a fresh URL and resumes the old position without leaking authentication',
      () async {
        await fixture.controller.start();
        final old = fixture.current;
        old.emit(old.state.copyWith(position: const Duration(seconds: 75)));
        old.fail();
        expect(fixture.controller.error, isNot(contains('fixture-secret')));
        await fixture.controller.retry();
        expect(fixture.current.openedStart, const Duration(seconds: 75));
        expect(fixture.current.openedSource!.url, isNot(old.openedSource!.url));
        expect(fixture.leases[old.openedSource!.url], 0);
        expect(old.closed, isTrue);
      },
    );
    test(
      'Seeking clamps both ends and seeking to zero replaces the prior bookmark',
      () async {
        await fixture.controller.start();
        await fixture.controller.seek(const Duration(seconds: 90));
        await fixture.controller.seek(const Duration(seconds: -5));
        expect(fixture.current.seeks.last, Duration.zero);
        expect(
          fixture.history.bookmark(fixture.entries[0].key)?.resumePosition,
          Duration.zero,
        );
        await fixture.controller.seek(const Duration(hours: 100));
        expect(fixture.current.seeks.last, const Duration(minutes: 10));
      },
    );
    test(
      'Long-press speed is temporary and pause restores the selected speed',
      () async {
        await fixture.controller.start();
        await fixture.controller.setRate(1.5);
        await fixture.controller.beginBoost();
        expect(fixture.current.rates.last, 2);
        expect(fixture.history.preferences.rate, 1.5);
        await fixture.controller.pause();
        expect(fixture.current.rates.last, 1.5);
        expect(fixture.controller.boosting, isFalse);
        expect(fixture.current.state.playing, isFalse);
      },
    );
    test(
      'Configured boost and slide speed stay separate from regular speed',
      () async {
        await fixture.controller.start();
        await fixture.controller.setRate(1.5);
        await fixture.controller.updatePreferences(
          fixture.controller.preferences.copyWith(boostRate: 2.75),
        );
        await fixture.controller.beginBoost();
        expect(fixture.current.rates.last, 2.75);
        await fixture.controller.adjustBoost(3.5);
        expect(fixture.current.rates.last, 3.5);
        expect(fixture.history.preferences.boostRate, 2.75);
        expect(fixture.history.preferences.rate, 1.5);
        await fixture.controller.endBoost();
        expect(fixture.current.rates.last, 1.5);
        await fixture.controller.beginBoost();
        expect(fixture.current.rates.last, 2.75);
        await fixture.controller.next();
        expect(fixture.controller.boosting, isFalse);
        expect(fixture.current.rates.last, 1.5);
      },
    );
    test(
      'Locking holds a temporary speed across release without changing preferences',
      () async {
        await fixture.controller.start();
        await fixture.controller.setRate(1.25);
        await fixture.controller.beginBoost();
        await fixture.controller.adjustBoost(3);
        fixture.controller.lockBoost();
        await fixture.controller.releaseBoost();
        expect(fixture.controller.boostLocked, isTrue);
        expect(fixture.controller.boosting, isTrue);
        expect(fixture.current.state.rate, 3);
        expect(fixture.history.preferences.rate, 1.25);
        expect(fixture.history.preferences.boostRate, 2);
        await fixture.controller.endBoost();
        expect(fixture.controller.boostLocked, isFalse);
        expect(fixture.current.state.rate, 1.25);
        await fixture.controller.beginBoost();
        await fixture.controller.releaseBoost();
        expect(fixture.controller.boosting, isFalse);
        expect(fixture.current.state.rate, 1.25);
      },
    );
    for (final action in ['pause', 'next', 'background', 'select speed']) {
      test('A locked speed is cleared by $action', () async {
        await fixture.controller.start();
        await fixture.controller.setRate(1.5);
        await fixture.controller.beginBoost();
        await fixture.controller.adjustBoost(3.5);
        fixture.controller.lockBoost();
        await fixture.controller.releaseBoost();
        switch (action) {
          case 'pause':
            await fixture.controller.pause();
          case 'next':
            await fixture.controller.next();
          case 'background':
            await fixture.controller.background(pictureInPicture: false);
          case 'select speed':
            await fixture.controller.setRate(2.5);
        }
        expect(fixture.controller.boosting, isFalse);
        expect(fixture.controller.boostLocked, isFalse);
        expect(
          fixture.current.state.rate,
          action == 'select speed' ? 2.5 : 1.5,
        );
        await fixture.controller.beginBoost();
        expect(fixture.controller.boostLocked, isFalse);
        expect(fixture.current.state.rate, 2);
      });
    }
    test(
      'Releasing while a native rate write is pending restores speed last',
      () async {
        await fixture.controller.start();
        await fixture.controller.setRate(1.25);
        final backend = fixture.current;
        final barrier = Completer<void>();
        backend.rateBarrier = barrier.future;
        final begin = fixture.controller.beginBoost();
        for (final rate in [2.5, 2.75, 3.0, 4.0]) {
          unawaited(fixture.controller.adjustBoost(rate));
        }
        final end = fixture.controller.endBoost();
        barrier.complete();
        await Future.wait([begin, end]);
        expect(backend.rates.last, 1.25);
        expect(backend.rates.where((rate) => rate > 1.25), [2.0]);
        expect(fixture.controller.boosting, isFalse);
      },
    );
    test(
      'Tracks use their native ids and sync offsets are scoped to the current video',
      () async {
        await fixture.controller.start();
        await fixture.controller.setAudioTrack(
          const AudioTrack('2', 'English', 'eng'),
        );
        await fixture.controller.setSubtitleTrack(SubtitleTrack.no());
        await fixture.controller.setSubtitleDelay(100);
        await fixture.controller.setAudioDelay(-100);
        expect(fixture.current.state.track.audio.id, '2');
        expect(fixture.current.state.track.subtitle.id, 'no');
        expect(fixture.current.subtitleDelay, 10);
        expect(fixture.current.audioDelay, -5);
        await fixture.controller.next();
        expect(fixture.controller.subtitleDelay, 0);
        expect(fixture.controller.audioDelay, 0);
        expect(fixture.current.state.track.subtitle.id, 'no');
      },
    );
    test('A download acquires its own lease before the player exits', () async {
      await fixture.controller.start();
      final source = fixture.current.openedSource!;
      await expectLater(
        fixture.controller.enqueueDownload((_) async {
          throw StateError('Download queue is unavailable');
        }),
        throwsStateError,
      );
      expect(fixture.leases[source.url], 1);
      await fixture.controller.enqueueDownload((selected) async {
        expect(selected.url, source.url);
      });
      expect(fixture.leases[source.url], 2);
      await fixture.controller.close();
      expect(fixture.leases[source.url], 1);
      await fixture.controller.release(source);
      expect(fixture.leases[source.url], 0);
    });
  });
  test(
    'Subtitle staging limits size, keeps bytes, and only writes inside its own directory',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-player-subtitles-',
      );
      addTearDown(() => removePlayerFixture(directory));
      final files = SubtitleFiles(directory),
          bytes = utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n字幕');
      final file = await files.stage('../../outside.srt', Stream.value(bytes));
      expect(file.parent.path, directory.path);
      expect(await file.readAsBytes(), bytes);
      await expectLater(
        files.stage('a.exe', Stream.value(bytes)),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        files.stage('empty.srt', const Stream.empty()),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        files.stage(
          'huge.srt',
          Stream.value(List<int>.filled(SubtitleFiles.maximumBytes + 1, 1)),
        ),
        throwsA(isA<AppException>()),
      );
      expect(await directory.list().length, 1);
    },
  );
}
