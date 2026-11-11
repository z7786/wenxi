import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback_screen_display.dart';
import 'package:asterlink/playback/playback_screen_info.dart';
import 'package:asterlink/ui/player_screen_display.dart';
import 'player_support.dart';

void main() {
  testWidgets(
    'Clock and progress update independently and suspend in the background',
    (tester) async {
      final fixture = PlaybackFixture(
        data: {
          'playbackPreferences': {
            'screenDisplay': {
              'enabled': true,
              'items': ['time', 'network', 'progress'],
            },
          },
        },
      );
      await fixture.controller.start();
      final backend = fixture.current;
      backend.screenInfo = const PlaybackScreenInfo(
        transport: 'direct',
        bytesPerSecond: 2048,
      );
      var now = DateTime(2026, 11, 11, 14, 25, 59);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 844,
            height: 390,
            child: PlayerScreenDisplay(
              controller: fixture.controller,
              now: () => now,
            ),
          ),
        ),
      );
      expect(find.text('时间 14:25:59'), findsOneWidget);
      expect(backend.screenMonitoring, isTrue);
      now = DateTime(2026, 11, 11, 14, 26);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('时间 14:26:00'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(backend.screenMonitoring, isFalse);
      now = DateTime(2026, 11, 11, 14, 30);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('时间 14:26:00'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('时间 14:30:00'), findsOneWidget);
      expect(backend.screenMonitoring, isTrue);
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(
          screenDisplay: fixture.controller.preferences.screenDisplay.withItem(
            PlaybackScreenItem.network,
            false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(backend.screenMonitoring, isFalse);
      expect(find.textContaining('网速'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.controller.close();
      fixture.store.dispose();
    },
  );
}
