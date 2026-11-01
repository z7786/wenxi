import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_folder.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/playback/playlist_order.dart';
import 'package:asterlink/playback/playback_sleep_timer.dart';
import 'player_support.dart';

PlaybackEntry entry(String name, String folder) => PlaybackEntry(
  id: name,
  key: name,
  name: name,
  video: true,
  settingsFolder: folder,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'folder identity isolates accounts, drives and folders, ignores token refresh',
    () {
      String? folder({
        String account = 'a',
        String parent = 'p',
        String drive = 'd',
        int revision = 1,
      }) => playbackSourceFolder(
        PlaybackSource.cloud(
          DownloadOrigin(
            BrowseSession(
              platform: CloudPlatform.aliyun,
              mode: BrowseMode.personal,
              title: 'any name',
              rootId: 'root',
              metadata: {'accountId': account, 'driveId': drive},
            ),
            CloudFile(id: 'video', name: 'v.mp4', parentId: parent),
            revision,
          ),
        ),
      );
      expect(folder(), folder(revision: 999));
      expect(folder(), isNot(folder(account: 'b')));
      expect(folder(), isNot(folder(parent: 'other')));
      expect(folder(), isNot(folder(drive: 'backup')));
      expect(folder(parent: ''), isNull);
      expect(
        playbackSourceFolder(
          const PlaybackSource.local(path: r'D:\Movies\Show\a.mp4'),
        ),
        playbackSourceFolder(
          const PlaybackSource.local(path: 'd:/movies/show/b.mp4'),
        ),
      );
      expect(
        playbackSourceFolder(
          const PlaybackSource.local(
            path: 'content://media/external/video/media/21',
          ),
        ),
        isNull,
      );
      expect(
        playbackSourceFolder(
          const PlaybackSource.local(
            path: 'content://docs/document/primary%3AMovies%2FA%2Fa.mp4',
          ),
        ),
        playbackSourceFolder(
          const PlaybackSource.local(
            path: 'content://docs/document/primary%3AMovies%2FA%2Fb.mp4',
          ),
        ),
      );
    },
  );

  test(
    'folder overrides survive reopen, preserve global fallback and can be disabled',
    () async {
      final state = StateStore.memory({
        'playbackPreferences': {'rate': 1.25, 'volume': 70},
      });
      final history = PlaybackStore(state);
      final initial = history.preferencesFor('show-a');
      await history.saveEffectivePreferences(
        'show-a',
        initial.copyWith(
          rate: 1.5,
          skipIntroSeconds: 80,
          aspectRatio: 4 / 3,
          subtitleSize: 30,
          subtitles: false,
          volume: 50,
        ),
        initial,
      );
      await history.saveOrder('show-a', PlaybackPlaylistOrder.descending);
      final reopened = PlaybackStore(StateStore.memory(state.data));
      expect(reopened.preferencesFor('show-a').rate, 1.5);
      expect(reopened.preferencesFor('show-a').aspectRatio, 4 / 3);
      expect(reopened.preferencesFor('show-a').subtitles, isFalse);
      expect(reopened.preferencesFor('show-b').rate, 1.25);
      expect(reopened.preferencesFor('show-b').skipIntroSeconds, 0);
      expect(reopened.preferencesFor('show-b').volume, 50);
      expect(reopened.orderFor('show-a'), PlaybackPlaylistOrder.descending);
      await reopened.rememberFolder('show-a', false);
      expect(reopened.preferencesFor('show-a').rate, 1.25);
      expect(reopened.orderFor('show-a'), PlaybackPlaylistOrder.source);
      await reopened.rememberFolder('show-a', true);
      expect(reopened.preferencesFor('show-a').rate, 1.5);
      await reopened.clearHistory();
      expect(reopened.preferencesFor('show-a').rate, 1.5);
      // A volume-only update must not freeze all directory defaults.
      final other = reopened.preferencesFor('show-b');
      await reopened.saveEffectivePreferences(
        'show-b',
        other.copyWith(volume: 45),
        other,
      );
      expect(reopened.store.data['playbackFolders'], isNot(contains('show-b')));
    },
  );

  test(
    'explicit ratios survive serialization and invalid custom ratios reset',
    () {
      for (final value in [.5, 16 / 9, 4 / 3, 21 / 9, 1.0, 9 / 16, 1.23]) {
        final preference = const PlaybackPreferences().copyWith(
          aspectRatio: value,
        );
        expect(
          PlaybackPreferences.fromJson(preference.toJson()).aspectRatio,
          value,
        );
      }
      for (final invalid in [double.nan, double.infinity, -1.0, 50.0]) {
        expect(
          const PlaybackPreferences()
              .copyWith(aspectRatio: invalid)
              .aspectRatio,
          0,
        );
      }
    },
  );

  test(
    'episode order sorts natural digits, padded digits and Chinese episode numbers',
    () {
      final episodes = [
        'S01E10.mp4',
        'S01E02.mp4',
        'S01E1.mp4',
      ].map((n) => entry(n, 'a')).toList();
      expect(
        orderedPlaybackIndices(episodes, PlaybackPlaylistOrder.ascending),
        [2, 1, 0],
      );
      expect(
        orderedPlaybackIndices(episodes, PlaybackPlaylistOrder.descending),
        [0, 1, 2],
      );
      final chinese = [
        '第十二集',
        '第二集',
        '第一百零二集',
        '第十集',
      ].map((n) => entry(n, 'a')).toList();
      expect(orderedPlaybackIndices(chinese, PlaybackPlaylistOrder.ascending), [
        1,
        3,
        0,
        2,
      ]);
    },
  );

  test(
    'reordering keeps current entry; previous, next, auto-next and progress use that queue',
    () async {
      final f = PlaybackFixture(
        suppliedEntries: [
          entry('10.mp4', 'a'),
          entry('2.mp4', 'a'),
          entry('1.mp4', 'a'),
        ],
        initialIndex: 1,
      );
      addTearDown(f.controller.close);
      await f.controller.start();
      await f.controller.setPlaylistOrder(PlaybackPlaylistOrder.ascending);
      expect(f.controller.current.name, '2.mp4');
      expect(f.controller.previousIndex, 2);
      expect(f.controller.nextIndex, 0);
      await f.controller.previous();
      expect(f.controller.current.name, '1.mp4');
      await f.controller.next();
      expect(f.controller.current.name, '2.mp4');
      f.current.emit(
        f.current.state.copyWith(
          position: const Duration(minutes: 10),
          completed: true,
        ),
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(f.controller.current.name, '10.mp4');
      expect(f.history.bookmark('2.mp4')!.completed, isTrue);
      expect(f.history.orderFor('a'), PlaybackPlaylistOrder.ascending);
    },
  );

  test(
    'Chinese playlist names use pinyin, natural digits and stable homophones',
    () {
      final names = [
        '资料.mp4',
        '同01.mp4',
        '阿里10.mp4',
        '童1.mp4',
        '阿里2.mp4',
        '工作.mp4',
        '重庆.mp4',
      ];
      final entries = names.map((name) => entry(name, 'a')).toList();
      expect(orderedPlaybackIndices(entries, PlaybackPlaylistOrder.source), [
        0,
        1,
        2,
        3,
        4,
        5,
        6,
      ]);
      expect(orderedPlaybackIndices(entries, PlaybackPlaylistOrder.ascending), [
        4,
        2,
        6,
        5,
        1,
        3,
        0,
      ]);
      expect(
        orderedPlaybackIndices(entries, PlaybackPlaylistOrder.descending),
        [0, 1, 3, 5, 6, 2, 4],
      );
    },
  );

  test(
    'switching folders applies their rate, intro and subtitles without overwriting each other',
    () async {
      final f = PlaybackFixture(
        suppliedEntries: [entry('1', 'a'), entry('2', 'b'), entry('3', 'a')],
      );
      addTearDown(f.controller.close);
      await f.controller.start();
      await f.controller.setRate(1.75);
      await f.controller.updatePreferences(
        f.controller.preferences.copyWith(
          skipIntroSeconds: 45,
          subtitles: false,
        ),
      );
      await f.controller.next();
      expect(f.current.state.rate, 1);
      expect(f.controller.preferences.subtitles, isTrue);
      expect(f.current.seeks, isEmpty);
      await f.controller.next();
      expect(f.current.state.rate, 1.75);
      expect(f.current.state.track.subtitle.id, 'no');
      expect(f.current.seeks, contains(const Duration(seconds: 45)));
      await f.controller.setRememberFolder(false);
      expect(f.current.state.rate, 1);
      expect(f.current.state.track.subtitle.id, 'auto');
      await f.controller.setRememberFolder(true);
      expect(f.current.state.rate, 1.75);
    },
  );

  test(
    'sleep expiry while acquiring source cannot start playback and manual play can resume',
    () {
      fakeAsync((async) {
        final origin = DateTime(2026);
        final f = PlaybackFixture(now: () => origin.add(async.elapsed));
        final gate = Completer<void>();
        f.prepareBarrier = (_, _) => gate.future;
        unawaited(f.controller.start());
        async.flushMicrotasks();
        f.controller.sleepTimer.schedule(const Duration(seconds: 10));
        async.elapse(const Duration(seconds: 10));
        gate.complete();
        async.flushMicrotasks();
        expect(f.controller.sleepTimer.stopped, isTrue);
        expect(f.current.plays, 0);
        expect(f.current.state.playing, isFalse);
        unawaited(f.controller.play());
        async.flushMicrotasks();
        expect(f.current.state.playing, isTrue);
        unawaited(f.controller.close());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'end-of-episode timer waits through skipped outro, saves progress and prevents auto-next',
    () {
      fakeAsync((async) {
        final f = PlaybackFixture(
          data: {
            'playbackPreferences': {'skipOutroSeconds': 20},
          },
        );
        unawaited(f.controller.start());
        async.flushMicrotasks();
        f.controller.sleepTimer.afterEpisode();
        f.current.emit(
          f.current.state.copyWith(
            position: const Duration(minutes: 9, seconds: 50),
          ),
        );
        async.flushMicrotasks();
        expect(f.controller.index, 0);
        expect(f.current.state.playing, isTrue);
        f.current.emit(
          f.current.state.copyWith(
            position: const Duration(minutes: 10),
            completed: true,
          ),
        );
        async.flushMicrotasks();
        expect(f.controller.index, 0);
        expect(f.controller.sleepTimer.stopped, isTrue);
        expect(f.current.state.playing, isFalse);
        expect(f.history.bookmark(f.entries.first.key)!.completed, isTrue);
        expect(f.controller.preferences.autoNext, isTrue);
        unawaited(f.controller.close());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'timed stop persists current position and cancellation never restarts it',
    () {
      fakeAsync((async) {
        final start = DateTime(2026);
        final f = PlaybackFixture(now: () => start.add(async.elapsed));
        unawaited(f.controller.start());
        async.flushMicrotasks();
        f.current.emit(
          f.current.state.copyWith(position: const Duration(minutes: 4)),
        );
        f.controller.sleepTimer.schedule(const Duration(seconds: 3));
        async.elapse(const Duration(seconds: 3));
        expect(f.current.state.playing, isFalse);
        expect(
          f.history.bookmark(f.entries.first.key)!.position,
          const Duration(minutes: 4),
        );
        f.controller.sleepTimer.cancel();
        expect(f.controller.sleepTimer.mode, PlaybackSleepMode.off);
        expect(f.controller.sleepTimer.stopped, isTrue);
        unawaited(f.controller.close());
        async.flushMicrotasks();
      });
    },
  );

  test('sleep at episode end selected after completion stops immediately', () {
    fakeAsync((async) {
      final f = PlaybackFixture(count: 1);
      unawaited(f.controller.start());
      async.flushMicrotasks();
      f.current.emit(
        f.current.state.copyWith(
          completed: true,
          position: const Duration(minutes: 10),
        ),
      );
      async.flushMicrotasks();
      f.controller.sleepTimer.afterEpisode();
      async.flushMicrotasks();
      expect(f.controller.sleepTimer.stopped, isTrue);
      expect(f.controller.sleepTimer.mode, PlaybackSleepMode.off);
      expect(f.current.state.playing, isFalse);
      unawaited(f.controller.close());
      async.flushMicrotasks();
    });
  });
}
