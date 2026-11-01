import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/ui/operation_progress_view.dart';

void main() {
  for (final compact in [false, true]) {
    for (final desktop in [false, true]) {
      testWidgets(
        'deletion progress waits for record saving with compact=$compact and desktop=$desktop',
        (tester) async {
          final size = desktop ? const Size(1280, 800) : const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final progress = OperationProgress();
          addTearDown(progress.dispose);
          final release = Completer<void>();
          late Zone deleteZone;
          final work = progress.run(
            () => OperationProgress.step(
              OperationStage.deleteDownloads,
              () async {
                deleteZone = Zone.current;
                OperationProgress.reportItems((
                  processed: 5000,
                  total: 5000,
                  succeeded: 4998,
                  failed: 1,
                  skipped: 0,
                  activity: OperationStage.removeDownloadRecords,
                ));
                await release.future;
              },
              statusForResult: (_) => OperationStepStatus.failed,
            ),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(desktop ? 1 : 1.8),
                ),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: desktop ? 480 : 280,
                      child: OperationProgressView(
                        progress: progress,
                        label: '正在删除 5000 项…',
                        compact: compact,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(find.text('已处理 5000 / 5000 项'), findsOneWidget);
          expect(find.text('正在移除下载记录…'), findsOneWidget);
          expect(find.textContaining('失败 1 项 · 等待保存 1 项'), findsOneWidget);
          expect(
            tester
                .widget<LinearProgressIndicator>(
                  find.byKey(const Key('operation-item-progress')),
                )
                .value,
            lessThan(1),
          );
          deleteZone.run(
            () => OperationProgress.reportItems((
              processed: 5000,
              total: 5000,
              succeeded: 4999,
              failed: 1,
              skipped: 0,
              activity: OperationStage.removeDownloadRecords,
            )),
          );
          release.complete();
          await work;
          await tester.pump();
          expect(find.text('删除下载任务 · 未完成'), findsOneWidget);
          expect(find.text('已删除 4999 项 · 失败 1 项'), findsOneWidget);
          expect(find.textContaining('等待保存'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );

      testWidgets(
        'file read progress wraps on ${desktop ? 'desktop' : 'phone'} with compact=$compact',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = desktop
              ? const Size(1280, 800)
              : const Size(320, 640);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final progress = OperationProgress();
          addTearDown(progress.dispose);
          final release = Completer<void>();
          late Zone readZone;
          final work = progress.run(
            () => OperationProgress.step(OperationStage.readFiles, () async {
              readZone = Zone.current;
              OperationProgress.reportFiles(5200);
              await release.future;
            }),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: desktop ? const Size(1280, 800) : const Size(320, 640),
                  textScaler: TextScaler.linear(desktop ? 1 : 1.8),
                ),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: desktop ? 480 : 280,
                      child: OperationProgressView(
                        progress: progress,
                        label: '正在打开文件夹',
                        compact: compact,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(find.text('正在读取文件列表… · 已读取 5200 项'), findsOneWidget);
          readZone.run(
            () => OperationProgress.reportFiles(5200, waitingForRetry: true),
          );
          await tester.pump();
          expect(find.text('请求较频繁，正在等待重试… · 已读取 5200 项'), findsOneWidget);
          expect(tester.takeException(), isNull);
          release.complete();
          await work;
          await tester.pump();
          expect(find.text('读取文件列表 · 完成 · 已读取 5200 项'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
