import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/baidu_download_prompt.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'remembered Baidu notice survives unrelated settings and app reconstruction',
    (tester) async {
      final active = <AppServices>[];
      var confirmed = 0;
      Future<AppServices> render(
        StateStore store,
        CloudPlatform platform,
      ) async {
        final services = AppServices(
          store: store,
          dataDirectory: Directory('test-fixture'),
          cacheDirectory: Directory('test-fixture/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('test-fixture/saved')),
          http: FakeHttp(),
          platformFeatures: false,
          controlEnabled: false,
        );
        active.add(services);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    if (await confirmBaiduDownload(
                      context,
                      services,
                      platform,
                    )) {
                      confirmed++;
                    }
                  },
                  child: const Text('下载文件'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return services;
      }

      try {
        final services = await render(StateStore.memory(), CloudPlatform.baidu);
        await tester.tap(find.text('下载文件'));
        await tester.pumpAndSettle();
        expect(confirmed, 0);
        expect(
          find.text(
            '百度网盘风控严重，下载存在一定风险可能导致账号被限制，请自行权衡，另外尽量不要一次性下载太多文件易导致下载失败。\n\n'
            '下载单个文件大于 1 GB 时会限速。',
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('不再显示'));
        await tester.pumpAndSettle();
        expect(confirmed, 1);
        expect(services.settings.hideBaiduDownloadNotice, isTrue);
        await services.updateSettings({'threads': 32});
        await render(
          StateStore.memory(services.store.data),
          CloudPlatform.baidu,
        );
        await tester.tap(find.text('下载文件'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(confirmed, 2);
        await render(StateStore.memory(), CloudPlatform.quark);
        await tester.tap(find.text('下载文件'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(confirmed, 3);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        for (final services in active) {
          await services.close();
        }
      }
    },
  );

  test('Baidu notice preference survives encrypted state reopening', () async {
    final directory = await Directory.systemTemp.createTemp('baidu-notice-');
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    StateStore? first, reopened;
    try {
      expect(const AppSettings().hideBaiduDownloadNotice, isFalse);
      first = await StateStore.open(directory, testKey: key);
      await first.put(
        'settings',
        const AppSettings(hideBaiduDownloadNotice: true).toJson(),
      );
      reopened = await StateStore.open(directory, testKey: key);
      final settings = AppSettings.fromJson(
        Map<String, dynamic>.from(reopened.data['settings'] as Map),
      );
      expect(settings.hideBaiduDownloadNotice, isTrue);
      expect(settings.hideGuestDownloadNotice, isFalse);
    } finally {
      first?.dispose();
      reopened?.dispose();
      await directory.delete(recursive: true);
    }
  });
}
