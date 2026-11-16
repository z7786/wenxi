import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/upload/upload_manager.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'support.dart';

class QueueConnector extends CloudConnector {
  @override
  final platform = CloudPlatform.quark;
  final started = <String>[], owners = <String>[], parents = <String>[];
  final files = <CloudFile>[];
  Completer<void>? hold;
  int inFlight = 0, maxInFlight = 0;
  bool fail = false;
  @override
  Future<BrowseSession> openPersonal(Credential c) async => uploadSession;
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => List.of(files);
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    started.add(source.name);
    owners.add(c.label);
    parents.add(parent);
    try {
      onProgress?.call(UploadProgress(UploadPhase.uploading, 1, source.size));
      if (hold != null) await RequestScope.cancellable(hold!.future);
      if (fail) throw const AppException('模拟上传失败');
      await source.openRead().drain<void>();
      onProgress?.call(
        UploadProgress(UploadPhase.finishing, source.size, source.size),
      );
      RequestScope.checkpoint();
      final f = CloudFile(
        id: '${files.length}',
        name: source.name,
        size: source.size,
        parentId: parent,
      );
      files.add(f);
      return f;
    } finally {
      inFlight--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const uploadSession = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.personal,
  title: 'Files',
  rootId: '0',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StateStore store;
  late Vault vault;
  late CloudRepository cloud;
  late QueueConnector provider;
  late UploadManager manager;
  late BrowseSession session;
  Future<XFile> file(String name) async {
    final f = File(p.join(root.path, name));
    await f.writeAsBytes([1, 2, 3]);
    return XFile(f.path);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('upload-queue-test-');
    store = StateStore.memory();
    vault = Vault(store);
    await vault.putCredential(
      CloudPlatform.quark,
      Credential('original', {'primary': 'one'}, updatedAt: 1),
    );
    final http = FakeHttp();
    cloud = CloudRepository(http, vault, CleanupOutbox(store, http));
    provider = QueueConnector();
    cloud.connectors[CloudPlatform.quark] = provider;
    manager = UploadManager(store: store, cloud: cloud, concurrent: 1);
    await manager.initialize();
    session = cloud.bindSession(uploadSession);
  });
  tearDown(() async {
    await manager.close();
    manager.dispose();
    await root.delete(recursive: true);
  });

  test(
    'queue survives caller cancellation, binds account and target, and uploads serially',
    () async {
      provider.hold = Completer<void>();
      final outer = RequestScope();
      final inputs = [await file('a.txt'), await file('b.txt')];
      final ids = await outer.run(
        () => manager.enqueue(session, 'folder', 'Folder', inputs),
      );
      outer.cancel();
      await until(() => provider.started.isNotEmpty);
      // Switch active account while the first task is running.
      await store.change((d) {
        d['cloudAccounts'] = {
          'Quark': {
            session.accountId!: {
              'credential': Credential('original', {
                'primary': 'one',
              }, updatedAt: 1).toJson(),
            },
          },
        };
        d['activeCloudAccounts'] = {'Quark': 'other'};
        d['credentials'] = {
          'Quark': Credential('other', {
            'primary': 'two',
          }, updatedAt: 2).toJson(),
        };
      });
      provider.hold!.complete();
      await until(
        () => ids.every(
          (id) => manager.task(id)!.status == UploadStatus.completed,
        ),
      );
      expect(provider.maxInFlight, 1);
      expect(provider.owners, ['original', 'original']);
      expect(provider.parents, ['folder', 'folder']);
    },
  );

  test(
    'default queue starts two files and a queued third uses a freed slot',
    () async {
      await manager.close();
      manager.dispose();
      manager = UploadManager(store: store, cloud: cloud);
      provider.hold = Completer<void>();
      final ids = await manager.enqueue(session, '0', 'Root', [
        await file('a.txt'),
        await file('b.txt'),
        await file('c.txt'),
      ]);
      await until(() => provider.started.length == 2);
      expect(provider.maxInFlight, 2);
      expect(manager.task(ids.last)!.status, UploadStatus.pending);
      await manager.cancel(ids.first);
      await until(() => provider.started.length == 3);
      expect(manager.task(ids[1])!.status, UploadStatus.running);
      provider.hold!.complete();
      await until(
        () => ids
            .skip(1)
            .every((id) => manager.task(id)!.status == UploadStatus.completed),
      );
      // Parallel uploads may finish in either order after both are released.
      expect(
        provider.files.map((file) => file.name),
        unorderedEquals(['b.txt', 'c.txt']),
      );
      expect(provider.maxInFlight, 2);
    },
  );

  test(
    'a new batch wakes an idle slot while another file is uploading',
    () async {
      await manager.close();
      manager.dispose();
      manager = UploadManager(store: store, cloud: cloud);
      provider.hold = Completer<void>();
      await manager.enqueue(session, '0', 'Root', [await file('a.txt')]);
      await until(() => provider.started.length == 1);
      await manager.enqueue(session, '0', 'Root', [await file('b.txt')]);
      await until(() => provider.started.length == 2);
      expect(provider.maxInFlight, 2);
    },
  );

  test('one failed upload does not block later files and can retry', () async {
    provider.fail = true;
    final id = (await manager.enqueue(session, '0', 'Root', [
      await file('a.txt'),
    ])).single;
    await until(() => manager.task(id)!.status == UploadStatus.failed);
    provider.fail = false;
    await manager.retry(id);
    await until(() => manager.task(id)!.status == UploadStatus.completed);
    expect(provider.started, ['a.txt', 'a.txt']);
    final another = (await manager.enqueue(session, '0', 'Root', [
      await file('b.txt'),
    ])).single;
    await until(() => manager.task(another)!.status == UploadStatus.completed);
  });

  test(
    'cancel active request continues queue and never reports late success',
    () async {
      provider.hold = Completer<void>();
      final ids = await manager.enqueue(session, '0', 'Root', [
        await file('a.txt'),
        await file('b.txt'),
      ]);
      await until(() => provider.started.isNotEmpty);
      await manager.cancel(ids.first);
      provider.hold!.complete();
      await until(
        () => manager.task(ids.last)!.status == UploadStatus.completed,
      );
      expect(manager.task(ids.first)!.status, UploadStatus.cancelled);
      expect(provider.files.map((f) => f.name), ['b.txt']);
      expect(provider.maxInFlight, 1);
    },
  );

  test(
    'restart preserves history without automatically retransmitting; missing source explains recovery',
    () async {
      provider.hold = Completer<void>();
      final source = await file('a.txt');
      final id = (await manager.enqueue(session, '0', 'Root', [source])).single;
      await until(() => provider.started.isNotEmpty);
      await manager.close();
      manager.dispose();
      await File(source.path).delete();
      manager = UploadManager(store: store, cloud: cloud);
      await manager.initialize();
      expect(manager.task(id)!.status, UploadStatus.interrupted);
      expect(provider.started, ['a.txt']);
      await manager.retry(id);
      await until(() => manager.task(id)!.status == UploadStatus.failed);
      expect(manager.task(id)!.error, contains('重新选择'));
      expect(provider.started, ['a.txt']);
    },
  );

  test(
    'missing original account never falls back to current account',
    () async {
      provider.fail = true;
      final id = (await manager.enqueue(session, '0', 'Root', [
        await file('a.txt'),
      ])).single;
      await until(() => manager.task(id)!.status == UploadStatus.failed);
      await store.put('credentials', {});
      await store.put('cloudAccounts', {});
      await expectLater(manager.retry(id), throwsA(isA<AppException>()));
      expect(provider.started, ['a.txt']);
    },
  );

  test(
    'duplicate destination refuses to overwrite a completed remote file',
    () async {
      provider.files.add(
        const CloudFile(id: 'existing', name: 'a.txt', size: 3),
      );
      final id = (await manager.enqueue(session, '0', 'Root', [
        await file('a.txt'),
      ])).single;
      await until(() => manager.task(id)!.status == UploadStatus.failed);
      expect(provider.started, isEmpty);
      expect(manager.task(id)!.error, contains('同名'));
    },
  );

  test(
    'foreground failure interrupts queued tasks before any provider upload',
    () async {
      await manager.close();
      manager.dispose();
      manager = UploadManager(
        store: store,
        cloud: cloud,
        foreground: () async {
          throw const AppException('service denied');
        },
      );
      final id = (await manager.enqueue(session, '0', 'Root', [
        await file('a.txt'),
      ])).single;
      await until(() => manager.task(id)!.status == UploadStatus.interrupted);
      expect(provider.started, isEmpty);
      // Ignore the expected native idle-publication failure for teardown.
      await until(() => manager.activeCount == 0);
    },
  );

  test(
    'saved tasks contain account references but no personal session secrets',
    () async {
      provider.hold = Completer<void>();
      final bound = BrowseSession(
        platform: session.platform,
        mode: session.mode,
        title: session.title,
        rootId: session.rootId,
        metadata: {'accountId': session.accountId!, 'cookie': 'secret-cookie'},
      );
      final id = (await manager.enqueue(bound, '0', 'Root', [
        await file('a.txt'),
      ])).single;
      await until(() => provider.started.isNotEmpty);
      expect(
        store.data
            .list('uploadTasks')
            .single
            .obj('session')
            .obj('metadata')
            .containsKey('cookie'),
        isFalse,
      );
      expect(manager.task(id)!.session.accountId, session.accountId);
    },
  );

  test(
    'a conflicting file does not prevent other files in the same batch uploading',
    () async {
      provider.files.add(
        const CloudFile(id: 'existing', name: 'a.txt', size: 3),
      );
      final ids = await manager.enqueue(session, '0', 'Root', [
        await file('a.txt'),
        await file('b.txt'),
      ]);
      await until(
        () => manager.task(ids.last)!.status == UploadStatus.completed,
      );
      expect(manager.task(ids.first)!.status, UploadStatus.failed);
      expect(provider.started, ['b.txt']);
    },
  );

  test(
    'stopping all preserves both tasks and restart can reupload a readable source',
    () async {
      provider.hold = Completer<void>();
      final ids = await manager.enqueue(session, '0', 'Root', [
        await file('a.txt'),
        await file('b.txt'),
      ]);
      await until(() => provider.started.isNotEmpty);
      await manager.stopAll();
      await manager.close();
      manager.dispose();
      expect(provider.files, isEmpty);
      expect(provider.started, ['a.txt']);
      manager = UploadManager(store: store, cloud: cloud);
      await manager.initialize();
      expect(
        manager.tasks.every((t) => t.status == UploadStatus.interrupted),
        isTrue,
      );
      provider.hold = null;
      await manager.retry(ids.last);
      await until(
        () => manager.task(ids.last)!.status == UploadStatus.completed,
      );
      expect(manager.task(ids.first)!.status, UploadStatus.interrupted);
      expect(provider.files.single.name, 'b.txt');
    },
  );

  test('changing a waiting source fails before sending file bytes', () async {
    provider.hold = Completer<void>();
    final source = await file('b.txt');
    final ids = await manager.enqueue(session, '0', 'Root', [
      await file('a.txt'),
      source,
    ]);
    await until(() => provider.started.isNotEmpty);
    await File(source.path).writeAsBytes([9, 8, 7, 6]);
    provider.hold!.complete();
    await until(() => manager.task(ids.last)!.status == UploadStatus.failed);
    expect(manager.task(ids.last)!.error, contains('文件已变化'));
    expect(provider.started, ['a.txt']);
  });
}
