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
      expect(calls, ['gopeed', 'freeSpace', 'gopeed']);
    },
  );
  test(
    'iOS player exposes brightness and rotation while unsupported features remain hidden',
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
      expect(device.supportsExternalPlayer, false);
      await device.start(video: true);
      expect(device.supportsPip, false);
      expect(device.supportsSystemVolume, false);
      await device.setBrightness(.2);
      await device.finish();
      expect(calls, ['begin', 'brightness', 'end']);
    },
  );
}
