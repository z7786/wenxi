import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/platform/playback_device.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = binding.defaultBinaryMessenger;
  const channel = MethodChannel('com.asterlink.app/playback');
  final platformCalls = <MethodCall>[];
  final playbackCalls = <MethodCall>[];
  Future<void>? endBarrier;
  setUp(() {
    platformCalls.clear();
    playbackCalls.clear();
    endBarrier = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      playbackCalls.add(call);
      if (call.method == 'begin') return {'pip': true};
      if (call.method == 'end') await endBarrier;
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(channel, null);
  });
  List<Object?> getOverlays() => List<Object?>.from(
    platformCalls
            .lastWhere(
              (call) =>
                  call.method == 'SystemChrome.setEnabledSystemUIOverlays',
            )
            .arguments
        as List,
  );
  test(
    'iPad landscape hides system bars even with player controls visible',
    () async {
      final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      addTearDown(device.finish);
      await device.start(video: true);
      await device.update(
        playing: false,
        orientation: PlaybackOrientation.portrait,
      );
      platformCalls.clear();
      await device.update(playing: true, width: 1920, height: 1080);
      expect(getOverlays(), isEmpty);
      final directions = platformCalls.where(
        (call) => call.method == 'SystemChrome.setPreferredOrientations',
      );
      expect(directions.last.arguments, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      final count = platformCalls.length;
      await device.update(playing: false, width: 1920, height: 1080);
      await device.update(playing: true, width: 1920, height: 1080);
      expect(platformCalls.length, count);
      device.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(getOverlays(), isEmpty);
      await device.finish();
      expect(platformCalls.last.method, 'SystemChrome.setEnabledSystemUIMode');
      expect(platformCalls.last.arguments, 'SystemUiMode.edgeToEdge');
    },
  );
  test(
    'portrait controls and audio restore bars while hidden controls and lock hide them',
    () async {
      final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      addTearDown(device.finish);
      await device.start(video: true);
      await device.update(
        playing: true,
        orientation: PlaybackOrientation.portrait,
        controlsVisible: false,
      );
      expect(getOverlays(), isEmpty);
      await device.update(
        playing: false,
        orientation: PlaybackOrientation.portrait,
      );
      expect(getOverlays(), ['SystemUiOverlay.top', 'SystemUiOverlay.bottom']);
      await device.update(
        playing: false,
        orientation: PlaybackOrientation.portrait,
        locked: true,
      );
      expect(getOverlays(), isEmpty);
      await device.fullscreen(true);
      await device.update(
        playing: false,
        orientation: PlaybackOrientation.portrait,
      );
      expect(getOverlays(), isEmpty);
      await device.fullscreen(false);
      expect(getOverlays(), ['SystemUiOverlay.top', 'SystemUiOverlay.bottom']);
      await device.finish();
      final audio = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      addTearDown(audio.finish);
      await audio.start(video: false);
      platformCalls.clear();
      await audio.update(
        playing: true,
        width: 1920,
        height: 1080,
        controlsVisible: false,
      );
      expect(
        platformCalls.where(
          (call) => call.method == 'SystemChrome.setEnabledSystemUIOverlays',
        ),
        isEmpty,
      );
      expect(playbackCalls.last.arguments['orientation'], 'system');
    },
  );
  test(
    'a delayed old close cannot show bars or reset the new player orientation',
    () async {
      final old = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      final current = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      addTearDown(old.finish);
      addTearDown(current.finish);
      await old.start(video: true);
      await old.update(playing: true, width: 1920, height: 1080);
      final barrier = Completer<void>();
      endBarrier = barrier.future;
      final closing = old.finish();
      await current.start(video: true);
      await current.update(playing: true, width: 1920, height: 1080);
      platformCalls.clear();
      old.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await old.update(
        playing: false,
        orientation: PlaybackOrientation.portrait,
      );
      barrier.complete();
      await closing;
      expect(platformCalls, isEmpty);
      endBarrier = null;
      current.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(getOverlays(), isEmpty);
    },
  );
  testWidgets(
    'iPad window rotation updates bars when automatic rotation is disabled',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(768, 1024);
      addTearDown(tester.view.reset);
      final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      addTearDown(device.finish);
      await device.start(video: true);
      await device.update(playing: true, autoRotate: false);
      expect(getOverlays(), ['SystemUiOverlay.top', 'SystemUiOverlay.bottom']);
      tester.view.physicalSize = const Size(1024, 768);
      await tester.pump();
      expect(getOverlays(), isEmpty);
      tester.view.physicalSize = const Size(768, 1024);
      await tester.pump();
      expect(getOverlays(), ['SystemUiOverlay.top', 'SystemUiOverlay.bottom']);
    },
  );
}
