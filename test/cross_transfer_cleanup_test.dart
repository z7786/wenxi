import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/rapid_transfer.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/transfer/cross_transfer_relay.dart';
import 'package:asterlink/transfer/rapid_transfer_manager.dart';
import 'package:asterlink/transfer/rapid_transfer_task.dart';
import 'support.dart';
import 'rapid_transfer_manager_test.dart' show Drive, file, personal;

class _CleanupRelay extends CrossTransferRelay {
  _CleanupRelay({
    required super.cloud,
    required super.http,
    required super.cache,
  });
  final calls = <String>[];
  final failures = <String>{};
  final holds = <String, Completer<void>>{};

  @override
  Future<void> clearTask(String taskId) async {
    calls.add(taskId);
    await holds[taskId]?.future;
    if (failures.contains(taskId)) throw const AppException('缓存文件正在使用');
    await super.clearTask(taskId);
  }
}

class _SettlingDrive extends Drive {
  _SettlingDrive(super.platform) {
    hold = Completer<void>();
  }
  final finish = Completer<void>();
  @override
  Future<RapidTransferResult> rapidTransfer(
    BrowseSession session,
    String parent,
    RapidTransferFile source,
    Credential credential,
  ) async {
    try {
      return await super.rapidTransfer(session, parent, source, credential);
    } finally {
      await finish.future;
    }
  }
}

RapidTransferTask _task(String id, RapidTaskStatus status) {
  const source = BrowseSession(
    platform: CloudPlatform.tianyi,
    mode: BrowseMode.personal,
    title: '来源',
    rootId: '0',
    metadata: {'accountId': 'source'},
  );
  const target = BrowseSession(
    platform: CloudPlatform.pan123,
    mode: BrowseMode.personal,
    title: '目标',
    rootId: '0',
    metadata: {'accountId': 'target'},
  );
  final file = CloudFile(id: id, name: '$id.bin', size: 3, parentId: '0');
  return RapidTransferTask(
    id: id,
    source: source,
    target: target,
    parent: '0',
    folderName: '全部文件',
    selections: [file],
    entries: [
      RapidTransferEntry(
        file,
        [],
        status: status == RapidTaskStatus.completed
            ? RapidEntryStatus.uploaded
            : RapidEntryStatus.failed,
      ),
    ],
    scanned: true,
    status: status,
    createdAt: 1,
  );
}

void main() {
  late Directory root;
  late StateStore store;
  late TransferHttp http;
  late _CleanupRelay relay;
  late RapidTransferManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('asterlink-cross-cleanup-');
    store = StateStore.memory({
      'rapidTransferTasks': [
        _task('first', RapidTaskStatus.failed).toJson(),
        _task('second', RapidTaskStatus.failed).toJson(),
        _task('completed', RapidTaskStatus.completed).toJson(),
      ],
    });
    final api = FakeHttp();
    final cloud = CloudRepository(api, Vault(store), CleanupOutbox(store, api));
    http = TransferHttp();
    relay = _CleanupRelay(cloud: cloud, http: http, cache: root);
    manager = RapidTransferManager(cloud: cloud, store: store, relay: relay);
    await manager.initialize();
    for (final id in ['first', 'second', 'completed']) {
      final key = sha256.convert(utf8.encode(id)).toString();
      final payload = File(p.join(root.path, 'relay-$key', 'entry', 'payload'));
      await payload.parent.create(recursive: true);
      await payload.writeAsString('abc');
    }
  });
  tearDown(() async {
    for (final hold in relay.holds.values) {
      if (!hold.isCompleted) hold.complete();
    }
    await manager.close();
    manager.dispose();
    http.dio.close(force: true);
    await root.delete(recursive: true);
  });

  List<String> savedIds() => store.data
      .list('rapidTransferTasks')
      .map((value) => asJson(value).str('id'))
      .toList();

  test(
    'one cache deletion failure keeps its record and clears later tasks',
    () async {
      relay.failures.add('first');
      final result = await manager.clearFailed();
      expect(result.succeeded, ['second']);
      expect(result.failed.keys, ['first']);
      expect(result.skipped, isEmpty);
      expect(result.cancelled, isFalse);
      expect(relay.calls, ['first', 'second']);
      expect(manager.task('first'), isNotNull);
      expect(manager.task('second'), isNull);
      expect(manager.task('completed'), isNotNull);
      expect(savedIds(), ['first', 'completed']);
    },
  );

  test(
    'completed removals are saved and published before a slow next task',
    () async {
      final hold = relay.holds['second'] = Completer<void>();
      final changes = <List<String>>[];
      manager.addListener(
        () => changes.add(manager.tasks.map((t) => t.id).toList()),
      );
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      final cleanup = progress.run(manager.clearFailed);
      try {
        await until(() => relay.calls.contains('second'));
        expect(manager.task('first'), isNull);
        expect(changes, contains(equals(['second', 'completed'])));
        expect(savedIds(), ['second', 'completed']);
        final step = progress.value.single;
        expect(step.stage, OperationStage.deleteCrossTransfers);
        expect(step.items!.processed, 1);
        expect(step.items!.succeeded, 1);
        expect(step.items!.total, 2);
        expect(step.items!.activity, OperationStage.deleteFiles);
      } finally {
        hold.complete();
        await cleanup;
      }
      expect(savedIds(), ['completed']);
    },
  );

  test(
    'cancelling cleanup finishes the current deletion and keeps remaining caches',
    () async {
      final hold = relay.holds['first'] = Completer<void>();
      final scope = RequestScope();
      final cleanup = scope.run(manager.clearFailed);
      await until(() => relay.calls.contains('first'));
      scope.cancel();
      hold.complete();
      final result = await cleanup;
      expect(result.succeeded, ['first']);
      expect(result.failed, isEmpty);
      expect(result.cancelled, isTrue);
      expect(relay.calls, ['first']);
      expect(manager.task('first'), isNull);
      expect(manager.task('second'), isNotNull);
      expect(savedIds(), ['second', 'completed']);
      final key = sha256.convert(utf8.encode('second')).toString();
      expect(
        await File(
          p.join(root.path, 'relay-$key', 'entry', 'payload'),
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'queued cleanup protects resumed tasks and newly failed tasks',
    () async {
      final hold = relay.holds['first'] = Completer<void>();
      final removal = manager.remove('first');
      await until(() => relay.calls.contains('first'));
      final cleanup = manager.clearFailed();
      manager.task('second')!.status = RapidTaskStatus.pending;
      manager.task('completed')!.status = RapidTaskStatus.failed;
      hold.complete();
      await removal;
      final result = await cleanup;
      expect(result.skipped, ['first', 'second']);
      expect(relay.calls, ['first']);
      expect(manager.task('second')!.active, isTrue);
      expect(manager.task('completed'), isNotNull);
    },
  );

  test('cancellation while queued starts no cleanup', () async {
    final hold = relay.holds['first'] = Completer<void>();
    final removal = manager.remove('first');
    await until(() => relay.calls.contains('first'));
    final scope = RequestScope();
    final cleanup = scope.run(manager.clearFailed);
    scope.cancel();
    hold.complete();
    await removal;
    final result = await cleanup;
    expect(result.cancelled, isTrue);
    expect(result.succeeded, isEmpty);
    expect(relay.calls, ['first']);
    expect(manager.task('second'), isNotNull);
    expect(savedIds(), ['second', 'completed']);
  });

  test('a failed record save keeps the task visible and retryable', () async {
    await manager.close();
    manager.dispose();
    final diskStore = await StateStore.open(
      Directory(p.join(root.path, 'state')),
    );
    await diskStore.put('rapidTransferTasks', [
      _task('first', RapidTaskStatus.failed).toJson(),
      _task('second', RapidTaskStatus.failed).toJson(),
    ]);
    store = diskStore;
    manager = RapidTransferManager(
      cloud: relay.cloud,
      store: store,
      relay: relay,
    );
    await manager.initialize();
    final blocked = Directory('${diskStore.file!.path}.tmp');
    await blocked.create();
    try {
      final result = await manager.clearFailed();
      expect(result.failed.keys, ['first', 'second']);
      expect(result.succeeded, isEmpty);
      expect(manager.tasks.map((t) => t.id), ['first', 'second']);
      expect(savedIds(), ['first', 'second']);
    } finally {
      await blocked.delete();
    }
    final retry = await manager.clearFailed();
    expect(retry.succeeded, ['first', 'second']);
    expect(retry.failed, isEmpty);
    expect(manager.tasks, isEmpty);
    final reopened = await StateStore.open(diskStore.file!.parent);
    expect(reopened.data.list('rapidTransferTasks'), isEmpty);
    reopened.dispose();
  });

  test(
    'cleanup can cancel its stopping wait without deleting an unfinished run',
    () async {
      await manager.close();
      manager.dispose();
      final cloud = relay.cloud;
      final from = Drive(CloudPlatform.tianyi);
      final to = _SettlingDrive(CloudPlatform.pan123);
      final input = file('waiting', 'waiting.bin', '0');
      from.directories['0'] = [input];
      cloud.connectors[from.platform] = from;
      cloud.connectors[to.platform] = to;
      await cloud.vault.putCredential(
        from.platform,
        Credential('source', {'primary': 'source'}, updatedAt: 1),
      );
      await cloud.vault.putCredential(
        to.platform,
        Credential('target', {'primary': 'target'}, updatedAt: 2),
      );
      manager = RapidTransferManager(cloud: cloud, store: store, relay: relay);
      await manager.initialize();
      final id = await manager.enqueue(
        cloud.bindSession(personal(from.platform)),
        [input],
        cloud.bindSession(personal(to.platform)),
        '0',
        '全部文件',
      );
      await until(() => to.calls.isNotEmpty);
      await manager.cancel(id);
      final progress = OperationProgress();
      addTearDown(progress.dispose);
      final scope = RequestScope();
      final cleanup = scope.run(
        () => progress.run(() => manager.clearFailed(ids: [id])),
      );
      try {
        await until(
          () =>
              progress.value.singleOrNull?.items?.activity ==
              OperationStage.stopCrossTransfers,
        );
        scope.cancel();
        final result = await cleanup.timeout(const Duration(seconds: 3));
        expect(result.cancelled, isTrue);
        expect(relay.calls, isEmpty);
        expect(manager.task(id), isNotNull);
        final removal = manager.remove('first');
        await until(() => relay.calls.contains('first'));
        await removal;
      } finally {
        to.finish.complete();
      }
    },
  );
}
