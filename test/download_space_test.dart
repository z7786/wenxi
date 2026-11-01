import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/space_budget.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

const _spec = DownloadSpec(
  url: 'https://fixture.invalid/space.bin',
  fileName: 'space.bin',
  expectedSize: 4,
);

class _Probe extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"space-fixture"', null), false);
}

class _VolumeFiles extends PlatformFileAccess {
  _VolumeFiles(super.transport, super.defaultDirectory, this.selected);
  final Directory selected;
  final checked = <String>[];
  int systemFree = 0, targetFree = 1 << 40;

  StorageVolume volume(String path) => StorageVolume(
    p.equals(path, selected.path) || p.isWithin(selected.path, path)
        ? 'target'
        : 'system',
    path,
  );

  @override
  Future<StoragePlan> storagePlan(String cache, String? destination) async =>
      StoragePlan(volume(cache), volume(destination ?? defaultDirectory.path));

  @override
  Future<int> freeBytes(String path) async {
    checked.add(path);
    return volume(path).id == 'target' ? targetFree : systemFree;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'An already downloaded cache needs no new space on its volume',
    () async {
      final checked = <String>[];
      final budget = SpaceBudget(
        () async => throw StateError('Unexpected fallback to the app cache'),
        margin: 10,
        availableOnVolume: (volume) async {
          checked.add(volume);
          return volume == 'system' ? 0 : 1000;
        },
      );
      await budget.reserveVolumes('file', {'system': 0, 'target': 4});
      expect(checked, ['target']);
    },
  );

  group('Download capacity follows each task destination', () {
    late Directory root, selected, cache;
    late StateStore store;
    late FakeNative native;
    late _VolumeFiles files;
    late DownloadManager manager;

    Future<void> open() async {
      manager = DownloadManager(
        store: store,
        engine: GopeedEngine(
          native,
          store,
          Vault(store),
          Directory(p.join(root.path, 'native')),
          cache,
        ),
        files: files,
        cleanups: CleanupOutbox(store, FakeHttp()),
        http: _Probe(),
        refreshSource: (_) async => throw StateError('Unexpected refresh'),
      );
      await manager.initialize();
    }

    Future<void> settle(String id, DownloadStatus status) async {
      await until(() => !manager.task(id)!.active && manager.activeCount == 0);
      expect(manager.task(id)!.status, status, reason: manager.task(id)!.error);
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('aster-space-test-');
      selected = Directory(p.join(root.path, 'selected-volume'));
      cache = Directory(p.join(root.path, 'system-cache'));
      store = StateStore.memory({
        'settings': {'concurrent': 1, 'retries': 0},
      });
      native = FakeNative();
      files = _VolumeFiles(
        native,
        Directory(p.join(root.path, 'default-downloads')),
        selected,
      );
      await open();
    });

    tearDown(() async {
      await manager.close();
      manager.dispose();
      final resolved = await root.resolveSymbolicLinks();
      require(
        p.isWithin(
              await Directory.systemTemp.resolveSymbolicLinks(),
              resolved,
            ) &&
            p.basename(resolved).startsWith('aster-space-test-'),
        'Unexpected space test cleanup directory',
      );
      await root.delete(recursive: true);
    });

    test(
      'A new selected-volume download ignores system-volume capacity',
      () async {
        await manager.changeDestination(selected.path);
        final id = await manager.enqueue(_spec);
        await settle(id, DownloadStatus.completed);
        expect(files.checked, isNotEmpty);
        expect(
          files.checked.every((path) => files.volume(path).id == 'target'),
          isTrue,
        );
        expect(p.isWithin(selected.path, manager.task(id)!.savedPath!), isTrue);
      },
    );

    test(
      'An empty legacy task adopts its selected destination cache',
      () async {
        await manager.close();
        manager.dispose();
        await store.put('tasks', [
          DownloadTask(
            id: 'empty-legacy',
            spec: _spec,
            createdAt: 1,
            status: DownloadStatus.paused,
            destination: selected.path,
          ).toJson(),
        ]);
        await open();
        await manager.resume('empty-legacy');
        await settle('empty-legacy', DownloadStatus.completed);
        expect(
          files.checked.every((path) => files.volume(path).id == 'target'),
          isTrue,
        );
        expect(
          native.begins.single.str('cacheRoot'),
          p.join(selected.path, '.asterlink-cache'),
        );
      },
    );

    test(
      'A complete legacy payload exports with no system-volume capacity',
      () async {
        await manager.close();
        manager.dispose();
        final payload = File(
          p.join(cache.path, 'ready-legacy', 'payload.gopeed'),
        );
        await payload.parent.create(recursive: true);
        await payload.writeAsBytes(native.content);
        await store.put('tasks', [
          DownloadTask(
            id: 'ready-legacy',
            spec: _spec,
            createdAt: 1,
            status: DownloadStatus.paused,
            destination: selected.path,
            total: 4,
            downloaded: 4,
            payloadReady: true,
          ).toJson(),
        ]);
        await open();
        await manager.resume('ready-legacy');
        await settle('ready-legacy', DownloadStatus.completed);
        expect(native.begins, isEmpty);
        expect(
          files.checked.every((path) => files.volume(path).id == 'target'),
          isTrue,
        );
        expect(
          await File(manager.task('ready-legacy')!.savedPath!).readAsBytes(),
          native.content,
        );
      },
    );

    test(
      'A partial legacy cache still checks its actual volume and keeps bytes',
      () async {
        await manager.close();
        manager.dispose();
        final payload = File(
          p.join(cache.path, 'partial-legacy', 'payload.gopeed'),
        );
        await payload.parent.create(recursive: true);
        await payload.writeAsBytes([1, 2]);
        await store.put('tasks', [
          DownloadTask(
            id: 'partial-legacy',
            spec: _spec,
            createdAt: 1,
            status: DownloadStatus.paused,
            destination: selected.path,
            total: 4,
            downloaded: 2,
            identity: const RemoteIdentity(4, '"space-fixture"', null),
          ).toJson(),
        ]);
        await open();
        await manager.resume('partial-legacy');
        await settle('partial-legacy', DownloadStatus.failed);
        expect(manager.task('partial-legacy')!.error, contains('空间不足'));
        expect(native.begins, isEmpty);
        expect(
          files.checked.any((path) => files.volume(path).id == 'system'),
          isTrue,
        );
        expect(await payload.readAsBytes(), [1, 2]);
        expect(manager.task('partial-legacy')!.downloaded, 2);
      },
    );

    test('The selected volume still rejects insufficient capacity', () async {
      final log = DiagnosticLog.open(null);
      final previousLog = DiagnosticLog.active;
      DiagnosticLog.active = log;
      try {
        files.targetFree = 0;
        await manager.changeDestination(selected.path);
        final id = await manager.enqueue(_spec);
        await settle(id, DownloadStatus.failed);
        expect(manager.task(id)!.error, contains('空间不足'));
        expect(native.begins, isEmpty);
        expect(
          files.checked.every((path) => files.volume(path).id == 'target'),
          isTrue,
        );
        final failure = log.entries(errorsOnly: true).single.data;
        final fields = asJson(failure['fields']);
        expect(fields.integer('freeBytes'), 0);
        expect(fields.integer('requiredBytes'), _spec.expectedSize * 2);
        expect(fields.integer('reservedBytes'), 0);
        expect(fields.integer('marginBytes'), 32 * 1024 * 1024);
        expect(fields.str('spaceRole'), 'cache_and_target');
        if (Platform.isWindows) {
          expect(
            fields.str('disk'),
            p.rootPrefix(selected.path).substring(0, 2),
          );
          expect(failure.toString(), isNot(contains(root.path)));
        }
      } finally {
        DiagnosticLog.active = previousLog;
        log.close();
        log.dispose();
      }
    });
  });
}
