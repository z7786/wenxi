import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/completed_file_actions.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'support.dart';

class _FileActions extends CompletedFileActions {
  final calls = <(String, String, String)>[];
  Completer<void>? pending;
  @override
  Future<void> openWith(String path, String name, {Rect? origin}) async {
    calls.add(('open-with', path, name));
    if (pending != null) await pending!.future;
  }

  @override
  Future<void> share(String path, String name, {Rect? origin}) async {
    calls.add(('share', path, name));
    expect(origin, isNotNull);
    expect(origin!.isEmpty, isFalse);
    if (pending != null) await pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<
    ({
      AppServices services,
      FakeFiles files,
      _FileActions actions,
      List<String> played,
    })
  >
  render(
    WidgetTester tester, {
    Size size = const Size(393, 864),
    double textScale = 1,
  }) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('wenxi-file-actions-'),
    ))!;
    final files = FakeFiles(Directory('${root.path}/saved'));
    final actions = _FileActions();
    final played = <String>[];
    final services = (await tester.runAsync(() async {
      final value = AppServices(
        controlEnabled: false,
        store: StateStore.memory({
          'tasks': [
            for (final name in [
              'movie.mp4',
              'app.apk',
              'notes.txt',
              'archive.zip',
            ])
              DownloadTask(
                id: name.replaceAll('.', '-'),
                spec: DownloadSpec(
                  url: 'https://example.test/$name',
                  fileName: name,
                ),
                createdAt: 1,
                status: DownloadStatus.completed,
                savedPath: '${root.path}/$name',
              ).toJson(),
            const DownloadTask(
              id: 'unfinished',
              spec: DownloadSpec(
                url: 'https://example.test/pending',
                fileName: 'pending.mp4',
              ),
              createdAt: 0,
              status: DownloadStatus.paused,
            ).toJson(),
          ],
        }),
        dataDirectory: root,
        cacheDirectory: Directory('${root.path}/cache'),
        transport: FakeNative(),
        files: files,
        http: FakeHttp(),
        platformFeatures: false,
      );
      await value.downloads.initialize();
      return value;
    }))!;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DownloadsPage(
            services,
            fileActions: actions,
            onPlay: (task) async => played.add(task.id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      if (actions.pending?.isCompleted == false) actions.pending!.complete();
      actions.pending = null;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await services.close();
        await root.delete(recursive: true);
      });
    });
    return (services: services, files: files, actions: actions, played: played);
  }

  Future<void> choose(WidgetTester tester, String id, String label) async {
    await tester.tap(
      find.byKey(ValueKey('download-file-actions-${id.replaceAll('.', '-')}')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Completed APK, video, text and archives expose sharing and app selection',
    (tester) async {
      final fixture = await render(tester);
      for (final name in ['app.apk', 'movie.mp4', 'notes.txt', 'archive.zip']) {
        await choose(tester, name, '用其他应用打开');
        expect(fixture.actions.calls.last.$1, 'open-with');
        expect(fixture.actions.calls.last.$3, name);
        await choose(tester, name, '分享文件');
        expect(fixture.actions.calls.last.$1, 'share');
        expect(fixture.actions.calls.last.$3, name);
      }
      expect(fixture.played, isEmpty);
      expect(
        find.byKey(const ValueKey('download-file-actions-unfinished')),
        findsNothing,
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Details include app selection while the existing video play button still plays',
    (tester) async {
      final fixture = await render(tester);
      await tester.tap(find.byKey(const ValueKey('download-row-movie-mp4')));
      await tester.pumpAndSettle();
      expect(find.text('分享文件'), findsOneWidget);
      await tester.tap(find.text('用其他应用打开'));
      await tester.pumpAndSettle();
      expect(fixture.actions.calls.single.$1, 'open-with');
      final row = find.byKey(const ValueKey('download-row-movie-mp4'));
      await tester.tap(
        find.descendant(of: row, matching: find.byType(IconButton)).first,
      );
      await tester.pumpAndSettle();
      expect(fixture.played, ['movie-mp4']);
    },
  );

  testWidgets('Missing or newly removed files never get sent to another app', (
    tester,
  ) async {
    final fixture = await render(tester);
    await tester.tap(
      find.byKey(const ValueKey('download-file-actions-app-apk')),
    );
    await tester.pumpAndSettle();
    fixture.files.availability[fixture.services.downloads
            .task('app-apk')!
            .savedPath!] =
        FileAvailability.missing;
    await tester.tap(find.text('分享文件'));
    await tester.pumpAndSettle();
    expect(fixture.actions.calls, isEmpty);
    expect(
      find.byKey(const ValueKey('download-file-actions-app-apk')),
      findsNothing,
    );
    expect(find.text('用其他应用打开'), findsNothing);
    expect(find.text('移除下载记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Pending system sharing keeps the page usable without opening a second share dialog',
    (tester) async {
      final fixture = await render(tester);
      fixture.actions.pending = Completer<void>();
      await choose(tester, 'app.apk', '分享文件');
      expect(find.byType(AlertDialog), findsNothing);
      await choose(tester, 'movie.mp4', '用其他应用打开');
      expect(fixture.actions.calls, hasLength(1));
      fixture.actions.pending!.complete();
      fixture.actions.pending = null;
      await tester.pumpAndSettle();
      await choose(tester, 'movie.mp4', '用其他应用打开');
      expect(fixture.actions.calls, hasLength(2));
    },
  );

  testWidgets(
    'More file actions remain reachable on narrow screens with large text',
    (tester) async {
      await render(tester, size: const Size(320, 700), textScale: 1.8);
      await choose(tester, 'app.apk', '用其他应用打开');
      expect(tester.takeException(), isNull);
    },
  );
}
