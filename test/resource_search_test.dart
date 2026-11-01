import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/resource_link_checks.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'support.dart';
import 'resource_link_check_support.dart';

Stream<ResourceSearchBatch> checkedSearchBatch(List<ResourceSearchHit> hits) {
  // A local cancellation future stays inside fake_async's clock/zone.
  final stream = StreamController<ResourceSearchBatch>(onCancel: () async {});
  stream.add(ResourceSearchBatch(hits, complete: true));
  unawaited(stream.close());
  return stream.stream;
}

ResourceSearchHit searchHit(
  String id, {
  String password = '',
  String? url,
  String title = 'Python 教程',
  String description = '',
}) => ResourceSearchHit.fromRaw({
  'title': title,
  'share_link': url ?? 'https://pan.quark.cn/s/$id',
  'password': password,
  'description': description,
  'source_name': '资料分享',
});

class SearchApiFixture
    implements ResourceSearchApi, ResourceDiscoveryApi, ResourceCatalogApi {
  SearchApiFixture(this.respond);
  final Stream<ResourceSearchBatch> Function(String, CancelToken) respond;
  final calls = <String>[];
  final cancellations = <CancelToken>[];
  final openCalls = <ResourceSearchHit>[];
  final openCancellations = <CancelToken>[];
  final openSelections = <ResourceSearchFileSelection>[];
  final recommendationCalls = <({List<int> exclude, bool refresh})>[];
  Future<List<ResourceSearchHit>> Function(List<int>, bool)? discover;
  final catalogCalls = <({String section, List<int> exclude})>[];
  Future<ResourceCatalog> Function(String, List<int>)? catalogRespond;
  @override
  Future<ResourceCatalog> catalog({
    String refreshSection = '',
    List<int> exclude = const [],
  }) async {
    catalogCalls.add((section: refreshSection, exclude: exclude));
    return catalogRespond?.call(refreshSection, exclude) ??
        ResourceCatalog(
          popular: await recommendations(
            exclude: exclude,
            refresh: refreshSection.isNotEmpty,
          ),
        );
  }

  @override
  Future<List<ResourceSearchHit>> recommendations({
    List<int> exclude = const [],
    bool refresh = false,
  }) {
    recommendationCalls.add((exclude: exclude, refresh: refresh));
    return discover?.call(exclude, refresh) ?? Future.value([]);
  }

  Future<ResourceSearchOpenResult> Function(
    ResourceSearchHit,
    CancelToken,
    ResourceSearchFileSelection,
  )?
  resolve;
  @override
  Future<ResourceSearchOpenResult> open(
    ResourceSearchHit hit,
    CancelToken cancellation, {
    required ResourceSearchFileSelection selection,
  }) {
    openCalls.add(hit);
    openCancellations.add(cancellation);
    openSelections.add(selection);
    return resolve?.call(hit, cancellation, selection) ??
        Future.value(
          ResourceSearchOpenResult(
            hit: hit,
            mode: 'pool_share',
            transferScope: 'file',
            sourceFileId: selection.fileId,
          ),
        );
  }

  @override
  Stream<ResourceSearchBatch> search(String keyword, CancelToken cancellation) {
    calls.add(keyword);
    cancellations.add(cancellation);
    return respond(keyword, cancellation);
  }
}

void main() {
  test('Tianyi share code is not shown as an extraction password', () {
    final hit = ResourceSearchHit.fromRaw({
      'title': '天翼资源',
      'url': 'https://cloud.189.cn/web/share?code=j6bEZvJRry22',
      'password': 'j6bEZvJRry22',
      'cloud_name': '天翼云盘',
    });
    expect(hit.password, isEmpty);
    expect(hit.link?.passcode, isNull);
    final oldResponse = ResourceSearchHit.fromRaw({
      'title': '天翼资源',
      'url': 'https://cloud.189.cn/web/share?code=j6bEZvJRry22',
      'password': 'j6bEZv',
    });
    expect(oldResponse.password, isEmpty);
  });

  test('Explicit Tianyi accessCode remains available', () {
    final hit = ResourceSearchHit.fromRaw({
      'title': '天翼资源',
      'url': 'https://cloud.189.cn/web/share?code=j6bEZvJRry22&accessCode=aB12',
      'cloud_name': '天翼云盘',
    });
    expect(hit.password, 'aB12');
    expect(hit.link?.passcode, 'aB12');
  });

  test(
    'new pool share uses only its own password and grants refresh during merge',
    () {
      final original = ResourceSearchHit.fromRaw({
        'title': 'Python',
        'url': 'https://pan.quark.cn/s/original',
        'password': 'old1',
        'open_ticket': 'old-ticket',
      });
      final updated = ResourceSearchHit.fromRaw({
        'title': 'Python',
        'url': original.url,
        'open_ticket': 'new-ticket',
      });
      expect(original.merge(updated).openTicket, 'new-ticket');
      for (final data in [
        {'mode': 'temp_share', 'url': 'https://pan.quark.cn/s/new'},
        {'mode': 'temp_share', 'url': 'https://pan.quark.cn/s/new?pwd=nEw2'},
        {
          'mode': 'temp_share',
          'url': 'https://pan.quark.cn/s/new',
          'password': 'nEw2',
        },
      ]) {
        final result = ResourceSearchOpenResult.fromJson(original, data);
        expect(
          result.hit.password,
          data['password'] ?? (data['url']!.contains('?pwd=') ? 'nEw2' : ''),
        );
        expect(result.hit.password, isNot('old1'));
      }
      expect(original.password, 'old1');
    },
  );
  test(
    'magnet results reuse the existing torrent flow and deduplicate trackers',
    () {
      const hash = '1234567890123456789012345678901234567890';
      final one = searchHit('one', url: 'magnet:?xt=urn:btih:$hash&dn=sample');
      final two = searchHit(
        'two',
        url: 'magnet:?xt=urn:btih:$hash&tr=https%3A%2F%2Ftracker.example',
      );
      expect(one.canParse, isTrue);
      expect(one.identity, two.identity);
      expect(one.cloudName, '磁力链接');
    },
  );
  test(
    'split UTF-8, CRLF, comments and multiline SSE data are decoded',
    () async {
      const text =
          ': heartbeat\r\nevent: message\r\ndata: {"type":"update",\r\ndata: "results":[{"title":"电子书","url":"https://pan.quark.cn/s/test"}]}\r\n\r\ndata: {"type":"complete","results":[]}\n\n';
      final chunks = Stream.fromIterable(
        utf8.encode(text).map((byte) => [byte]),
      );
      final events = await decodeSearchEvents(chunks).toList();
      expect(events.length, 2);
      expect(events[0]['results'][0]['title'], '电子书');
      expect(events[1]['type'], 'complete');
    },
  );

  test(
    'JSON fallback uses the public API and preserves explicit password',
    () async {
      final http = FakeHttp(
        (call) => jsonResponse({
          'success': true,
          'results': [
            {
              'title': '教材',
              'url': 'https://pan.quark.cn/s/books',
              'password': 'aB12',
            },
          ],
        }),
      );
      final api = HttpResourceSearchApi(
        http,
        endpoint: 'https://search.example/',
      );
      final token = CancelToken();
      final result = await api.search('Python 教程', token).single;
      token.cancel();
      expect(result.complete, isTrue);
      expect(result.items.single.link!.passcode, 'aB12');
      expect(http.calls.single.uri.path, '/api/v1/search');
      expect(http.calls.single.uri.queryParameters['keyword'], 'Python 教程');
      expect(http.calls.single.uri.queryParameters['limit'], '0');
      expect(http.calls.single.headers.keys, isNot(contains('X-API-Key')));
    },
  );

  test('search batches accept more than one thousand results', () {
    final batch = ResourceSearchBatch.fromJson({
      'type': 'complete',
      'results': [
        for (var i = 0; i < 1500; i++)
          {'title': 'Python 教程 $i', 'url': 'https://pan.quark.cn/s/lesson$i'},
      ],
    });
    expect(batch.items, hasLength(1500));
    expect(batch.complete, true);
  });

  test('SSE total bytes do not truncate later search batches', () async {
    final description = 'x' * (1024 * 1024);
    final chunks = Stream.fromIterable([
      for (var i = 0; i < 5; i++)
        utf8.encode(
          'data: ${jsonEncode({
            'type': 'update',
            'results': [
              {'title': 'Python $i', 'description': description},
            ],
          })}\n\n',
        ),
      utf8.encode('data: {"type":"complete","results":[]}\n\n'),
    ]);
    final events = await decodeSearchEvents(chunks).toList();
    expect(events, hasLength(6));
    expect(events.last['type'], 'complete');
  });

  test(
    'canonical identities ignore tracking queries and retain separate shares',
    () {
      final first = searchHit('same');
      final duplicate = searchHit(
        'same?from=channel',
        password: 'aB12',
        description: '完整资料',
      );
      expect(first.identity, duplicate.identity);
      expect(first.identity, isNot(searchHit('another').identity));
      final merged = first.merge(duplicate);
      expect(merged.password, 'aB12');
      expect(merged.link!.passcode, 'aB12');
      expect(merged.copyText, contains('提取码：aB12'));
    },
  );

  test('legacy array results and malformed upstream items are tolerated', () {
    final result = ResourceSearchBatch.fromJson({
      'type': 'complete',
      'results': [
        ['tg', '电子书', 'https://pan.baidu.com/s/1test?pwd=1234', '百度网盘'],
        {'url': 'javascript:alert(1)'},
        {'url': ''},
      ],
    });
    expect(result.items.length, 1);
    expect(result.items.single.password, '1234');
    expect(result.items.single.canParse, isTrue);
  });

  test(
    'incremental duplicates merge, final order replaces provisional order',
    () async {
      final api = SearchApiFixture(
        (_, _) => Stream.fromIterable([
          ResourceSearchBatch([searchHit('one'), searchHit('two')]),
          ResourceSearchBatch([searchHit('one?from=tg', password: '1234')]),
          ResourceSearchBatch([
            searchHit('two'),
            searchHit('one', password: '1234'),
          ], complete: true),
        ]),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      expect(search.items.map((h) => h.identity), ['Quark:two', 'Quark:one']);
      expect(search.items.last.password, '1234');
      expect(search.phase, ResourceSearchPhase.complete);
      search.filter('百度网盘');
      expect(search.items, isEmpty);
      search.filter(null);
      expect(search.items.length, 2);
      expect(api.calls.length, 1);
    },
  );

  test('a new query cancels the old one and ignores late batches', () async {
    final old = StreamController<ResourceSearchBatch>();
    final api = SearchApiFixture(
      (keyword, _) => keyword == '旧查询'
          ? old.stream
          : Stream.value(
              ResourceSearchBatch([searchHit('new')], complete: true),
            ),
    );
    final search = ResourceSearch(store: StateStore.memory(), api: api);
    addTearDown(search.dispose);
    final previous = search.search('旧查询');
    await Future<void>.delayed(Duration.zero);
    await search.search('新查询');
    expect(api.cancellations.first.isCancelled, isTrue);
    old.add(ResourceSearchBatch([searchHit('old')], complete: true));
    await old.close();
    await previous;
    expect(search.items.single.identity, 'Quark:new');
    expect(search.keyword, '新查询');
  });

  test(
    'title filters combine all include terms and any exclude term locally',
    () async {
      final api = SearchApiFixture(
        (_, _) => Stream.value(
          ResourceSearchBatch([
            searchHit('book', title: 'PYTHON 数据分析 · 电子书'),
            searchHit('video', title: 'Python 数据分析视频课程'),
            searchHit('other', title: 'Python 自动化办公'),
            searchHit(
              'baidu',
              url: 'https://pan.baidu.com/s/1book',
              title: 'Python 数据分析教材',
            ),
          ], complete: true),
        ),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      search.setKeywordFilters(include: 'python  数据', exclude: '视频 办公');
      expect(search.items.map((hit) => hit.identity), [
        'Quark:book',
        'Baidu:book',
      ]);
      search.filter('百度网盘');
      expect(search.items.single.identity, 'Baidu:book');
      expect(search.allItems.length, 4);
      expect(api.calls.length, 1);
      search.setKeywordFilters();
      search.filter(null);
      expect(search.items.length, 4);
      expect(search.hasKeywordFilters, isFalse);
    },
  );

  test(
    'more than one thousand streamed hits survive final ordering and cache',
    () async {
      final hits = List.generate(1500, (i) => searchHit('bulk$i'));
      final api = SearchApiFixture(
        (_, _) => Stream.fromIterable([
          ResourceSearchBatch(hits.take(75).toList()),
          ResourceSearchBatch(hits.reversed.toList(), complete: true),
        ]),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      expect(search.allItems.length, 1500);
      expect(search.items.first.identity, 'Quark:bulk1499');
      await search.search('python');
      expect(search.items.length, 1500);
      expect(api.calls.length, 1);
    },
  );

  test('stopping a query preserves partial results', () async {
    final stream = StreamController<ResourceSearchBatch>();
    final search = ResourceSearch(
      store: StateStore.memory(),
      api: SearchApiFixture((_, _) => stream.stream),
    );
    addTearDown(search.dispose);
    final running = search.search('Python');
    stream.add(ResourceSearchBatch([searchHit('partial')]));
    await Future<void>.delayed(Duration.zero);
    search.stop();
    stream.add(const ResourceSearchBatch([], complete: true));
    await stream.close();
    await running;
    expect(search.phase, ResourceSearchPhase.stopped);
    expect(search.items.single.identity, 'Quark:partial');
  });

  test(
    'stream failure retains results and is never cached as complete',
    () async {
      final api = SearchApiFixture((_, _) async* {
        yield ResourceSearchBatch([searchHit('partial')]);
        throw const AppException('连接中断');
      });
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      expect(search.phase, ResourceSearchPhase.failed);
      expect(search.items.length, 1);
      expect(search.error, '连接中断');
      await search.search('Python');
      expect(api.calls.length, 2);
    },
  );

  test(
    'complete results have bounded cache and case-insensitive history',
    () async {
      final api = SearchApiFixture(
        (_, _) => Stream.value(
          ResourceSearchBatch([searchHit('cached')], complete: true),
        ),
      );
      final search = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(search.dispose);
      await search.search('Python');
      await search.search('python');
      expect(search.fromCache, isTrue);
      expect(api.calls.length, 1);
      await search.search('Python', refresh: true);
      expect(api.calls.length, 2);
      await Future<void>.delayed(Duration.zero);
      expect(search.history.length, 1);
      await search.clearHistory();
      expect(search.history, isEmpty);
    },
  );

  test('total budget stops silent streams and preserves partial results', () {
    fakeAsync((time) {
      final stream = StreamController<ResourceSearchBatch>();
      final api = SearchApiFixture((_, _) => stream.stream);
      final search = ResourceSearch(
        store: StateStore.memory(),
        api: api,
        budget: const Duration(seconds: 3),
      );
      unawaited(search.search('Python'));
      stream.add(ResourceSearchBatch([searchHit('partial')]));
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 4));
      expect(search.phase, ResourceSearchPhase.failed);
      expect(search.items.length, 1);
      expect(api.cancellations.single.isCancelled, isTrue);
      search.dispose();
      unawaited(stream.close());
      time.flushMicrotasks();
    });
  });

  test('checked links are published in batches before the search finishes', () {
    fakeAsync((fake) {
      final stream = StreamController<ResourceSearchBatch>(
        onCancel: () async {},
      );
      final probe = LinkCheckApiFixture();
      final search = ResourceSearch(
        store: StateStore.memory(),
        api: SearchApiFixture((_, _) => stream.stream),
        linkChecks: ResourceLinkChecks(probe),
      );
      unawaited(search.search('Python'));
      stream.add(
        ResourceSearchBatch([
          searchHit('dead'),
          searchHit('good'),
          searchHit('locked'),
          searchHit('slow'),
        ]),
      );
      fake.flushMicrotasks();
      expect(search.items, isEmpty);
      expect(search.checkTotal, 4);
      expect(probe.calls, hasLength(3));
      probe.calls[1].complete(ResourceLinkState.valid);
      probe.calls[0].complete(ResourceLinkState.invalid);
      probe.calls[2].complete(ResourceLinkState.locked);
      fake.flushMicrotasks();
      fake.elapse(const Duration(milliseconds: 250));
      expect(search.phase, ResourceSearchPhase.searching);
      expect(search.items.map((h) => h.identity), [
        'Quark:good',
        'Quark:locked',
        'Quark:dead',
      ]);
      expect(search.checkCompleted, 3);
      expect(search.items.any((hit) => hit.identity == 'Quark:slow'), isFalse);
      stream.add(ResourceSearchBatch(search.allItems, complete: true));
      unawaited(stream.close());
      fake.flushMicrotasks();
      expect(search.phase, ResourceSearchPhase.checking);
      probe.calls.last.complete(ResourceLinkState.unknown);
      fake.flushMicrotasks();
      expect(search.phase, ResourceSearchPhase.complete);
      expect(search.items.map((h) => h.identity), [
        'Quark:good',
        'Quark:locked',
        'Quark:slow',
        'Quark:dead',
      ]);
      search.dispose();
      fake.flushMicrotasks();
      expect(fake.pendingTimers, isEmpty);
    });
  });

  test(
    'all unconfirmed states share a middle group and manual rechecks preserve order',
    () {
      fakeAsync((fake) {
        final hits = [
          searchHit('invalid'),
          searchHit('unknown'),
          searchHit('unsupported'),
          searchHit('locked'),
          searchHit('valid', url: 'https://pan.baidu.com/s/1valid'),
        ];
        final probe = LinkCheckApiFixture();
        final checks = ResourceLinkChecks(probe, concurrency: 5);
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: SearchApiFixture((_, _) => checkedSearchBatch(hits)),
          linkChecks: checks,
        );
        unawaited(search.search('Python'));
        fake.flushMicrotasks();
        for (final (i, state) in [
          ResourceLinkState.invalid,
          ResourceLinkState.unknown,
          ResourceLinkState.unsupported,
          ResourceLinkState.locked,
          ResourceLinkState.valid,
        ].indexed) {
          probe.calls[i].complete(state);
        }
        fake.flushMicrotasks();
        final order = search.items.map((h) => h.identity).toList();
        expect(order, [
          'Baidu:valid',
          'Quark:unknown',
          'Quark:unsupported',
          'Quark:locked',
          'Quark:invalid',
        ]);
        checks.retry(hits.first);
        fake.flushMicrotasks();
        expect(search.items.map((h) => h.identity), order);
        probe.calls.last.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        expect(search.health(hits.first)!.state, ResourceLinkState.valid);
        expect(search.items.map((h) => h.identity), order);
        search.filter('夸克网盘');
        expect(search.items.map((h) => h.identity), order.skip(1));
        search.filter(null);
        expect(search.items.map((h) => h.identity), order);
        search.dispose();
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'stopping detection publishes found links once and rejects late results',
    () {
      fakeAsync((fake) {
        final hits = [searchHit('good'), searchHit('slow')];
        final probe = LinkCheckApiFixture();
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: SearchApiFixture((_, _) => checkedSearchBatch(hits)),
          linkChecks: ResourceLinkChecks(probe),
        );
        var finished = false;
        unawaited(search.search('Python').then((_) => finished = true));
        fake.flushMicrotasks();
        probe.calls.first.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        search.stop();
        fake.flushMicrotasks();
        expect(finished, isTrue);
        expect(search.phase, ResourceSearchPhase.stopped);
        expect(search.items, hasLength(2));
        expect(search.health(hits.last)!.state, ResourceLinkState.unknown);
        expect(probe.calls.last.cancellation.isCancelled, isTrue);
        probe.calls.last.complete(ResourceLinkState.invalid);
        fake.flushMicrotasks();
        expect(search.health(hits.last)!.state, ResourceLinkState.unknown);
        search.dispose();
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test('later results remain independent of an earlier slow probe', () {
    fakeAsync((fake) {
      final stream = StreamController<ResourceSearchBatch>(
        onCancel: () async {},
      );
      final probe = LinkCheckApiFixture();
      final search = ResourceSearch(
        store: StateStore.memory(),
        api: SearchApiFixture((_, _) => stream.stream),
        linkChecks: ResourceLinkChecks(probe),
      );
      unawaited(search.search('Python'));
      stream.add(ResourceSearchBatch([searchHit('slow')]));
      fake.flushMicrotasks();
      stream.add(
        ResourceSearchBatch([searchHit('second'), searchHit('third')]),
      );
      fake.flushMicrotasks();
      expect(probe.calls, hasLength(3));
      probe.calls[1].complete(ResourceLinkState.valid);
      probe.calls[2].complete(ResourceLinkState.unknown);
      fake.flushMicrotasks();
      fake.elapse(const Duration(milliseconds: 250));
      expect(search.items.map((hit) => hit.identity), [
        'Quark:second',
        'Quark:third',
      ]);
      expect(search.checkCompleted, 2);
      probe.calls.first.complete(ResourceLinkState.invalid);
      stream.add(ResourceSearchBatch(search.allItems, complete: true));
      unawaited(stream.close());
      fake.flushMicrotasks();
      expect(search.phase, ResourceSearchPhase.complete);
      expect(search.items.last.identity, 'Quark:slow');
      search.dispose();
      fake.flushMicrotasks();
      expect(fake.pendingTimers, isEmpty);
    });
  });

  test(
    'corrected passwords are checked again without showing duplicate or unchecked rows',
    () {
      fakeAsync((fake) {
        final stream = StreamController<ResourceSearchBatch>(
          onCancel: () async {},
        );
        final probe = LinkCheckApiFixture();
        final checks = ResourceLinkChecks(probe);
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: SearchApiFixture((_, _) => stream.stream),
          linkChecks: checks,
        );
        final hit = searchHit('book');
        final protected = searchHit('book', password: 'aB12');
        unawaited(search.search('Python'));
        stream.add(ResourceSearchBatch([hit]));
        fake.flushMicrotasks();
        probe.calls.first.complete(ResourceLinkState.locked);
        fake.flushMicrotasks();
        fake.elapse(const Duration(milliseconds: 250));
        expect(search.items.single.password, isEmpty);
        stream.add(ResourceSearchBatch([protected]));
        fake.flushMicrotasks();
        expect(probe.calls, hasLength(2));
        expect(probe.calls.last.hit.password, 'aB12');
        expect(search.items.single.password, isEmpty);
        probe.calls.last.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        fake.elapse(const Duration(milliseconds: 250));
        expect(search.items, hasLength(1));
        expect(search.items.single.password, 'aB12');
        expect(
          search.health(search.items.single)!.state,
          ResourceLinkState.valid,
        );
        stream.add(ResourceSearchBatch([protected], complete: true));
        unawaited(stream.close());
        fake.flushMicrotasks();
        expect(search.phase, ResourceSearchPhase.complete);
        search.dispose();
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'final batches can remove provisional results while remaining checks continue',
    () {
      fakeAsync((fake) {
        final stream = StreamController<ResourceSearchBatch>(
          onCancel: () async {},
        );
        final probe = LinkCheckApiFixture();
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: SearchApiFixture((_, _) => stream.stream),
          linkChecks: ResourceLinkChecks(probe),
        );
        final hits = [
          searchHit('one'),
          searchHit('removed'),
          searchHit('slow'),
        ];
        unawaited(search.search('Python'));
        stream.add(ResourceSearchBatch(hits));
        fake.flushMicrotasks();
        probe.calls[0].complete(ResourceLinkState.valid);
        probe.calls[1].complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        fake.elapse(const Duration(milliseconds: 250));
        expect(search.items, hasLength(2));
        stream.add(ResourceSearchBatch([hits[2], hits[0]], complete: true));
        unawaited(stream.close());
        fake.flushMicrotasks();
        expect(search.items.single.identity, 'Quark:one');
        expect(search.phase, ResourceSearchPhase.checking);
        probe.calls.last.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        expect(search.items.map((hit) => hit.identity), [
          'Quark:slow',
          'Quark:one',
        ]);
        search.dispose();
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'search deadline stops probes and preserves found links as unconfirmed',
    () {
      fakeAsync((fake) {
        final stream = StreamController<ResourceSearchBatch>(
          onCancel: () async {},
        );
        final probe = LinkCheckApiFixture();
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: SearchApiFixture((_, _) => stream.stream),
          linkChecks: ResourceLinkChecks(probe),
          budget: const Duration(seconds: 2),
        );
        unawaited(search.search('Python'));
        stream.add(ResourceSearchBatch([searchHit('slow')]));
        fake.flushMicrotasks();
        fake.elapse(const Duration(seconds: 2));
        expect(search.phase, ResourceSearchPhase.failed);
        expect(search.items, hasLength(1));
        expect(
          search.health(search.items.single)!.state,
          ResourceLinkState.unknown,
        );
        expect(probe.calls.single.cancellation.isCancelled, isTrue);
        search.dispose();
        unawaited(stream.close());
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'new queries cancel publication timers and checks from older searches',
    () {
      fakeAsync((fake) {
        final probe = LinkCheckApiFixture();
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: SearchApiFixture(
            (keyword, _) => checkedSearchBatch([
              searchHit('${keyword}one'),
              searchHit('${keyword}two'),
            ]),
          ),
          linkChecks: ResourceLinkChecks(probe),
        );
        unawaited(search.search('old'));
        fake.flushMicrotasks();
        probe.calls.first.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        final old = probe.calls.last;
        unawaited(search.search('new'));
        fake.flushMicrotasks();
        expect(old.cancellation.isCancelled, isTrue);
        fake.elapse(const Duration(milliseconds: 300));
        expect(search.items, isEmpty);
        old.complete(ResourceLinkState.invalid);
        for (final call in probe.calls.skip(2)) {
          call.complete(ResourceLinkState.valid);
        }
        fake.flushMicrotasks();
        expect(search.items.map((hit) => hit.identity), [
          'Quark:newone',
          'Quark:newtwo',
        ]);
        search.dispose();
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'cached searches reuse fresh health and recheck expired results before publishing',
    () {
      fakeAsync((fake) {
        final probe = LinkCheckApiFixture();
        DateTime clock() => DateTime(2026, 10, 29).add(fake.elapsed);
        final api = SearchApiFixture(
          (_, _) => checkedSearchBatch([searchHit('cache')]),
        );
        final search = ResourceSearch(
          store: StateStore.memory(),
          api: api,
          clock: clock,
          linkChecks: ResourceLinkChecks(probe, clock: clock),
        );
        unawaited(search.search('Python'));
        fake.flushMicrotasks();
        probe.calls.single.complete(ResourceLinkState.unknown);
        fake.flushMicrotasks();
        unawaited(search.search('python'));
        fake.flushMicrotasks();
        expect(search.fromCache, isTrue);
        expect(probe.calls, hasLength(1));
        expect(search.items, hasLength(1));
        fake.elapse(const Duration(minutes: 1));
        unawaited(search.search('Python'));
        fake.flushMicrotasks();
        expect(api.calls, hasLength(1));
        expect(probe.calls, hasLength(2));
        expect(search.items, isEmpty);
        probe.calls.last.complete(ResourceLinkState.valid);
        fake.flushMicrotasks();
        expect(search.items, hasLength(1));
        search.dispose();
        fake.flushMicrotasks();
        expect(fake.pendingTimers, isEmpty);
      });
    },
  );

  test('cloud display priority keeps unsupported results available', () async {
    final api = SearchApiFixture(
      (_, _) => Stream.value(
        ResourceSearchBatch([
          searchHit('other', url: 'https://unknown.example/share/one'),
          searchHit('supported'),
        ], complete: true),
      ),
    );
    final search = ResourceSearch(store: StateStore.memory(), api: api);
    addTearDown(search.dispose);
    await search.search('Python');
    expect(search.items.first.canParse, isTrue);
    expect(search.items.length, 2);
    await search.setPreferSupported(false);
    expect(search.items.first.canParse, isTrue);
    expect(search.items.last.canParse, isFalse);
    expect(search.allItems.first.canParse, isFalse);
  });
}
