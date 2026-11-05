import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/playback.dart';
import 'player_support.dart';
import 'support.dart';

PlayerState header({int rotation = 0, double par = 1}) => PlayerState(
  tracks: Tracks(
    video: [
      VideoTrack('1', null, null, w: 1920, h: 1080, rotate: rotation, par: par),
    ],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Partial decoded dimensions retain the container rotation and pixel aspect',
    () {
      final backend = FakePlaybackBackend('partial-metadata', []);
      final source = header(rotation: 90, par: 4 / 3);
      backend.emit(source);
      const expected = VideoGeometry(1080, 2560);
      expect(backend.videoGeometry, expected);
      backend.emit(
        source.copyWith(videoParams: const VideoParams(w: 1920, h: 1080)),
      );
      expect(backend.videoGeometry, expected);
      backend.emit(
        source.copyWith(videoParams: const VideoParams(dw: 2560, dh: 1080)),
      );
      expect(backend.videoGeometry, expected);
      // Once rotation is applied by the decoder, zero must not be replaced by
      // the container's 90 degrees and applied a second time.
      backend.emit(
        source.copyWith(
          videoParams: const VideoParams(dw: 1080, dh: 2560, rotate: 0),
        ),
      );
      expect(backend.videoGeometry, expected);
    },
  );
  test(
    'Container track dimensions and rotation work without a decoded frame',
    () {
      final backend = FakePlaybackBackend('metadata', []);
      for (final angle in [90, 270, -90, 450]) {
        backend.emit(header(rotation: angle));
        expect(backend.state.width, isNull);
        expect(backend.state.height, isNull);
        expect(backend.videoGeometry, const VideoGeometry(1080, 1920));
      }
      backend.emit(header(rotation: 180));
      expect(backend.videoGeometry, const VideoGeometry(1920, 1080));
    },
  );

  test(
    'Pixel aspect ratios and display dimensions are applied before rotation',
    () {
      final backend = FakePlaybackBackend('metadata', []);
      backend.emit(
        const PlayerState(
          tracks: Tracks(
            video: [
              VideoTrack(
                '1',
                null,
                null,
                w: 1440,
                h: 1080,
                par: 4 / 3,
                rotate: 270,
              ),
            ],
          ),
        ),
      );
      expect(backend.videoGeometry, const VideoGeometry(1080, 1920));
      backend.emit(
        const PlayerState(
          videoParams: VideoParams(
            w: 1440,
            h: 1080,
            dw: 1920,
            dh: 1080,
            par: 4 / 3,
            rotate: 90,
          ),
          width: 1080,
          height: 1920,
        ),
      );
      expect(backend.videoGeometry, const VideoGeometry(1080, 1920));
    },
  );

  test(
    'Selected video metadata wins over defaults and cover artwork is ignored',
    () {
      final backend = FakePlaybackBackend('metadata', []);
      const tracks = Tracks(
        video: [
          VideoTrack('cover', null, null, w: 3000, h: 3000, albumart: true),
          VideoTrack('1', null, null, w: 1920, h: 1080, isDefault: true),
          VideoTrack('2', null, null, w: 720, h: 1280),
        ],
      );
      backend.emit(const PlayerState(tracks: tracks));
      expect(backend.videoGeometry, const VideoGeometry(1920, 1080));
      backend.emit(
        const PlayerState(
          tracks: tracks,
          track: Track(video: VideoTrack('2', null, null)),
        ),
      );
      expect(backend.videoGeometry, const VideoGeometry(720, 1280));
      backend.emit(
        const PlayerState(
          tracks: Tracks(
            video: [
              VideoTrack('cover', null, null, w: 3000, h: 3000, albumart: true),
            ],
          ),
        ),
      );
      expect(backend.videoGeometry, isNull);
    },
  );

  test(
    'Invalid dimensions are unknown and near-square videos follow the system',
    () {
      expect(VideoGeometry.fromMetadata(width: 0, height: 1080), isNull);
      expect(VideoGeometry.fromMetadata(width: 1000000, height: 1080), isNull);
      expect(
        VideoGeometry.fromMetadata(
          width: 100,
          height: 100,
          pixelAspect: double.nan,
        ),
        isNull,
      );
      expect(
        VideoGeometry.fromMetadata(
          width: 100,
          height: 100,
          pixelAspect: double.infinity,
        ),
        isNull,
      );
      expect(VideoGeometry.fromJson({'width': -1, 'height': 100}), isNull);
      expect(
        playbackOrientation(
          video: true,
          automatic: true,
          width: 1088,
          height: 1080,
        ),
        PlaybackOrientation.system,
      );
    },
  );

  test(
    'Metadata cache is bounded, survives reopening, and clears with history',
    () async {
      final store = StateStore.memory(),
          history = PlaybackStore(StateStore.memory());
      final saved = PlaybackStore(store);
      for (var i = 0; i < PlaybackStore.historyLimit + 3; i++) {
        await saved.saveVideoGeometry(
          playbackKey(i),
          const VideoGeometry(1080, 1920),
        );
      }
      final reopened = PlaybackStore(store);
      expect(reopened.videoGeometry(playbackKey(0)), isNull);
      expect(
        reopened.videoGeometry(playbackKey(202)),
        const VideoGeometry(1080, 1920),
      );
      expect(
        store.data.obj('playbackVideoInfo').length,
        PlaybackStore.historyLimit,
      );
      expect(jsonEncode(store.data), isNot(contains('http')));
      expect(history.videoGeometry('missing'), isNull);
      await reopened.clearHistory();
      expect(store.data.obj('playbackVideoInfo'), isEmpty);
    },
  );

  test(
    'Previously inspected geometry is available before URL resolution starts',
    () async {
      final fixture = PlaybackFixture(), barrier = Completer<void>();
      addTearDown(() async {
        if (!barrier.isCompleted) barrier.complete();
        await fixture.controller.close();
      });
      await fixture.history.saveVideoGeometry(
        fixture.entries.first.key,
        const VideoGeometry(720, 1280),
      );
      fixture.prepareBarrier = (_, _) => barrier.future;
      expect(fixture.controller.videoGeometry, const VideoGeometry(720, 1280));
      final loading = fixture.controller.start();
      await until(() => fixture.preparations == 1);
      expect(fixture.backends, hasLength(1));
      expect(fixture.current.openedSource, isNull);
      expect(fixture.controller.videoGeometry, const VideoGeometry(720, 1280));
      barrier.complete();
      await loading;
      expect(fixture.controller.videoGeometry, const VideoGeometry(1920, 1080));
    },
  );

  test('Metadata and the presentation barrier precede autoplay', () async {
    final fixture = PlaybackFixture(), presentation = Completer<void>();
    addTearDown(fixture.controller.close);
    fixture.configureBackend = (backend) => backend.emit(header(rotation: 90));
    var preparing = false;
    fixture.controller.beforePlay = () async {
      preparing = true;
      expect(fixture.current.plays, 0);
      expect(fixture.current.state.width, isNull);
      expect(fixture.controller.videoGeometry, const VideoGeometry(1080, 1920));
      await presentation.future;
    };
    final loading = fixture.controller.start();
    await until(() => preparing);
    expect(fixture.controller.loading, isTrue);
    presentation.complete();
    await loading;
    expect(fixture.current.plays, 1);
    expect(
      fixture.history.videoGeometry(fixture.entries.first.key),
      const VideoGeometry(1080, 1920),
    );
  });

  test(
    'A cold load waits for late container metadata while still paused',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.emit(const PlayerState());
      final loading = fixture.controller.start();
      await until(
        () =>
            fixture.backends.isNotEmpty && fixture.current.openedSource != null,
      );
      expect(fixture.current.plays, 0);
      expect(fixture.controller.videoGeometry, isNull);
      fixture.current.emit(header(rotation: 270));
      await loading;
      expect(fixture.controller.videoGeometry, const VideoGeometry(1080, 1920));
      expect(fixture.current.plays, 1);
    },
  );

  test(
    'Closing during metadata discovery releases the paused source promptly',
    () async {
      final fixture = PlaybackFixture();
      fixture.configureBackend = (backend) => backend.emit(const PlayerState());
      final loading = fixture.controller.start();
      await until(
        () =>
            fixture.backends.isNotEmpty && fixture.current.openedSource != null,
      );
      await fixture.controller.close().timeout(const Duration(seconds: 1));
      await loading;
      expect(fixture.current.plays, 0);
      expect(fixture.leases.values, everyElement(0));
    },
  );

  test(
    'An unknown next episode never reuses the previous video dimensions',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      final old = fixture.current;
      fixture.configureBackend = (backend) => backend.emit(const PlayerState());
      final next = fixture.controller.load(1);
      await until(
        () =>
            fixture.backends.length == 2 &&
            fixture.current.openedSource != null,
      );
      expect(fixture.controller.videoGeometry, isNull);
      old.emit(header(rotation: 0));
      expect(fixture.controller.videoGeometry, isNull);
      fixture.current.emit(header(rotation: 90));
      await next;
      expect(fixture.controller.videoGeometry, const VideoGeometry(1080, 1920));
    },
  );

  test(
    'Decoded metadata corrects a cached or provisional container ratio',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.emit(header());
      await fixture.controller.start();
      fixture.current.emit(
        header().copyWith(
          videoParams: const VideoParams(dw: 1080, dh: 1920, rotate: 0),
        ),
      );
      expect(fixture.controller.videoGeometry, const VideoGeometry(1080, 1920));
      await until(
        () =>
            fixture.history.videoGeometry(fixture.entries.first.key) ==
            const VideoGeometry(1080, 1920),
      );
    },
  );

  test(
    'Formats without early metadata can still start after the bounded wait',
    () async {
      final fixture = PlaybackFixture();
      addTearDown(fixture.controller.close);
      fixture.configureBackend = (backend) => backend.emit(const PlayerState());
      await fixture.controller.start().timeout(const Duration(seconds: 5));
      expect(fixture.controller.ready, isTrue);
      expect(fixture.current.plays, 1);
    },
  );
}
