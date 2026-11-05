import '../app_services.dart';
import '../core/json.dart';
import '../data/playback_store.dart';
import '../domain/playback.dart';
import '../platform/external_open.dart';
import 'media_backend.dart';
import 'playback_backend_factory.dart';
import 'playback_controller.dart';

PlaybackController externalPlayback(
  AppServices services,
  ExternalOpenRequest request, {
  PlaybackBackend Function(PlaybackEntry, bool)? backendFactory,
}) {
  require(request.kind == ExternalOpenKind.play, '外部播放请求无效');
  final spec = request.playbackSpec;
  return PlaybackController(
    entries: [
      PlaybackEntry(
        id: request.id,
        key: playbackKey(['external', spec.url]),
        name: spec.fileName,
        video: true,
        // Temporary content grants and signed URLs belong only to this session.
      ),
    ],
    initialIndex: 0,
    history: PlaybackStore(services.store),
    prepare: (_, _) async => spec,
    retain: (_) {},
    release: (_) async {},
    backendFactory:
        backendFactory ??
        (entry, hardware) => createPlaybackBackend(
          video: entry.video,
          hardwareAcceleration: hardware,
        ),
  );
}
