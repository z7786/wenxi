import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'browser_test_support.dart';

class _SharingConnector extends BrowserTestConnector {
  _SharingConnector(super.drive);
  final calls = <(List<CloudFile>, ShareOptions)>[];
  String? failId;
  @override
  Future<ShareCreation> createShare(
    BrowseSession session,
    List<CloudFile> files,
    ShareOptions options,
    Credential? credential,
  ) async {
    calls.add((List.of(files), options));
    if (files.length == 1 && files.single.id == failId) {
      throw const AppException('当前文件分享受限');
    }
    return ShareCreation(
      'https://share.test/${files.map((file) => file.id).join('-')}',
      '1234',
      options.title,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (platform, individual, partial, size) in [
    (CloudPlatform.tianyi, true, false, const Size(393, 864)),
    (CloudPlatform.tianyi, true, true, const Size(1100, 780)),
    (CloudPlatform.tianyi, false, false, const Size(393, 864)),
    (CloudPlatform.lanzou, true, false, const Size(393, 864)),
    (CloudPlatform.ctfile, true, false, const Size(393, 864)),
  ]) {
    testWidgets(
      '$platform share individual=$individual partial=$partial at $size',
      (tester) async {
        late BrowserUiFixture fixture;
        await tester.runAsync(() async {
          fixture = await BrowserUiFixture.create(platform: platform);
        });
        final connector = _SharingConnector(platform)
          ..failId = partial ? 'video' : null;
        fixture.services.cloud.connectors[platform] = connector;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            if (call.method == 'Clipboard.getData') return {'text': copied};
            if (call.method == 'Clipboard.hasStrings') {
              return {'value': copied != null};
            }
            return null;
          },
        );
        try {
          await fixture.render(tester, size: size);
          if (size.width < 600) {
            await tester.tap(find.text('多选'));
            await tester.pumpAndSettle();
          }
          for (final name in ['使用说明.txt', '02 旅行视频.mp4']) {
            final row = find.ancestor(
              of: find.text(name),
              matching: find.byType(ListTile),
            );
            await tester.tap(
              find.descendant(of: row, matching: find.byType(Checkbox)),
            );
            await tester.pump();
          }
          await tester.ensureVisible(find.widgetWithText(TextButton, '分享'));
          await tester.tap(find.widgetWithText(TextButton, '分享'));
          await tester.pumpAndSettle();
          if (individual && platform == CloudPlatform.tianyi) {
            await tester.tap(find.byType(DropdownButtonFormField<bool>));
            await tester.pumpAndSettle();
            await tester.tap(find.text('单文件批量分享（多个链接）').last);
            await tester.pumpAndSettle();
          }
          if (individual) {
            expect(find.text('分享标题'), findsNothing);
          }
          await tester.ensureVisible(find.widgetWithText(TextButton, '创建'));
          await tester.tap(find.widgetWithText(TextButton, '创建'));
          await tester.pumpAndSettle();
          if (individual) {
            expect(connector.calls.length, 2);
            expect(
              connector.calls.every((call) => call.$1.length == 1),
              isTrue,
            );
            for (final call in connector.calls) {
              expect(call.$2.title, call.$1.single.displayName);
            }
            expect(find.text('批量分享结果'), findsOneWidget);
            expect(
              find.textContaining(partial ? '成功 1 · 失败 1' : '成功 2 · 失败 0'),
              findsOneWidget,
            );
            if (partial) {
              expect(find.textContaining('当前文件分享受限'), findsOneWidget);
            }
            await tester.tap(find.text('复制全部分享'));
            await tester.pumpAndSettle();
            expect(copied, contains('https://share.test/notes'));
            expect(copied!.contains('https://share.test/video'), !partial);
            await tester.tap(find.text('关闭'));
          } else {
            expect(connector.calls.length, 1);
            expect(connector.calls.single.$1.length, 2);
            expect(find.text('分享已创建'), findsOneWidget);
            await tester.tap(find.text('关闭'));
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(fixture.close);
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        }
      },
    );
  }
}
