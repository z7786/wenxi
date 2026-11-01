import 'package:asterlink/ui/app_navigation.dart';
import 'package:asterlink/download/navigation_transfers.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> render(
    WidgetTester tester, {
    bool rtl = false,
    double scale = 1,
    bool reduceMotion = true,
    ValueNotifier<NavigationTransferStatus>? transfers,
    ValueChanged<int>? onSelected,
  }) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: reduceMotion,
            ),
            child: Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: Scaffold(
                body: Text('page-$selected'),
                bottomNavigationBar: AppNavigation(
                  selectedIndex: selected,
                  transfers: transfers,
                  onSelected: (index) {
                    onSelected?.call(index);
                    setState(() => selected = index);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('tap and drag commit navigation; cancelled drag preserves page', (
    tester,
  ) async {
    await render(tester);
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);
    final start = tester.getCenter(find.byKey(const ValueKey('navigation-1')));
    final end = tester.getCenter(find.byKey(const ValueKey('navigation-3')));
    var gesture = await tester.startGesture(start);
    await gesture.moveTo(end);
    await tester.pump();
    expect(find.text('page-1'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('page-3'), findsOneWidget);
    gesture = await tester.startGesture(end);
    await gesture.moveTo(start);
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.text('page-3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL drag and large text fit a narrow screen', (tester) async {
    await render(tester, rtl: true, scale: 2);
    final start = tester.getCenter(find.byKey(const ValueKey('navigation-0')));
    final end = tester.getCenter(find.byKey(const ValueKey('navigation-3')));
    await tester.dragFrom(start, end - start);
    await tester.pumpAndSettle();
    expect(find.text('page-3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final rtl in [false, true]) {
    testWidgets('long press scrubs without lag and commits once (rtl: $rtl)', (
      tester,
    ) async {
      final selections = <int>[];
      await render(
        tester,
        rtl: rtl,
        reduceMotion: false,
        onSelected: selections.add,
      );
      final first = tester.getCenter(
        find.byKey(const ValueKey('navigation-0')),
      );
      final last = tester.getCenter(find.byKey(const ValueKey('navigation-3')));
      final target = tester.getCenter(
        find.byKey(const ValueKey('navigation-2')),
      );
      final gesture = await tester.startGesture(first);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
      // Continuous movement, a reversal, and vertical drift all belong to the
      // same long press. Selection changes only when the finger is released.
      for (final point in [
        Offset.lerp(first, last, .4)!,
        last,
        target.translate(0, -22),
      ]) {
        await gesture.moveTo(point);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getCenter(find.byKey(const Key('navigation-lens'))).dx,
          closeTo(point.dx, .5),
        );
        expect(find.text('page-0'), findsOneWidget);
        expect(selections, isEmpty);
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('page-2'), findsOneWidget);
      expect(selections, [2]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('cancelled long press rolls back and the next tap works', (
    tester,
  ) async {
    await render(tester, reduceMotion: false);
    final target = tester.getCenter(find.byKey(const ValueKey('navigation-3')));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('navigation-0'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.text('page-0'), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(const Key('navigation-lens'))).dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('navigation-0'))).dx,
        .5,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('navigation-1')));
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag lens grows like the reference and rests without a ticker', (
    tester,
  ) async {
    await render(tester, reduceMotion: false);
    final first = tester.getCenter(find.byKey(const ValueKey('navigation-0')));
    final last = tester.getCenter(find.byKey(const ValueKey('navigation-3')));
    final gesture = await tester.startGesture(first);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
    await gesture.moveTo(last);
    await tester.pump(const Duration(milliseconds: 240));
    final pressed = tester.widget<Transform>(
      find.byKey(const Key('navigation-lens-transform')),
    );
    expect(pressed.transform.storage[0], greaterThan(1.35));
    expect(pressed.transform.storage[5], greaterThan(1.35));
    expect(find.text('page-0'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    final released = tester.widget<Transform>(
      find.byKey(const Key('navigation-lens-transform')),
    );
    expect(released.transform.storage[0], closeTo(1, .001));
    expect(find.text('page-3'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('animated selection settles on the requested tab', (
    tester,
  ) async {
    await render(tester, reduceMotion: false);
    await tester.tap(find.byKey(const ValueKey('navigation-3')));
    await tester.pumpAndSettle();
    final lens = tester.getCenter(find.byKey(const Key('navigation-lens')));
    final tab = tester.getCenter(find.byKey(const ValueKey('navigation-3')));
    expect(lens.dx, closeTo(tab.dx, 1));
    expect(find.text('page-3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final rail in [false, true]) {
    testWidgets(
      'hidden resources preserve page IDs and navigation (rail: $rail)',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(rail ? 1024 : 393, 864));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var selected = 1;
        var hidden = true;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                Widget navigation() => AppNavigation(
                  rail: rail,
                  hideResources: hidden,
                  selectedIndex: selected,
                  onSelected: (index) => setState(() => selected = index),
                );
                return Scaffold(
                  body: Row(
                    children: [
                      if (rail) navigation(),
                      Expanded(child: Text('page-$selected')),
                    ],
                  ),
                  bottomNavigationBar: rail ? null : navigation(),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('navigation-1')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('navigation-0')));
        await tester.pumpAndSettle();
        expect(find.text('page-0'), findsOneWidget);
        for (final index in [2, 3, 4]) {
          await tester.tap(find.byKey(ValueKey('navigation-$index')));
          await tester.pumpAndSettle();
          expect(find.text('page-$index'), findsOneWidget);
        }
        if (!rail) {
          final first = tester.getCenter(
            find.byKey(const ValueKey('navigation-0')),
          );
          final downloads = tester.getCenter(
            find.byKey(const ValueKey('navigation-3')),
          );
          await tester.dragFrom(first, downloads - first);
          await tester.pumpAndSettle();
          expect(find.text('page-3'), findsOneWidget);
        }
        final before = selected;
        update(() => hidden = false);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('navigation-1')), findsOneWidget);
        expect(find.text('page-$before'), findsOneWidget);
        update(() => hidden = true);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('navigation-1')), findsNothing);
        expect(find.text('page-$before'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'press previews the touched tab without switching; cancellation rolls back',
    (tester) async {
      await render(tester, reduceMotion: false);
      final target = tester.getCenter(
        find.byKey(const ValueKey('navigation-2')),
      );
      final gesture = await tester.startGesture(target);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('page-0'), findsOneWidget);
      expect(
        tester.getCenter(find.byKey(const Key('navigation-lens'))).dx,
        closeTo(target.dx, 1),
      );
      final transform = tester.widget<Transform>(
        find.byKey(const Key('navigation-lens-transform')),
      );
      expect(transform.transform.storage[0], lessThan(1.10));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(find.text('page-0'), findsOneWidget);
      final original = tester.getCenter(
        find.byKey(const ValueKey('navigation-0')),
      );
      expect(
        tester.getCenter(find.byKey(const Key('navigation-lens'))).dx,
        closeTo(original.dx, 1),
      );
    },
  );

  testWidgets(
    'mouse hover never changes tabs and keyboard activation still works',
    (tester) async {
      await render(tester, reduceMotion: false);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('navigation-3'))),
      );
      await tester.pumpAndSettle();
      expect(find.text('page-0'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('page-1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'transfer badge follows both queues and completion only appears once',
    (tester) async {
      final transfers = ValueNotifier(
        const NavigationTransferStatus(completion: 7),
      );
      addTearDown(transfers.dispose);
      await render(tester, transfers: transfers, scale: 2);
      expect(
        find.byKey(const Key('navigation-transfer-complete')),
        findsNothing,
      );
      transfers.value = const NavigationTransferStatus(
        downloads: 1,
        uploads: 2,
        progress: 42,
        completion: 7,
      );
      await tester.pumpAndSettle();
      expect(find.text('3'), findsOneWidget);
      expect(
        find.byKey(const Key('navigation-transfer-progress')),
        findsOneWidget,
      );
      transfers.value = const NavigationTransferStatus(completion: 8);
      await tester.pump();
      expect(
        find.byKey(const Key('navigation-transfer-complete')),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('navigation-transfer-complete')),
        findsNothing,
      );
      expect(find.byKey(const Key('navigation-transfer-count')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('navigation-3')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('navigation-transfer-complete')),
        findsNothing,
      );
      transfers.value = const NavigationTransferStatus(
        uploads: 1,
        completion: 8,
      );
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
