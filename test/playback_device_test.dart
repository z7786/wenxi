import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/platform/playback_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/playback');
  const nativeChannel = MethodChannel('com.asterlink.app/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final nativeCalls = <MethodCall>[];
  var systemVolume = 60.0;
  var systemVolumeSupported = true;
  setUp(() {
    calls.clear();
    nativeCalls.clear();
    systemVolume = 60;
    systemVolumeSupported = true;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      nativeCalls.add(call);
      return call.method == 'openExternalPlayer' ? true : null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'begin') {
        return {
          'pip': true,
          'brightness': .6,
          'systemVolumeSupported': systemVolumeSupported,
          'systemVolume': systemVolume,
        };
      }
      if (call.method == 'volume') {
        final requested = (call.arguments['value'] as num).toDouble();
        systemVolume = (requested / 10).round() * 10.0;
        return {
          'systemVolumeSupported': systemVolumeSupported,
          'systemVolume': systemVolume,
        };
      }
      if (call.method == 'enterPip') return true;
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(nativeChannel, null);
  });

  test(
    'Android volume uses native media steps and ignores stale session updates',
    () async {
      final device = NativePlaybackDevice(
        targetPlatform: TargetPlatform.android,
      );
      addTearDown(device.finish);
      await device.start(video: true);
      expect(device.supportsSystemVolume, isTrue);
      expect(device.systemVolume, 60);
      expect(calls.where((call) => call.method == 'volume'), isEmpty);
      final session = calls.first.arguments['session'];
      expect(await device.setSystemVolume(37), 40);
      expect(calls.last.method, 'volume');
      expect(calls.last.arguments['value'], 37);
      expect(calls.last.arguments['session'], session);
      Future<void> emit(String token, double value) =>
          messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(
              MethodCall('volume', {
                'session': token,
                'systemVolumeSupported': true,
                'systemVolume': value,
              }),
            ),
            (_) {},
          );
      await emit('old-player-session', 10);
      expect(device.systemVolume, 40);
      await emit(session as String, 80);
      expect(device.systemVolume, 80);
      expect(await device.setSystemVolume(140), 100);
      expect(calls.last.arguments['value'], 100);
      await device.finish();
      final count = calls.length;
      await device.setSystemVolume(0);
      await emit(session, 0);
      expect(device.systemVolume, 100);
      expect(calls.length, count);
    },
  );

  test(
    'Fixed-volume Android devices keep the existing player-volume path',
    () async {
      systemVolumeSupported = false;
      final device = NativePlaybackDevice(
        targetPlatform: TargetPlatform.android,
      );
      addTearDown(device.finish);
      await device.start(video: true);
      expect(device.supportsSystemVolume, isFalse);
      await device.setSystemVolume(20);
      expect(calls.where((call) => call.method == 'volume'), isEmpty);
    },
  );

  test(
    'Android and Windows expose external playback; Android hands off title and position',
    () async {
      final mobile = NativePlaybackDevice(
        targetPlatform: TargetPlatform.android,
      );
      final desktop = NativePlaybackDevice(
        targetPlatform: TargetPlatform.windows,
      );
      expect(mobile.supportsExternalPlayer, isTrue);
      expect(desktop.supportsExternalPlayer, isTrue);
      expect(
        await mobile.openExternalPlayer(
          url: 'content://fixture/video/1',
          title: 'movie.mkv',
          position: const Duration(seconds: 37),
        ),
        isTrue,
      );
      expect(nativeCalls.last.arguments['url'], 'content://fixture/video/1');
      expect(nativeCalls.last.arguments['title'], 'movie.mkv');
      expect(nativeCalls.last.arguments['positionMs'], 37000);
      await mobile.finish();
      expect(nativeCalls.last.method, 'cancelExternalPlayer');
    },
  );

  test(
    'Playback direction uses displayed dimensions and leaves unknown sizes alone',
    () {
      for (final (width, height, expected)
          in <(int?, int?, PlaybackOrientation?)>[
            (null, null, null),
            (1920, null, null),
            (0, 1080, null),
            (-1, 1080, null),
            (1920, 1080, PlaybackOrientation.landscape),
            (1080, 1920, PlaybackOrientation.portrait),
            (1080, 1080, PlaybackOrientation.system),
          ]) {
        expect(
          playbackOrientation(
            video: true,
            automatic: true,
            width: width,
            height: height,
          ),
          expected,
        );
      }
      expect(
        playbackOrientation(
          video: true,
          automatic: false,
          width: 1920,
          height: 1080,
        ),
        PlaybackOrientation.system,
      );
      expect(
        playbackOrientation(
          video: false,
          automatic: true,
          width: 1920,
          height: 1080,
        ),
        PlaybackOrientation.system,
      );
      expect(PlaybackPreferences.fromJson({}).autoRotate, isTrue);
      expect(
        PlaybackPreferences.fromJson(
          const PlaybackPreferences().copyWith(autoRotate: false).toJson(),
        ).autoRotate,
        isFalse,
      );
    },
  );

  test(
    'Android bridge receives changes in direction, lock and auto-rotate preferences',
    () async {
      final device = NativePlaybackDevice(
        targetPlatform: TargetPlatform.android,
      );
      addTearDown(device.finish);
      await device.start(video: true);
      await device.update(playing: false);
      expect(calls.last.arguments['orientation'], isNull);
      await device.update(playing: true, width: 1920, height: 1080);
      expect(calls.last.arguments['orientation'], 'landscape');
      final count = calls.length;
      await device.update(playing: true, width: 1920, height: 1080);
      expect(calls.length, count);
      await device.update(
        playing: true,
        width: 1920,
        height: 1080,
        controlsVisible: false,
      );
      expect(calls.last.arguments['controlsVisible'], isFalse);
      expect(calls.length, count + 1);
      await device.update(
        playing: true,
        width: 1920,
        height: 1080,
        controlsVisible: false,
      );
      expect(calls.length, count + 1);
      // The decoder has already swapped dimensions for a 90-degree encoded video.
      await device.update(playing: true, width: 1080, height: 1920);
      expect(calls.last.arguments['orientation'], 'portrait');
      expect(calls.last.arguments['controlsVisible'], isTrue);
      await device.update(
        playing: true,
        width: 1080,
        height: 1920,
        locked: true,
      );
      expect(calls.last.arguments['locked'], isTrue);
      await device.update(
        playing: true,
        width: 1080,
        height: 1920,
        autoRotate: false,
      );
      expect(calls.last.arguments['orientation'], 'system');
      expect(calls.last.arguments['locked'], isFalse);
      await device.fullscreen(true);
      expect(calls.last.method, 'fullscreen');
      expect(calls.last.arguments['enabled'], isTrue);
      final session = calls.first.arguments['session'];
      await device.finish();
      expect(calls.last.method, 'end');
      expect(calls.last.arguments['session'], session);
      final finishedCount = calls.length;
      await device.update(playing: true, width: 1920, height: 1080);
      await device.finish();
      expect(calls.length, finishedCount);
    },
  );

  test(
    'Manual Android direction overrides geometry without changing video dimensions',
    () async {
      final device = NativePlaybackDevice(
        targetPlatform: TargetPlatform.android,
      );
      addTearDown(device.finish);
      await device.start(video: true);
      await device.update(
        playing: true,
        width: 1920,
        height: 1080,
        orientation: PlaybackOrientation.portrait,
      );
      expect(calls.last.arguments['orientation'], 'portrait');
      expect(calls.last.arguments['width'], 1920);
      expect(calls.last.arguments['height'], 1080);
      await device.update(
        playing: false,
        width: 1920,
        height: 1080,
        orientation: PlaybackOrientation.portrait,
      );
      expect(calls.last.arguments['orientation'], 'portrait');
      await device.update(
        playing: true,
        width: 1080,
        height: 1920,
        autoRotate: false,
        orientation: PlaybackOrientation.landscape,
      );
      expect(calls.last.arguments['orientation'], 'landscape');
      final count = calls.length;
      await device.update(
        playing: true,
        width: 1080,
        height: 1920,
        autoRotate: false,
        orientation: PlaybackOrientation.landscape,
      );
      expect(calls.length, count);
      await device.update(
        playing: true,
        width: 1080,
        height: 1920,
        autoRotate: false,
      );
      expect(calls.last.arguments['orientation'], 'system');
      await device.update(playing: true, width: 1080, height: 1920);
      expect(calls.last.arguments['orientation'], 'portrait');
    },
  );

  test('Audio playback never requests a video orientation', () async {
    final device = NativePlaybackDevice(targetPlatform: TargetPlatform.android);
    addTearDown(device.finish);
    await device.start(video: false);
    await device.update(playing: true, width: 1920, height: 1080);
    expect(calls.last.arguments['orientation'], 'system');
    await device.update(
      playing: true,
      width: 1920,
      height: 1080,
      orientation: PlaybackOrientation.portrait,
    );
    expect(calls.last.arguments['orientation'], 'system');
  });

  test(
    'Closing an old player cannot remove the new native session handler',
    () async {
      final old = NativePlaybackDevice(targetPlatform: TargetPlatform.android);
      final current = NativePlaybackDevice(
        targetPlatform: TargetPlatform.android,
      );
      addTearDown(old.finish);
      addTearDown(current.finish);
      await old.start(video: true);
      final oldSession = calls.last.arguments['session'];
      await current.start(video: true);
      final session = calls.last.arguments['session'];
      await old.finish();
      Future<void> emit(String token) async {
        await messenger.handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(
            MethodCall('pip', {'session': token, 'active': true}),
          ),
          (_) {},
        );
      }

      await emit(oldSession as String);
      expect(current.inPip, isFalse);
      await emit(session as String);
      expect(current.inPip, isTrue);
      expect(current.supportsPip, isTrue);
      expect(current.brightness, .6);
    },
  );
}
