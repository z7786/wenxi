import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/common.dart';
import 'browser_test_support.dart';

void main() {
  const capture = String.fromEnvironment('FEEDBACK_CAPTURE_DIR');
  bool loadedFont = false;
  setUpAll(() async {
    if (capture.isEmpty) return;
    for (final (family, asset) in [
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
    final font = File('C:/Windows/Fonts/msyh.ttc');
    if (await font.exists()) {
      await (FontLoader('FeedbackFixture')..addFont(
            Future.value(ByteData.sublistView(await font.readAsBytes())),
          ))
          .load();
      loadedFont = true;
    }
  });
  for (final brightness in Brightness.values) {
    for (final size in [const Size(393, 864), const Size(1100, 780)]) {
      testWidgets(
        'Download feedback opens management from nested routes: $brightness $size',
        (tester) async {
          final fixture = await BrowserUiFixture.create();
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = 1.8;
          final navigator = GlobalKey<NavigatorState>();
          final boundary = GlobalKey();
          try {
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundary,
                child: MaterialApp(
                  navigatorKey: navigator,
                  theme: appTheme(
                    brightness,
                    fontFamily: loadedFont ? 'FeedbackFixture' : null,
                  ),
                  home: MainShell(fixture.services, initialTab: 0),
                ),
              ),
            );
            await tester.pumpAndSettle();
            navigator.currentState!.push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('分享文件')),
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => message(
                        context,
                        '已添加 3 个下载任务',
                        onTap: fixture.services.requestDownloadManager,
                      ),
                      child: const Text('开始下载'),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('开始下载'));
            await tester.pumpAndSettle();
            final snack = tester.widget<SnackBar>(find.byType(SnackBar));
            expect(snack.behavior, SnackBarBehavior.floating);
            expect(snack.margin!.resolve(TextDirection.ltr).bottom, 28);
            final button = tester.getRect(find.text('已添加 3 个下载任务'));
            expect(button.bottom, lessThan(size.height - 28));
            expect(
              snack.backgroundColor,
              appTheme(brightness).colorScheme.surface,
            );
            if (capture.isNotEmpty) {
              final rendered =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await rendered.toImage(pixelRatio: 1);
                try {
                  final png = await image.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  await Directory(capture).create(recursive: true);
                  await File(
                    '$capture/feedback-${brightness.name}-${size.width.toInt()}.png',
                  ).writeAsBytes(png!.buffer.asUint8List());
                } finally {
                  image.dispose();
                }
              });
            }
            await tester.tap(find.text('已添加 3 个下载任务'));
            await tester.pumpAndSettle();
            expect(navigator.currentState!.canPop(), isFalse);
            expect(find.text('分享文件'), findsNothing);
            expect(find.byType(SnackBar), findsNothing);
            final indexed = tester.widget<IndexedStack>(
              find.byType(IndexedStack).first,
            );
            expect(indexed.index, 3);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await fixture.close();
          }
        },
      );
    }
  }
}
