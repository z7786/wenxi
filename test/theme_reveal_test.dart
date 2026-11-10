import 'dart:async';
import 'dart:ui' as ui;

import 'package:asterlink/ui/liquid_glass.dart';
import 'package:asterlink/ui/theme_reveal.dart';
import 'package:asterlink/platform/theme_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _screen = Key('screen');
const _toggle = Key('toggle');
const _overlay = Key('theme-reveal-overlay');
const _origin = Offset(340, 180);

class _Harness extends StatefulWidget {
  const _Harness({
    this.dark = false,
    this.transparent = false,
    this.controls,
    this.captureFrame,
  });
  final bool dark;
  final bool transparent;
  final Widget? controls;
  final ThemeFrameCapture? captureFrame;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final host = GlobalKey<ThemeRevealHostState>();
  late bool dark = widget.dark;
  Future<void> Function()? beforeUpdate;
  Future<void>? lastChange;
  int updates = 0, presses = 0;
  bool keepOriginVisible = false;

  Future<void> change(BuildContext origin) => ThemeRevealHost.change(
    origin,
    dark: !dark,
    keepOriginVisible: keepOriginVisible,
    update: () async {
      await beforeUpdate?.call();
      if (!mounted) return;
      setState(() {
        dark = !dark;
        updates++;
      });
    },
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData.light().copyWith(scaffoldBackgroundColor: Colors.white),
    darkTheme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    themeAnimationDuration: host.currentState?.isPrepared == true
        ? Duration.zero
        : const Duration(milliseconds: 240),
    builder: (context, child) => ThemeRevealHost(
      key: host,
      captureFrame: widget.captureFrame,
      child: child!,
    ),
    home: Builder(
      builder: (context) => ColoredBox(
        color: widget.transparent
            ? Colors.transparent
            : Theme.of(context).brightness == Brightness.dark
            ? Colors.black
            : Colors.white,
        child: Stack(
          children: [
            const _RetainedState(),
            ?widget.controls,
            Positioned(
              left: _origin.dx - 20,
              top: _origin.dy - 20,
              width: 40,
              height: 40,
              child: Builder(
                builder: (context) => GestureDetector(
                  key: _toggle,
                  behavior: HitTestBehavior.opaque,
                  onTap: () => lastChange = change(context),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 10,
              width: 40,
              height: 40,
              child: GestureDetector(
                key: const Key('action'),
                behavior: HitTestBehavior.opaque,
                onTap: () => presses++,
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _RetainedState extends StatefulWidget {
  const _RetainedState();
  @override
  State<_RetainedState> createState() => _RetainedStateState();
}

class _RetainedStateState extends State<_RetainedState> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<void> _start(WidgetTester tester) async {
  await tester.tap(find.byKey(_toggle));
  await _rasterize(tester);
  await tester.pump();
  await tester.pump();
  expect(find.byKey(_overlay), findsOneWidget);
}

Future<void> _rasterize(WidgetTester tester) => tester.runAsync(
  () => Future<void>.delayed(const Duration(milliseconds: 40)),
);

Future<List<Color>> _pixels(WidgetTester tester, List<Offset> points) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_screen),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      return [
        for (final point in points)
          Color.fromARGB(
            255,
            data.getUint8(
              (point.dy.toInt() * image.width + point.dx.toInt()) * 4,
            ),
            data.getUint8(
              (point.dy.toInt() * image.width + point.dx.toInt()) * 4 + 1,
            ),
            data.getUint8(
              (point.dy.toInt() * image.width + point.dx.toInt()) * 4 + 2,
            ),
          ),
      ];
    } finally {
      image.dispose();
    }
  }))!;
}

void main() {
  Future<_HarnessState> render(
    WidgetTester tester, {
    bool dark = false,
    bool transparent = false,
    Widget? controls,
    ThemeFrameCapture? captureFrame,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _screen,
        child: _Harness(
          dark: dark,
          transparent: transparent,
          controls: controls,
          captureFrame: captureFrame,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<_HarnessState>(find.byType(_Harness));
  }

  testWidgets('native frame keeps displayed pixels instead of replaying clips', (
    tester,
  ) async {
    var captures = 0;
    final state = await render(
      tester,
      controls: const Positioned(
        left: 20,
        top: 500,
        width: 220,
        height: 180,
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(32)),
          child: ColoredBox(color: Colors.red),
        ),
      ),
      captureFrame: (bounds, devicePixelRatio, pixelRatio) async {
        captures++;
        expect(bounds, const Rect.fromLTWH(0, 0, 400, 800));
        expect(devicePixelRatio, 1);
        expect(pixelRatio, 1);
        // Distinct source pixels make an accidental offscreen fallback visible.
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(bounds, Paint()..color = Colors.yellow);
        final picture = recorder.endRecording();
        try {
          return await picture.toImage(400, 800);
        } finally {
          picture.dispose();
        }
      },
    );
    await _start(tester);
    await tester.pump(const Duration(milliseconds: 140));
    expect(await _pixels(tester, [_origin, const Offset(50, 660)]), [
      Colors.black,
      const Color(0xffffeb3b),
    ]);
    await tester.pumpAndSettle();
    expect(captures, 1);
    expect(state.dark, isTrue);
    expect(find.byKey(_overlay), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unavailable native frame never falls back to clip replay', (
    tester,
  ) async {
    final state = await render(tester, captureFrame: (_, _, _) async => null);
    await tester.tap(find.byKey(_toggle));
    await _rasterize(tester);
    await tester.pumpAndSettle();
    expect(state.dark, isTrue);
    expect(state.updates, 1);
    expect(find.byKey(_overlay), findsNothing);
    expect(state.host.currentState!.isPrepared, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a delayed native frame is discarded after the app backgrounds', (
    tester,
  ) async {
    final frame = Completer<ui.Image?>();
    final state = await render(tester, captureFrame: (_, _, _) => frame.future);
    await tester.tap(find.byKey(_toggle));
    expect(state.updates, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    frame.complete(null);
    await tester.pumpAndSettle();
    expect(state.dark, isTrue);
    expect(find.byKey(_overlay), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the theme waits until the old frame is rasterized', (
    tester,
  ) async {
    final state = await render(tester);
    final change = state.change(tester.element(find.byKey(_toggle)));
    expect(state.updates, 0);
    expect(state.dark, isFalse);
    await _rasterize(tester);
    await tester.pump();
    await tester.pump();
    expect(state.updates, 1);
    expect(find.byKey(_overlay), findsOneWidget);
    await tester.pumpAndSettle();
    await change;
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'translucent controls keep their old backing outside the circle',
    (tester) async {
      await render(
        tester,
        transparent: true,
        controls: const Positioned(
          left: 20,
          top: 650,
          width: 120,
          height: 80,
          child: ColoredBox(color: Color(0x33ff0000)),
        ),
      );
      const point = Offset(50, 700);
      final before = await _pixels(tester, [point]);
      await _start(tester);
      await tester.pump(const Duration(milliseconds: 140));
      expect(await _pixels(tester, [point]), before);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('glass and rounded controls survive both reveal directions', (
    tester,
  ) async {
    final state = await render(
      tester,
      controls: const Positioned(
        left: 20,
        top: 500,
        width: 220,
        height: 220,
        child: LiquidGlassSurface(
          tint: Color(0xff88bbff),
          opacity: .35,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                TextField(decoration: InputDecoration(labelText: 'Search')),
                FilledButton(onPressed: null, child: Text('Button')),
              ],
            ),
          ),
        ),
      ),
    );
    final points = [const Offset(30, 660), const Offset(120, 690)];
    for (var i = 0; i < 2; i++) {
      final before = await _pixels(tester, points);
      await _start(tester);
      expect(await _pixels(tester, points), before);
      await tester.pump(const Duration(milliseconds: 140));
      expect(await _pixels(tester, points), before);
      await tester.pumpAndSettle();
    }
    expect(state.dark, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'dark expands from the control and reaches every viewport corner',
    (tester) async {
      final state = await render(tester);
      final retained = tester.state(find.byType(_RetainedState));
      await _start(tester);
      await tester.pump(const Duration(milliseconds: 140));
      expect(await _pixels(tester, [_origin, const Offset(10, 780)]), [
        Colors.black,
        Colors.white,
      ]);
      await tester.tap(find.byKey(const Key('action')));
      expect(state.presses, 1);
      await tester.pumpAndSettle();
      expect(find.byKey(_overlay), findsNothing);
      expect(
        await _pixels(tester, const [
          Offset(1, 1),
          Offset(398, 1),
          Offset(1, 798),
          Offset(398, 798),
        ]),
        everyElement(Colors.black),
      );
      expect(tester.state(find.byType(_RetainedState)), same(retained));
      expect(state.updates, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('light contracts the dark circle toward the same control', (
    tester,
  ) async {
    await render(tester, dark: true);
    await _start(tester);
    await tester.pump(const Duration(milliseconds: 280));
    expect(await _pixels(tester, [_origin, const Offset(10, 780)]), [
      Colors.black,
      Colors.white,
    ]);
    await tester.pumpAndSettle();
    expect(find.byKey(_overlay), findsNothing);
    expect(await _pixels(tester, [_origin]), [Colors.white]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rapid reversal starts at the current circle radius', (
    tester,
  ) async {
    final state = await render(tester);
    await _start(tester);
    await tester.pump(const Duration(milliseconds: 240));
    final points = [_origin, const Offset(100, 300), const Offset(10, 780)];
    final before = await _pixels(tester, points);
    await _start(tester);
    expect(await _pixels(tester, points), before);
    await tester.pumpAndSettle();
    expect(await _pixels(tester, points), everyElement(Colors.white));
    expect(state.updates, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the trigger stays live while the dark snapshot contracts', (
    tester,
  ) async {
    final state = await render(tester, dark: true);
    state.keepOriginVisible = true;
    await _start(tester);
    await tester.pump(const Duration(milliseconds: 140));
    expect(await _pixels(tester, [_origin, _origin + const Offset(40, 0)]), [
      Colors.white,
      Colors.black,
    ]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rejected save clears preparation without changing the theme', (
    tester,
  ) async {
    final state = await render(tester);
    state.beforeUpdate = () async => throw StateError('save failed');
    final change = state.change(tester.element(find.byKey(_toggle)));
    final rejected = expectLater(change, throwsStateError);
    await _rasterize(tester);
    await rejected;
    await tester.pumpAndSettle();
    expect(state.dark, isFalse);
    expect(state.host.currentState!.isPrepared, isFalse);
    expect(find.byKey(_overlay), findsNothing);
    state.beforeUpdate = null;
    await _start(tester);
    await tester.pumpAndSettle();
    expect(state.dark, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('resize and backgrounding finish the overlay and release it', (
    tester,
  ) async {
    await render(tester);
    await _start(tester);
    await tester.pump(const Duration(milliseconds: 100));
    tester.view.physicalSize = const Size(800, 400);
    await tester.pumpAndSettle();
    expect(find.byKey(_overlay), findsNothing);
    await _start(tester);
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(find.byKey(_overlay), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposing the app while a save is pending does not retain a frame',
    (tester) async {
      final state = await render(tester);
      final save = Completer<void>();
      state.beforeUpdate = () => save.future;
      final change = state.change(tester.element(find.byKey(_toggle)));
      await _rasterize(tester);
      expect(state.host.currentState!.isPrepared, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      save.complete();
      await change;
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('backgrounding during rasterization discards the old frame', (
    tester,
  ) async {
    final state = await render(tester);
    await tester.tap(find.byKey(_toggle));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _rasterize(tester);
    await tester.pumpAndSettle();
    expect(state.dark, isTrue);
    expect(state.host.currentState!.isPrepared, isFalse);
    expect(find.byKey(_overlay), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
