import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/baidu_share_route.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/download_request.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _ProbeHttp extends TransferHttp {
  final probes = <String>[];
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async {
    probes.add(url);
    if (url.contains('/expired')) throw DownloadHttpException(403);
    return const Probe(RemoteIdentity(4, '"fixture"', null), false);
  }
}

DownloadSpec _planned(String id) {
  final file = CloudFile(id: id, name: '$id.bin', size: 4, parentId: 'root');
  return DownloadSpec(
    url: '',
    fileName: file.name,
    expectedSize: file.size,
    relativePath: 'selected-folder',
    source: DownloadOrigin(
      BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'fixture',
        rootId: 'root',
        metadata: const {'accountId': 'original-account'},
      ),
      file,
      42,
    ).toJson(),
  );
}

DownloadSpec _ready(DownloadSpec planned) => DownloadSpec.fromJson({
  ...planned.toJson(),
  'url': 'https://cdn.example.test/${planned.source!.obj('file').str('id')}',
  'profile': 'quark_route_2',
  'fileName': 'temporary-server-name.bin',
  'relativePath': '',
});

class _Fixture {
  _Fixture._(this.directory, this.store) {
    native = FakeNative();
    files = FakeFiles(Directory(p.join(directory.path, 'saved')));
    engine = GopeedEngine(
      native,
      store,
      Vault(store),
      Directory(p.join(directory.path, 'native')),
      Directory(p.join(directory.path, 'cache')),
    );
    cleanups = CleanupOutbox(store, FakeHttp());
    manager = DownloadManager(
      store: store,
      engine: engine,
      files: files,
      cleanups: cleanups,
      http: http,
      refreshSource: (previous) => resolve(previous),
      onGuestDownload: () => guestNotices++,
    );
  }
  final Directory directory;
  final StateStore store;
  final http = _ProbeHttp();
  late final FakeNative native;
  late final FakeFiles files;
  late final GopeedEngine engine;
  late final CleanupOutbox cleanups;
  late final DownloadManager manager;
  Future<DownloadSpec> Function(DownloadSpec) resolve = (previous) async =>
      _ready(previous);
  bool closed = false;
  int guestNotices = 0;

  static Future<_Fixture> create({StateStore? state}) async {
    final result = _Fixture._(
      await Directory.systemTemp.createTemp('aster-preparation-'),
      state ??
          StateStore.memory({
            'settings': {
              'concurrent': 2,
              'threads': 8,
              'retries': 1,
              'speedLimit': 4096,
              'downloadThreadOverrides': {
                'quark_route_1': 16,
                'quark_route_2': 9,
              },
            },
          }),
    );
    await result.manager.initialize();
    addTearDown(result.close);
    return result;
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    await manager.close();
    manager.dispose();
    await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final legacy in [false, true]) {
    test(
      'public Baidu resumed tasks retain chosen threads, legacy=$legacy',
      () async {
        final planned = _planned('public');
        final spec = DownloadSpec.fromJson({
          ...planned.toJson(),
          'url': 'https://cdn.example.test/public',
          'profile': legacy ? 'baidu' : 'baidu_public',
          'source': {
            ...planned.source!,
            'platform': 'baidu',
            'session': {
              ...planned.source!.obj('session'),
              'platform': 'baidu',
              'mode': 'share',
              'metadata': {
                BaiduShareRoute.metadataKey: BaiduShareRoute.publicParser.key,
              },
            },
          },
        });
        final task = DownloadTask(
          id: 'old-public',
          spec: spec,
          createdAt: 1,
          status: DownloadStatus.paused,
          connections: legacy ? 1 : 12,
        );
        final f = await _Fixture.create(
          state: StateStore.memory({
            'settings': {
              'downloadThreadOverrides': {'baidu': 1},
            },
            'tasks': [task.toJson()],
          }),
        );
        await f.manager.resume(task.id);
        await until(
          () => f.manager.task(task.id)!.status == DownloadStatus.completed,
        );
        expect(f.manager.task(task.id)!.spec.profile, 'baidu_public');
        expect(f.native.begins.single['connections'], legacy ? 64 : 12);
        expect(f.native.begins.single['connectionProfile'], 'baidu_public');
      },
    );
  }

  test(
    'a planned public task captures its own thread choice before resolution',
    () async {
      final f = await _Fixture.create();
      final planned = _planned('public');
      final spec = DownloadSpec.fromJson({
        ...planned.toJson(),
        'profile': 'baidu_public',
        'source': {
          ...planned.source!,
          'platform': 'baidu',
          'session': {...planned.source!.obj('session'), 'platform': 'baidu'},
        },
      });
      f.resolve = (previous) async => DownloadSpec.fromJson({
        ...previous.toJson(),
        'url': 'https://cdn.example.test/public',
      });
      final id = await f.manager.enqueue(spec, connections: 32);
      await until(() => f.manager.task(id)!.status == DownloadStatus.completed);
      expect(f.native.begins.single['connections'], 32);
      expect(f.manager.settings.threads, 8);
    },
  );

  test(
    'external thread choice survives restart and applies to Baidu account downloads',
    () async {
      final f = await _Fixture.create();
      const spec = DownloadSpec(
        url: 'https://cdn.example.test/direct',
        fileName: 'direct.bin',
      );
      final id = await f.manager.enqueue(spec, connections: 19);
      await until(() => f.manager.task(id)!.status == DownloadStatus.completed);
      expect(f.native.begins.single['connections'], 19);
      final task = f.manager.task(id)!.update({'status': 'paused'});
      final reopened = await _Fixture.create(
        state: StateStore.memory({
          'settings': {'threads': 128},
          'tasks': [task.toJson()],
        }),
      );
      await reopened.manager.resume(id);
      await until(
        () => reopened.manager.task(id)!.status == DownloadStatus.completed,
      );
      expect(reopened.native.begins.single['connections'], 19);
      final account = DownloadSpec.fromJson({
        ...spec.toJson(),
        'profile': 'baidu_preview',
      });
      final accountId = await f.manager.enqueue(account, connections: 64);
      await until(
        () => f.manager.task(accountId)!.status == DownloadStatus.completed,
      );
      expect(f.native.begins.last['connections'], 64);
      await expectLater(
        f.manager.enqueue(spec, connections: 513),
        throwsA(isA<AppException>()),
      );
    },
  );

  for (final profile in ['baidu', 'baidu_preview']) {
    for (final ready in [false, true]) {
      test(
        'Baidu resume and route changes preserve captured $profile threads, ready=$ready',
        () async {
          final limit = ready ? 64 : 512;
          final planned = _planned('baidu');
          final spec = DownloadSpec.fromJson({
            ...planned.toJson(),
            'profile': ready
                ? profile
                : (profile == 'baidu' ? 'baidu_preview' : 'baidu'),
            'source': {
              ...planned.source!,
              'platform': CloudPlatform.baidu.key,
              'session': {
                ...planned.source!.obj('session'),
                'platform': CloudPlatform.baidu.key,
              },
            },
            'url': ready ? 'https://cdn.example.test/baidu' : '',
          });
          final task = DownloadTask(
            id: 'old-baidu',
            spec: spec,
            createdAt: 1,
            status: DownloadStatus.paused,
            connections: 64,
            connectionOptions: const {'baidu': 512},
          );
          final fixture = await _Fixture.create(
            state: StateStore.memory({
              'settings': {
                'threads': 512,
                'downloadThreadOverrides': {'baidu': 512},
              },
              'tasks': [task.toJson()],
            }),
          );
          fixture.resolve = (previous) async => DownloadSpec.fromJson({
            ...previous.toJson(),
            'profile': profile,
            'url': 'https://cdn.example.test/baidu',
          });
          await fixture.manager.resume(task.id);
          await until(
            () =>
                fixture.manager.task(task.id)!.status ==
                DownloadStatus.completed,
          );
          expect(fixture.manager.task(task.id)!.connections, limit);
          expect(fixture.native.begins.single['connections'], limit);
          expect(fixture.native.begins.single['connectionProfile'], profile);
        },
      );
    }
  }

  test(
    'Failed guest attempts still explain the route and do not repeat on retry',
    () async {
      final fixture = await _Fixture.create();
      fixture.resolve = (previous) async {
        DownloadRequestContext.current!.onGuestDownload!();
        throw const AppException('guest interface unavailable');
      };
      final id = await fixture.manager.enqueue(_planned('failed-guest'));
      await until(
        () => fixture.manager.task(id)!.status == DownloadStatus.failed,
      );
      expect(fixture.guestNotices, 1);
      await fixture.manager.resume(id);
      await until(
        () => fixture.manager.task(id)!.status == DownloadStatus.failed,
      );
      expect(fixture.guestNotices, 1);
    },
  );

  test(
    'Guest batches notify once after resolution, and ordinary downloads do not',
    () async {
      final fixture = await _Fixture.create();
      fixture.resolve = (previous) async =>
          _ready(previous).copyWith(guestDownload: true);
      final ids = await fixture.manager.enqueueAll([
        _planned('guest-a'),
        _planned('guest-b'),
        _planned('guest-c'),
      ]);
      await until(
        () => ids.every(
          (id) => fixture.manager.task(id)!.status == DownloadStatus.completed,
        ),
      );
      expect(fixture.guestNotices, 1);
      for (final task in fixture.store.data.list('tasks')) {
        expect(DownloadTask.fromJson(task).spec.guestDownload, isTrue);
      }

      fixture.resolve = (previous) async => _ready(previous);
      final normal = await fixture.manager.enqueue(_planned('account-route'));
      await until(
        () => fixture.manager.task(normal)!.status == DownloadStatus.completed,
      );
      expect(fixture.guestNotices, 1);

      final ready = await fixture.manager.enqueue(
        _ready(_planned('preview-guest')).copyWith(guestDownload: true),
      );
      await until(
        () => fixture.manager.task(ready)!.status == DownloadStatus.completed,
      );
      expect(fixture.guestNotices, 2);
    },
  );

  test('Refreshing an expired guest URL does not repeat its notice', () async {
    final fixture = await _Fixture.create();
    fixture.resolve = (previous) async =>
        _ready(previous).copyWith(guestDownload: true);
    final ready = DownloadSpec.fromJson({
      ..._ready(_planned('guest-refresh')).toJson(),
      'url': 'https://cdn.example.test/expired',
      'guestDownload': true,
    });
    final id = await fixture.manager.enqueue(ready);
    await until(
      () => fixture.manager.task(id)!.status == DownloadStatus.completed,
    );
    expect(fixture.http.probes, contains(ready.url));
    expect(fixture.guestNotices, 1);
  });

  test(
    'Update task identity survives cloud URL preparation and task persistence',
    () async {
      final fixture = await _Fixture.create();
      final planned = _planned(
        'app-update',
      ).copyWith(appUpdateKey: 'release-content-key');
      fixture.resolve = (previous) async => DownloadSpec.fromJson({
        ..._ready(previous).toJson(),
        'appUpdateKey': null,
      });
      final id = await fixture.manager.enqueue(planned);
      await until(
        () => fixture.manager.task(id)!.status == DownloadStatus.completed,
      );
      expect(
        fixture.manager.task(id)!.spec.appUpdateKey,
        'release-content-key',
      );
      final saved = fixture.store.data
          .list('tasks')
          .singleWhere((t) => t.str('id') == id);
      expect(
        DownloadTask.fromJson(saved).spec.appUpdateKey,
        'release-content-key',
      );
    },
  );

  test(
    'Preparing a URL cannot discard a known checksum when the refreshed listing omits it',
    () async {
      final fixture = await _Fixture.create();
      final digest = md5.convert(fixture.native.content).toString();
      fixture.native.content[3] = 5;
      final planned = DownloadSpec.fromJson({
        ..._planned('verified').toJson(),
        'checksumType': 'md5',
        'checksumValue': digest,
      });
      fixture.resolve = (previous) async => DownloadSpec.fromJson({
        ..._ready(previous).toJson(),
        'checksumType': null,
        'checksumValue': null,
        'expectedSize': 0,
      });
      final id = await fixture.manager.enqueue(planned);
      await until(
        () =>
            fixture.manager.activeCount == 0 &&
            fixture.manager.task(id)!.status == DownloadStatus.failed,
      );
      expect(fixture.manager.task(id)!.spec.checksumValue, digest);
      expect(fixture.manager.task(id)!.spec.expectedSize, 4);
      expect(fixture.manager.task(id)!.error, contains('校验'));
      expect(fixture.files.savedCount, 0);
    },
  );

  test(
    'An uncommitted prepared source rolls back and remains recoverable after a storage failure',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aster-source-commit-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final state = await StateStore.open(directory, testKey: Uint8List(32));
      final fixture = await _Fixture.create(state: state);
      const cleanup = DownloadCleanup(
        url: 'https://example.test/delete',
        body: '{}',
      );
      Directory? blocked;
      fixture.resolve = (previous) async {
        await fixture.cleanups.stage(cleanup);
        fixture.cleanups.retain(cleanup);
        blocked = await Directory('${state.file!.path}.tmp').create();
        return _ready(previous).copyWith(cleanup: cleanup);
      };
      final id = await fixture.manager.enqueue(_planned('commit'));
      try {
        await until(() => blocked != null && fixture.manager.activeCount == 0);
        expect(fixture.manager.task(id)!.spec.needsPreparation, isTrue);
        expect(fixture.manager.task(id)!.spec.cleanup, isNull);
        expect(fixture.native.begins, isEmpty);
      } finally {
        await blocked?.delete();
      }
      await fixture.manager.pause(id);
      await fixture.cleanups.reconcile(recoverOrphans: true);
      expect(
        state.data.obj('cleanups').obj(cleanupKey(cleanup)).boolean('ready'),
        isTrue,
      );
      await fixture.cleanups.drain();
      expect(fixture.cleanups.pendingCount, 0);
    },
  );

  test(
    'Batch tasks are durable before bounded preparation; a failed item can resume with its original ID',
    () async {
      final fixture = await _Fixture.create();
      final release = Completer<void>();
      var preparing = 0, peak = 0, failFirst = true;
      final contexts = <String, String>{};
      fixture.resolve = (previous) async {
        final name = previous.source!.obj('file').str('id');
        expect(fixture.store.data.list('tasks'), hasLength(3));
        contexts[name] = DownloadRequestContext.current!.id;
        preparing++;
        if (preparing > peak) peak = preparing;
        try {
          await Future.any([release.future, RequestScope.current!.whenCancel]);
          RequestScope.checkpoint();
          if (name == 'first' && failFirst) {
            throw const AppException('fixture link unavailable');
          }
          return _ready(previous);
        } finally {
          preparing--;
        }
      };
      final ids = await fixture.manager.enqueueAll([
        _planned('first'),
        _planned('second'),
        _planned('third'),
      ]);
      await until(() => preparing == 2);
      expect(fixture.native.begins, isEmpty);
      expect(fixture.manager.task(ids.last)!.status, DownloadStatus.pending);
      release.complete();
      await until(
        () => fixture.manager.activeCount == 0 && fixture.files.savedCount == 2,
      );
      expect(fixture.manager.task(ids.first)!.status, DownloadStatus.failed);
      expect(contexts, {'first': ids[0], 'second': ids[1], 'third': ids[2]});
      expect(peak, 2);
      expect(fixture.manager.task(ids[1])!.spec.fileName, 'second.bin');
      expect(
        fixture.manager.task(ids[1])!.spec.relativePath,
        'selected-folder',
      );
      failFirst = false;
      await fixture.manager.resume(ids.first);
      await until(
        () =>
            fixture.manager.task(ids.first)!.status ==
                DownloadStatus.completed &&
            fixture.manager.activeCount == 0,
      );
      expect(fixture.manager.tasks.map((task) => task.id).toSet(), ids.toSet());
      expect(fixture.files.savedCount, 3);
      expect(contexts['first'], ids.first);
    },
  );

  test(
    'Queued origins survive restart and retain their captured retry, speed, and route settings',
    () async {
      final first = await _Fixture.create();
      await first.store.put('settings', {
        ...first.store.data.obj('settings'),
        'concurrent': 1,
      });
      final entered = Completer<void>();
      first.resolve = (previous) async {
        if (!entered.isCompleted) entered.complete();
        await RequestScope.wait(const Duration(hours: 1));
        return _ready(previous);
      };
      final ids = await first.manager.enqueueAll([
        _planned('first'),
        _planned('waiting'),
      ]);
      await entered.future;
      final snapshot = StateStore.memory(first.store.data);
      await first.close();
      await snapshot.put('settings', {
        'threads': 2,
        'concurrent': 3,
        'retries': 0,
        'speedLimit': 0,
        'downloadThreadOverrides': {'quark_route_2': 2},
      });
      final restarted = await _Fixture.create(state: snapshot);
      expect(restarted.native.begins, isEmpty);
      for (final id in ids) {
        final task = restarted.manager.task(id)!;
        expect(task.status, DownloadStatus.paused);
        expect(task.spec.needsPreparation, isTrue);
        final origin = DownloadOrigin.fromJson(task.spec.source!);
        expect(origin.session.accountId, 'original-account');
        expect(origin.accountRevision, 42);
        expect(task.connectionOptions['quark_route_2'], 9);
      }
      restarted.resolve = (previous) async {
        expect(DownloadRequestContext.current!.id, ids.last);
        expect(DownloadRequestContext.current!.retries, 1);
        return _ready(previous);
      };
      await restarted.manager.resume(ids.last);
      await until(
        () =>
            restarted.manager.task(ids.last)!.status ==
                DownloadStatus.completed &&
            restarted.manager.activeCount == 0,
      );
      final completed = restarted.manager.task(ids.last)!;
      expect(completed.connections, 9);
      expect(completed.speedLimit, 4096);
      expect(completed.retries, 1);
      expect(completed.connectionOptions, isEmpty);
      expect(restarted.native.begins.single['connections'], 9);
      expect(restarted.manager.task(ids.first)!.status, DownloadStatus.paused);
    },
  );

  test(
    'Pause interrupts preparation without starting the native downloader',
    () async {
      final fixture = await _Fixture.create();
      final entered = Completer<void>();
      fixture.resolve = (previous) async {
        entered.complete();
        await RequestScope.wait(const Duration(hours: 1));
        return _ready(previous);
      };
      final id = await fixture.manager.enqueue(_planned('waiting'));
      await entered.future;
      await fixture.manager.pause(id).timeout(const Duration(seconds: 1));
      expect(fixture.manager.task(id)!.status, DownloadStatus.paused);
      expect(fixture.manager.task(id)!.spec.needsPreparation, isTrue);
      expect(fixture.native.begins, isEmpty);
      expect(fixture.native.openCount, 0);
    },
  );

  test(
    'A late prepared response after pause releases its temporary transfer',
    () async {
      final fixture = await _Fixture.create();
      final entered = Completer<void>(), cancelled = Completer<void>();
      final response = Completer<DownloadSpec>();
      const cleanup = DownloadCleanup(
        url: 'https://example.test/delete',
        body: '{}',
      );
      fixture.resolve = (previous) async {
        await fixture.cleanups.stage(cleanup);
        fixture.cleanups.retain(cleanup);
        unawaited(
          RequestScope.current!.whenCancel.then((_) => cancelled.complete()),
        );
        entered.complete();
        return response.future;
      };
      final planned = _planned('late');
      final id = await fixture.manager.enqueue(planned);
      await entered.future;
      final pausing = fixture.manager.pause(id);
      await cancelled.future;
      response.complete(_ready(planned).copyWith(cleanup: cleanup));
      await pausing;
      expect(fixture.native.begins, isEmpty);
      expect(fixture.manager.task(id)!.spec.needsPreparation, isTrue);
      expect(
        fixture.store.data
            .obj('cleanups')
            .obj(cleanupKey(cleanup))
            .boolean('ready'),
        isTrue,
      );
      await fixture.cleanups.drain();
      expect(fixture.cleanups.pendingCount, 0);
    },
  );

  test(
    'An invalid prepared URL fails only its task and releases temporary ownership',
    () async {
      final fixture = await _Fixture.create();
      const cleanup = DownloadCleanup(
        url: 'https://example.test/delete',
        body: '{}',
      );
      fixture.resolve = (previous) async {
        await fixture.cleanups.stage(cleanup);
        fixture.cleanups.retain(cleanup);
        return DownloadSpec.fromJson({
          ..._ready(previous).toJson(),
          'url': 'file:///invalid',
          'cleanup': cleanup.toJson(),
        });
      };
      final id = await fixture.manager.enqueue(_planned('invalid'));
      await until(
        () =>
            fixture.manager.task(id)!.status == DownloadStatus.failed &&
            fixture.manager.activeCount == 0,
      );
      expect(fixture.native.begins, isEmpty);
      expect(
        fixture.store.data
            .obj('cleanups')
            .obj(cleanupKey(cleanup))
            .boolean('ready'),
        isTrue,
      );
    },
  );

  test(
    'An expired transfer is refreshed within the same task context',
    () async {
      final fixture = await _Fixture.create();
      final previous = DownloadSpec.fromJson({
        ..._planned('expired').toJson(),
        'url': 'https://cdn.example.test/expired',
      });
      final contexts = <String>[];
      fixture.resolve = (old) async {
        expect(old.url, previous.url);
        contexts.add(DownloadRequestContext.current!.id);
        return DownloadSpec.fromJson({
          ..._ready(old).toJson(),
          'url': 'https://cdn.example.test/renewed',
        });
      };
      final id = await fixture.manager.enqueue(previous);
      await until(
        () =>
            fixture.manager.task(id)!.status == DownloadStatus.completed &&
            fixture.manager.activeCount == 0,
      );
      expect(contexts, [id]);
      expect(fixture.http.probes, [
        previous.url,
        'https://cdn.example.test/renewed',
      ]);
      expect(fixture.manager.task(id)!.connections, 16);
    },
  );

  test(
    'Failure to persist a batch rolls back every new row before preparation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aster-preparation-state-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final state = await StateStore.open(directory, testKey: Uint8List(32));
      final fixture = await _Fixture.create(state: state);
      await Future<void>.delayed(Duration.zero);
      await state.flush();
      final blocked = await Directory('${state.file!.path}.tmp').create();
      var preparations = 0;
      fixture.resolve = (previous) async {
        preparations++;
        return _ready(previous);
      };
      try {
        await expectLater(
          fixture.manager.enqueueAll([_planned('first'), _planned('second')]),
          throwsA(isA<FileSystemException>()),
        );
        expect(fixture.manager.tasks, isEmpty);
        expect(state.data.list('tasks'), isEmpty);
        expect(preparations, 0);
        expect(fixture.native.begins, isEmpty);
      } finally {
        await blocked.delete();
      }
    },
  );
}
