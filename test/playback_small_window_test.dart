import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/ui/desktop_pip_surface.dart';
import 'package:asterlink/playback/playback_viewport_updater.dart';

class _Progress extends ValueNotifier<DesktopPipProgress> {
  _Progress(super.value);
  bool get observed => hasListeners;
}

void main() {
  testWidgets(
    'Progress only rebuilds visible controls and leaves video mounted',
    (tester) async {
      final progress = _Progress((
        playing: true,
        position: Duration.zero,
        duration: const Duration(minutes: 1),
      ));
      addTearDown(progress.dispose);
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopPipSurface(
              video: Builder(
                builder: (_) {
                  builds++;
                  return const SizedBox.expand();
                },
              ),
              playing: false,
              position: Duration.zero,
              duration: Duration.zero,
              progress: progress,
              onToggle: () {},
              onSeek: (_) {},
              onDrag: () {},
              onResize: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      expect(progress.observed, isTrue);
      progress.value = (
        playing: false,
        position: const Duration(seconds: 12),
        duration: const Duration(minutes: 1),
      );
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byKey(const Key('player-pip-seek'))).value,
        12000,
      );
      expect(builds, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(progress.observed, isFalse);
      progress.value = (
        playing: true,
        position: const Duration(seconds: 20),
        duration: const Duration(minutes: 1),
      );
      await tester.pump();
      expect(builds, 1);
      await tester.tap(find.byKey(const Key('player-pip-drag')));
      await tester.pump();
      expect(
        tester.widget<Slider>(find.byKey(const Key('player-pip-seek'))).value,
        20000,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Rapid window resizes serialize, retain latest target and close safely',
    (tester) async {
      final calls = <Size>[];
      final barrier = Completer<void>();
      final updater = PlaybackViewportUpdater((size) async {
        calls.add(size);
        if (calls.length == 1) await barrier.future;
      }, onError: (e, s) => fail('$e'));
      updater.request(const Size(640, 360));
      await tester.pump(const Duration(milliseconds: 220));
      updater.request(const Size(800, 450));
      await tester.pump(const Duration(milliseconds: 220));
      updater.request(const Size(960, 540));
      barrier.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 220));
      expect(calls, [const Size(640, 360), const Size(960, 540)]);
      updater.request(const Size(1920, 1080));
      await updater.close();
      await tester.pump(const Duration(seconds: 1));
      expect(calls, hasLength(2));
    },
  );
}
