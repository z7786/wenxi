import 'package:asterlink/ui/skeleton_loading.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> render(
    WidgetTester tester, {
    SkeletonLayout layout = SkeletonLayout.fileList,
    Size size = const Size(393, 720),
    bool dark = false,
    bool active = true,
    bool tickers = true,
    double scale = 1,
    bool bounded = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
          ),
          child: TickerMode(
            enabled: tickers,
            child: Scaffold(
              body: bounded
                  ? SizedBox.expand(
                      child: AppSkeleton(layout: layout, active: active),
                    )
                  : SingleChildScrollView(
                      child: AppSkeleton(layout: layout, active: active),
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final layout in SkeletonLayout.values) {
    testWidgets('$layout paints on phone, desktop, dark and large text', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final (size, dark, scale) in [
        (const Size(320, 640), false, 1.0),
        (const Size(393, 864), true, 1.0),
        (const Size(1024, 768), false, 1.0),
        (const Size(320, 640), true, 2.0),
      ]) {
        await render(
          tester,
          layout: layout,
          size: size,
          dark: dark,
          scale: scale,
        );
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(AppSkeleton)).width, size.width);
        await render(
          tester,
          layout: layout,
          size: size,
          dark: dark,
          scale: scale,
          bounded: false,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byType(AppSkeleton)).height.isFinite,
          isTrue,
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('The sweep advances linearly across all rows and repeats', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await render(tester);
    final customPaint = find.descendant(
      of: find.byType(AppSkeleton),
      matching: find.byType(CustomPaint),
    );
    final painter = tester.widget<CustomPaint>(customPaint).painter;
    // The animation updates paint without rebuilding placeholder layouts.
    await tester.pump(const Duration(milliseconds: 450));
    final dynamic delegate = tester.widget<CustomPaint>(customPaint).painter;
    expect(identical(painter, delegate), isTrue);
    expect(delegate.sweep.value, closeTo(.25, .001));
    await tester.pump(const Duration(milliseconds: 450));
    expect(delegate.sweep.value, closeTo(.5, .001));
    await tester.pump(const Duration(milliseconds: 1125));
    expect(delegate.sweep.value, closeTo(.125, .001));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Hidden pages and the background stop animating and resume', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await render(tester);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await render(tester, tickers: false);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await render(tester, active: false);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    await render(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Placeholder rectangles cannot capture touches or announce files',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      await render(tester);
      expect(find.bySemanticsLabel('正在加载'), findsOneWidget);
      final ignore = tester.renderObject<RenderIgnorePointer>(
        find.descendant(
          of: find.byType(AppSkeleton),
          matching: find.byType(IgnorePointer),
        ),
      );
      expect(ignore.ignoring, isTrue);
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );
}
