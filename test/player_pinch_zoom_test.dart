import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_screen_display.dart';
import 'package:asterlink/ui/player_page.dart';
import 'player_support.dart';

const _surface = Key('player-gesture-surface');
const _transform = Key('player-video-transform');

Future<({PlaybackFixture fixture, FakePlaybackDevice device})> _render(
  WidgetTester tester, {
  Size size = const Size(393, 864),
  PlaybackFixture? suppliedFixture,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final fixture = suppliedFixture ?? PlaybackFixture();
  fixture.configureBackend = (backend) => backend.videoSurface = true;
  final device = FakePlaybackDevice();
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('asterlink-player-pinch-'),
  ))!;
  addTearDown(() => removePlayerFixture(directory));
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: PlayerPage(
        fixture.controller,
        subtitleDirectory: directory,
        device: device,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(fixture.controller.ready, isTrue);
  return (fixture: fixture, device: device);
}

Future<({TestGesture first, TestGesture second, Offset center})> _startPinch(
  WidgetTester tester, {
  double span = 100,
}) async {
  final center = tester.getCenter(find.byKey(_surface));
  final first = await tester.startGesture(
    center - Offset(span / 2, 0),
    pointer: 1,
  );
  final second = await tester.startGesture(
    center + Offset(span / 2, 0),
    pointer: 2,
  );
  return (first: first, second: second, center: center);
}

Future<void> _zoom(WidgetTester tester, double factor) async {
  final pinch = await _startPinch(tester);
  await pinch.first.moveTo(pinch.center - Offset(50 * factor, 0));
  await pinch.second.moveTo(pinch.center + Offset(50 * factor, 0));
  await pinch.first.up();
  await pinch.second.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [
    const Size(393, 864),
    const Size(844, 390),
    const Size(800, 600),
  ]) {
    testWidgets('Pinch previews, preserves overlays and saves at $size', (
      tester,
    ) async {
      final page = await _render(tester, size: size);
      final fixture = page.fixture, controller = fixture.controller;
      await controller.updatePreferences(
        controller.preferences.copyWith(
          videoScale: 1.25,
          videoOffsetX: .2,
          screenDisplay: const PlaybackScreenDisplay(enabled: true),
        ),
      );
      fixture.current.emit(fixture.current.state.copyWith(subtitle: ['测试字幕']));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(find.byKey(_surface)));
      await tester.pumpAndSettle();
      final video = tester.element(
        find.byKey(const Key('player-video-surface')),
      );
      final caption = tester.getRect(find.byKey(const Key('player-captions')));
      final corners = <String, Rect>{
        for (final corner in [
          'top-left',
          'top-right',
          'bottom-left',
          'bottom-right',
        ])
          corner: tester.getRect(
            find.byKey(Key('player-screen-region-$corner')),
          ),
      };
      final position = controller.state.position;
      final volume = controller.state.volume;
      final pinch = await _startPinch(tester);
      await pinch.first.moveTo(pinch.center - const Offset(100, 0));
      await pinch.second.moveTo(pinch.center + const Offset(100, 0));
      await tester.pump();
      expect(controller.preferences.videoScale, 2.5);
      expect(fixture.history.preferences.videoScale, 1.25);
      final matrix = tester.widget<Transform>(find.byKey(_transform)).transform;
      expect(matrix.storage[0], 2.5);
      expect(matrix.storage[5], 2.5);
      expect(fixture.current.lastRenderScale, 1.25);
      expect(
        tester.element(find.byKey(const Key('player-video-surface'))),
        same(video),
      );
      expect(tester.getRect(find.byKey(const Key('player-captions'))), caption);
      for (final corner in corners.entries) {
        expect(
          tester.getRect(find.byKey(Key('player-screen-region-${corner.key}'))),
          corner.value,
        );
      }
      expect(find.text('缩放  250%'), findsOneWidget);
      expect(controller.state.position, position);
      expect(controller.state.volume, volume);
      expect(page.device.brightness, .5);
      expect(fixture.current.seeks, isEmpty);
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(fixture.history.preferences.videoScale, 2.5);
      expect(controller.preferences.videoOffsetX, .2);
      expect(fixture.current.lastRenderScale, 2.5);
      expect(fixture.preparations, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Pinch is bounded and starts from the current zoom', (
    tester,
  ) async {
    final page = await _render(tester);
    final controller = page.fixture.controller;
    await _zoom(tester, .2);
    expect(controller.preferences.videoScale, .5);
    expect(page.fixture.history.preferences.videoScale, .5);
    final pinch = await _startPinch(tester, span: 40);
    await pinch.first.moveTo(pinch.center - const Offset(150, 0));
    await pinch.second.moveTo(pinch.center + const Offset(150, 0));
    await tester.pump();
    expect(controller.preferences.videoScale, 3);
    await pinch.first.up();
    await pinch.second.up();
    await tester.pumpAndSettle();
    expect(page.fixture.history.preferences.videoScale, 3);
    await _zoom(tester, .5);
    expect(controller.preferences.videoScale, 1.5);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A second finger cancels seeking and suppresses the remaining finger',
    (tester) async {
      final page = await _render(tester);
      final fixture = page.fixture, controller = fixture.controller;
      final position = controller.state.position;
      final first = await tester.startGesture(
        const Offset(120, 360),
        pointer: 1,
      );
      await first.moveBy(const Offset(60, 0));
      await first.moveBy(const Offset(60, 0));
      await tester.pump();
      final second = await tester.startGesture(
        const Offset(320, 360),
        pointer: 2,
      );
      await second.moveBy(const Offset(40, 0));
      await first.up();
      await second.moveBy(const Offset(-70, -160));
      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.state.position, position);
      expect(controller.state.volume, 100);
      expect(page.device.brightness, .5);
      expect(controller.boosting, isFalse);
      expect(fixture.current.seeks, isEmpty);
      await second.up();
      await tester.pumpAndSettle();
      expect(fixture.current.seeks, isEmpty);
      await tester.dragFrom(const Offset(160, 300), const Offset(110, 0));
      await tester.pumpAndSettle();
      expect(controller.state.position, greaterThan(position));
      await tester.dragFrom(const Offset(90, 400), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(page.device.brightness, greaterThan(.5));
      await tester.dragFrom(const Offset(310, 350), const Offset(0, 160));
      await tester.pumpAndSettle();
      expect(controller.state.volume, lessThan(100));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Vertical two-finger movement never adjusts brightness or volume',
    (tester) async {
      final page = await _render(tester);
      final controller = page.fixture.controller;
      final first = await tester.startGesture(
        const Offset(110, 360),
        pointer: 1,
      );
      final second = await tester.startGesture(
        const Offset(285, 480),
        pointer: 2,
      );
      await first.moveBy(const Offset(0, -120));
      await second.moveBy(const Offset(0, 120));
      await tester.pump(const Duration(milliseconds: 700));
      expect(controller.preferences.videoScale, greaterThan(1));
      expect(page.device.brightness, .5);
      expect(controller.state.volume, 100);
      expect(controller.boosting, isFalse);
      await second.up();
      await first.moveBy(const Offset(0, -120));
      await first.up();
      await tester.pumpAndSettle();
      expect(page.device.brightness, .5);
      expect(controller.state.volume, 100);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Two-finger taps preserve playback and controls, then single taps work',
    (tester) async {
      final page = await _render(tester);
      final pinch = await _startPinch(tester);
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(page.fixture.controller.state.playing, isTrue);
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsOneWidget,
      );
      expect(page.fixture.history.preferences.videoScale, 1);
      await tester.tapAt(pinch.center);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsNothing,
      );
      await tester.tapAt(pinch.center);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(pinch.center);
      await tester.pumpAndSettle();
      expect(page.fixture.controller.state.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Locked playback ignores pinch until unlocked', (tester) async {
    final page = await _render(tester);
    await tester.tap(find.byKey(const Key('player-lock')));
    await tester.pumpAndSettle();
    await _zoom(tester, 2);
    expect(page.fixture.controller.preferences.videoScale, 1);
    expect(page.fixture.history.preferences.videoScale, 1);
    expect(page.device.brightness, .5);
    expect(page.fixture.current.seeks, isEmpty);
    await tester.tap(find.byKey(const Key('player-unlock')));
    await tester.pumpAndSettle();
    await _zoom(tester, 2);
    expect(page.fixture.controller.preferences.videoScale, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A single tap immediately after a two-finger tap never pauses playback',
    (tester) async {
      final page = await _render(tester);
      final pinch = await _startPinch(tester);
      await tester.pump(const Duration(milliseconds: 80));
      await pinch.first.up();
      await pinch.second.up();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(pinch.center);
      await tester.pumpAndSettle();
      expect(page.fixture.controller.state.playing, isTrue);
      expect(
        find.byKey(const Key('player-play-pause')).hitTestable(),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Backgrounding during a pinch saves zoom and permits a new gesture',
    (tester) async {
      final page = await _render(tester);
      final pinch = await _startPinch(tester);
      await pinch.first.moveBy(const Offset(-50, 0));
      await pinch.second.moveBy(const Offset(50, 0));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(page.fixture.history.preferences.videoScale, 2);
      await pinch.first.cancel();
      await pinch.second.cancel();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await _zoom(tester, .5);
      expect(page.fixture.controller.preferences.videoScale, 1);
      expect(page.fixture.current.seeks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Closing during a pinch preserves its latest zoom', (
    tester,
  ) async {
    final page = await _render(tester);
    final pinch = await _startPinch(tester);
    await pinch.first.moveBy(const Offset(-50, 0));
    await pinch.second.moveBy(const Offset(50, 0));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await page.fixture.controller.close();
    expect(page.fixture.history.preferences.videoScale, 2);
    await pinch.first.cancel();
    await pinch.second.cancel();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A third finger suspends zoom and removal rebases without a jump',
    (tester) async {
      final page = await _render(tester);
      final pinch = await _startPinch(tester);
      await pinch.first.moveBy(const Offset(-25, 0));
      await pinch.second.moveBy(const Offset(25, 0));
      await tester.pump();
      expect(page.fixture.controller.preferences.videoScale, 1.5);
      final third = await tester.startGesture(
        pinch.center + const Offset(0, 80),
        pointer: 3,
      );
      await pinch.first.moveBy(const Offset(-25, 0));
      await pinch.second.moveBy(const Offset(25, 0));
      await third.moveBy(const Offset(0, 50));
      await tester.pump();
      expect(page.fixture.controller.preferences.videoScale, 1.5);
      await third.up();
      await tester.pump();
      expect(page.fixture.controller.preferences.videoScale, 1.5);
      await pinch.first.moveBy(const Offset(-40, 0));
      await pinch.second.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(
        page.fixture.controller.preferences.videoScale,
        closeTo(2.1, .001),
      );
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(page.fixture.history.preferences.videoScale, closeTo(2.1, .001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('A second finger ends active long-press boost before zooming', (
    tester,
  ) async {
    final page = await _render(tester);
    final center = tester.getCenter(find.byKey(_surface));
    final first = await tester.startGesture(
      center - const Offset(50, 0),
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(page.fixture.controller.boosting, isTrue);
    final second = await tester.startGesture(
      center + const Offset(50, 0),
      pointer: 2,
    );
    await first.moveBy(const Offset(-50, 0));
    await second.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(page.fixture.controller.boosting, isFalse);
    expect(page.fixture.controller.state.rate, 1);
    expect(page.fixture.controller.preferences.videoScale, 2);
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(page.fixture.history.preferences.rate, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Saved pinch zoom follows folder preferences', (tester) async {
    final fixture = PlaybackFixture(
      suppliedEntries: const [
        PlaybackEntry(
          id: 'a1',
          key: 'a1',
          name: '第1集.mp4',
          video: true,
          settingsFolder: 'show-a',
        ),
        PlaybackEntry(
          id: 'a2',
          key: 'a2',
          name: '第2集.mp4',
          video: true,
          settingsFolder: 'show-a',
        ),
        PlaybackEntry(
          id: 'b1',
          key: 'b1',
          name: '其他剧.mp4',
          video: true,
          settingsFolder: 'show-b',
        ),
      ],
    );
    await _render(tester, suppliedFixture: fixture);
    await _zoom(tester, 2);
    expect(fixture.history.preferencesFor('show-a').videoScale, 2);
    expect(fixture.history.preferences.videoScale, 1);
    await fixture.controller.next();
    await tester.pumpAndSettle();
    expect(fixture.controller.preferences.videoScale, 2);
    await fixture.controller.next();
    await tester.pumpAndSettle();
    expect(fixture.controller.preferences.videoScale, 1);
    await fixture.controller.load(0);
    await tester.pumpAndSettle();
    expect(fixture.controller.preferences.videoScale, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Switching videos cancels the old pinch without changing the new folder',
    (tester) async {
      final fixture = PlaybackFixture(
        suppliedEntries: const [
          PlaybackEntry(
            id: 'a',
            key: 'a',
            name: 'A.mp4',
            video: true,
            settingsFolder: 'show-a',
          ),
          PlaybackEntry(
            id: 'b',
            key: 'b',
            name: 'B.mp4',
            video: true,
            settingsFolder: 'show-b',
          ),
        ],
        data: {
          'playbackFolders': {
            'show-b': {
              'preferences': {'videoScale': .75},
            },
          },
        },
      );
      await _render(tester, suppliedFixture: fixture);
      final pinch = await _startPinch(tester);
      await pinch.first.moveBy(const Offset(-50, 0));
      await pinch.second.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(fixture.controller.preferences.videoScale, 2);
      await fixture.controller.next();
      await tester.pumpAndSettle();
      await pinch.first.moveBy(const Offset(0, -90));
      await pinch.second.moveBy(const Offset(0, 90));
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(fixture.controller.preferences.videoScale, .75);
      expect(fixture.history.preferencesFor('show-a').videoScale, 1);
      expect(fixture.history.preferencesFor('show-b').videoScale, .75);
      expect(fixture.current.seeks, isEmpty);
      await _zoom(tester, 2);
      expect(fixture.history.preferencesFor('show-b').videoScale, 1.5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Pointer cancellation saves zoom and releases gesture suppression',
    (tester) async {
      final page = await _render(tester);
      final pinch = await _startPinch(tester);
      await pinch.first.moveBy(const Offset(-50, 0));
      await pinch.second.moveBy(const Offset(50, 0));
      await pinch.first.cancel();
      await pinch.second.moveBy(const Offset(0, -120));
      await pinch.second.cancel();
      await tester.pumpAndSettle();
      expect(page.fixture.history.preferences.videoScale, 2);
      expect(page.device.brightness, .5);
      expect(page.fixture.current.seeks, isEmpty);
      await _zoom(tester, .5);
      expect(page.fixture.controller.preferences.videoScale, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Audio playback ignores two-finger scaling', (tester) async {
    final fixture = PlaybackFixture(
      suppliedEntries: const [
        PlaybackEntry(id: 'audio', key: 'audio', name: '音乐.mp3', video: false),
      ],
    );
    final page = await _render(tester, suppliedFixture: fixture);
    await _zoom(tester, 2);
    expect(fixture.controller.preferences.videoScale, 1);
    expect(fixture.controller.state.volume, 100);
    expect(page.device.brightness, .5);
    expect(fixture.current.seeks, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
