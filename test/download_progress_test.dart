import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/download_progress.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'package:asterlink/upload/upload_folder.dart';
import 'download_overlay_test.dart' show uploadTask;

DownloadTask task({
  DownloadStatus status = DownloadStatus.running,
  int received = 25,
  int total = 100,
  int speed = 100,
  bool ready = false,
  String phase = '',
}) => DownloadTask(
  id: 'progress',
  spec: const DownloadSpec(
    url: 'https://example.test/file',
    fileName: 'sample.bin',
  ),
  status: status,
  createdAt: 1,
  downloaded: received,
  total: total,
  speed: speed,
  payloadReady: ready,
  phase: phase,
);

void main() {
  testWidgets('folder preparation keeps completed bytes visible', (
    tester,
  ) async {
    final source = uploadTask('folder-progress');
    final plan = UploadFolder(
      location: 'local',
      name: '资料',
      files: [
        UploadFolderFile(
          location: 'local/one',
          relativePath: 'one.txt',
          size: 40,
          modifiedAt: 0,
          fileId: 'done',
        ),
        UploadFolderFile(
          location: 'local/two',
          relativePath: 'two.txt',
          size: 60,
          modifiedAt: 0,
        ),
      ],
    );
    final upload = UploadTask(
      id: source.id,
      session: source.session,
      parent: source.parent,
      folderName: source.folderName,
      accountName: source.accountName,
      path: plan.location,
      name: plan.name,
      size: plan.size,
      modifiedAt: 0,
      createdAt: 1,
      folder: plan,
      status: UploadStatus.running,
      phase: UploadPhase.preparing,
      sent: plan.completedBytes,
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: TransferProgress.upload(upload))),
    );
    await tester.pump();
    final dynamic paint = tester
        .widget<CustomPaint>(
          find.byKey(ValueKey('upload-progress-paint-${upload.id}')),
        )
        .painter;
    expect(paint.fill.value, .4);
    expect(find.text('准备中'), findsOneWidget);
    expect(paint.flowing, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Mutable uploads animate byte changes and wait for provider confirmation',
    (tester) async {
      final upload = uploadTask('progress');
      Future<void> renderUpload() async {
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TransferProgress.upload(upload))),
        );
        await tester.pump();
      }

      dynamic uploadPainter() => tester
          .widget<CustomPaint>(
            find.byKey(const ValueKey('upload-progress-paint-progress')),
          )
          .painter;
      await renderUpload();
      expect(uploadPainter().fill.value, .5);
      upload.sent = 80;
      await renderUpload();
      await tester.pump(const Duration(milliseconds: 100));
      expect(uploadPainter().fill.value, greaterThan(.5));
      expect(uploadPainter().fill.value, lessThan(.8));
      upload.phase = UploadPhase.finishing;
      upload.sent = 100;
      await renderUpload();
      expect(find.text('确认中'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      expect(uploadPainter().flowing, isFalse);
      upload.status = UploadStatus.completed;
      await renderUpload();
      expect(find.text('已完成'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(
        find
            .byType(CustomPaint)
            .evaluate()
            .where(
              (e) =>
                  e.widget.key ==
                  const ValueKey('upload-progress-paint-progress'),
            ),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  Future<void> render(
    WidgetTester tester,
    DownloadTask task, {
    bool enabled = true,
    bool reduce = false,
    bool tickers = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduce),
          child: TickerMode(
            enabled: tickers,
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 280,
                  child: DownloadProgress(task: task, enabled: enabled),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  dynamic painter(WidgetTester tester) => tester
      .widget<CustomPaint>(
        find.byKey(
          const ValueKey('download-progress-paint-progress'),
          skipOffstage: false,
        ),
      )
      .painter;
  Future<void> dispose(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox());

  testWidgets('Bytes advance smoothly without overshooting actual progress', (
    tester,
  ) async {
    await render(tester, task());
    expect(painter(tester).flowing, isTrue);
    await render(tester, task(received: 65));
    await tester.pump(const Duration(milliseconds: 100));
    final double value = painter(tester).fill.value;
    expect(value, greaterThan(.25));
    expect(value, lessThan(.65));
    await tester.pump(const Duration(milliseconds: 300));
    expect(painter(tester).fill.value, .65);
    expect(find.text('65%'), findsOneWidget);
    await dispose(tester);
  });
  testWidgets('A stale nonzero speed stops shimmering after three seconds', (
    tester,
  ) async {
    await render(tester, task());
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(find.text('等待数据'), findsOneWidget);
    expect(painter(tester).flowing, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await render(tester, task(received: 30));
    expect(painter(tester).flowing, isTrue);
    expect(find.text('30%'), findsOneWidget);
    await dispose(tester);
  });
  testWidgets('Pause and failure retain bytes but stop all moving effects', (
    tester,
  ) async {
    await render(tester, task());
    for (final status in [DownloadStatus.paused, DownloadStatus.failed]) {
      await render(tester, task(status: status));
      expect(painter(tester).fill.value, .25);
      expect(painter(tester).flowing, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
    }
    await dispose(tester);
  });
  testWidgets('Retry resets the bar immediately to the real byte count', (
    tester,
  ) async {
    await render(tester, task(received: 80));
    await render(tester, task(received: 10));
    expect(painter(tester).fill.value, .1);
    await dispose(tester);
  });
  testWidgets(
    'Saving is not completion and history does not replay celebration',
    (tester) async {
      await render(tester, task(received: 100, phase: '校验文件', speed: 0));
      expect(find.text('处理中'), findsOneWidget);
      expect(painter(tester).flowing, isFalse);
      await render(tester, task(received: 100, ready: true, speed: 0));
      expect(find.text('处理中'), findsOneWidget);
      expect(find.text('已完成'), findsNothing);
      expect(painter(tester).flowing, isFalse);
      await render(
        tester,
        task(received: 100, status: DownloadStatus.completed),
      );
      expect(find.text('已完成'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1200));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('download-progress-paint-progress')),
        findsNothing,
      );
      await dispose(tester);
      await render(
        tester,
        task(received: 100, status: DownloadStatus.completed),
      );
      expect(find.text('已完成'), findsNothing);
      await dispose(tester);
    },
  );
  testWidgets('Unknown file size never invents a percentage', (tester) async {
    await render(tester, task(total: 0));
    expect(find.text('大小未知'), findsOneWidget);
    expect(painter(tester).unknown, isTrue);
    expect(painter(tester).fill.value, 0);
    await dispose(tester);
  });
  testWidgets(
    'Inactive, reduced-motion and disabled ticker contexts stop repaint loops',
    (tester) async {
      await render(tester, task());
      await render(tester, task(), enabled: false);
      expect(painter(tester).flowing, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await render(tester, task(received: 30), reduce: true);
      expect(painter(tester).flowing, isFalse);
      expect(painter(tester).fill.value, .3);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await render(tester, task(received: 40), tickers: false);
      expect(painter(tester).flowing, isFalse);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await dispose(tester);
    },
  );
  testWidgets('Cached rows outside the scroll viewport do not animate', (
    tester,
  ) async {
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 140,
            child: ListView(
              controller: scroll,
              cacheExtent: 1000,
              children: [
                DownloadProgress(task: task()),
                const SizedBox(height: 900),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(painter(tester).flowing, isTrue);
    scroll.jumpTo(450);
    await tester.pump();
    await tester.pump();
    expect(painter(tester).flowing, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
    scroll.jumpTo(0);
    await tester.pump();
    await tester.pump();
    expect(painter(tester).flowing, isTrue);
    await dispose(tester);
    scroll.dispose();
  });
}
