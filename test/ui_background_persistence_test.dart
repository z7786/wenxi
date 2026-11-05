import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/client_search_engine.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/recent_playback.dart';
import 'browser_test_support.dart' show BrowserTestConnector;
import 'cloud_accounts_favorites_test.dart'
    show AccountFixtureConnector, addFixtureAccount;
import 'player_support.dart' show FakePlaybackBackend;
import 'support.dart' show FakeFiles, FakeHttp, FakeNative, jsonResponse;

/// Models a busy state-storage queue without delaying network requests.
class _BlockedStateStore extends ChangeNotifier implements StateStore {
  _BlockedStateStore([Json? initial]) : delegate = StateStore.memory(initial) {
    delegate.addListener(notifyListeners);
  }
  final StateStore delegate;
  final _writes = AsyncGate();
  Completer<void>? barrier;
  Object? failure;
  int requestedWrites = 0;

  void hold() => barrier = Completer<void>();
  void release() {
    barrier?.complete();
    barrier = null;
  }

  @override
  Json get data => delegate.data;

  @override
  Future<T> change<T>(T Function(Json draft) edit, {String? recoveryPassword}) {
    requestedWrites++;
    final waiting = barrier?.future, rejected = failure;
    return _writes.run(() async {
      await waiting;
      if (rejected != null) throw rejected;
      return delegate.change(edit, recoveryPassword: recoveryPassword);
    });
  }

  @override
  Future<void> put(String key, Object? value) => change<void>((draft) {
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

Json _manifest(String name) => asJson(
  jsonDecode(File('test/fixtures/client_search/$name.json').readAsStringSync()),
);
final _publicKey = File(
  'test/fixtures/client_search/tg-server-public-key.txt',
).readAsStringSync();
final _hit = ResourceSearchHit.fromRaw({
  'title': 'Python 课程',
  'url': 'https://pan.quark.cn/s/tgcourse',
  'open_ticket': 'fixture-grant',
});
Stream<ResourceSearchBatch> _server(
  String keyword,
  List<String> ids,
  CancelToken token,
) async* {
  yield ResourceSearchBatch([_hit], complete: true);
}

Stream<ResourceSearchBatch> _offline(
  String keyword,
  List<String> ids,
  CancelToken token,
) async* {
  throw const SocketException('offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const deadline = Duration(seconds: 2);

  test(
    'Reopening a video uses its closing bookmark while disk persistence is blocked',
    () async {
      final store = _BlockedStateStore();
      final history = PlaybackStore(store);
      const entry = PlaybackEntry(
        id: 'video',
        key: 'reopened-video',
        name: 'video.mkv',
        video: true,
      );
      PlaybackController controller(FakePlaybackBackend backend) =>
          PlaybackController(
            entries: const [entry],
            initialIndex: 0,
            history: PlaybackStore(store),
            prepare: (_, _) async => const DownloadSpec(
              url: 'https://video.example.test/video.mkv',
              fileName: 'video.mkv',
            ),
            retain: (_) {},
            release: (_) async {},
            backendFactory: (_, _) => backend,
          );
      final firstBackend = FakePlaybackBackend('first', []);
      final secondBackend = FakePlaybackBackend('second', []);
      final first = controller(firstBackend),
          second = controller(secondBackend);
      Future<void>? closing;
      try {
        await history.save(
          entry.key,
          const PlaybackBookmark(
            position: Duration(seconds: 30),
            duration: Duration(minutes: 10),
            updatedAt: 1,
          ),
        );
        await first.start();
        await store.flush();
        firstBackend.emit(
          firstBackend.state.copyWith(position: const Duration(minutes: 2)),
        );
        store.hold();
        final writes = store.requestedWrites;
        closing = first.close();
        expect(store.requestedWrites, greaterThan(writes));
        await second.start().timeout(deadline);
        expect(secondBackend.openedStart, const Duration(minutes: 2));
        expect(
          history.recent.first.bookmark.position,
          const Duration(minutes: 2),
        );
        expect(
          PlaybackBookmark.fromJson(
            store.data.obj('playbackHistory').obj(entry.key),
          ).position,
          const Duration(seconds: 30),
        );
      } finally {
        store.release();
        await closing;
        await first.close();
        await second.close();
        await store.flush();
        store.dispose();
      }
    },
  );

  test(
    'A failed pending bookmark falls back to its durable progress',
    () async {
      final store = _BlockedStateStore();
      final history = PlaybackStore(store);
      const key = 'failed-bookmark';
      try {
        await history.save(
          key,
          const PlaybackBookmark(
            position: Duration(seconds: 30),
            duration: Duration(minutes: 10),
            updatedAt: 1,
          ),
        );
        store.hold();
        store.failure = const FileSystemException('fixture disk full');
        final saving = history.save(
          key,
          const PlaybackBookmark(
            position: Duration(minutes: 2),
            duration: Duration(minutes: 10),
            updatedAt: 2,
          ),
        );
        final failed = expectLater(saving, throwsA(isA<FileSystemException>()));
        expect(
          PlaybackStore(store).bookmark(key)!.position,
          const Duration(minutes: 2),
        );
        store.release();
        await failed;
        expect(history.bookmark(key)!.position, const Duration(seconds: 30));
      } finally {
        store.release();
        await store.flush();
        store.dispose();
      }
    },
  );

  for (final clearAll in [false, true]) {
    test(
      'Removing ${clearAll ? 'all history' : 'one record'} after a pending save does not resurrect it',
      () async {
        final store = _BlockedStateStore();
        final history = PlaybackStore(store);
        const key = 'removed-pending-bookmark';
        Future<void>? saving, removing;
        try {
          store.hold();
          saving = history.save(
            key,
            const PlaybackBookmark(
              position: Duration(seconds: 90),
              duration: Duration(minutes: 10),
              updatedAt: 1,
            ),
          );
          expect(PlaybackStore(store).recent, hasLength(1));
          removing = clearAll ? history.clearHistory() : history.remove(key);
          expect(PlaybackStore(store).bookmark(key), isNull);
          store.release();
          await Future.wait([saving, removing]);
          expect(history.bookmark(key), isNull);
          expect(history.recent, isEmpty);
        } finally {
          store.release();
          await saving;
          await removing;
          await store.flush();
          store.dispose();
        }
      },
    );
  }

  test('A completed save cannot discard a newer pending bookmark', () async {
    final store = _BlockedStateStore();
    final history = PlaybackStore(store);
    const key = 'successive-pending-bookmarks';
    Future<void>? first, second;
    try {
      final firstBarrier = Completer<void>();
      store.barrier = firstBarrier;
      first = history.save(
        key,
        const PlaybackBookmark(
          position: Duration(seconds: 90),
          duration: Duration(minutes: 10),
          updatedAt: 1,
        ),
      );
      final secondBarrier = Completer<void>();
      store.barrier = secondBarrier;
      second = PlaybackStore(store).save(
        key,
        const PlaybackBookmark(
          position: Duration(minutes: 3),
          duration: Duration(minutes: 10),
          updatedAt: 2,
        ),
      );
      firstBarrier.complete();
      await first;
      expect(history.bookmark(key)!.position, const Duration(minutes: 3));
      expect(
        store.data.obj('playbackHistory').obj(key).integer('position'),
        90000,
      );
      store.release();
      await second;
      expect(history.bookmark(key)!.position, const Duration(minutes: 3));
    } finally {
      store.release();
      await first;
      await second;
      await store.flush();
      store.dispose();
    }
  });

  test(
    'A pending BT history entry restores before its metadata is on disk',
    () async {
      final root = await Directory.systemTemp.createTemp('pending-bt-history-');
      final store = _BlockedStateStore();
      final app = AppServices(
        store: store,
        dataDirectory: root,
        cacheDirectory: Directory('${root.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${root.path}/saved')),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
      final history = PlaybackStore(store);
      const file = TorrentFile(0, 'lesson.mp4', 4096);
      Future<void>? saving;
      PlaybackController? restored;
      try {
        store.hold();
        saving = history.save(
          'pending-torrent',
          PlaybackBookmark(
            position: const Duration(seconds: 90),
            duration: const Duration(minutes: 10),
            updatedAt: 1,
            name: file.name,
            source: PlaybackSource.torrent(
              '0123456789012345678901234567890123456789',
              file,
              torrentData: '${torrentDataPrefix}Zml4dHVyZQ==',
              torrentFiles: const [file],
            ),
          ),
        );
        expect(store.data.obj('playbackTorrents'), isEmpty);
        restored = await restoreRecentPlayback(
          app,
          PlaybackStore(store).recent.single,
          backendFactory: (_, _) => FakePlaybackBackend('bt', []),
        ).timeout(deadline);
        expect(restored.current.name, file.name);
        expect(restored.entries, hasLength(1));
        expect(app.engine.transport.connected, isFalse);
      } finally {
        store.release();
        await saving;
        await restored?.close();
        await app.close();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'Playback cleanup runs after navigation and shutdown waits for every lease',
    () async {
      final dir = await Directory.systemTemp.createTemp('background-playback-');
      final store = StateStore.memory();
      final services = AppServices(
        store: store,
        dataDirectory: dir,
        cacheDirectory: Directory('${dir.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${dir.path}/saved')),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
      final first = Completer<void>(), second = Completer<void>();
      var closed = false;
      try {
        services.finishPlaybackInBackground(
          first.future.then((_) => store.put('bookmarkSaved', true)),
        );
        final closing = services.close().then((_) => closed = true);
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        services.finishPlaybackInBackground(
          second.future.then((_) => store.put('sourceReleased', true)),
        );
        services.finishPlaybackInBackground(
          Future<void>.error(StateError('fixture failed cleanup')),
        );
        first.complete();
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        second.complete();
        await closing.timeout(deadline);
        expect(store.data.boolean('bookmarkSaved'), isTrue);
        expect(store.data.boolean('sourceReleased'), isTrue);
      } finally {
        if (!first.isCompleted) first.complete();
        if (!second.isCompleted) second.complete();
        await services.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'Favorites open before recent-use persistence and cannot be resurrected',
    () async {
      final store = _BlockedStateStore();
      final vault = Vault(store), http = FakeHttp();
      final cloud = CloudRepository(http, vault, CleanupOutbox(store, http));
      cloud.connectors[CloudPlatform.tianyi] = AccountFixtureConnector(
        CloudPlatform.tianyi,
        vault,
      );
      final owner = await addFixtureAccount(
        vault,
        CloudPlatform.tianyi,
        'A',
        10,
      );
      await vault.activate(CloudPlatform.tianyi, owner);
      final session = await cloud.personal(CloudPlatform.tianyi);
      final favorites = CloudFavorites(store, cloud);
      await favorites.toggle(session, AccountFixtureConnector.folder, [
        ('root', '全部文件'),
      ]);
      final favorite = favorites.all.single;
      try {
        store.hold();
        final opened = await favorites.open(favorite).timeout(deadline);
        expect(opened.files.single.id, 'movie');
        expect(favorites.all.single.lastOpenedAt, 0);
        store.release();
        await store.flush();
        expect(favorites.all.single.lastOpenedAt, greaterThan(0));

        // Deletion may already be queued when a valid location is opened.
        store.hold();
        final removal = favorites.remove(favorite.id);
        expect(
          (await favorites.open(favorite).timeout(deadline)).files,
          isNotEmpty,
        );
        store.release();
        await removal;
        await store.flush();
        expect(favorites.all, isEmpty);
        expect(
          favorites.contains(session, AccountFixtureConnector.folder),
          isFalse,
        );
      } finally {
        store.release();
        await store.flush();
        store.dispose();
      }
    },
  );

  test(
    'Account quota finishes while nickname persistence is blocked',
    () async {
      final dir = await Directory.systemTemp.createTemp('background-account-');
      const platform = CloudPlatform.aliyun;
      final store = _BlockedStateStore({
        'credentials': {
          platform.key: Credential('fixture', {
            'primary': 'fixture-token',
            'accessToken': 'fixture-token',
            'authType': 'webToken',
            'nickname': 'initial',
          }, updatedAt: 42).toJson(),
        },
      });
      final services = AppServices(
        store: store,
        dataDirectory: dir,
        cacheDirectory: Directory('${dir.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${dir.path}/saved')),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
      services.cloud.connectors[platform] = BrowserTestConnector(platform);
      try {
        await services.initialize();
        await services.refreshAccounts();
        await store.flush();
        final owner = services.vault.activeAccountId(platform)!;
        await services.vault.updateAccountNickname(
          platform,
          owner,
          42,
          'stored',
        );
        store.hold();
        final before = store.requestedWrites;
        await services.refreshAccount(platform).timeout(deadline);
        expect(services.accounts[platform]?.total, 1000);
        expect(services.accountLoading, isNot(contains(platform)));
        expect(services.accountErrors, isNot(contains(platform)));
        expect(store.requestedWrites, greaterThan(before));
        expect(services.vault.profiles(platform).single.nickname, 'stored');
        store.release();
        await store.flush();
        expect(services.vault.profiles(platform).single.nickname, '测试账号');
        expect(services.vault.credential(platform)?.updatedAt, 42);
      } finally {
        store.release();
        await services.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'Queued nickname saves reject replaced and removed credentials',
    () async {
      final store = _BlockedStateStore();
      final vault = Vault(store);
      const platform = CloudPlatform.tianyi;
      final owner = await addFixtureAccount(vault, platform, 'A', 10);
      await vault.activate(platform, owner);
      try {
        store.hold();
        final replacement = vault.putCredential(
          platform,
          Credential('new', {
            'primary': 'new-token',
            'nickname': 'new-name',
          }, updatedAt: 20),
        );
        final stale = vault.updateAccountNickname(
          platform,
          owner,
          10,
          'late-name',
        );
        store.release();
        await replacement;
        expect(await stale, isFalse);
        expect(
          vault.credentialFor(platform, owner)?.field('nickname'),
          'new-name',
        );

        store.hold();
        final removal = vault.removeAccount(platform, owner);
        final removed = vault.updateAccountNickname(
          platform,
          owner,
          20,
          'late-name',
        );
        store.release();
        await removal;
        expect(await removed, isFalse);
        expect(vault.profiles(platform), isEmpty);
      } finally {
        store.release();
        await store.flush();
        store.dispose();
      }
    },
  );

  test(
    'Concurrent resource previews share an identity before it is saved',
    () async {
      final store = _BlockedStateStore()..hold();
      final identities = <String>[];
      final http = FakeHttp((call) {
        identities.add(call.headers['X-Resource-Client']!);
        return jsonResponse({
          'success': true,
          'data': {'mode': 'original', 'reason': 'pool_disabled'},
        });
      });
      final api = HttpResourceSearchApi(
        http,
        store: store,
        endpoint: 'http://127.0.0.1:1',
      );
      const selection = ResourceSearchFileSelection(
        fileId: 'file',
        parentId: 'root',
        name: 'lesson.mp4',
        size: 123,
      );
      try {
        final results = await Future.wait([
          api.open(_hit, CancelToken(), selection: selection),
          api.open(_hit, CancelToken(), selection: selection),
        ]).timeout(deadline);
        expect(results.every((r) => r.reason == 'pool_disabled'), isTrue);
        expect(identities, hasLength(2));
        expect(identities.toSet(), hasLength(1));
        expect(identities.first, matches(r'^[a-f0-9]{32}$'));
        expect(store.data.str('resourceClientId'), isEmpty);
        store.release();
        await store.flush();
        expect(store.data.str('resourceClientId'), identities.first);
      } finally {
        store.release();
        await store.flush();
        store.dispose();
      }
    },
  );

  for (final failing in [false, true]) {
    test(
      'Verified search and offline results remain usable with ${failing ? 'failed' : 'blocked'} cache writes',
      () async {
        final store = _BlockedStateStore()..hold();
        if (failing) {
          store.failure = const FileSystemException('fixture disk full');
        }
        final engine = ClientSearchEngine(
          store: store,
          endpoint: 'https://backend.example.com',
          publicKey: _publicKey,
          fetch: (_) async => _manifest('tg-server'),
        );
        try {
          await engine.prepare(CancelToken()).timeout(deadline);
          expect(engine.available, isTrue);
          expect(
            store.data.keys.where((k) => k.startsWith('clientSearch:')),
            isEmpty,
          );
          final result = await engine
              .search('Python', CancelToken(), _server)
              .last
              .timeout(deadline);
          expect(result.complete, isTrue);
          expect(result.items.single.url, _hit.url);
          final cached = await engine
              .search('Python', CancelToken(), _offline)
              .last
              .timeout(deadline);
          expect(cached.complete, isTrue);
          expect(cached.items.single.url, _hit.url);
          store.release();
          await store.flush();
          if (!failing) {
            expect(
              store.data.values.whereType<Map>().single['results'],
              isNotEmpty,
            );
            final restarted = ClientSearchEngine(
              store: store,
              endpoint: 'https://backend.example.com',
              publicKey: _publicKey,
              fetch: (_) async => throw const SocketException('offline'),
            );
            expect(
              (await restarted.search('Python', CancelToken(), _offline).last)
                  .items
                  .single
                  .url,
              _hit.url,
            );
          }
        } finally {
          store.release();
          await store.flush();
          store.dispose();
        }
      },
    );
  }

  test(
    'A successful result save repairs a failed offline search configuration write',
    () async {
      final store = _BlockedStateStore()
        ..failure = const FileSystemException('fixture transient disk failure');
      final engine = ClientSearchEngine(
        store: store,
        endpoint: 'https://backend.example.com',
        publicKey: _publicKey,
        fetch: (_) async => _manifest('tg-server'),
      );
      try {
        await engine.prepare(CancelToken()).timeout(deadline);
        await store.flush();
        store.failure = null;
        await engine
            .search('Python', CancelToken(), _server)
            .last
            .timeout(deadline);
        await store.flush();
        final restarted = ClientSearchEngine(
          store: store,
          endpoint: 'https://backend.example.com',
          publicKey: _publicKey,
          fetch: (_) async => throw const SocketException('offline'),
        );
        expect(
          (await restarted
                  .search('Python', CancelToken(), _offline)
                  .last
                  .timeout(deadline))
              .items
              .single
              .url,
          _hit.url,
        );
      } finally {
        await store.flush();
        store.dispose();
      }
    },
  );

  test(
    'Old in-flight searches cannot restore cache after signed source removal',
    () async {
      final store = _BlockedStateStore()..hold();
      var now = DateTime(2026, 11, 2), release = _manifest('tg-server');
      final engine = ClientSearchEngine(
        store: store,
        endpoint: 'https://backend.example.com',
        publicKey: _publicKey,
        fetch: (_) async => release,
        clock: () => now,
      );
      final started = Completer<void>(), finish = Completer<void>();
      Stream<ResourceSearchBatch> delayed(
        String keyword,
        List<String> ids,
        CancelToken token,
      ) async* {
        started.complete();
        await finish.future;
        yield ResourceSearchBatch([_hit], complete: true);
      }

      try {
        await engine
            .search('Python', CancelToken(), _server)
            .last
            .timeout(deadline);
        final late = engine.search('Dart', CancelToken(), delayed).last;
        await started.future.timeout(deadline);
        now = now.add(const Duration(minutes: 6));
        release = _manifest('tg-server-disabled');
        await engine.prepare(CancelToken()).timeout(deadline);
        expect(engine.sources, isEmpty);
        finish.complete();
        await late.timeout(deadline);
        store.release();
        await store.flush();
        final saved = asJson(store.data.values.whereType<Map>().single);
        expect(saved.obj('results'), isEmpty);
        await expectLater(
          engine.search('Python', CancelToken(), _offline).last,
          throwsA(isA<AppException>()),
        );
      } finally {
        if (!finish.isCompleted) finish.complete();
        store.release();
        await store.flush();
        store.dispose();
      }
    },
  );

  test(
    'Memory and delayed disk search caches keep only twelve keywords',
    () async {
      final store = _BlockedStateStore()..hold();
      final engine = ClientSearchEngine(
        store: store,
        endpoint: 'https://backend.example.com',
        publicKey: _publicKey,
        fetch: (_) async => _manifest('tg-server'),
      );
      try {
        for (var i = 0; i < 13; i++) {
          await engine
              .search('Python$i', CancelToken(), _server)
              .last
              .timeout(deadline);
        }
        await expectLater(
          engine.search('Python0', CancelToken(), _offline).last,
          throwsA(isA<AppException>()),
        );
        expect(
          (await engine.search('Python12', CancelToken(), _offline).last)
              .items
              .single
              .url,
          _hit.url,
        );
        store.release();
        await store.flush();
        final results = asJson(
          store.data.values.whereType<Map>().single,
        ).obj('results');
        expect(results, hasLength(12));
        expect(results, isNot(contains('python0')));
        expect(results, contains('python12'));
      } finally {
        store.release();
        await store.flush();
        store.dispose();
      }
    },
  );
}
