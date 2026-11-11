import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/media_backend.dart';

class _ProgressPlayer extends PlatformPlayer {
  _ProgressPlayer() : super(configuration: const PlayerConfiguration());
  @override
  Future<void> open(Playable playable, {bool play = true}) async {}
  void progress(int ms) {
    state = state.copyWith(position: Duration(milliseconds: ms));
    positionController.add(state.position);
  }

  void buffering(bool value) {
    state = state.copyWith(buffering: value);
    bufferingController.add(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'High frequency progress coalesces while buffering state notifies immediately',
    () async {
      final platform = _ProgressPlayer();
      final backend = MediaKitBackend(
        video: false,
        player: Player(platformPlayer: platform),
      );
      try {
        await backend.open(
          const DownloadSpec(url: 'fixture.mkv', fileName: 'fixture.mkv'),
          Duration.zero,
        );
        var notifications = 0;
        backend.addListener(() => notifications++);
        for (var i = 0; i < 100; i++) {
          platform.progress(i * 10);
        }
        await Future<void>.delayed(Duration.zero);
        expect(notifications, 1);
        expect(backend.state.position, const Duration(milliseconds: 990));
        platform.buffering(true);
        await Future<void>.delayed(Duration.zero);
        expect(notifications, 2);
        await Future<void>.delayed(const Duration(milliseconds: 260));
        platform.progress(1500);
        await Future<void>.delayed(Duration.zero);
        expect(notifications, 3);
      } finally {
        await backend.close();
      }
    },
  );
}
