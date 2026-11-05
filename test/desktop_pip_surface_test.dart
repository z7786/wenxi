import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/platform/windows_pip.dart';
import 'package:asterlink/ui/desktop_pip_surface.dart';

void main() {
  for (final aspect in [16 / 9, 4 / 3, 9 / 16, 21 / 9, .3]) {
    test('PiP window and minimum size preserve video ratio $aspect', () {
      final size = desktopPipWindowSize(aspect);
      final minimum = desktopPipMinimumSize(aspect);
      expect(size.aspectRatio, closeTo(aspect, .0001));
      expect(size.height, lessThanOrEqualTo(540));
      expect(minimum.width, lessThanOrEqualTo(size.width));
      expect(minimum.height, lessThanOrEqualTo(size.height));
    });
  }

  for (final size in [
    const Size(480, 270),
    const Size(270, 480),
    const Size(240, 135),
  ]) {
    testWidgets(
      'PiP controls use the whole video viewport and disappear at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var toggles = 0, closes = 0;
        Duration? sought;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DesktopPipSurface(
                video: const ColoredBox(color: Color(0xff2468ac)),
                playing: true,
                position: const Duration(seconds: 30),
                duration: const Duration(minutes: 3),
                onToggle: () => toggles++,
                onSeek: (position) => sought = position,
                onDrag: () {},
                onResize: (_) {},
                onClose: () => closes++,
              ),
            ),
          ),
        );
        await tester.pump();
        final video = find.byKey(const Key('desktop-pip-video'));
        expect(tester.getRect(video), Offset.zero & size);
        expect(find.text('文析助手'), findsNothing);
        expect(find.byTooltip('关闭画中画').hitTestable(), findsOneWidget);
        final slider = tester.widget<Slider>(
          find.byKey(const Key('player-pip-seek')),
        );
        slider.onChangeStart!(60000);
        slider.onChanged!(60000);
        await tester.pump(const Duration(seconds: 3));
        expect(find.byKey(const Key('player-pip-seek')), findsOneWidget);
        expect(sought, isNull);
        slider.onChangeEnd!(60000);
        await tester.pump();
        expect(sought, const Duration(minutes: 1));
        await tester.pump(const Duration(seconds: 2));
        expect(find.byKey(const Key('player-pip-toggle')), findsNothing);
        expect(find.byTooltip('关闭画中画'), findsNothing);
        expect(tester.getRect(video), Offset.zero & size);
        await tester.tapAt(Offset(size.width / 2, size.height / 2));
        await tester.pump(const Duration(milliseconds: 350));
        expect(toggles, 1);
        expect(find.byTooltip('关闭画中画').hitTestable(), findsOneWidget);
        await tester.tap(find.byTooltip('关闭画中画'));
        expect(closes, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
