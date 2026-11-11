import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/ui/app_switch.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_shutdown.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/platform/windows_actions.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/ui/text_preview.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Windows previews text, plays videos and preserves explicit Explorer actions',
    (tester) async {
      final calls = <(String, List<String>)>[];
      final played = <String>[];
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('wenxi-download-ui-'),
      ))!;
      final path = p.join(root.path, '视频 (1).mp4');
      final document = p.join(root.path, '说明.txt');
      await tester.runAsync(() => File(path).writeAsString('fixture'));
      await tester.runAsync(() => File(document).writeAsString('fixture'));
      final services = (await tester.runAsync(() async {
        final services = AppServices(
          controlEnabled: false,
          store: StateStore.memory({
            'tasks': [
              DownloadTask(
                id: 'document',
                spec: const DownloadSpec(
                  url: 'https://example.invalid/doc',
                  fileName: '说明.txt',
                ),
                createdAt: 3,
                status: DownloadStatus.completed,
                savedPath: document,
              ).toJson(),
              DownloadTask(
                id: 'saved',
                spec: const DownloadSpec(
                  url: 'https://example.invalid/a',
                  fileName: '视频 (1).mp4',
                ),
                createdAt: 2,
                status: DownloadStatus.completed,
                savedPath: path,
              ).toJson(),
              const DownloadTask(
                id: 'pending',
                spec: DownloadSpec(
                  url: 'https://example.invalid/b',
                  fileName: '未完成.mp4',
                ),
                createdAt: 1,
                status: DownloadStatus.paused,
              ).toJson(),
            ],
          }),
          dataDirectory: root,
          cacheDirectory: Directory(p.join(root.path, 'cache')),
          transport: FakeNative(),
          files: FakeFiles(Directory(p.join(root.path, 'saved'))),
          http: FakeHttp(),
          platformFeatures: false,
          windowsActions: WindowsActions(
            supported: true,
            start: (command, arguments) async =>
                calls.add((command, arguments)),
            run: (_, _) async =>
                fail('Widget must not really request shutdown'),
          ),
        );
        await services.downloads.initialize();
        return services;
      }))!;
      try {
        tester.view.physicalSize = const Size(1100, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: DownloadsPage(
                services,
                onPlay: (task) async => played.add(task.id),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('下载完成后'), findsOneWidget);
        expect(find.text('关机'), findsOneWidget);
        expect(services.downloadShutdown.enabled, isFalse);
        await tester.tap(
          find.byKey(const Key('download-completion-hibernate')),
        );
        await tester.pumpAndSettle();
        expect(
          services.downloadShutdown.action,
          DownloadCompletionAction.hibernate,
        );
        expect(find.text('休眠'), findsOneWidget);
        expect(services.downloadShutdown.enabled, isFalse);
        final powerSwitch = find.descendant(
          of: find.byKey(const Key('download-shutdown-option')),
          matching: find.byType(AppSwitch),
        );
        await tester.tap(powerSwitch);
        await tester.pumpAndSettle();
        expect(services.downloadShutdown.enabled, isTrue);
        await tester.tap(powerSwitch);
        await tester.pumpAndSettle();
        expect(services.downloadShutdown.enabled, isFalse);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final (size, scale) in [
          (const Size(320, 700), 1.8),
          (const Size(1100, 780), 1.0),
        ]) {
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpAndSettle();
          expect(
            find
                .byKey(const Key('download-completion-hibernate'))
                .hitTestable(),
            findsOneWidget,
          );
          expect(powerSwitch.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byTooltip('预览文本'));
        for (
          var i = 0;
          i < 100 && find.byType(TextPreview).evaluate().isEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(find.byType(TextPreview), findsOneWidget);
        expect(find.text('fixture'), findsOneWidget);
        expect(calls, isEmpty);
        Navigator.of(tester.element(find.byType(LocalTextPreviewPage))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('说明.txt'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('打开所在文件夹'));
        for (var i = 0; i < 100 && calls.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
        expect(calls.single.$1, 'explorer.exe');
        expect(calls.single.$2, ['/select,', document]);
        expect(find.byType(PlayerPage), findsNothing);
        await tester.tap(find.byTooltip('播放视频'));
        await tester.pumpAndSettle();
        expect(played, ['saved']);
        expect(calls.length, 1);
        await tester.tap(find.text('视频 (1).mp4'));
        await tester.pumpAndSettle();
        expect(find.text('打开所在文件夹'), findsOneWidget);
        expect(find.text('播放视频'), findsOneWidget);
        Navigator.of(tester.element(find.text('播放视频'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('未完成.mp4'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('download-stream-play')), findsOneWidget);
        expect(find.text('边下边播'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'HLS download details and context menu explain independent online playback',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('asterlink-hls-download-ui-'),
      ))!;
      final services = (await tester.runAsync(() async {
        final services = AppServices(
          controlEnabled: false,
          store: StateStore.memory({
            'tasks': [
              const DownloadTask(
                id: 'hls',
                createdAt: 1,
                status: DownloadStatus.paused,
                spec: DownloadSpec(
                  url: 'https://example.invalid/playlist.m3u8',
                  fileName: '连续剧.ts',
                ),
                hls: {'fingerprint': 'fixture', 'index': 1, 'bytes': 1024},
              ).toJson(),
            ],
          }),
          dataDirectory: root,
          cacheDirectory: Directory('${root.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('${root.path}/saved')),
          http: FakeHttp(),
          platformFeatures: false,
        );
        await services.downloads.initialize();
        return services;
      }))!;
      try {
        tester.view.physicalSize = const Size(1100, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(body: DownloadsPage(services)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('连续剧.ts'));
        await tester.pumpAndSettle();
        expect(find.text('在线播放'), findsOneWidget);
        expect(find.text('播放与下载独立取流，不复用已下载片段'), findsOneWidget);
        expect(find.text('边下边播'), findsNothing);
        Navigator.of(tester.element(find.text('在线播放'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('连续剧.ts'), buttons: 2);
        await tester.pumpAndSettle();
        expect(find.text('在线播放'), findsOneWidget);
        expect(find.text('边下边播'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await services.close();
          await root.delete(recursive: true);
        });
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
