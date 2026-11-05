import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

const _spec = DownloadSpec(
  url: 'https://example.invalid/destination-test',
  fileName: '目录验证.bin',
  relativePath: '文件夹/子目录',
  expectedSize: 4,
);

class _Probe extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"local-fixture"', null), false);
}

class _Native extends FakeNative {
  bool legacy = false, failRemoval = false;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'version' && legacy) return {'protocol': 1};
    if (method == 'remove' && failRemoval) throw const AppException('busy');
    return super.call(method, args);
  }
}

class _ExportFiles extends PlatformFileAccess {
  _ExportFiles(super.transport, super.defaultDirectory);
  final exporting = Completer<void>(), cancelled = Completer<void>();
  bool hold = true;

  @override
  Future<void> cancelExport(String id) async {
    if (hold && !cancelled.isCompleted) cancelled.complete();
  }

  @override
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int, int)? onProgress,
  }) async {
    if (hold) {
      if (!exporting.isCompleted) exporting.complete();
      await cancelled.future;
      hold = false;
      checkpoint();
    }
    return super.save(
      id: id,
      source: source,
      name: name,
      relativePath: relativePath,
      destination: destination,
      checkpoint: checkpoint,
      onProgress: onProgress,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, defaults, target, legacyCache;
  late StateStore store;
  late _Native native;
  late DownloadManager manager;
  var disposed = false;

  Future<void> open({FileAccess? files}) async {
    manager = DownloadManager(
      store: store,
      engine: GopeedEngine(
        native,
        store,
        Vault(store),
        Directory(p.join(root.path, 'native')),
        legacyCache,
      ),
      files: files ?? PlatformFileAccess(native, defaults, android: false),
      cleanups: CleanupOutbox(store, FakeHttp()),
      http: _Probe(),
      refreshSource: (_) async => throw const AppException('unused'),
    );
    disposed = false;
    await manager.initialize();
  }

  Future<void> close() async {
    await manager.close();
    manager.dispose();
    disposed = true;
  }

  Future<void> completed(String id) => until(
    () =>
        manager.task(id)?.status == DownloadStatus.completed &&
        manager.activeCount == 0,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-destination-test-');
    root = Directory(await root.resolveSymbolicLinks());
    defaults = Directory(p.join(root.path, 'default-downloads'));
    target = Directory(p.join(root.path, 'chosen-downloads'));
    legacyCache = Directory(p.join(root.path, 'old-cache'));
    store = StateStore.memory({
      'settings': {'concurrent': 1, 'threads': 1},
    });
    native = _Native();
    await open();
  });

  tearDown(() async {
    if (!disposed) await close();
    final resolved = await root.resolveSymbolicLinks();
    require(
      p.isWithin(await Directory.systemTemp.resolveSymbolicLinks(), resolved) &&
          p.basename(resolved).startsWith('aster-destination-test-'),
      'unexpected test cleanup directory',
    );
    await root.delete(recursive: true);
  });

  test(
    'new payload and exported file both follow the chosen directory',
    () async {
      native.finish = false;
      await manager.changeDestination(target.path);
      final id = await manager.enqueue(_spec);
      final cached = File(
        p.join(target.path, '.asterlink-cache', id, 'payload.gopeed'),
      );
      await until(cached.existsSync);
      expect(await cached.readAsBytes(), native.content);
      expect(await Directory(p.join(legacyCache.path, id)).exists(), isFalse);
      expect(native.begins.single['cacheRoot'], cached.parent.parent.path);
      native.finish = true;
      await completed(id);
      final saved = File(manager.task(id)!.savedPath!);
      expect(p.isWithin(target.path, saved.path), isTrue);
      expect(await saved.readAsBytes(), native.content);
      expect(await cached.exists(), isFalse);
      expect(await defaults.exists(), isFalse);
    },
  );

  test(
    'only-new choice leaves an active task at its captured location',
    () async {
      native.finish = false;
      final id = await manager.enqueue(_spec);
      await until(() => native.begins.isNotEmpty);
      final originalRoot = manager.engine.taskCacheRoot(id).path;
      await manager.changeDestination(target.path);
      expect(manager.task(id)!.status, DownloadStatus.running);
      expect(manager.task(id)!.destination, isNull);
      expect(manager.engine.taskCacheRoot(id).path, originalRoot);
      native.finish = true;
      await completed(id);
      expect(p.isWithin(defaults.path, manager.task(id)!.savedPath!), isTrue);
    },
  );

  test(
    'sync pauses live exports and keeps their payload for the new target',
    () async {
      await close();
      final files = _ExportFiles(native, defaults);
      await open(files: files);
      final id = await manager.enqueue(_spec);
      await files.exporting.future;
      final cached = File(
        p.join(manager.engine.taskDirectory(id).path, 'payload.gopeed'),
      );
      expect(
        await manager.changeDestination(target.path, includeUnfinished: true),
        1,
      );
      expect(files.cancelled.isCompleted, isTrue);
      expect(manager.activeCount, 0);
      expect(manager.task(id)!.status, DownloadStatus.paused);
      expect(await cached.readAsBytes(), native.content);
      final begins = native.begins.length;
      await manager.resume(id);
      await completed(id);
      expect(native.begins.length, begins);
      expect(p.isWithin(target.path, manager.task(id)!.savedPath!), isTrue);
      expect(await cached.exists(), isFalse);
    },
  );

  test('legacy cache survives changing destination and restarting', () async {
    await close();
    final cached = File(p.join(legacyCache.path, 'legacy', 'payload.gopeed'));
    await cached.parent.create(recursive: true);
    await cached.writeAsBytes(native.content);
    await store.put('tasks', [
      const DownloadTask(
        id: 'legacy',
        spec: _spec,
        createdAt: 0,
        status: DownloadStatus.paused,
        total: 4,
        downloaded: 4,
        payloadReady: true,
      ).toJson(),
    ]);
    await open();
    await manager.changeDestination(target.path, includeUnfinished: true);
    expect(manager.engine.taskCacheRoot('legacy').path, legacyCache.path);
    expect(await cached.readAsBytes(), native.content);
    await close();
    store = StateStore.memory(store.data);
    await open();
    await manager.resume('legacy');
    await completed('legacy');
    expect(native.begins, isEmpty);
    expect(p.isWithin(target.path, manager.task('legacy')!.savedPath!), isTrue);
  });

  test(
    'default reset and explicit task destination each select their own cache',
    () async {
      await manager.changeDestination(target.path);
      await manager.changeDestination(null);
      var id = await manager.enqueue(_spec);
      await completed(id);
      expect(p.isWithin(defaults.path, manager.task(id)!.savedPath!), isTrue);
      id = (await manager.enqueueAll([_spec], destination: target.path)).single;
      await completed(id);
      expect(p.isWithin(target.path, manager.task(id)!.savedPath!), isTrue);
      expect(
        native.begins.last.str('cacheRoot'),
        p.join(target.path, '.asterlink-cache'),
      );
    },
  );

  test(
    '2274 queued tasks change in one commit without starting transfers',
    () async {
      await close();
      await store.put('tasks', [
        for (var i = 0; i < 2274; i++)
          DownloadTask(
            id: 'queue-$i',
            spec: _spec,
            createdAt: i,
            status: i == 0 ? DownloadStatus.failed : DownloadStatus.paused,
          ).toJson(),
        const DownloadTask(
          id: 'done',
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.completed,
          savedPath: 'untouched.bin',
        ).toJson(),
      ]);
      final preallocated = Directory(p.join(legacyCache.path, 'queue-1'));
      await preallocated.create(recursive: true);
      await File(
        p.join(preallocated.path, 'payload.gopeed'),
      ).writeAsBytes(native.content);
      await open();
      var writes = 0, ticks = 0;
      store.addListener(() => writes++);
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        expect(
          await manager.changeDestination(target.path, includeUnfinished: true),
          2274,
        );
      } finally {
        timer.cancel();
      }
      expect(writes, 1);
      expect(ticks, greaterThan(0));
      expect(native.begins, isEmpty);
      expect(manager.task('queue-0')!.status, DownloadStatus.failed);
      expect(manager.task('done')!.destination, isNull);
      expect(manager.task('done')!.savedPath, 'untouched.bin');
      expect(manager.engine.taskCacheRoot('queue-1').path, legacyCache.path);
      expect(
        manager.engine.taskCacheRoot('queue-2273').path,
        p.join(target.path, '.asterlink-cache'),
      );
    },
  );

  test('history cleanup keeps custom roots until removal succeeds', () async {
    native.finish = false;
    await manager.changeDestination(target.path);
    final id = await manager.enqueue(_spec);
    await until(() => native.begins.isNotEmpty);
    await manager.pause(id);
    final cache = manager.engine.taskDirectory(id);
    native.failRemoval = true;
    await manager.delete(id);
    expect(store.data.obj('downloadCacheRoots')[id], isNotNull);
    expect(await cache.exists(), isTrue);
    await close();
    store = StateStore.memory(store.data);
    native = _Native();
    await open();
    await until(() => !(store.data['downloadRemovals'] as List).contains(id));
    expect(store.data.obj('downloadCacheRoots')[id], isNull);
    expect(await cache.exists(), isFalse);
  });

  test(
    'unwritable target fails without downloading into the default folder',
    () async {
      final blocked = File(p.join(root.path, 'blocked'));
      await blocked.writeAsString('keep');
      await manager.changeDestination(p.join(blocked.path, 'child'));
      final id = await manager.enqueue(_spec);
      await until(
        () =>
            manager.task(id)!.status == DownloadStatus.failed &&
            manager.activeCount == 0,
      );
      expect(manager.task(id)!.savedPath, isNull);
      expect(await defaults.exists(), isFalse);
      expect(await Directory(p.join(legacyCache.path, id)).exists(), isFalse);
      expect(await blocked.readAsString(), 'keep');
    },
  );

  test(
    'older helper is rejected before it can write the payload to the old drive',
    () async {
      native.legacy = true;
      await manager.changeDestination(target.path);
      final id = await manager.enqueue(_spec);
      await until(
        () =>
            manager.task(id)!.status == DownloadStatus.failed &&
            manager.activeCount == 0,
      );
      expect(manager.task(id)!.error, contains('下载组件版本过旧'));
      expect(native.begins, isEmpty);
      expect(await Directory(p.join(legacyCache.path, id)).exists(), isFalse);
    },
  );

  test('Android document destinations retain the private cache', () async {
    final files = PlatformFileAccess(native, defaults, android: true);
    expect(
      await files.downloadCacheRoot(
        'content://documents/tree/primary:Download',
      ),
      isNull,
    );
    expect(await files.downloadCacheRoot(null), isNull);
  });

  test(
    'failed settings commit rolls back task destinations and cache mappings',
    () async {
      await close();
      store = await StateStore.open(
        Directory(p.join(root.path, 'state')),
        testKey: Uint8List(32),
      );
      await store.put('tasks', [
        const DownloadTask(
          id: 'queued',
          spec: _spec,
          createdAt: 0,
          status: DownloadStatus.paused,
        ).toJson(),
      ]);
      await open();
      final blocked = Directory('${store.file!.path}.tmp');
      await blocked.create();
      try {
        await expectLater(
          manager.changeDestination(target.path, includeUnfinished: true),
          throwsA(isA<FileSystemException>()),
        );
        expect(manager.task('queued')!.destination, isNull);
        expect(store.data.obj('settings')['destination'], isNull);
        expect(store.data.obj('downloadCacheRoots'), isEmpty);
        expect(manager.engine.taskCacheRoot('queued').path, legacyCache.path);
      } finally {
        await blocked.delete();
      }
    },
  );

  test('a linked task cache is never read or recursively deleted', () async {
    await close();
    await store.put('tasks', [
      const DownloadTask(
        id: 'linked',
        spec: _spec,
        createdAt: 0,
        status: DownloadStatus.paused,
      ).toJson(),
    ]);
    await legacyCache.create();
    final outside = Directory(p.join(root.path, 'user-files'));
    await outside.create();
    final keep = File(p.join(outside.path, 'keep.bin'));
    await keep.writeAsBytes(native.content);
    final link = Link(p.join(legacyCache.path, 'linked'));
    try {
      await link.create(outside.path);
    } on FileSystemException {
      markTestSkipped('symlink creation unavailable');
      return;
    }
    await open();
    await expectLater(
      manager.engine.checkedTaskDirectory('linked'),
      throwsA(isA<AppException>()),
    );
    await manager.delete('linked');
    expect(await keep.readAsBytes(), native.content);
    expect(store.data['downloadRemovals'], contains('linked'));
    await link.delete();
  });
}
