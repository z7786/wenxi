import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/client_search_engine.dart';
import 'package:asterlink/data/client_search_host.dart';
import 'package:asterlink/data/client_search_telegram.dart';
import 'package:asterlink/data/sources/runtime.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';

Json fixture(String name) => asJson(
  jsonDecode(File('test/fixtures/client_search/$name.json').readAsStringSync()),
);
final publicKey = File(
  'test/fixtures/client_search/public-key.txt',
).readAsStringSync();
Stream<ResourceSearchBatch> unavailable(
  String keyword,
  List<String> ids,
  CancelToken token,
) async* {
  throw const AppException('offline');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  final native = library != null && File(library).existsSync();
  ClientSearchEngine engine(
    StateStore store,
    Future<Json> Function(CancelToken) fetch, {
    DateTime Function()? clock,
  }) => ClientSearchEngine(
    store: store,
    endpoint: 'https://backend.example.com',
    fetch: fetch,
    publicKey: publicKey,
    clock: clock,
    runtime: SourceRuntime(libraryPath: library),
    originFetch: (source, options) async => {
      'status': 200,
      'text': jsonEncode({
        'items': [
          {
            'title': 'Python 教程',
            'url': 'https://pan.quark.cn/s/demo',
            'password': 'aB12',
          },
        ],
      }),
    },
  );
  test(
    'signed production manifest validates every enabled local adapter package',
    () {
      final client = engine(StateStore.memory(), (_) async => fixture('one'));
      expect(client.verify(fixture('all-local')).list('sources'), isNotEmpty);
      final tampered = fixture('one')
        ..['signature'] = base64Encode(List<int>.filled(256, 0));
      expect(() => client.verify(tampered), throwsA(isA<AppException>()));
    },
  );
  test('online release validates against bundled backend identity', () {
    final api = ClientSearchEngine(
      store: StateStore.memory(),
      endpoint: 'https://pan.dr7786.top',
      fetch: (_) async => fixture('online-release'),
    );
    final value = api.verify(fixture('online-release'));
    expect(value.list('sources'), hasLength(148));
    expect(
      value.list('sources').where((s) => s.str('control_kind') == 'telegram'),
      hasLength(114),
    );
    expect(
      value
          .list('sources')
          .where((s) => s.str('control_kind') == 'telegram')
          .every((s) => s.str('kind') == 'server'),
      true,
    );
  });
  test(
    'first search waits for startup rules and shares the configuration request',
    () async {
      final manifest = Completer<Json>();
      var fetches = 0;
      final api = engine(StateStore.memory(), (_) {
        fetches++;
        return manifest.future;
      });
      var startupFinished = false, searchFinished = false;
      final startup = api
          .prepare(CancelToken())
          .then((_) => startupFinished = true);
      final firstSearch = api
          .prepare(CancelToken())
          .then((_) => searchFinished = true);
      await Future<void>.delayed(Duration.zero);
      expect(fetches, 1);
      expect(startupFinished, isFalse);
      expect(searchFinished, isFalse);
      manifest.complete(fixture('one'));
      await Future.wait([startup, firstSearch]);
      expect(api.available, isTrue);
      expect(api.revision, isNotEmpty);
      await api.prepare(CancelToken());
      expect(fetches, 1);
    },
  );
  test(
    'canceling a search waiting for startup rules leaves the startup request alive',
    () async {
      final manifest = Completer<Json>();
      final startupToken = CancelToken(), searchToken = CancelToken();
      final api = engine(StateStore.memory(), (token) {
        expect(identical(token, startupToken), isTrue);
        return manifest.future;
      });
      final startup = api.prepare(startupToken);
      final waiting = expectLater(
        api.prepare(searchToken),
        throwsA(isA<AppException>()),
      );
      searchToken.cancel();
      await waiting;
      expect(startupToken.isCancelled, isFalse);
      manifest.complete(fixture('one'));
      await startup;
      expect(api.available, isTrue);
    },
  );
  test(
    'TG starts on the backend without device requests and retains offline cache',
    () async {
      final store = StateStore.memory();
      final tgKey = File(
        'test/fixtures/client_search/tg-server-public-key.txt',
      ).readAsStringSync();
      var requests = 0;
      ClientSearchEngine tgClient(Future<Json> Function(CancelToken) fetch) =>
          ClientSearchEngine(
            store: store,
            endpoint: 'https://backend.example.com',
            fetch: fetch,
            publicKey: tgKey,
            originFetch: (source, options) async {
              requests++;
              throw const SocketException('device cannot reach Telegram');
            },
          );
      final calls = <List<String>>[];
      Stream<ResourceSearchBatch> server(
        String keyword,
        List<String> ids,
        CancelToken token,
      ) async* {
        calls.add(ids.toList());
        expect(keyword, 'Python');
        final hit = ResourceSearchHit.fromRaw({
          'title': 'Python 课程',
          'url': 'https://pan.quark.cn/s/tgcourse',
          'password': 'aB12',
        });
        yield ResourceSearchBatch([hit]);
        yield ResourceSearchBatch([hit], complete: true);
      }

      final online = tgClient((_) async => fixture('tg-server'));
      final batches = await online
          .search('Python', CancelToken(), server)
          .toList();
      expect(calls, [
        ['tg:first', 'tg:second'],
      ]);
      expect(requests, 0);
      expect(batches.first.complete, false);
      expect(batches.last.complete, true);
      expect(batches.last.items, hasLength(1));
      expect(batches.last.items.single.password, 'aB12');
      final offline = tgClient(
        (_) async => throw const SocketException('backend offline'),
      );
      final cached = await offline
          .search('Python', CancelToken(), unavailable)
          .last;
      expect(cached.items.single.url, 'https://pan.quark.cn/s/tgcourse');
      expect(requests, 0);
    },
  );
  test(
    'disabling TG clears cached backend hits and removes TG from the next request',
    () async {
      var now = DateTime(2026, 10, 30), value = fixture('tg-server');
      final calls = <List<String>>[];
      final api = ClientSearchEngine(
        store: StateStore.memory(),
        endpoint: 'https://backend.example.com',
        fetch: (_) async => value,
        publicKey: File(
          'test/fixtures/client_search/tg-server-public-key.txt',
        ).readAsStringSync(),
        clock: () => now,
      );
      Stream<ResourceSearchBatch> server(
        String keyword,
        List<String> ids,
        CancelToken token,
      ) async* {
        calls.add(ids.toList());
        yield ResourceSearchBatch([
          if (ids.isNotEmpty)
            ResourceSearchHit.fromRaw({
              'title': 'Python 课程',
              'url': 'https://pan.quark.cn/s/tgcourse',
            }),
        ], complete: true);
      }

      expect(
        (await api.search('Python', CancelToken(), server).last).items,
        hasLength(1),
      );
      now = now.add(const Duration(minutes: 6));
      value = fixture('tg-server-disabled');
      expect(
        (await api.search('Python', CancelToken(), server).last).items,
        isEmpty,
      );
      expect(calls, [
        ['tg:first', 'tg:second'],
        <String>[],
      ]);
    },
  );
  for (final entry in {'limit-open': 1500, 'limit-locked': 50}.entries) {
    test(
      '${entry.key} merges local and backend hits, deduplicates and caches the configured capacity',
      () async {
        final store = StateStore.memory();
        final limitKey = File(
          'test/fixtures/client_search/limit-public-key.txt',
        ).readAsStringSync();
        Json row(int i) => {
          'title': 'Python 教程 $i',
          'url': 'https://pan.quark.cn/s/lesson$i',
        };
        final client = ClientSearchEngine(
          store: store,
          endpoint: 'https://backend.example.com',
          fetch: (_) async => fixture(entry.key),
          publicKey: limitKey,
          runtime: SourceRuntime(libraryPath: library),
          originFetch: (source, options) async {
            final start = source.id.endsWith('_2') ? 40 : 0;
            return {
              'status': 200,
              'text': jsonEncode({
                'items': [for (var i = start; i < start + 80; i++) row(i)],
              }),
            };
          },
        );
        Stream<ResourceSearchBatch> server(
          String keyword,
          List<String> ids,
          CancelToken token,
        ) async* {
          yield ResourceSearchBatch([
            for (var i = 100; i < 1500; i++) ResourceSearchHit.fromRaw(row(i)),
          ], complete: true);
        }

        final batches = await client
            .search('Python', CancelToken(), server)
            .toList();
        expect(batches.last.items, hasLength(entry.value));
        expect(
          batches.last.items.map((h) => h.identity).toSet(),
          hasLength(entry.value),
        );
        expect(batches.last.complete, true);
        final restarted = ClientSearchEngine(
          store: store,
          endpoint: 'https://backend.example.com',
          publicKey: limitKey,
          fetch: (_) async => throw const SocketException('backend offline'),
          runtime: SourceRuntime(libraryPath: library),
          originFetch: (source, options) async =>
              throw const SocketException('upstream offline'),
        );
        final cached = await restarted
            .search('Python', CancelToken(), unavailable)
            .last;
        expect(cached.items, hasLength(entry.value));
      },
      skip: !native,
    );
  }
  test(
    'offline restart retains authenticated rules and executes on user network',
    () async {
      final store = StateStore.memory();
      final online = engine(store, (_) async => fixture('one'));
      expect(
        (await online.search('Python', CancelToken(), unavailable).last)
            .items
            .single
            .password,
        'aB12',
      );
      final offline = engine(
        store,
        (_) async => throw const SocketException('offline'),
      );
      final result = await offline
          .search('Dart', CancelToken(), unavailable)
          .last;
      expect(result.items.single.url, 'https://pan.quark.cn/s/demo');
      expect(offline.available, true);
    },
    skip: !native,
  );
  test(
    'signed removal clears result cache and never falls back to disabled sources',
    () async {
      var now = DateTime(2026, 10, 30), value = fixture('one');
      final store = StateStore.memory(),
          client = engine(StateStore.memory(), (_) async => value);
      // Use one store across both revisions.
      final api = engine(store, (_) async => value, clock: () => now);
      expect(
        (await api.search('Python', CancelToken(), unavailable).last).items,
        hasLength(1),
      );
      now = now.add(const Duration(minutes: 6));
      value = fixture('empty');
      await api.prepare(CancelToken());
      expect(api.sources, isEmpty);
      expect(
        store.data.values.whereType<Map>().any(
          (v) => asJson(v).obj('results').isNotEmpty,
        ),
        false,
      );
      await expectLater(
        api.search('Python', CancelToken(), unavailable).last,
        throwsA(isA<AppException>()),
      );
      expect(client.disabled, false);
    },
    skip: !native,
  );
  test('signed total shutdown persists across an offline restart', () async {
    final store = StateStore.memory(),
        online = engine(StateStore.memory(), (_) async => fixture('disabled'));
    final api = engine(store, (_) async => fixture('disabled'));
    await api.prepare(CancelToken());
    expect(api.disabled, true);
    final restarted = engine(
      store,
      (_) async => throw const SocketException('offline'),
    );
    await restarted.prepare(CancelToken());
    expect(restarted.disabled, true);
    await expectLater(
      restarted.search('Python', CancelToken(), unavailable).last,
      throwsA(isA<AppException>()),
    );
    expect(online.available, false);
  });
  test('invalid update retains authenticated cached revision', () async {
    var now = DateTime(2026, 10, 30), value = fixture('one');
    final client = engine(
      StateStore.memory(),
      (_) async => value,
      clock: () => now,
    );
    await client.prepare(CancelToken());
    final revision = client.revision;
    now = now.add(const Duration(minutes: 6));
    value = fixture('empty')
      ..['signature'] = base64Encode(List<int>.filled(256, 0));
    await client.prepare(CancelToken());
    expect(client.revision, revision);
  });
  test(
    'encrypted disk cache survives process restart with all networks offline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-search-cache-',
      );
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      try {
        final store = await StateStore.open(directory, testKey: key);
        final api = engine(store, (_) async => fixture('one'));
        expect(
          (await api.search('Python', CancelToken(), unavailable).last).items,
          hasLength(1),
        );
        final disk = await store.file!.readAsBytes();
        expect(
          utf8.decode(disk, allowMalformed: true),
          isNot(contains('pan.quark.cn')),
        );
        store.dispose();
        final reopened = await StateStore.open(directory, testKey: key);
        final offline = ClientSearchEngine(
          store: reopened,
          endpoint: 'https://backend.example.com',
          publicKey: publicKey,
          fetch: (_) async => throw const SocketException('backend offline'),
          runtime: SourceRuntime(libraryPath: library),
          originFetch: (s, o) async =>
              throw const SocketException('upstream offline'),
        );
        expect(
          (await offline.search('Python', CancelToken(), unavailable).last)
              .items
              .single
              .title,
          'Python 教程',
        );
        reopened.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !native,
  );
  test(
    'successful owner query does not erase cached fallback hits on source outage',
    () async {
      final store = StateStore.memory();
      var searches = 0;
      final client = ClientSearchEngine(
        store: store,
        endpoint: 'https://backend.example.com',
        publicKey: publicKey,
        fetch: (_) async => fixture('one'),
        runtime: SourceRuntime(libraryPath: library),
        originFetch: (s, o) async =>
            throw const SocketException('direct offline'),
      );
      Stream<ResourceSearchBatch> server(
        String k,
        List<String> ids,
        CancelToken t,
      ) async* {
        if (ids.isEmpty) {
          yield const ResourceSearchBatch([], complete: true);
          return;
        }
        if (++searches > 1) throw const SocketException('server offline');
        yield ResourceSearchBatch([
          ResourceSearchHit.fromRaw({
            'title': 'Python 教程',
            'url': 'https://pan.quark.cn/s/fallback',
          }),
        ], complete: true);
      }

      expect(
        (await client.search('Python', CancelToken(), server).last).items,
        hasLength(1),
      );
      expect(
        (await client.search('Python', CancelToken(), server).last).items,
        hasLength(1),
      );
      expect(
        store.data.values
            .whereType<Map>()
            .map(asJson)
            .expand((j) => j.obj('results').obj('python').list('items')),
        hasLength(1),
      );
    },
    skip: !native,
  );
  test(
    'TG multi-resource posts retain heading and password next to each link',
    () {
      final rows = parseClientTelegram({
        'text':
            '名称：Python 第一册\n夸克网盘：https://pan.quark.cn/s/first 提取码：aB12\n名称：Dart 第二册\n夸克：https://pan.quark.cn/s/second\n提取码：cD34\n关注频道 @ads',
      });
      expect(rows.map((r) => r.str('title')), ['Python 第一册', 'Dart 第二册']);
      expect(rows.map((r) => r.str('password')), ['aB12', 'cD34']);
    },
  );
  test('TG one resource with several clouds and description keeps title', () {
    final rows = parseClientTelegram({
      'text':
          '#Photoshop\nv2026.1\n简介：软件介绍\n百度：https://pan.baidu.com/s/1example?pwd=aB12\n夸克：https://pan.quark.cn/s/example\n天翼：https://cloud.189.cn/t/example',
    });
    expect(rows.map((r) => r.str('title')).toSet(), {'Photoshop v2026.1'});
    expect(ResourceSearchHit.fromRaw(rows.last).password, isEmpty);
  });
  test(
    'runtime executes legacy projection, typed JSON and parallel details',
    () async {
      final client = engine(StateStore.memory(), (_) async => fixture('one'));
      final manifest = client.verify(fixture('one'));
      final source = manifest.list('sources').single;
      source['rule'] = {
        'variables': {'limit': 2},
        'steps': [
          {
            'id': 'search',
            'request': {
              'url': 'https://example.com/search',
              'json': {'q': '[[keyword]]', 'limit': '[[vars.limit]]'},
              'method': 'POST',
            },
            'extract': {'type': 'json', 'path': 'items'},
          },
          {
            'id': 'detail',
            'foreach': 'steps.search',
            'parallel': 3,
            'on_error': 'skip',
            'request': {'url': 'https://example.com/detail/[[item.id]]'},
            'extract': {'type': 'json', 'path': 'items[*].[title,url]'},
          },
        ],
        'output': 'steps.detail',
      };
      var active = 0, maxActive = 0;
      final package = client.package(source, manifest);
      final host = ClientSearchHost(
        package,
        fetch: (source, options) async {
          if (options.str('url').endsWith('/search')) {
            expect(options.obj('body').integer('limit'), 2);
            expect(options.obj('body').str('q'), 'quote " and 中文');
            return {
              'status': 200,
              'text': jsonEncode({
                'items': [
                  {'id': 1},
                  {'id': 2},
                  {'id': 3},
                ],
              }),
            };
          }
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 30));
          active--;
          return {
            'status': 200,
            'text': jsonEncode({
              'items': [
                {'title': 'Python', 'url': 'https://pan.quark.cn/s/demo'},
              ],
            }),
          };
        },
      );
      final result = await SourceRuntime(libraryPath: library).run(
        package,
        'search',
        {'source': source, 'keyword': 'quote " and 中文', 'uuid': 'visitor'},
        host.call,
      );
      expect(result.list('results'), hasLength(3));
      expect(result.list('results').first.str('title'), 'Python');
      expect(maxActive, 3);
    },
    skip: !native,
  );
  test(
    'HTML extraction captures variables and applies full JMESPath filtering',
    () async {
      final client = engine(StateStore.memory(), (_) async => fixture('one')),
          manifest = fixture('one');
      final parsed = client.verify(manifest),
          source = client.verify(manifest).list('sources').single;
      source['rule'] = {
        'steps': [
          {
            'id': 'init',
            'request': {'url': 'https://example.com/'},
            'extract': {
              'type': 'html',
              'selector': '.item',
              'fields': {
                'title': {'css': 'b'},
                'url': {'css': 'a', 'attr': 'href', 'absolute': true},
              },
            },
            'capture': {
              'csrf': {'css': 'meta', 'attr': 'content'},
            },
          },
          {
            'id': 'search',
            'request': {
              'url': 'https://example.com/api',
              'method': 'POST',
              'json': {'csrf': '[[vars.csrf]]'},
            },
            'extract': {
              'type': 'json',
              'path': 'items[?enabled == `true`].{title:name,url:link}',
            },
          },
        ],
        'output': 'steps.search',
      };
      final p = client.package(source, parsed),
          host = ClientSearchHost(
            client.package(source, parsed),
            fetch: (s, o) async {
              if (o.str('url').endsWith('/api')) {
                expect(o.obj('body').str('csrf'), 'public-token');
                return {
                  'status': 200,
                  'text': jsonEncode({
                    'items': [
                      {
                        'enabled': true,
                        'name': 'Python',
                        'link': 'https://pan.quark.cn/s/demo',
                      },
                      {'enabled': false, 'name': 'skip'},
                    ],
                  }),
                };
              }
              return {
                'status': 200,
                'text':
                    '<meta content="public-token"><div class="item"><b>Python</b><a href="/detail">详情</a></div>',
              };
            },
          );
      final result = await SourceRuntime(libraryPath: library).run(
        p,
        'search',
        {'source': source, 'keyword': 'Python', 'uuid': 'visitor'},
        host.call,
      );
      expect(result.list('results').single.str('title'), 'Python');
    },
    skip: !native,
  );
}
