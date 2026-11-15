import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:asterlink/playback/delegating_backend.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'support.dart' show until;

class _ViewportPlayer extends PlatformPlayer {
  _ViewportPlayer() : super(configuration: const PlayerConfiguration());
  void geometry(Size size) {
    state = state.copyWith(
      videoParams: VideoParams(
        dw: size.width.toInt(),
        dh: size.height.toInt(),
        rotate: 0,
      ),
    );
    videoParamsController.add(state.videoParams);
  }

  void volume(double value) {
    state = state.copyWith(volume: value);
    volumeController.add(value);
  }
}

class _ViewportOutput extends PlatformVideoController {
  _ViewportOutput(Player player)
    : super(player, const VideoControllerConfiguration());
  final sizes = <Size>[];
  Future<void>? barrier;
  bool failNext = false;
  @override
  Future<void> setSize({int? width, int? height}) async {
    sizes.add(Size(width!.toDouble(), height!.toDouble()));
    await barrier;
    if (failNext) {
      failNext = false;
      throw StateError('fixture resize failed');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  ({MediaKitBackend backend, _ViewportPlayer native, _ViewportOutput output})
  create() {
    final native = _ViewportPlayer();
    final player = Player(platformPlayer: native);
    final backend = MediaKitBackend(video: true, player: player);
    final output = _ViewportOutput(player);
    // Supply a texture fixture without pumping the SDK's platform factory.
    // Timers and property serialization below execute the real backend code.
    backend.videoController!.platform.complete(output);
    native.videoControllerCompleter.complete();
    native.state = native.state.copyWith(
      videoParams: const VideoParams(dw: 3840, dh: 2160, rotate: 0),
    );
    addTearDown(backend.close);
    return (backend: backend, native: native, output: output);
  }

  Future<void> tick([int ms = 240]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test(
    'Repeated notifications cannot starve a scheduled render resize',
    () async {
      final fixture = create();
      void request() => fixture.backend.setRenderViewport(
        const Size(1920, 1080),
        1,
        BoxFit.contain,
        1,
      );
      request();
      for (var i = 0; i < 8; i++) {
        await tick(50);
        request();
        fixture.native.volume(50.0 + i);
      }
      expect(fixture.output.sizes, [const Size(1920, 1080)]);
      await tick();
      expect(fixture.output.sizes, hasLength(1));
    },
  );

  test(
    'Android full-screen rotation reuses one sharp output through a delegate',
    () async {
      final fixture = create();
      final backend = DelegatingPlaybackBackend(fixture.backend);
      addTearDown(backend.close);
      void request(Size size) => backend.setRenderViewport(
        size,
        3,
        BoxFit.contain,
        1,
        stableOrientation: true,
      );
      request(const Size(904, 407));
      await until(() => fixture.output.sizes.isNotEmpty);
      expect(fixture.output.sizes, [const Size(2172, 1222)]);
      for (final viewport in const [
        Size(407, 904),
        Size(904, 407),
        Size(407, 904),
      ]) {
        request(viewport);
        await tick();
      }
      expect(fixture.output.sizes, hasLength(1));
      expect(fixture.backend.diagnosticFields['renderWidth'], 2172);
      expect(fixture.backend.diagnosticFields['renderHeight'], 1222);
    },
  );

  test(
    'Rapid viewport changes apply only the last size and restore normal sizing for PiP',
    () async {
      final fixture = create();
      fixture.backend.setRenderViewport(
        const Size(904, 407),
        3,
        BoxFit.contain,
        1,
        stableOrientation: true,
      );
      await until(() => fixture.output.sizes.length == 1);
      fixture.backend.setRenderViewport(
        const Size(600, 900),
        1,
        BoxFit.contain,
        1,
      );
      await tick(50);
      fixture.backend.setRenderViewport(
        const Size(400, 225),
        1,
        BoxFit.contain,
        1,
      );
      await until(() => fixture.output.sizes.length == 2);
      expect(fixture.output.sizes, [
        const Size(2172, 1222),
        const Size(400, 226),
      ]);
    },
  );

  test(
    'Returning to the current size cancels an obsolete pending resize',
    () async {
      final fixture = create();
      void request(Size size) =>
          fixture.backend.setRenderViewport(size, 1, BoxFit.contain, 1);
      request(const Size(1920, 1080));
      await until(() => fixture.output.sizes.isNotEmpty);
      request(const Size(960, 540));
      await tick(50);
      request(const Size(1920, 1080));
      await tick();
      expect(fixture.output.sizes, [const Size(1920, 1080)]);
    },
  );

  test(
    'Returning during a native resize reapplies the final viewport',
    () async {
      final fixture = create();
      void request(Size size) =>
          fixture.backend.setRenderViewport(size, 1, BoxFit.contain, 1);
      request(const Size(1920, 1080));
      await until(() => fixture.output.sizes.isNotEmpty);
      final barrier = Completer<void>();
      addTearDown(() {
        fixture.output.barrier = null;
        if (!barrier.isCompleted) barrier.complete();
      });
      fixture.output.barrier = barrier.future;
      request(const Size(960, 540));
      await until(() => fixture.output.sizes.length == 2);
      expect(fixture.output.sizes.last, const Size(960, 540));
      request(const Size(1920, 1080));
      fixture.output.barrier = null;
      barrier.complete();
      await until(() => fixture.output.sizes.length == 3);
      expect(fixture.output.sizes, [
        const Size(1920, 1080),
        const Size(960, 540),
        const Size(1920, 1080),
      ]);
    },
  );

  test(
    'A pending resize that expires during native work coalesces to the newest viewport',
    () async {
      final fixture = create();
      void request(Size size) =>
          fixture.backend.setRenderViewport(size, 1, BoxFit.contain, 1);
      request(const Size(1920, 1080));
      await until(() => fixture.output.sizes.isNotEmpty);
      final barrier = Completer<void>();
      addTearDown(() {
        fixture.output.barrier = null;
        if (!barrier.isCompleted) barrier.complete();
      });
      fixture.output.barrier = barrier.future;
      request(const Size(960, 540));
      await until(() => fixture.output.sizes.length == 2);
      request(const Size(800, 450));
      await tick(50);
      request(const Size(640, 360));
      await tick();
      expect(fixture.output.sizes, [
        const Size(1920, 1080),
        const Size(960, 540),
      ]);
      fixture.output.barrier = null;
      barrier.complete();
      await until(() => fixture.output.sizes.length == 3);
      expect(fixture.output.sizes, [
        const Size(1920, 1080),
        const Size(960, 540),
        const Size(640, 360),
      ]);
    },
  );

  test(
    'A failed resize retries on the next viewport update without a busy loop',
    () async {
      final fixture = create();
      fixture.output.failNext = true;
      void request() => fixture.backend.setRenderViewport(
        const Size(1920, 1080),
        1,
        BoxFit.contain,
        1,
      );
      request();
      await until(() => !fixture.output.failNext);
      expect(fixture.output.sizes, hasLength(1));
      request();
      await until(() => fixture.output.sizes.length == 2);
      expect(fixture.output.sizes, hasLength(2));
      expect(fixture.backend.diagnosticFields['renderWidth'], 1920);
    },
  );

  test(
    'Changing source geometry updates output and closing cancels pending work',
    () async {
      final fixture = create();
      fixture.backend.setRenderViewport(
        const Size(1920, 1080),
        1,
        BoxFit.contain,
        1,
      );
      await until(() => fixture.output.sizes.isNotEmpty);
      fixture.native.geometry(const Size(2160, 3840));
      await until(() => fixture.output.sizes.length == 2);
      expect(fixture.output.sizes, [
        const Size(1920, 1080),
        const Size(608, 1080),
      ]);
      fixture.backend.setRenderViewport(
        const Size(960, 540),
        1,
        BoxFit.contain,
        1,
      );
      await fixture.backend.close();
      await tick();
      expect(fixture.output.sizes, hasLength(2));
    },
  );

  test(
    'Desktop resizing uses the actual viewport even when orientation reuse is requested',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final fixture = create();
      fixture.backend.setRenderViewport(
        const Size(400, 900),
        1,
        BoxFit.contain,
        1,
        stableOrientation: true,
      );
      await until(() => fixture.output.sizes.isNotEmpty);
      expect(fixture.output.sizes, [const Size(400, 226)]);
    },
  );
}
