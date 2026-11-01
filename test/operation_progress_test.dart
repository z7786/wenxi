import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  test(
    'Item progress deduplicates updates and retains returned failures',
    () async {
      final outer = OperationProgress(), inner = OperationProgress();
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      const items = (
        processed: 3,
        total: 5,
        succeeded: 1,
        failed: 1,
        skipped: 0,
        activity: OperationStage.removeDownloadRecords,
      );
      var reports = 0;
      outer.addListener(() => reports++);
      await outer.run(
        () => inner.run(
          () => OperationProgress.step(
            OperationStage.deleteDownloads,
            () async {
              OperationProgress.reportItems(items);
              final count = reports;
              OperationProgress.reportItems(items);
              OperationProgress.reportItems((
                processed: 6,
                total: 5,
                succeeded: 0,
                failed: 0,
                skipped: 0,
                activity: null,
              ));
              expect(reports, count);
              return false;
            },
            statusForResult: (ok) =>
                ok ? OperationStepStatus.completed : OperationStepStatus.failed,
          ),
        ),
      );
      expect(outer.value.single.items, items);
      expect(inner.value.single.items, items);
      expect(outer.value.single.status, OperationStepStatus.failed);
      expect(inner.value.single.status, OperationStepStatus.failed);
    },
  );

  test(
    'Cancelled item progress freezes and late reports cannot enter a new run',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      final release = Completer<void>(), current = Completer<void>();
      final old = progress.run(
        () => OperationProgress.step(OperationStage.deleteDownloads, () async {
          OperationProgress.reportItems((
            processed: 1,
            total: 3,
            succeeded: 0,
            failed: 0,
            skipped: 0,
            activity: OperationStage.deleteFiles,
          ));
          await release.future;
          OperationProgress.reportItems((
            processed: 3,
            total: 3,
            succeeded: 3,
            failed: 0,
            skipped: 0,
            activity: OperationStage.removeDownloadRecords,
          ));
        }),
      );
      progress.close(cancelled: true);
      expect(progress.value.single.items!.processed, 1);
      expect(progress.value.single.items!.succeeded, 0);
      expect(progress.value.single.status, OperationStepStatus.cancelled);
      final fresh = progress.run(
        () => OperationProgress.step(
          OperationStage.readFiles,
          () => current.future,
        ),
      );
      release.complete();
      await old;
      expect(progress.value.single.items, isNull);
      expect(progress.value.single.status, OperationStepStatus.running);
      current.complete();
      await fresh;
    },
  );

  test('Detached cleanup only reports to its own progress observer', () async {
    final dialog = OperationProgress(), cleanup = OperationProgress();
    addTearDown(dialog.dispose);
    addTearDown(cleanup.dispose);
    final release = Completer<void>();
    late Future<void> background;
    await dialog.run(
      () => OperationProgress.step(OperationStage.deleteDownloads, () async {
        background = OperationProgress.detached(
          () => cleanup.run(
            () => OperationProgress.step(
              OperationStage.cleanup,
              () => release.future,
            ),
          ),
        );
      }),
    );
    expect(dialog.value.single.stage, OperationStage.deleteDownloads);
    expect(dialog.value.single.status, OperationStepStatus.completed);
    expect(cleanup.value.single.status, OperationStepStatus.running);
    release.complete();
    await background;
    expect(cleanup.value.single.status, OperationStepStatus.completed);
    expect(dialog.value, hasLength(1));
  });

  test('A step stays running until its real work completes', () async {
    final progress = OperationProgress(), pending = Completer<String>();
    addTearDown(progress.dispose);
    final work = progress.run(
      () =>
          OperationProgress.step(OperationStage.transfer, () => pending.future),
    );
    expect(progress.value.single.stage, OperationStage.transfer);
    expect(progress.value.single.status, OperationStepStatus.running);
    pending.complete('transferred-file');
    expect(await work, 'transferred-file');
    expect(progress.value.single.status, OperationStepStatus.completed);
  });

  test(
    'Late completion from a cancelled run cannot overwrite a new run',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      final old = Completer<void>(), current = Completer<void>();
      final before = progress.run(
        () => OperationProgress.step(
          OperationStage.verifyShare,
          () => old.future,
        ),
      );
      progress.close(cancelled: true);
      expect(progress.value.single.status, OperationStepStatus.cancelled);
      final after = progress.run(
        () => OperationProgress.step(
          OperationStage.readFiles,
          () => current.future,
        ),
      );
      old.complete();
      await before;
      expect(progress.value.single.stage, OperationStage.readFiles);
      expect(progress.value.single.status, OperationStepStatus.running);
      current.complete();
      await after;
      expect(progress.value.single.status, OperationStepStatus.completed);
    },
  );

  test('file counts and retry state belong to the active read step', () async {
    final progress = OperationProgress();
    addTearDown(progress.dispose);
    final release = Completer<void>();
    final work = progress.run(
      () => OperationProgress.step(OperationStage.readFiles, () async {
        OperationProgress.reportFiles(400, waitingForRetry: true);
        await release.future;
        OperationProgress.reportFiles(600);
      }),
    );
    expect(progress.value.single.itemsRead, 400);
    expect(progress.value.single.waitingForRetry, isTrue);
    release.complete();
    await work;
    expect(progress.value.single.itemsRead, 600);
    expect(progress.value.single.waitingForRetry, isFalse);
    expect(progress.value.single.status, OperationStepStatus.completed);
  });

  test(
    'late file progress from a cancelled run cannot update a new run',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      final previous = Completer<void>(), current = Completer<void>();
      final old = progress.run(
        () => OperationProgress.step(OperationStage.readFiles, () async {
          OperationProgress.reportFiles(200, waitingForRetry: true);
          await previous.future;
          OperationProgress.reportFiles(9999);
        }),
      );
      progress.close(cancelled: true);
      expect(progress.value.single.itemsRead, 200);
      expect(progress.value.single.status, OperationStepStatus.cancelled);
      expect(progress.value.single.waitingForRetry, isFalse);
      final fresh = progress.run(
        () => OperationProgress.step(OperationStage.readFiles, () async {
          OperationProgress.reportFiles(10);
          await current.future;
        }),
      );
      previous.complete();
      await old;
      expect(progress.value.single.itemsRead, 10);
      expect(progress.value.single.status, OperationStepStatus.running);
      current.complete();
      await fresh;
    },
  );

  test(
    'parallel read steps update their own counts and stop updating after completion',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      final first = Completer<void>(), second = Completer<void>();
      late Zone completedZone;
      final work = progress.run(
        () => Future.wait([
          OperationProgress.step(OperationStage.readFiles, () async {
            completedZone = Zone.current;
            OperationProgress.reportFiles(200);
            await first.future;
            OperationProgress.reportFiles(400);
          }),
          OperationProgress.step(OperationStage.readFiles, () async {
            OperationProgress.reportFiles(10, waitingForRetry: true);
            await second.future;
          }),
        ]),
      );
      expect(progress.value.map((step) => step.itemsRead), [200, 10]);
      first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(progress.value.map((step) => step.itemsRead), [400, 10]);
      expect(progress.value.last.waitingForRetry, isTrue);
      completedZone.run(() => OperationProgress.reportFiles(999));
      expect(progress.value.first.itemsRead, 400);
      second.complete();
      await work;
    },
  );

  test(
    'file counts propagate through nested observers without leaking the account zone',
    () async {
      final outer = OperationProgress(), inner = OperationProgress();
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      final accountKey = Object();
      final notifiedScopes = <Object?>[];
      outer.addListener(() => notifiedScopes.add(Zone.current[accountKey]));
      inner.addListener(() => notifiedScopes.add(Zone.current[accountKey]));
      await outer.run(
        () => inner.run(
          () => runZoned(
            () => OperationProgress.step(OperationStage.readFiles, () async {
              OperationProgress.reportFiles(200);
              await Future<void>.delayed(Duration.zero);
              expect(Zone.current[accountKey], 'owner');
              OperationProgress.reportFiles(201);
            }),
            zoneValues: {accountKey: 'owner'},
          ),
        ),
      );
      expect(outer.value.single.itemsRead, 201);
      expect(inner.value.single.itemsRead, 201);
      expect(notifiedScopes, everyElement(isNull));
    },
  );

  test(
    'failed reads retain the count and other stages ignore file reports',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      await expectLater(
        progress.run(
          () =>
              OperationProgress.step<void>(OperationStage.readFiles, () async {
                OperationProgress.reportFiles(200, waitingForRetry: true);
                throw const AppException('fixture rate limit');
              }),
        ),
        throwsA(isA<AppException>()),
      );
      expect(progress.value.single.itemsRead, 200);
      expect(progress.value.single.waitingForRetry, isFalse);
      expect(progress.value.single.status, OperationStepStatus.failed);
      await progress.run(
        () => OperationProgress.step(OperationStage.downloadLink, () async {
          OperationProgress.reportFiles(500);
        }),
      );
      expect(progress.value.single.itemsRead, isNull);
    },
  );

  test(
    'Failure is preserved and unexecuted stages are never reported',
    () async {
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      const failure = AppException('fixture transfer failure');
      await expectLater(
        progress.run(() async {
          await OperationProgress.step(
            OperationStage.createTemporary,
            () async {},
          );
          await OperationProgress.step<void>(
            OperationStage.transfer,
            () async => throw failure,
          );
          await OperationProgress.step(
            OperationStage.downloadLink,
            () async {},
          );
        }),
        throwsA(same(failure)),
      );
      expect(progress.value.map((s) => s.stage), [
        OperationStage.createTemporary,
        OperationStage.transfer,
      ]);
      expect(progress.value.map((s) => s.status), [
        OperationStepStatus.completed,
        OperationStepStatus.failed,
      ]);
    },
  );

  test(
    'Nested progress preserves account scope and notifies in the UI zone',
    () async {
      final outer = OperationProgress(),
          inner = OperationProgress(),
          unrelated = OperationProgress();
      addTearDown(outer.dispose);
      addTearDown(inner.dispose);
      addTearDown(unrelated.dispose);
      final accountScope = Object();
      final notificationScopes = <Object?>[];
      outer.addListener(
        () => notificationScopes.add(Zone.current[accountScope]),
      );
      inner.addListener(
        () => notificationScopes.add(Zone.current[accountScope]),
      );
      await outer.run(
        () => inner.run(
          () => runZoned(
            () => OperationProgress.step(OperationStage.downloadLink, () async {
              await Future<void>.delayed(Duration.zero);
              expect(Zone.current[accountScope], 'fixture-owner');
            }),
            zoneValues: {accountScope: 'fixture-owner'},
          ),
        ),
      );
      expect(outer.value.single.status, OperationStepStatus.completed);
      expect(inner.value.single.status, OperationStepStatus.completed);
      expect(notificationScopes, isNotEmpty);
      expect(notificationScopes.every((value) => value == null), isTrue);
      expect(unrelated.value, isEmpty);
    },
  );

  test(
    'Long batches stay bounded and disposed observers ignore late results',
    () async {
      final progress = OperationProgress();
      await progress.run(() async {
        for (var i = 0; i < 60; i++) {
          await OperationProgress.step(
            OperationStage.downloadLink,
            () async {},
          );
        }
      });
      expect(progress.value, hasLength(12));
      final pending = Completer<void>();
      final work = progress.run(
        () => OperationProgress.step(
          OperationStage.readFiles,
          () => pending.future,
        ),
      );
      progress.dispose();
      pending.complete();
      await work;
    },
  );

  test(
    'Cleanup progress starts only after leases release and follows the deletion response',
    () async {
      final store = StateStore.memory();
      final entered = Completer<void>(), response = Completer<void>();
      final http = FakeHttp((request) async {
        expect(request.uri.path, '/remove-temporary');
        entered.complete();
        await response.future;
        return jsonResponse({'code': 0});
      });
      final outbox = CleanupOutbox(store, http), progress = OperationProgress();
      addTearDown(outbox.progress.dispose);
      addTearDown(progress.dispose);
      const cleanup = DownloadCleanup(
        url: 'https://fixture.invalid/remove-temporary',
      );
      await outbox.stage(cleanup);
      outbox.retain(cleanup);
      await outbox.ready(cleanup);
      await outbox.drain();
      expect(http.calls, isEmpty);
      expect(outbox.progress.value, isEmpty);
      await outbox.release(cleanup);
      await outbox.ready(cleanup);
      final work = progress.run(outbox.drain);
      await entered.future;
      expect(outbox.progress.value.single.stage, OperationStage.cleanup);
      expect(outbox.progress.value.single.status, OperationStepStatus.running);
      expect(outbox.pendingCount, 1);
      response.complete();
      await work;
      expect(outbox.pendingCount, 0);
      expect(
        outbox.progress.value.single.status,
        OperationStepStatus.completed,
      );
      expect(progress.value.single.status, OperationStepStatus.completed);
    },
  );

  test(
    'Failed cleanup remains queued and is not displayed as completed',
    () async {
      final store = StateStore.memory();
      final outbox = CleanupOutbox(
        store,
        FakeHttp((_) => jsonResponse({'code': 500})),
      );
      addTearDown(outbox.progress.dispose);
      const cleanup = DownloadCleanup(
        url: 'https://fixture.invalid/remove-temporary',
      );
      await outbox.stage(cleanup);
      await outbox.ready(cleanup);
      await outbox.drain();
      expect(outbox.pendingCount, 1);
      expect(outbox.progress.value.single.status, OperationStepStatus.failed);
      expect(
        asJson(store.data.obj('cleanups').values.single).integer('attempts'),
        1,
      );
    },
  );
}
