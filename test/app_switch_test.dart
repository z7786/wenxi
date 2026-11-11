import 'package:asterlink/ui/app_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late bool value, enabled, commit;
  late int changes;
  late StateSetter update;

  Future<void> render(
    WidgetTester tester, {
    bool tile = false,
    bool rtl = false,
    bool dark = false,
    bool tickers = true,
    FocusNode? focusNode,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: TickerMode(
            enabled: tickers,
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  void changed(bool next) {
                    changes++;
                    if (commit) setState(() => value = next);
                  }

                  return Center(
                    child: tile
                        ? AppSwitchListTile(
                            title: const Text('示例开关'),
                            subtitle: const Text('点击整行或滑动开关'),
                            value: value,
                            onChanged: enabled ? changed : null,
                            focusNode: focusNode,
                          )
                        : AppSwitch(
                            value: value,
                            onChanged: enabled ? changed : null,
                            semanticLabel: '示例开关',
                            focusNode: focusNode,
                          ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  dynamic frame(WidgetTester tester) => tester
      .widget<CustomPaint>(
        find.descendant(
          of: find.byType(AppSwitch),
          matching: find.byType(CustomPaint),
        ),
      )
      .painter;

  setUp(() {
    value = false;
    enabled = true;
    commit = true;
    changes = 0;
  });

  testWidgets(
    'The circle stretches in flight, restores on arrival and bounces',
    (tester) async {
      await render(tester);
      expect(frame(tester).frame().width, 1);
      await tester.tap(find.byType(AppSwitch));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 130));
      final dynamic moving = frame(tester).frame();
      expect(moving.position, closeTo(.5, .04));
      expect(moving.width, greaterThan(1.4));
      expect(moving.height, 1);
      await tester.pump(const Duration(milliseconds: 129));
      final dynamic arrived = frame(tester).frame();
      expect(arrived.position, closeTo(1, .002));
      expect(arrived.width, closeTo(1, .005));
      await tester.pump(const Duration(milliseconds: 18));
      expect(frame(tester).frame().position, greaterThan(1));
      await tester.pumpAndSettle();
      expect(frame(tester).frame().position, 1);
      expect(frame(tester).frame().width, 1);
      expect(frame(tester).frame().height, 1);
      expect(changes, 1);
      await tester.tap(find.byType(AppSwitch));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 130));
      expect(frame(tester).frame().width, greaterThan(1.4));
      await tester.pumpAndSettle();
      expect(frame(tester).frame().position, 0);
      expect(frame(tester).frame().width, 1);
    },
  );

  testWidgets('Rapid reversal continues from the current position and shape', (
    tester,
  ) async {
    await render(tester);
    await tester.tap(find.byType(AppSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final dynamic previous = frame(tester).frame();
    await tester.tap(find.byType(AppSwitch));
    await tester.pump();
    expect(frame(tester).frame().position, closeTo(previous.position, .001));
    expect(frame(tester).frame().width, closeTo(previous.width, .001));
    await tester.pumpAndSettle();
    expect(frame(tester).frame().position, 0);
    expect(frame(tester).frame().width, 1);
    expect(value, isFalse);
    expect(changes, 2);
  });

  testWidgets(
    'A pending or rejected parent change cannot commit a false state',
    (tester) async {
      commit = false;
      await render(tester);
      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(changes, 1);
      expect(value, isFalse);
      expect(frame(tester).frame().position, 0);
      expect(tester.binding.hasScheduledFrame, isFalse);
      update(() => value = true);
      await tester.pumpAndSettle();
      expect(frame(tester).frame().position, 1);
    },
  );

  for (final rtl in [false, true]) {
    testWidgets(
      'Drag commits once and cancellation restores the value (rtl=$rtl)',
      (tester) async {
        await render(tester, rtl: rtl);
        final direction = rtl ? -1.0 : 1.0;
        await tester.drag(find.byType(AppSwitch), Offset(45 * direction, 0));
        await tester.pumpAndSettle();
        expect(value, isTrue);
        expect(changes, 1);
        await tester.drag(find.byType(AppSwitch), Offset(-45 * direction, 0));
        await tester.pumpAndSettle();
        expect(value, isFalse);
        expect(changes, 2);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(AppSwitch)),
        );
        await gesture.moveBy(Offset(30 * direction, 0));
        await tester.pump();
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(value, isFalse);
        expect(frame(tester).frame().position, 0);
        expect(frame(tester).frame().width, 1);
        expect(changes, 2);
      },
    );
  }

  testWidgets('Disabled controls ignore tap, drag and keyboard activation', (
    tester,
  ) async {
    enabled = false;
    await render(tester);
    await tester.tap(find.byType(AppSwitch));
    await tester.drag(find.byType(AppSwitch), const Offset(45, 0));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(changes, 0);
    expect(value, isFalse);
    expect(frame(tester).frame().position, 0);
  });

  for (final tile in [false, true]) {
    testWidgets('Space and Enter activate one focus target (tile=$tile)', (
      tester,
    ) async {
      final focus = FocusNode();
      await render(tester, tile: tile, focusNode: focus);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(changes, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(value, isFalse);
      expect(changes, 2);
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
    });
  }

  testWidgets('A row label and its thumb both toggle exactly once', (
    tester,
  ) async {
    await render(tester, tile: true);
    await tester.tap(find.text('示例开关'));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(changes, 1);
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect(changes, 2);
  });

  testWidgets(
    'Accessibility reads a single labeled switch and its actual state',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await render(tester, tile: true);
      final node = tester.getSemantics(find.bySemanticsLabel(RegExp('示例开关')));
      expect(
        node.getSemanticsData().flagsCollection.isToggled,
        Tristate.isFalse,
      );
      expect(find.bySemanticsLabel(RegExp('示例开关')), findsOneWidget);
      await tester.tap(find.text('示例开关'));
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(RegExp('示例开关')))
            .getSemanticsData()
            .flagsCollection
            .isToggled,
        Tristate.isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      semantics.dispose();
    },
  );

  testWidgets('Dark mode, hiding and disposal leave no ongoing animation', (
    tester,
  ) async {
    await render(tester, dark: true);
    await tester.tap(find.byType(AppSwitch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    await render(tester, dark: true, tickers: false);
    await tester.pump();
    expect(frame(tester).frame().position, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await render(tester, dark: true);
    await tester.tap(find.byType(AppSwitch));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
