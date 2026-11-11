import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/ui/app_switch.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/link_opening.dart';
import 'package:asterlink/ui/link_opening_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/link-opening');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets(
    'changing a cloud and returning from system settings reads persisted state',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var enabled = true, reads = 0, opened = 0;
      List<Map<String, Object>> rows() => [
        {
          'id': 'quark',
          'label': '夸克网盘',
          'sample': 'pan.quark.cn/s/…',
          'enabled': enabled,
        },
      ];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'linkOpeningStatus') {
          reads++;
          return rows();
        }
        if (call.method == 'linkOpeningSet') {
          expect(call.arguments['id'], 'quark');
          enabled = call.arguments['enabled'] == true;
          return rows();
        }
        if (call.method == 'linkOpeningSettings') {
          opened++;
          return null;
        }
        fail('Unexpected ${call.method}');
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: const LinkOpeningPage(
            platform: LinkOpeningPlatform(channel: channel, android: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('link-opening-quark'));
      expect(tester.widget<AppSwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(enabled, isFalse);
      expect(tester.widget<AppSwitchListTile>(toggle).value, isFalse);
      await tester.tap(find.text('系统默认打开设置'));
      await tester.pumpAndSettle();
      expect(opened, 1);
      enabled = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(tester.widget<AppSwitchListTile>(toggle).value, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a rejected settings write keeps the actual toggle state', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'linkOpeningSet') {
        throw PlatformException(code: 'unavailable', message: '系统设置更新失败');
      }
      return [
        {
          'id': 'quark',
          'label': '夸克网盘',
          'sample': 'pan.quark.cn/s/…',
          'enabled': true,
        },
      ];
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: LinkOpeningPage(
          platform: LinkOpeningPlatform(channel: channel, android: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('link-opening-quark'));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<AppSwitchListTile>(toggle).value, isTrue);
    expect(find.textContaining('无法更改链接入口'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('link settings scroll at phone width with $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => [
          for (var index = 0; index < 18; index++)
            {
              'id': '$index',
              'label': '网盘 $index',
              'sample': 'pan.example.test/s/分享链接',
              'enabled': true,
            },
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(brightness),
          home: const LinkOpeningPage(
            platform: LinkOpeningPlatform(channel: channel, android: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('link-opening-17')),
        450,
      );
      expect(find.text('网盘 17'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Windows explains installed protocol support without Android calls',
    (tester) async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => fail('Android should not be called'),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: LinkOpeningPage(
            platform: LinkOpeningPlatform(
              channel: channel,
              android: false,
              operatingSystem: 'windows',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('网页一键打开'), findsOneWidget);
      expect(find.textContaining('Windows 安装版'), findsOneWidget);
      expect(find.byType(AppSwitchListTile), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  for (final system in ['ios', 'macos']) {
    testWidgets(
      '$system explains its own launch entry without Windows installation instructions',
      (tester) async {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => fail('Android method called'),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: LinkOpeningPage(
              platform: LinkOpeningPlatform(
                channel: channel,
                android: false,
                operatingSystem: system,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('网页一键打开'), findsOneWidget);
        expect(find.textContaining('Windows 安装版'), findsNothing);
        expect(find.byType(AppSwitchListTile), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
