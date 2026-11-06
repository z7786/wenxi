import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/platform/playback_device.dart';
import 'package:asterlink/playback/playback_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(nativeChannel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.asterlink.app/playback'),
      null,
    );
  });
  test(
    'iOS transport opens and closes in-process and requests disk space separately',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        calls.add(call.method);
        if (call.method == 'restoreStorage') {
          return {'paths': <String, String>{}, 'home': ''};
        }
        if (call.method == 'freeSpace') return {'bytes': 1024};
        expect(call.method, 'gopeed');
        return null;
      });
      final transport = IOSGopeedTransport();
      await transport.call('open');
      expect(transport.connected, true);
      expect(await transport.call('freeSpace', {'path': '/Documents'}), {
        'bytes': 1024,
      });
      await transport.dispose();
      expect(transport.connected, false);
      expect(calls, ['restoreStorage', 'gopeed', 'freeSpace', 'gopeed']);
    },
  );
  test(
    'iOS player exposes brightness, rotation and external apps while unsupported PiP remains hidden',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('com.asterlink.app/playback'),
        (call) async {
          calls.add(call.method);
          if (call.method == 'begin') return {'pip': false, 'brightness': .4};
          return null;
        },
      );
      final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      expect(device.supportsOrientation, true);
      expect(device.supportsBrightness, true);
      expect(device.supportsExternalPlayer, true);
      expect(device.externalPlayerNeedsDirectLink, true);
      expect(device.systemPip, isNotNull);
      await device.start(video: true);
      expect(device.supportsPip, false);
      expect(device.supportsSystemVolume, false);
      await device.setBrightness(.2);
      await device.finish();
      expect(calls, ['begin', 'brightness', 'end']);
    },
  );
  test(
    'iOS PiP commands and position events are scoped to the active handoff',
    () async {
      const channel = MethodChannel('com.asterlink.app/playback');
      final calls = <MethodCall>[];
      var nativePip = false;
      String session = '', pipId = '';
      messenger.setMockMethodCallHandler(nativeChannel, (_) async => null);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final args = Map<String, Object?>.from(call.arguments as Map);
        session = args['session'] as String;
        if (call.method == 'begin') return {'pip': true};
        if (call.method == 'preparePip') {
          pipId = args['pipId'] as String;
          return true;
        }
        if (call.method == 'enterPip') {
          nativePip = true;
          return true;
        }
        if (call.method == 'isPip') return nativePip;
        if (call.method == 'stopPip') {
          nativePip = false;
          return {
            'pipId': pipId,
            'positionMs': 64000,
            'durationMs': 600000,
            'playing': false,
          };
        }
        return null;
      });
      final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      await device.start(video: true);
      final pip = device.systemPip!;
      await pip.prepare(
        url: 'http://127.0.0.1:12345/local/video',
        title: 'fixture.mp4',
        initialState: const PlayerState(duration: Duration(minutes: 10)),
      );
      Future<void> emit(String token, String handoff, int position) async {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('pipState', {
              'session': token,
              'pipId': handoff,
              'positionMs': position,
              'durationMs': 600000,
              'playing': true,
            }),
          ),
          (_) {},
        );
      }

      await emit('previous-player', pipId, 9000);
      await emit(session, 'previous-handoff', 9000);
      expect(pip.state.position, Duration.zero);
      await emit(session, pipId, 42000);
      expect(pip.state.position, const Duration(seconds: 42));
      expect(await device.enterPip(), true);
      expect(await device.queryPip(), true);
      await device.exitPip();
      expect(calls.last.method, 'exitPip');
      expect((await pip.stop()).position, const Duration(seconds: 64));
      expect(device.inPip, false);
      await emit(session, pipId, 99000);
      expect(pip.state.position, const Duration(seconds: 64));
      await device.finish();
    },
  );
  test(
    'iOS sends restored storage roots before opening the download core',
    () async {
      const before =
          '/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111';
      const after =
          '/var/mobile/Containers/Data/Application/22222222-2222-2222-2222-222222222222';
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        calls.add(call);
        if (call.method == 'restoreStorage') {
          return {
            'home': after,
            'paths': {before: after},
          };
        }
        return null;
      });
      final transport = IOSGopeedTransport();
      await transport.call('open', {
        'storageDir': '$after/Library/Application Support/AsterLink',
        'cacheDir': '$after/Library/Caches/downloads',
      });
      final args = jsonDecode(calls.last.arguments['args'] as String) as Map;
      expect(args['storagePaths'], {before: after});
      expect(args['storageHome'], after);
      await transport.dispose();
    },
  );
  test(
    'iOS volume follows system changes and rejects a previous player session',
    () async {
      const channel = MethodChannel('com.asterlink.app/playback');
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'pip': false,
          'brightness': .5,
          'systemVolumeSupported': true,
          'systemVolume': call.method == 'volume' ? 80.0 : 30.0,
        };
      });
      final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      await device.start(video: true);
      expect(device.supportsSystemVolume, isTrue);
      expect(device.systemVolume, 30);
      expect(await device.setSystemVolume(80), 80);
      final session = calls.first.arguments['session'];
      Future<void> emit(String token, double value) async {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('volume', {
              'session': token,
              'systemVolumeSupported': true,
              'systemVolume': value,
            }),
          ),
          (_) {},
        );
      }

      await emit('previous-player', 0);
      expect(device.systemVolume, 80);
      await emit(session as String, 45);
      expect(device.systemVolume, 45);
      await device.finish();
      final count = calls.length;
      expect(await device.setSystemVolume(10), 45);
      expect(calls.length, count);
    },
  );
}
