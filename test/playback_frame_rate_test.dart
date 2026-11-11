import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'player_support.dart';

void main() {
  test(
    'Display cadence follows selected content and speed, not decoder drops',
    () {
      final backend = FakePlaybackBackend('cadence', []);
      backend.emit(
        backend.state.copyWith(
          tracks: const Tracks(
            video: [
              VideoTrack('cover', null, null, albumart: true, fps: 60),
              VideoTrack('1', null, null, fps: 24000 / 1001, isDefault: true),
              VideoTrack('2', null, null, fps: 50),
            ],
          ),
        ),
      );
      expect(backend.displayFrameRate, closeTo(23.976, .001));
      backend.emit(backend.state.copyWith(rate: 1.25));
      expect(backend.displayFrameRate, closeTo(29.970, .001));
      backend.emit(
        backend.state.copyWith(
          rate: 1,
          track: const Track(video: VideoTrack('2', null, null)),
        ),
      );
      expect(backend.displayFrameRate, 50);
      backend.emit(
        backend.state.copyWith(track: Track(video: VideoTrack.no())),
      );
      expect(backend.displayFrameRate, isNull);
    },
  );

  test(
    'Unknown or invalid cadence and cover art leave the display at its default',
    () {
      final backend = FakePlaybackBackend('cadence', []);
      expect(backend.displayFrameRate, isNull);
      backend.emit(
        backend.state.copyWith(
          tracks: const Tracks(video: [VideoTrack('1', null, null)]),
        ),
      );
      expect(backend.displayFrameRate, isNull);
      for (final invalid in [double.nan, double.infinity, 0.0, 500.0]) {
        backend.emit(
          backend.state.copyWith(
            tracks: Tracks(video: [VideoTrack('1', null, null, fps: invalid)]),
          ),
        );
        expect(backend.displayFrameRate, isNull);
      }
      backend.emit(
        backend.state.copyWith(
          rate: 3,
          tracks: const Tracks(video: [VideoTrack('1', null, null, fps: 120)]),
        ),
      );
      expect(backend.displayFrameRate, isNull);
      backend.emit(
        backend.state.copyWith(
          rate: 1,
          tracks: const Tracks(
            video: [VideoTrack('1', null, null, image: true)],
          ),
        ),
      );
      expect(backend.displayFrameRate, isNull);
    },
  );
}
