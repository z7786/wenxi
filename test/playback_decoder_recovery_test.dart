import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'player_support.dart';
import 'support.dart';

void main() {
  late PlaybackFixture f;
  setUp(() => f = PlaybackFixture(renewable: true));
  tearDown(() => f.controller.close());
  const failure = PlaybackFailure(
    'decoder stopped',
    PlaybackFailureKind.decoder,
    decoderUnavailable: true,
  );
  void fail() => f.current
    ..failure = failure
    ..fail();
  void video({int width = 1920, double fps = 24}) => f.current.emit(
    f.current.state.copyWith(
      tracks: Tracks(
        video: [VideoTrack('1', null, null, w: width, h: 1080, fps: fps)],
        audio: f.current.state.tracks.audio,
        subtitle: f.current.state.tracks.subtitle,
      ),
      track: Track(
        video: const VideoTrack('1', null, null),
        audio: f.current.state.track.audio,
        subtitle: f.current.state.track.subtitle,
      ),
    ),
  );
  test(
    'Reconstruction reuses the source and preserves selection, pause and position',
    () async {
      await f.controller.start();
      await f.controller.setAudioTrack(const AudioTrack('2', 'English', 'eng'));
      await f.controller.setSubtitleTrack(
        const SubtitleTrack('1', '简体中文', 'zho'),
      );
      await f.controller.setAudioDelay(.3);
      await f.controller.setSubtitleDelay(1.2);
      await f.controller.seek(const Duration(seconds: 395));
      await f.controller.pause();
      final old = f.current, source = old.openedSource!;
      fail();
      await until(() => f.backends.length == 2 && f.controller.ready);
      expect(old.closed, isTrue);
      expect(f.current.openedSource, same(source));
      expect(f.preparations, 1);
      expect(f.current.hardwareAcceleration, isTrue);
      expect(f.current.openedStart, const Duration(seconds: 395));
      expect(f.current.state.playing, isFalse);
      expect(f.current.state.track.audio.id, '2');
      expect(f.current.state.track.subtitle.id, '1');
      expect(f.current.audioDelay, .3);
      expect(f.current.subtitleDelay, 1.2);
      expect(f.leases[source.url], 1);
      fail();
      await Future<void>.delayed(Duration.zero);
      expect(f.backends, hasLength(2));
      expect(f.controller.error, failure.message);
    },
  );
  test(
    'Known 1080p24 gets one software attempt, never a recovery loop',
    () async {
      await f.controller.start();
      video();
      fail();
      await until(() => f.backends.length == 2 && f.controller.ready);
      fail();
      await until(() => f.backends.length == 3 && f.controller.ready);
      expect(f.current.hardwareAcceleration, isFalse);
      expect(f.controller.preferences.hardwareAcceleration, isTrue);
      fail();
      await Future<void>.delayed(Duration.zero);
      expect(f.backends, hasLength(3));
      expect(f.controller.error, failure.message);
      expect(f.preparations, 1);
    },
  );
  for (final (width, fps) in [(3840, 24.0), (1920, 60.0)]) {
    test(
      '$width / $fps does not automatically fall back to software',
      () async {
        await f.controller.start();
        video(width: width, fps: fps);
        fail();
        await until(() => f.backends.length == 2 && f.controller.ready);
        fail();
        await Future<void>.delayed(Duration.zero);
        expect(f.backends, hasLength(2));
        expect(f.controller.error, failure.message);
      },
    );
  }
  test('Pause during retirement is honored by the replacement', () async {
    await f.controller.start();
    final gate = Completer<void>();
    f.current.closeBarrier = gate.future;
    fail();
    await until(() => f.controller.backend == null);
    await f.controller.pause();
    gate.complete();
    await until(() => f.backends.length == 2 && f.controller.ready);
    expect(f.current.state.playing, isFalse);
  });
  test(
    'Switching episodes cancels recovery and releases the retained source',
    () async {
      await f.controller.start();
      final old = f.current, gate = Completer<void>();
      old.closeBarrier = gate.future;
      fail();
      await until(() => f.controller.backend == null);
      await f.controller.next();
      gate.complete();
      await until(() => f.leases[old.openedSource!.url] == 0);
      expect(f.backends, hasLength(2));
      expect(f.controller.current.id, '1');
      expect(f.leases.values, everyElement(inInclusiveRange(0, 1)));
    },
  );
  test(
    'Failed native teardown stops recovery before creating another decoder',
    () async {
      await f.controller.start();
      f.current.failClose = true;
      fail();
      await until(() => !f.controller.loading);
      expect(f.backends, hasLength(1));
      expect(f.controller.error, contains('关闭未完成'));
      expect(f.leases.values, everyElement(1));
    },
  );
  test('A background decoder failure does not start another decoder', () async {
    await f.controller.start();
    await f.controller.background(pictureInPicture: false);
    fail();
    await Future<void>.delayed(Duration.zero);
    expect(f.backends, hasLength(1));
    expect(f.controller.error, failure.message);
  });
}
