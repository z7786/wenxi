import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/quark_transfer_device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('native phone information is read again before each transfer', () async {
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'clientEnvironment');
      reads++;
      return {
        'deviceType': 'phone',
        'model': 'Pixel 9',
        'osVersion': '16',
        'screenWidth': reads == 1 ? 412 : 915,
        'screenHeight': reads == 1 ? 915 : 412,
        'locale': reads == 1 ? 'zh-CN' : 'en-US',
        'networkTransport': reads == 1 ? 'wifi' : 'cellular',
        'cellularSubtype': reads == 1 ? 0 : 20,
        'networkType': reads == 1 ? 'wifi' : 'cmnet',
        'networkSubtype': 20,
      };
    });
    final device = QuarkTransferDevice(platform: 'android');
    final first = (await device.read())!;
    final next = (await device.read())!;
    expect(first.parameters, {
      'device_model': 'Pixel 9',
      'mi': 'Pixel 9',
      'ss': '412x915',
      'la': 'zh',
      'nt': '5',
      'nw': '0',
    });
    expect(next.parameters['ss'], '915x412');
    expect(first.locale, 'zh-CN');
    expect(next.parameters['la'], 'en');
    expect(next.parameters['nt'], '7');
    expect(next.parameters['nw'], '5G');
    expect(reads, 2);
    expect(first.userAgent, contains('Android 16; Pixel%209'));
    expect(first.userAgent, contains('Quark/7.4.5.680'));
  });

  test(
    'radio values use the current transport, never an account SDK field',
    () async {
      for (final entry in <(String, int, Map<String, String>)>[
        ('wifi', 20, {'nt': '5', 'nw': '0'}),
        ('cellular', 13, {'nt': '6', 'nw': '4G'}),
        ('cellular', 20, {'nt': '7', 'nw': '5G'}),
        ('cellular', 0, {}),
        ('cellular', 3, {}),
        ('cellular', 18, {}),
        ('vpn', 13, {}),
        ('ethernet', 0, {}),
        ('', 13, {}),
      ]) {
        final info = (await QuarkTransferDevice(
          platform: 'android',
          readEnvironment: () async => {
            'deviceType': 'phone',
            'model': 'SM-S9380',
            'osVersion': '15',
            'screenWidth': 412,
            'screenHeight': 915,
            'networkTransport': entry.$1,
            'cellularSubtype': entry.$2,
            'networkType': 'cmnet',
            'networkSubtype': 13,
            'net_type': '5',
            'net_id': 'account-sdk-network',
          },
        ).read())!;
        expect(
          {
            for (final key in ['nt', 'nw'])
              if (info.parameters.containsKey(key)) key: info.parameters[key]!,
          },
          entry.$3,
          reason: '${entry.$1}/${entry.$2}',
        );
      }
    },
  );

  test(
    'missing optional fields preserve the verified minimal transfer profile',
    () async {
      for (final locale in ['', 'zh-Hans-CN', 'en_US', 'bad\r\nvalue']) {
        final info = (await QuarkTransferDevice(
          platform: 'android',
          readEnvironment: () async => {
            'deviceType': 'phone',
            'model': 'Pixel 9',
            'osVersion': '16',
            'screenWidth': 412,
            'screenHeight': 915,
            'locale': locale,
            'uid': 'account-uid',
            'androidId': 'android-identifier',
            'serial': 'hardware-serial',
            'networkType': 'wifi',
          },
        ).read())!;
        expect(info.parameters['la'], locale == 'zh-Hans-CN' ? 'zh' : isNull);
        for (final key in [
          'ut',
          'ds',
          'ni',
          'dn',
          'imei',
          'imsi',
          'sn',
          'mac',
          'local_ip',
          'dmn',
          'nt',
          'nw',
        ]) {
          expect(info.parameters, isNot(contains(key)));
        }
        expect(
          info.userAgent,
          contains('Quark/${QuarkTransferDeviceInfo.clientVersion}'),
        );
      }
    },
  );

  test('desktop and iOS do not invoke the Android device bridge', () async {
    var reads = 0;
    for (final platform in ['windows', 'macos', 'linux', 'ios']) {
      final device = QuarkTransferDevice(
        platform: platform,
        readEnvironment: () async {
          reads++;
          return {};
        },
      );
      expect(device.supported, isFalse);
      expect(await device.read(), isNull);
    }
    expect(reads, 0);
  });

  test(
    'non-phone and incomplete native information chooses web fallback',
    () async {
      final valid = <String, dynamic>{
        'deviceType': 'phone',
        'model': 'SM-S9380',
        'osVersion': '15',
        'screenWidth': 412,
        'screenHeight': 915,
      };
      for (final override in <Map<String, dynamic>>[
        {'deviceType': 'television'},
        {'deviceType': 'tablet'},
        {'deviceType': 'watch'},
        {'deviceType': 'car'},
        {'deviceType': ''},
        {'model': ''},
        {'model': 'bad\r\nheader'},
        {'osVersion': ''},
        {'screenWidth': 0},
        {'screenHeight': -1},
        {'screenWidth': 100000},
      ]) {
        expect(
          await QuarkTransferDevice(
            platform: 'android',
            readEnvironment: () async => {...valid, ...override},
          ).read(),
          isNull,
          reason: '$override',
        );
      }
    },
  );

  test('missing and failing platform channels select the web route', () async {
    final device = QuarkTransferDevice(platform: 'android');
    expect(await device.read(), isNull);
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await device.read(), isNull);
  });
}
