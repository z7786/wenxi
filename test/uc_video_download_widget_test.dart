import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'package:asterlink/ui/uc_video_download.dart';
import 'package:asterlink/data/http.dart';
import 'app_context_menu_test.dart' show rightClick;
import 'support.dart';
import 'uc_tv_support.dart';
import 'uc_video_download_support.dart';

void main() {
  Future<void> closeFixture(
    WidgetTester tester,
    AppServices services,
    Directory directory,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    final closing = services.close().then((_) => closed = true);
    for (var i = 0; i < 200 && !closed; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(closed, isTrue);
    await closing;
    await tester.runAsync(() => directory.delete(recursive: true));
  }

  AppServices createServices(UcTvFixture f, Directory directory) {
    final services = AppServices(
      controlEnabled: false,
      platformFeatures: false,
      store: f.store,
      dataDirectory: directory,
      cacheDirectory: Directory('${directory.path}/cache'),
      http: f.http,
      transport: FakeNative()..finish = false,
      files: FakeFiles(Directory('${directory.path}/saved')),
    );
    // The services repository must own the preparation cleanup lease.
    final connector = services.cloud.connector(CloudPlatform.uc);
    f.repository.connectors[CloudPlatform.uc] = connector;
    return services;
  }

  Future<void> renderButton(
    WidgetTester tester,
    AppServices services, {
    BrowseSession session = ucTvPersonal,
    bool pending = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => downloadUcPlayable(
                context,
                services,
                session: session,
                file: ucTvVideo,
              ),
              child: const Text('取视频'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('取视频'));
    if (pending) {
      await tester.pump(const Duration(milliseconds: 300));
    } else {
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'Quality and dimensions appear before confirmation, cancelling queues nothing',
    (tester) async {
      final f = ucPlayableFixture(),
          dir = Directory.systemTemp.createTempSync('uc-playable-ui-');
      final services = createServices(f, dir);
      try {
        await renderButton(tester, services);
        expect(find.textContaining('画质：流畅'), findsOneWidget);
        expect(find.textContaining('分辨率：270×480'), findsOneWidget);
        expect(find.textContaining('大小：120 B'), findsOneWidget);
        expect(find.text('下载流畅版本'), findsOneWidget);
        expect(find.textContaining('画质可能低于原文件'), findsOneWidget);
        expect(services.downloads.tasks, isEmpty);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(services.downloads.tasks, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await closeFixture(tester, services, dir);
      }
    },
  );

  testWidgets(
    'Segmented quality confirmation shows estimated size and actual container',
    (tester) async {
      final f = ucPlayableFixture(),
          dir = Directory.systemTemp.createTempSync('uc-hls-ui-');
      final services = createServices(f, dir);
      f.respond = (r) {
        if (r.uri.path.endsWith('/v2/play')) {
          final track = ucPlayableItem(
            url: 'https://video-play.drive.uc.cn/list.m3u8',
          );
          return ucPlayableResponse(
            items: [
              {
                ...track,
                'supports_format': 'p_qv',
                'video_info': {...track.obj('video_info'), 'format': 'm3u8'},
              },
            ],
          );
        }
        if (r.uri.host == 'video-play.drive.uc.cn') {
          return const HttpResult(
            200,
            '#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n',
          );
        }
        return null;
      };
      try {
        await renderButton(tester, services);
        expect(find.textContaining('预计大小：120 B'), findsOneWidget);
        expect(find.textContaining('保存格式：TS'), findsOneWidget);
        expect(find.textContaining('视频（流畅 270×480）.ts'), findsOneWidget);
        expect(services.downloads.tasks, isEmpty);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(services.downloads.tasks, isEmpty);
      } finally {
        await closeFixture(tester, services, dir);
      }
    },
  );

  testWidgets(
    'Confirming creates a labelled task using the transcode size and no original checksum',
    (tester) async {
      final f = ucPlayableFixture(),
          dir = Directory.systemTemp.createTempSync('uc-playable-ui-');
      final services = createServices(f, dir);
      try {
        await renderButton(tester, services);
        await tester.tap(find.byKey(const Key('uc-playable-confirm')));
        await tester.pumpAndSettle();
        final task = services.downloads.tasks.single;
        expect(task.spec.fileName, '视频（流畅 270×480）.mp4');
        expect(task.spec.expectedSize, 120);
        expect(task.spec.checksumValue, isNull);
        expect(task.spec.source!['ucVideo']['resolution'], 'low');
        expect(tester.takeException(), isNull);
      } finally {
        await closeFixture(tester, services, dir);
      }
    },
  );

  testWidgets(
    'Account changes while the confirmation dialog is open cannot queue old credentials',
    (tester) async {
      final f = ucPlayableFixture(),
          dir = Directory.systemTemp.createTempSync('uc-playable-ui-');
      final services = createServices(f, dir);
      try {
        await renderButton(tester, services);
        await f.vault.putCredential(
          CloudPlatform.uc,
          ucTvCredential(authorized: false, revision: 9),
        );
        await tester.tap(find.byKey(const Key('uc-playable-confirm')));
        await tester.pumpAndSettle();
        expect(services.downloads.tasks, isEmpty);
        expect(find.textContaining('UC 账号已变化'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await closeFixture(tester, services, dir);
      }
    },
  );

  testWidgets(
    'Cancelling a pending preparation queues nothing and never opens a quality dialog',
    (tester) async {
      final f = ucPlayableFixture(),
          dir = Directory.systemTemp.createTempSync('uc-playable-ui-');
      final services = createServices(f, dir);
      final reply = Completer<HttpResult>(), normal = f.respond!;
      f.respond = (r) =>
          r.uri.path.endsWith('/v2/play') ? reply.future : normal(r);
      try {
        await renderButton(tester, services, pending: true);
        expect(find.text('正在获取可播放版本…'), findsOneWidget);
        await tester.tap(find.text('取消'));
        reply.complete(ucPlayableResponse());
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('uc-playable-confirm')), findsNothing);
        expect(services.downloads.tasks, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await closeFixture(tester, services, dir);
      }
    },
  );

  testWidgets(
    'Share quality confirmation cancelled by the user releases its temporary folder',
    (tester) async {
      final f = ucPlayableFixture(),
          dir = Directory.systemTemp.createTempSync('uc-playable-ui-');
      final services = createServices(f, dir);
      try {
        await renderButton(tester, services, session: ucTvShare);
        expect(find.byKey(const Key('uc-playable-confirm')), findsOneWidget);
        expect(services.cleanups.pendingCount, 1);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(services.downloads.tasks, isEmpty);
        expect(f.calls('/1/clouddrive/file/delete'), isNotEmpty);
        expect(services.cleanups.pendingCount, 0);
      } finally {
        await closeFixture(tester, services, dir);
      }
    },
  );

  for (final desktop in [false, true]) {
    testWidgets(
      'UC file menu exposes the playable option on ${desktop ? 'Windows' : 'Android'}',
      (tester) async {
        final f = ucPlayableFixture(),
            dir = Directory.systemTemp.createTempSync('uc-playable-ui-');
        final services = createServices(f, dir);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = desktop
            ? const Size(1100, 900)
            : const Size(393, 864);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: BrowserPage(
                services,
                ucTvPersonal,
                initialItems: const [ucTvVideo],
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (desktop) {
            await rightClick(
              tester,
              tester.getCenter(find.text(ucTvVideo.name)),
            );
          } else {
            await tester.tap(find.byTooltip('${ucTvVideo.name}操作'));
            await tester.pumpAndSettle();
          }
          expect(find.text('下载可播放版本'), findsOneWidget);
          await tester.tap(find.text('下载可播放版本'));
          await tester.pumpAndSettle();
          expect(find.textContaining('画质：流畅'), findsOneWidget);
          expect(services.downloads.tasks, isEmpty);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        } finally {
          await closeFixture(tester, services, dir);
        }
      },
      variant: TargetPlatformVariant.only(
        desktop ? TargetPlatform.windows : TargetPlatform.android,
      ),
    );
  }

  testWidgets(
    'A failed original task can start the separate playable download flow',
    (tester) async {
      final f = ucPlayableFixture(),
          dir = Directory.systemTemp.createTempSync('uc-playable-ui-');
      final services = createServices(f, dir);
      try {
        final failed = DownloadTask(
          id: 'failed-original',
          spec: f.repository.planDownload(ucTvPersonal, ucTvVideo),
          createdAt: 1,
          status: DownloadStatus.failed,
          recoveryAction: DownloadRecoveryAction.ucAuthorization,
          error: 'UC 返回的内容与所选文件不一致',
        );
        await f.store.change((draft) => draft['tasks'] = [failed.toJson()]);
        await services.downloads.initialize();
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: DownloadsPage(services))),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(ucTvVideo.name));
        await tester.pumpAndSettle();
        final option = find.text('下载可播放版本');
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
        expect(find.textContaining('画质：流畅'), findsOneWidget);
        expect(services.downloads.tasks.single.id, 'failed-original');
        expect(services.downloads.tasks.single.status, DownloadStatus.failed);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        await closeFixture(tester, services, dir);
      }
    },
  );
}
