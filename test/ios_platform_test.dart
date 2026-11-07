import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/platform/playback_device.dart';

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
    'iOS player exposes brightness, rotation and external apps without PiP',
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
      expect(device.systemPip, isNull);
      await device.start(video: true);
      expect(device.supportsPip, false);
      expect(device.supportsSystemVolume, false);
      await device.setBrightness(.2);
      await device.finish();
      expect(calls, ['begin', 'brightness', 'end']);
    },
  );
  test(
    'iOS rejects native PiP capability and events without making PiP calls',
    () async {
      const channel = MethodChannel('com.asterlink.app/playback');
      final calls = <MethodCall>[];
      String session = '';
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        final args = Map<String, Object?>.from(call.arguments as Map);
        session = args['session'] as String;
        if (call.method == 'begin') return {'pip': true};
        if (call.method == 'enterPip' || call.method == 'isPip') return true;
        return null;
      });
      final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
      addTearDown(device.finish);
      await device.start(video: true);
      expect(device.supportsPip, isFalse);
      expect(device.supportsIndependentPlayerWindows, isFalse);
      expect(device.systemPip, isNull);
      expect(await device.enterPip(), isFalse);
      expect(await device.queryPip(), isFalse);
      await device.exitPip();
      for (final method in ['pip', 'pipState', 'pipDiagnostic']) {
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall(method, {
              'session': session,
              'pipId': 'previous-handoff',
              'active': true,
              'positionMs': 42000,
              'playing': true,
            }),
          ),
          (_) {},
        );
      }

      expect(device.inPip, isFalse);
      expect(device.supportsPip, isFalse);
      expect(await device.queryPip(), isFalse);
      expect(calls.map((call) => call.method), ['begin']);
      await device.finish();
      expect(calls.map((call) => call.method), ['begin', 'end']);
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
