import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/windows_gpu_preference.dart';
import 'package:asterlink/ui/windows_gpu_preference_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/gpu_preference');
  const preference = WindowsGpuPreference(platform: TargetPlatform.windows);
  final calls = <MethodCall>[];
  var enabled = false, restart = false, failRead = false, failWrite = false;
  Completer<void>? barrier;
  setUp(() {
    calls.clear();
    enabled = false;
    restart = false;
    failRead = false;
    failWrite = false;
    barrier = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'get' && failRead ||
              call.method == 'set' && failWrite) {
            throw PlatformException(code: 'denied');
          }
          if (call.method == 'set') {
            await barrier?.future;
            enabled = (call.arguments as Map)['enabled'] as bool;
            restart = true;
          }
          return {'enabled': enabled, 'restartRequired': restart};
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'Non-Windows platforms never call the native preference channel',
    () async {
      const unsupported = WindowsGpuPreference(
        platform: TargetPlatform.android,
      );
      expect((await unsupported.read()).enabled, false);
      await unsupported.setEnabled(true);
      expect(calls, isEmpty);
    },
  );

  testWidgets(
    'Opening the setting reads only; explicit switching reports restart',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WindowsGpuPreferenceTile(preference: preference),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.method), ['get']);
      expect(find.text('遵循 Windows 显卡设置'), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(calls.last.arguments, {'enabled': true});
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        true,
      );
      expect(find.textContaining('完全退出并重新启动'), findsOneWidget);
    },
  );

  testWidgets(
    'A failed write keeps the read-back value and surfaces an error',
    (tester) async {
      failWrite = true;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WindowsGpuPreferenceTile(preference: preference),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false,
      );
      expect(find.text('显卡设置未能更改，请重试'), findsOneWidget);
      expect(calls.map((c) => c.method), ['get', 'set', 'get']);
    },
  );

  testWidgets('A failed read can be retried without modifying settings', (
    tester,
  ) async {
    failRead = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: WindowsGpuPreferenceTile(preference: preference)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('player-gpu-preference-retry')),
      findsOneWidget,
    );
    failRead = false;
    await tester.tap(find.byKey(const Key('player-gpu-preference-retry')));
    await tester.pumpAndSettle();
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(calls.map((c) => c.method), ['get', 'get']);
  });

  testWidgets(
    'An in-flight write disables the switch and survives widget disposal',
    (tester) async {
      barrier = Completer<void>();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: WindowsGpuPreferenceTile(preference: preference),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      barrier!.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(calls.where((c) => c.method == 'set'), hasLength(1));
    },
  );
}
