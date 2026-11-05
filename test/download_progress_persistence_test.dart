import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _SlowStateStore extends ChangeNotifier implements StateStore {
  _SlowStateStore(this.delegate) {
    delegate.addListener(notifyListeners);
  }

  final StateStore delegate;
  final _writes = AsyncGate();
  Future<void>? barrier;
  int requestedWrites = 0;

  @override
  Json get data => delegate.data;

  @override
  Future<T> change<T>(T Function(Json draft) edit, {String? recoveryPassword}) {
    requestedWrites++;
    return _writes.run(() async {
      await barrier;
      return delegate.change(edit, recoveryPassword: recoveryPassword);
    });
  }

  @override
  Future<void> put(String key, Object? value) => change((draft) {
    draft[key] = value;
  });

  @override
  Future<void> flush() => _writes.run(delegate.flush);

  @override
  void dispose() {
    delegate.removeListener(notifyListeners);
    delegate.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProgressNative extends FakeNative {
  _ProgressNative() {
    finish = false;
    content
      ..clear()
      ..addAll(List.filled(256, 0));
  }

  int snapshots = 0;

  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method != 'snapshot' || finish) return result;
    snapshots++;
    return {
      ...asJson(result),
      'downloaded': snapshots.clamp(0, 255),
      'speed': 1,
    };
  }
}

class _ProbeHttp extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(
        RemoteIdentity(256, '"v1"', null),
        false,
        rangeSupported: true,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Slow progress writes stay bounded while downloading and retain the latest bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aster-progress-save-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = _SlowStateStore(StateStore.memory());
      addTearDown(store.dispose);
      final native = _ProgressNative();
      final manager = DownloadManager(
        store: store,
        engine: GopeedEngine(
          native,
          store,
          Vault(store),
          Directory(p.join(root.path, 'native')),
          Directory(p.join(root.path, 'cache')),
        ),
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        cleanups: CleanupOutbox(store, FakeHttp()),
        http: _ProbeHttp(),
        refreshSource: (_) async => throw StateError('unused'),
      );
      addTearDown(() async {
        await manager.close();
        manager.dispose();
      });
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.test/progress',
          fileName: 'progress.bin',
          expectedSize: 256,
        ),
      );
      await until(() => native.snapshots >= 2);
      await store.flush();
      final before = store.requestedWrites;
      final blocked = Completer<void>();
      store.barrier = blocked.future;
      late int latestBytes;
      try {
        await until(() => store.requestedWrites > before);
        final firstBytes = manager.task(id)!.downloaded;
        final firstSample = native.snapshots;
        await until(() => native.snapshots >= firstSample + 15);
        latestBytes = manager.task(id)!.downloaded;
        expect(latestBytes, greaterThan(firstBytes));
        expect(manager.task(id)!.status, DownloadStatus.running);
        expect(store.requestedWrites - before, 1);
      } finally {
        store.barrier = null;
        blocked.complete();
      }
      await until(() {
        final saved = asJson((store.data['tasks'] as List).single);
        return saved.integer('downloaded') >= latestBytes;
      });
      await manager.pause(id);
      await manager.close();
      final saved = DownloadTask.fromJson(
        asJson((store.data['tasks'] as List).single),
      );
      expect(saved.status, DownloadStatus.paused);
      expect(saved.downloaded, manager.task(id)!.downloaded);
      expect(saved.downloaded, greaterThanOrEqualTo(latestBytes));
    },
  );
  test(
    'Pause stops the writer before a slow save and a quick resume waits for its checkpoint',
    () async {
      final root = await Directory.systemTemp.createTemp('aster-pause-save-');
      addTearDown(() => root.delete(recursive: true));
      final store = _SlowStateStore(StateStore.memory());
      addTearDown(store.dispose);
      final native = _ProgressNative();
      final manager = DownloadManager(
        store: store,
        engine: GopeedEngine(
          native,
          store,
          Vault(store),
          Directory(p.join(root.path, 'native')),
          Directory(p.join(root.path, 'cache')),
        ),
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        cleanups: CleanupOutbox(store, FakeHttp()),
        http: _ProbeHttp(),
        refreshSource: (_) async => throw StateError('unused'),
      );
      addTearDown(() async {
        await manager.close();
        manager.dispose();
      });
      await manager.initialize();
      final id = await manager.enqueue(
        const DownloadSpec(
          url: 'https://example.test/pause',
          fileName: 'pause.bin',
          expectedSize: 256,
        ),
      );
      await until(() => native.snapshots >= 2);
      await store.flush();
      final oldPauses = native.calls
          .where((method) => method == 'pause')
          .length;
      final blocked = Completer<void>();
      store.barrier = blocked.future;
      final pausing = manager.pause(id);
      var pauseCompleted = false;
      pausing.then((_) => pauseCompleted = true);
      try {
        await until(() => !native.writer);
        expect(manager.task(id)!.status, DownloadStatus.paused);
        expect(manager.task(id)!.speed, 0);
        expect(pauseCompleted, isFalse);
        expect(
          native.calls.where((method) => method == 'pause').length,
          oldPauses + 1,
        );
        final resuming = manager.resume(id);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(native.begins.length, 1);
        store.barrier = null;
        blocked.complete();
        await Future.wait([pausing, resuming]);
        await until(() => native.begins.length == 2);
        expect(
          native.calls.where((method) => method == 'pause').length,
          oldPauses + 1,
          reason: 'The download finalizer must reuse the pause checkpoint',
        );
      } finally {
        store.barrier = null;
        if (!blocked.isCompleted) blocked.complete();
        await pausing;
      }
      await manager.pause(id);
      expect(manager.task(id)!.status, DownloadStatus.paused);
    },
  );
}
