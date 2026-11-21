import 'dart:async';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/main.dart' show appTheme;
import 'package:asterlink/ui/batch_share_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [const Size(320, 700), const Size(1100, 780)]) {
    testWidgets('batch stop retains links and fits $size with large text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final pending = Completer<ShareCreation>();
      final calls = <String>[];
      String? copied;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('打开'),
                onPressed: () => showDialog<void>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => BatchShareDialog(
                    files: const [
                      CloudFile(id: 'a', name: '视频A.mp4'),
                      CloudFile(id: 'b', name: '视频B.mp4'),
                      CloudFile(id: 'c', name: '视频C.mp4'),
                    ],
                    options: const ShareOptions(''),
                    guard: () {},
                    create: (file, options) async {
                      calls.add(file.id);
                      if (file.id == 'b') return pending.future;
                      return ShareCreation(
                        'https://share.test/a',
                        '1234',
                        file.name,
                      );
                    },
                    copy: (text) async => copied = text,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('已处理 1/3'), findsOneWidget);
      expect(find.text('正在逐个创建分享'), findsOneWidget);
      final context = tester.element(find.byType(BatchShareDialog));
      expect(await Navigator.of(context).maybePop(), isTrue);
      await tester.pump();
      expect(find.byType(BatchShareDialog), findsOneWidget);
      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();
      expect(find.text('批量分享结果'), findsOneWidget);
      expect(calls, ['a', 'b']);
      await tester.scrollUntilVisible(
        find.textContaining('结果未确认'),
        100,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.textContaining('结果未确认'), findsOneWidget);
      await tester.tap(find.text('复制全部分享'));
      await tester.pumpAndSettle();
      expect(copied, contains('https://share.test/a'));
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      pending.complete(const ShareCreation('late', '', 'b'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
