import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/playback/playback_ui_diagnostics.dart';

void main() {
  testWidgets(
    'UI diagnostics respect refresh budget, pause, logging and cleanup',
    (tester) async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      var elapsed = Duration.zero, active = true;
      final recorder = PlaybackUiDiagnostics(
        eligible: () => active,
        refreshRate: () => 120,
        context: () => {'playbackSource': 'fixture'},
        elapsed: () => elapsed,
      )..start();
      void frame(int build, int raster) =>
          SchedulerBinding.instance.platformDispatcher.onReportTimings?.call([
            FrameTiming(
              vsyncStart: 0,
              buildStart: 0,
              buildFinish: build,
              rasterStart: build,
              rasterFinish: build + raster,
              rasterFinishWallTime: build + raster,
            ),
          ]);
      frame(5000, 6000);
      frame(9000, 4000);
      frame(2000, 10000);
      elapsed = const Duration(seconds: 30);
      await tester.pump(const Duration(seconds: 1));
      final fields =
          log
                  .entries()
                  .singleWhere((e) => e.event == 'player.ui_sample')
                  .data['fields']
              as Map;
      expect(fields['uiFrames'], 3);
      expect(fields['uiOverBudgetFrames'], 2);
      expect(fields['uiOverBudgetRatio'], closeTo(2 / 3, .001));
      expect(fields['eventLoopMaxDelayMs'], 29000);
      expect(fields['uiTimingMode'], 'debug');
      active = false;
      frame(50000, 50000);
      elapsed = const Duration(seconds: 60);
      await tester.pump(const Duration(seconds: 1));
      expect(
        log.entries().where((e) => e.event == 'player.ui_sample'),
        hasLength(1),
      );
      active = true;
      log.setEnabled(false);
      frame(50000, 50000);
      elapsed = const Duration(seconds: 90);
      await tester.pump(const Duration(seconds: 1));
      expect(
        log.entries().where((e) => e.event == 'player.ui_sample'),
        hasLength(1),
      );
      recorder.dispose();
      frame(50000, 50000);
      DiagnosticLog.active = null;
      log.close();
    },
  );
}
