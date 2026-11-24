import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_screen_display.dart';
import 'package:asterlink/ui/player_page.dart';
import 'player_support.dart';

const _surface = Key('player-gesture-surface');
const _transform = Key('player-video-transform');
const _rotation = Key('player-video-rotation');
const _reset = Key('player-pinch-reset');

RenderBox _videoBox(WidgetTester tester) => tester.renderObject<RenderBox>(
  find
      .descendant(of: find.byKey(_rotation), matching: find.byType(ColoredBox))
      .first,
);

void _expectAnchor(WidgetTester tester, Offset videoPoint, Offset screenPoint) {
  expect(
    (_videoBox(tester).localToGlobal(videoPoint) - screenPoint).distance,
    lessThan(.001),
  );
}

Future<({PlaybackFixture fixture, FakePlaybackDevice device})> _render(
  WidgetTester tester, {
  Size size = const Size(393, 864),
  double textScale = 1,
  PlaybackFixture? suppliedFixture,
  FakePlaybackDevice? suppliedDevice,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final fixture = suppliedFixture ?? PlaybackFixture();
  fixture.configureBackend = (backend) => backend.videoSurface = true;
  final device = suppliedDevice ?? FakePlaybackDevice();
  final directory = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('asterlink-player-pinch-'),
  ))!;
  addTearDown(() => removePlayerFixture(directory));
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
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
  Offset? focal,
  double angle = 0,
}) async {
  final center = focal ?? tester.getCenter(find.byKey(_surface));
  final side = Offset.fromDirection(angle, span / 2);
  final first = await tester.startGesture(center - side, pointer: 1);
  final second = await tester.startGesture(center + side, pointer: 2);
  return (first: first, second: second, center: center);
}

Future<void> _movePair(
  ({TestGesture first, TestGesture second, Offset center}) pinch, {
  required Offset focal,
  double span = 100,
  double degrees = 0,
}) async {
  final side = Offset.fromDirection(degrees * math.pi / 180, span / 2);
  await pinch.first.moveTo(focal - side);
  await pinch.second.moveTo(focal + side);
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
      expect(fixture.current.lastRenderScale, 1);
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
      await _movePair(
        pinch,
        focal: pinch.center + const Offset(12, -8),
        span: 200,
        degrees: 25,
      );
      await tester.pump();
      expect(controller.preferences.videoRotation, closeTo(25, .001));
      expect(tester.getRect(find.byKey(const Key('player-captions'))), caption);
      for (final corner in corners.entries) {
        expect(
          tester.getRect(find.byKey(Key('player-screen-region-${corner.key}'))),
          corner.value,
        );
      }
      await _movePair(pinch, focal: pinch.center, span: 200);
      await tester.pump();
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(fixture.history.preferences.videoScale, 2.5);
      expect(controller.preferences.videoOffsetX, closeTo(.4, .001));
      expect(fixture.current.lastRenderScale, 1);
      expect(fixture.preparations, 1);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [
    const Size(393, 864),
    const Size(844, 390),
    const Size(800, 600),
  ]) {
    testWidgets('Off-centre zoom keeps the selected video point at $size', (
      tester,
    ) async {
      final page = await _render(tester, size: size);
      final bounds = tester.getRect(find.byKey(_surface));
      final focal =
          bounds.topLeft + Offset(bounds.width * .25, bounds.height * .4);
      final selected = _videoBox(tester).globalToLocal(focal);
      final pinch = await _startPinch(tester, focal: focal, span: 80);
      await _movePair(pinch, focal: focal, span: 160);
      await tester.pump();
      _expectAnchor(tester, selected, focal);
      expect(page.fixture.controller.preferences.videoScale, 2);
      expect(
        page.fixture.controller.preferences.videoOffsetX,
        closeTo(.5, .001),
      );
      expect(
        page.fixture.controller.preferences.videoOffsetY,
        closeTo(.2, .001),
      );
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      _expectAnchor(tester, selected, focal);
      expect(page.fixture.preparations, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Combined gestures start from an already transformed video', (
    tester,
  ) async {
    final page = await _render(tester);
    final controller = page.fixture.controller;
    await controller.updatePreferences(
      controller.preferences.copyWith(
        videoScale: 1.3,
        videoOffsetX: .2,
        videoOffsetY: -.15,
        videoRotation: 25,
      ),
    );
    await tester.pumpAndSettle();
    final focal =
        tester.getCenter(find.byKey(_surface)) + const Offset(32, -55);
    final selected = _videoBox(tester).globalToLocal(focal);
    final pinch = await _startPinch(tester, focal: focal);
    final moved = focal + const Offset(-15, 24);
    await _movePair(pinch, focal: moved, span: 140, degrees: 35);
    await tester.pump();
    _expectAnchor(tester, selected, moved);
    expect(controller.preferences.videoScale, closeTo(1.82, .001));
    expect(controller.preferences.videoRotation, closeTo(60, .001));
    expect(page.fixture.current.lastRenderScale, 1);
    expect(page.fixture.history.preferences.videoRotation, 25);
    await pinch.first.up();
    await pinch.second.up();
    await tester.pumpAndSettle();
    expect(page.fixture.current.lastRenderScale, 1);
    expect(page.fixture.history.preferences.videoRotation, closeTo(60, .001));

    final secondFocal = focal + const Offset(-25, 60);
    final secondPoint = _videoBox(tester).globalToLocal(secondFocal);
    final next = await _startPinch(
      tester,
      focal: secondFocal,
      span: 80,
      angle: 20 * math.pi / 180,
    );
    final nextFocal = secondFocal + const Offset(20, -10);
    await _movePair(next, focal: nextFocal, span: 56, degrees: -40);
    await tester.pump();
    _expectAnchor(tester, secondPoint, nextFocal);
    expect(controller.preferences.videoScale, closeTo(1.274, .001));
    expect(controller.preferences.videoRotation, closeTo(0, .001));
    await next.first.up();
    await next.second.up();
    await tester.pumpAndSettle();
    expect(page.fixture.preparations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Two fingers can pan without changing scale or playback', (
    tester,
  ) async {
    final page = await _render(tester);
    final pinch = await _startPinch(tester);
    final point = _videoBox(tester).globalToLocal(pinch.center);
    final moved = pinch.center + const Offset(45, -70);
    await _movePair(pinch, focal: moved);
    await tester.pump();
    _expectAnchor(tester, point, moved);
    expect(page.fixture.controller.preferences.videoScale, closeTo(1, .001));
    expect(page.fixture.controller.preferences.videoRotation, closeTo(0, .001));
    expect(
      page.fixture.controller.preferences.videoOffsetX,
      closeTo(90 / 393, .001),
    );
    expect(
      page.fixture.controller.preferences.videoOffsetY,
      closeTo(-140 / 864, .001),
    );
    expect(page.device.brightness, .5);
    expect(page.fixture.controller.state.volume, 100);
    expect(page.fixture.current.seeks, isEmpty);
    expect(page.fixture.controller.boosting, isFalse);
    await pinch.first.up();
    await pinch.second.up();
    await tester.pumpAndSettle();
    expect(
      page.fixture.history.preferences.videoOffsetX,
      closeTo(90 / 393, .001),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Rotation crosses 180 degrees and a full turn smoothly', (
    tester,
  ) async {
    final page = await _render(tester);
    await page.fixture.controller.updatePreferences(
      page.fixture.controller.preferences.copyWith(videoRotation: 170),
    );
    await tester.pumpAndSettle();
    final focal =
        tester.getCenter(find.byKey(_surface)) + const Offset(-35, -30);
    final point = _videoBox(tester).globalToLocal(focal);
    final pinch = await _startPinch(
      tester,
      focal: focal,
      angle: 170 * math.pi / 180,
    );
    await _movePair(pinch, focal: focal, degrees: 179);
    await tester.pump();
    expect(
      page.fixture.controller.preferences.videoRotation,
      closeTo(179, .001),
    );
    final marker = _videoBox(tester).localToGlobal(point + const Offset(30, 0));
    await _movePair(pinch, focal: focal, degrees: 181);
    await tester.pump();
    expect(
      page.fixture.controller.preferences.videoRotation,
      closeTo(-179, .001),
    );
    expect(
      (_videoBox(tester).localToGlobal(point + const Offset(30, 0)) - marker)
          .distance,
      lessThan(1.1),
    );
    for (final degrees in [190.0, 260.0, 330.0, 400.0, 470.0, 530.0]) {
      await _movePair(pinch, focal: focal, degrees: degrees);
      await tester.pump();
      _expectAnchor(tester, point, focal);
    }
    expect(
      page.fixture.controller.preferences.videoRotation,
      closeTo(170, .001),
    );
    await pinch.first.up();
    await pinch.second.up();
    await tester.pumpAndSettle();
    expect(page.fixture.history.preferences.videoRotation, closeTo(170, .001));
    expect(tester.takeException(), isNull);
  });

  for (final (scale, factor, degrees) in [(3.0, 2.0, 35.0), (.5, .2, -30.0)]) {
    testWidgets('Scale limit $scale still permits focal pan and rotation', (
      tester,
    ) async {
      final page = await _render(tester);
      await page.fixture.controller.updatePreferences(
        page.fixture.controller.preferences.copyWith(videoScale: scale),
      );
      await tester.pumpAndSettle();
      final focal =
          tester.getCenter(find.byKey(_surface)) + const Offset(-45, -60);
      final point = _videoBox(tester).globalToLocal(focal);
      final pinch = await _startPinch(tester, focal: focal);
      final moved = focal + const Offset(25, 15);
      await _movePair(
        pinch,
        focal: moved,
        span: 100 * factor,
        degrees: degrees,
      );
      await tester.pump();
      _expectAnchor(tester, point, moved);
      expect(page.fixture.controller.preferences.videoScale, scale);
      expect(
        page.fixture.controller.preferences.videoRotation,
        closeTo(degrees, .001),
      );
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Reset is shown for three seconds from the first real adjustment',
    (tester) async {
      final page = await _render(tester);
      final controller = page.fixture.controller;
      await controller.updatePreferences(
        controller.preferences.copyWith(
          rate: 1.5,
          fit: PlaybackFit.cover,
          aspectRatio: 4 / 3,
        ),
      );
      final position = controller.state.position;
      await tester.pumpAndSettle();
      final pinch = await _startPinch(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_reset), findsNothing);
      await _movePair(pinch, focal: pinch.center, span: 140, degrees: 20);
      await tester.pump();
      expect(find.byKey(_reset).hitTestable(), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await _movePair(
        pinch,
        focal: pinch.center + const Offset(20, -10),
        span: 160,
        degrees: 30,
      );
      await tester.pump(const Duration(milliseconds: 999));
      expect(find.byKey(_reset), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(_reset), findsNothing);
      await _movePair(
        pinch,
        focal: pinch.center + const Offset(15, 10),
        span: 150,
        degrees: 25,
      );
      await tester.pump();
      expect(find.byKey(_reset), findsNothing);
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();

      final next = await _startPinch(tester);
      await _movePair(next, focal: next.center, span: 120, degrees: 15);
      await next.first.up();
      await next.second.up();
      await tester.pump();
      expect(find.text('还原屏幕'), findsOneWidget);
      await tester.tap(find.byKey(_reset));
      await tester.pump();
      expect(find.byKey(_reset), findsNothing);
      final value = controller.preferences;
      expect(value.videoScale, 1);
      expect(value.videoOffsetX, 0);
      expect(value.videoOffsetY, 0);
      expect(value.videoRotation, 0);
      expect(value.rate, 1.5);
      expect(value.fit, PlaybackFit.cover);
      expect(value.aspectRatio, 4 / 3);
      expect(controller.state.position, position);
      expect(controller.state.playing, isTrue);
      expect(page.fixture.history.preferences.videoScale, 1);
      expect(page.fixture.history.preferences.videoRotation, 0);
      expect(page.fixture.preparations, 1);
      await tester.pump(const Duration(seconds: 4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Reset discards an unrendered preview and rebases active fingers',
    (tester) async {
      final page = await _render(tester);
      final pinch = await _startPinch(tester);
      await _movePair(pinch, focal: pinch.center, span: 160, degrees: 20);
      await tester.pump();
      final reset = tester.widget<TextButton>(find.byKey(_reset));
      await _movePair(
        pinch,
        focal: pinch.center + const Offset(15, 25),
        span: 180,
        degrees: 30,
      );
      reset.onPressed!();
      await tester.pump();
      expect(page.fixture.controller.preferences.videoScale, 1);
      expect(page.fixture.controller.preferences.videoRotation, 0);
      expect(page.fixture.controller.preferences.videoOffsetX, 0);
      expect(find.byKey(_reset), findsNothing);
      final focal = pinch.center + const Offset(15, 25);
      final point = _videoBox(tester).globalToLocal(focal);
      await _movePair(pinch, focal: focal, span: 198, degrees: 40);
      await tester.pump();
      _expectAnchor(tester, point, focal);
      expect(
        page.fixture.controller.preferences.videoScale,
        closeTo(1.1, .001),
      );
      expect(
        page.fixture.controller.preferences.videoRotation,
        closeTo(10, .001),
      );
      expect(find.byKey(_reset), findsNothing);
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(page.fixture.history.preferences.videoScale, closeTo(1.1, .001));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Moves coalesce per frame and releasing saves the last preview', (
    tester,
  ) async {
    final page = await _render(tester);
    var changes = 0;
    void changed() => changes++;
    page.fixture.controller.addListener(changed);
    final pinch = await _startPinch(tester);
    changes = 0;
    for (final span in [120.0, 140.0, 160.0]) {
      await _movePair(pinch, focal: pinch.center, span: span, degrees: 20);
    }
    expect(changes, 0);
    expect(page.fixture.controller.preferences.videoScale, 1);
    await tester.pump();
    expect(changes, 1);
    expect(page.fixture.controller.preferences.videoScale, closeTo(1.6, .001));
    expect(page.fixture.current.lastRenderScale, 1);
    final moved = pinch.center + const Offset(15, -30);
    await _movePair(pinch, focal: moved, span: 180, degrees: 35);
    await pinch.first.up();
    await pinch.second.up();
    await tester.pump();
    expect(page.fixture.history.preferences.videoScale, closeTo(1.8, .001));
    expect(page.fixture.history.preferences.videoRotation, closeTo(35, .001));
    expect(
      page.fixture.history.preferences.videoOffsetX,
      closeTo(30 / 393, .001),
    );
    expect(
      page.fixture.history.preferences.videoOffsetY,
      closeTo(-60 / 864, .001),
    );
    expect(page.fixture.current.lastRenderScale, 1);
    page.fixture.controller.removeListener(changed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Third-finger replacement rebases rotated and shifted video', (
    tester,
  ) async {
    final page = await _render(tester);
    final pinch = await _startPinch(tester);
    final focal = pinch.center + const Offset(10, 20);
    await _movePair(pinch, focal: focal, span: 150, degrees: 35);
    // The third finger arrives before the frame; the combined preview survives.
    final thirdPoint = pinch.center + const Offset(-60, 100);
    final third = await tester.startGesture(thirdPoint, pointer: 3);
    await tester.pump();
    final before = page.fixture.controller.preferences;
    expect(before.videoScale, closeTo(1.5, .001));
    expect(before.videoRotation, closeTo(35, .001));
    final side = Offset.fromDirection(35 * math.pi / 180, 75);
    await pinch.first.moveBy(const Offset(-20, -15));
    final secondPoint = focal + side + const Offset(12, -8);
    await pinch.second.moveTo(secondPoint);
    await tester.pump();
    expect(page.fixture.controller.preferences, same(before));
    await pinch.first.up();
    await tester.pump();
    expect(page.fixture.controller.preferences, same(before));
    final newFocal = (secondPoint + thirdPoint) / 2;
    final selected = _videoBox(tester).globalToLocal(newFocal);
    final vector = thirdPoint - secondPoint;
    final newSpan = vector.distance * .9;
    final newAngle = vector.direction + 20 * math.pi / 180;
    final moved = newFocal + const Offset(-10, 20);
    final newSide = Offset.fromDirection(newAngle, newSpan / 2);
    await pinch.second.moveTo(moved - newSide);
    await third.moveTo(moved + newSide);
    await tester.pump();
    _expectAnchor(tester, selected, moved);
    expect(page.fixture.controller.preferences.videoScale, closeTo(1.35, .001));
    expect(
      page.fixture.controller.preferences.videoRotation,
      closeTo(55, .001),
    );
    await pinch.second.up();
    await third.up();
    await tester.pumpAndSettle();
    expect(page.fixture.history.preferences.videoRotation, closeTo(55, .001));
    expect(tester.takeException(), isNull);
  });

  for (final exit in ['background', 'lock', 'pip', 'panel']) {
    testWidgets('Leaving for $exit hides reset and cancels its timer', (
      tester,
    ) async {
      final page = await _render(tester);
      final pinch = await _startPinch(tester);
      await _movePair(pinch, focal: pinch.center, span: 150, degrees: 25);
      await tester.pump();
      expect(find.byKey(_reset), findsOneWidget);
      await pinch.first.up();
      await pinch.second.up();
      await tester.pump();
      switch (exit) {
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        case 'lock':
          await tester.tap(find.byKey(const Key('player-lock')));
        case 'pip':
          await page.device.enterPip();
        case 'panel':
          await tester.tap(find.byTooltip('更多'));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(_reset), findsNothing);
      switch (exit) {
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        case 'lock':
          await tester.tap(find.byKey(const Key('player-unlock')));
        case 'pip':
          page.device.leavePip();
        case 'panel':
          await tester.binding.handlePopRoute();
      }
      await tester.pump(const Duration(seconds: 4));
      expect(find.byKey(_reset), findsNothing);
      expect(
        page.fixture.controller.preferences.videoRotation,
        closeTo(25, .001),
      );
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

  for (final (size, textScale) in [
    (const Size(393, 864), 1.0),
    (const Size(844, 390), 1.0),
    (const Size(320, 700), 1.8),
  ]) {
    testWidgets(
      'Reset avoids visible controls at $size and font scale $textScale',
      (tester) async {
        await _render(tester, size: size, textScale: textScale);
        final pinch = await _startPinch(tester, span: 80);
        await _movePair(pinch, focal: pinch.center, span: 100);
        await tester.pump();
        final bounds = tester.getRect(find.byKey(_surface));
        final reset = tester.getRect(find.byKey(_reset));
        final controls = tester.getRect(
          find.byKey(const Key('player-top-controls')),
        );
        expect(reset.top, greaterThanOrEqualTo(controls.bottom));
        expect(reset.left, greaterThanOrEqualTo(bounds.left));
        expect(reset.right, lessThanOrEqualTo(bounds.right));
        expect(reset.bottom, lessThanOrEqualTo(bounds.bottom));
        expect(reset.height, greaterThanOrEqualTo(48));
        await pinch.first.up();
        await pinch.second.up();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Desktop PiP uses the original frame then restores its transform',
    (tester) async {
      final device = FakePlaybackDevice()..supportsDesktopPip = true;
      final page = await _render(tester, suppliedDevice: device);
      final controller = page.fixture.controller;
      await controller.updatePreferences(
        controller.preferences.copyWith(
          videoScale: 1.8,
          videoOffsetX: 1.4,
          videoOffsetY: -.6,
          videoRotation: 35,
        ),
      );
      await tester.pumpAndSettle();
      await device.enterPip();
      tester.view.physicalSize = const Size(480, 270);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Transform>(find.byKey(_transform)).transform.storage[0],
        1,
      );
      expect(
        tester.widget<Transform>(find.byKey(_rotation)).transform.storage[0],
        1,
      );
      expect(page.fixture.current.lastRenderScale, 1);
      final surface = tester.getRect(
        find.byKey(const Key('player-video-surface')),
      );
      _expectAnchor(tester, surface.size.center(Offset.zero), surface.center);
      expect(controller.preferences.videoRotation, 35);
      device.leavePip();
      tester.view.physicalSize = const Size(393, 864);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Transform>(find.byKey(_transform)).transform.storage[0],
        1.8,
      );
      expect(
        tester.widget<Transform>(find.byKey(_rotation)).transform.storage[0],
        closeTo(.819152, .000001),
      );
      expect(controller.preferences.videoOffsetX, 1.4);
      expect(page.fixture.current.lastRenderScale, 1);
      expect(page.fixture.preparations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Vertical gestures use the outer 30 percent and keep the middle free for pinch',
    (tester) async {
      final page = await _render(tester);
      final controller = page.fixture.controller;
      final bounds = tester.getRect(find.byKey(_surface));
      final position = controller.state.position;
      for (final fraction in [.31, .4, .5, .6, .69]) {
        await tester.dragFrom(
          Offset(bounds.left + bounds.width * fraction, bounds.center.dy),
          const Offset(0, -90),
        );
        await tester.pumpAndSettle();
        expect(page.device.brightness, .5, reason: 'Middle swipe at $fraction');
        expect(
          controller.state.volume,
          100,
          reason: 'Middle swipe at $fraction',
        );
        expect(controller.state.position, position);
      }
      await tester.dragFrom(
        Offset(bounds.left + bounds.width * .29, bounds.center.dy),
        const Offset(0, -90),
      );
      await tester.pumpAndSettle();
      expect(page.device.brightness, greaterThan(.5));
      final brightness = page.device.brightness;
      await tester.dragFrom(
        Offset(bounds.left + bounds.width * .71, bounds.center.dy),
        const Offset(0, 90),
      );
      await tester.pumpAndSettle();
      expect(controller.state.volume, lessThan(100));
      final volume = controller.state.volume;
      final first = await tester.startGesture(
        bounds.center - const Offset(40, 0),
        pointer: 1,
      );
      await first.moveBy(const Offset(0, -45));
      await tester.pump();
      expect(page.device.brightness, brightness);
      expect(controller.state.volume, volume);
      final second = await tester.startGesture(
        bounds.center + const Offset(40, 0),
        pointer: 2,
      );
      await first.moveBy(const Offset(-30, 0));
      await second.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(controller.preferences.videoScale, greaterThan(1));
      expect(page.device.brightness, brightness);
      expect(controller.state.volume, volume);
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(controller.state.position, position);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A diagonal swipe keeps the control zone selected at pointer down',
    (tester) async {
      final page = await _render(tester);
      final bounds = tester.getRect(find.byKey(_surface));
      final controller = page.fixture.controller;
      final middle = await tester.startGesture(
        Offset(bounds.left + bounds.width * .32, bounds.center.dy),
      );
      await middle.moveBy(const Offset(-18, -45));
      await middle.moveBy(const Offset(0, -60));
      await middle.up();
      await tester.pumpAndSettle();
      expect(page.device.brightness, .5);
      expect(controller.state.volume, 100);
      final side = await tester.startGesture(
        Offset(bounds.left + bounds.width * .28, bounds.center.dy),
      );
      await side.moveBy(const Offset(18, -45));
      await side.moveBy(const Offset(0, -60));
      await side.up();
      await tester.pumpAndSettle();
      expect(page.device.brightness, greaterThan(.5));
      expect(controller.state.volume, 100);
      expect(tester.takeException(), isNull);
    },
  );

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
      await _movePair(pinch, focal: pinch.center, span: 220, degrees: 20);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(page.fixture.history.preferences.videoScale, closeTo(2.2, .001));
      expect(page.fixture.history.preferences.videoRotation, closeTo(20, .001));
      await pinch.first.cancel();
      await pinch.second.cancel();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await _zoom(tester, .5);
      expect(
        page.fixture.controller.preferences.videoScale,
        closeTo(1.1, .001),
      );
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
    await _movePair(pinch, focal: pinch.center, span: 240, degrees: 25);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await page.fixture.controller.close();
    expect(page.fixture.history.preferences.videoScale, closeTo(2.4, .001));
    expect(page.fixture.history.preferences.videoRotation, closeTo(25, .001));
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
      expect(find.byKey(_reset), findsOneWidget);
      await _movePair(pinch, focal: pinch.center, span: 240, degrees: 30);
      await fixture.controller.next();
      await tester.pumpAndSettle();
      expect(find.byKey(_reset), findsNothing);
      await pinch.first.moveBy(const Offset(0, -90));
      await pinch.second.moveBy(const Offset(0, 90));
      await pinch.first.up();
      await pinch.second.up();
      await tester.pumpAndSettle();
      expect(fixture.controller.preferences.videoScale, .75);
      expect(fixture.controller.preferences.videoRotation, 0);
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
