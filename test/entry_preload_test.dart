import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/client_search_engine.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'package:asterlink/main.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'remote_control_support.dart';
import 'resource_recommendations_test.dart' show recommendation;
import 'resource_search_test.dart' show SearchApiFixture;
import 'support.dart';

class _ConfigurationApi extends SearchApiFixture
    implements ResourceSearchConfigurationApi {
  _ConfigurationApi() : super((_, _) => const Stream.empty());
  final tokens = <CancelToken>[];
  Future<void> Function(CancelToken)? configure;
  @override
  Future<void> prepareSources(CancelToken cancellation) async {
    tokens.add(cancellation);
    await configure?.call(cancellation);
  }
}

class _FrameHub extends ParserRuleHub {
  _FrameHub(StateStore store, Directory directory)
    : super(
        store: Vault(store),
        directory: directory,
        url: '',
        apiKey: '',
        publicKey: '',
        backupUrl: '',
      );

  final starts = <SchedulerPhase>[];
  Completer<bool>? refreshPending;
  @override
  void start() => starts.add(SchedulerBinding.instance.schedulerPhase);
  @override
  Future<bool> refresh({bool force = false}) =>
      refreshPending?.future ?? Future.value(false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> closeServices(WidgetTester tester, AppServices services) async {
    var closed = false;
    final closing = services.close().whenComplete(() => closed = true);
    for (var i = 0; i < 100 && !closed; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(closed, isTrue, reason: 'Fixture cleanup must finish');
    await closing;
  }

  ResourceSearch service(_ConfigurationApi api, {DateTime Function()? clock}) {
    final result = ResourceSearch(
      api: api,
      store: StateStore.memory(),
      clock: clock ?? DateTime.now,
    );
    addTearDown(() {
      result.dispose();
      result.store.dispose();
    });
    return result;
  }

  test(
    'local initialization finishes before optional parser, data and rules refresh',
    () async {
      final root = Directory.systemTemp.createTempSync(
        'asterlink-entry-preload-',
      );
      final now = DateTime.fromMillisecondsSinceEpoch(1791936000000);
      final store = StateStore.memory(
        controlCache(controlJson(disabled: ['baidu']), fetched: now),
      );
      final api = _ConfigurationApi();
      final rules = Completer<void>();
      final recommendations = Completer<List<ResourceSearchHit>>();
      final catalog = Completer<ResourceCatalog>();
      api.configure = (_) => rules.future;
      api.discover = (_, _) => recommendations.future;
      api.catalogRespond = (_, _) => catalog.future;
      final search = ResourceSearch(store: store, api: api, clock: () => now);
      final envelope = asJson(
        jsonDecode(
          File('test/fixtures/parser_rules/bundle-1.json').readAsStringSync(),
        ),
      );
      final parserHttp = FakeHttp(
        (_) => jsonResponse({'ok': true, 'data': envelope}),
      );
      final hub = ParserRuleHub(
        store: Vault(store),
        directory: root,
        http: parserHttp,
        url: 'https://parser.example.test',
        apiKey: 'test',
        backupUrl: '',
        publicKey: File(
          'test/fixtures/parser_rules/public-key.txt',
        ).readAsStringSync(),
        clock: () => now,
      );
      final services = AppServices(
        store: store,
        dataDirectory: root,
        cacheDirectory: Directory('${root.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${root.path}/files')),
        http: FakeHttp(),
        parserRuleHub: hub,
        resourceSearch: search,
        platformFeatures: false,
        controlEnabled: true,
        controlUrl: controlEndpoint,
        controlFetcher: FakeControlFetcher(controlJson(disabled: ['baidu'])),
        announcementsUrl: '',
        clock: () => now,
      );
      try {
        expect(services.control.cloudEnabled(CloudPlatform.baidu), isFalse);
        await services.initialize();
        expect(api.tokens, isEmpty);
        expect(api.recommendationCalls, isEmpty);
        expect(api.catalogCalls, isEmpty);
        expect(parserHttp.calls, isEmpty);
        services.refreshEntryData();
        expect(api.tokens, hasLength(1));
        expect(api.recommendationCalls, hasLength(1));
        expect(api.catalogCalls, hasLength(1));
        expect(search.recommendationsLoading, isTrue);
        expect(search.catalogLoading, contains(''));
        expect(api.calls, isEmpty);
        services.refreshEntryData();
        services.refreshEntryData();
        expect(api.tokens, hasLength(1));
        await hub.refresh();
        expect(parserHttp.calls, hasLength(1));
        expect(parserHttp.calls.single.uri.path, '/v1/rules');
        expect(hub.sites, isNotEmpty);
        rules.complete();
        recommendations.complete([recommendation(1)]);
        catalog.complete(ResourceCatalog(popular: [recommendation(2)]));
        await search.preload();
        await search.loadCatalog();
        await search.loadRecommendations();
        expect(search.catalog.popular.single.recommendationId, 2);
        expect(search.recommendations.single.recommendationId, 1);
        expect(api.catalogCalls, hasLength(1));
        expect(api.recommendationCalls, hasLength(1));
        expect(api.calls, isEmpty);
      } finally {
        if (!rules.isCompleted) rules.complete();
        if (!recommendations.isCompleted) recommendations.complete([]);
        if (!catalog.isCompleted) catalog.complete(const ResourceCatalog());
        await services.close();
        store.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  testWidgets('main UI is usable while all entry interfaces remain pending', (
    tester,
  ) async {
    final store = StateStore.memory();
    final root = Directory('test-fixture/startup');
    final hub = _FrameHub(store, root)..refreshPending = Completer<bool>();
    final api = _ConfigurationApi();
    final rules = Completer<void>();
    final recommendations = Completer<List<ResourceSearchHit>>();
    final catalog = Completer<ResourceCatalog>();
    final phases = <SchedulerPhase>[];
    api.configure = (_) {
      phases.add(SchedulerBinding.instance.schedulerPhase);
      return rules.future;
    };
    api.discover = (_, _) => recommendations.future;
    api.catalogRespond = (_, _) => catalog.future;
    final search = ResourceSearch(store: store, api: api);
    final services = AppServices(
      store: store,
      dataDirectory: root,
      cacheDirectory: Directory('${root.path}/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('${root.path}/files')),
      http: FakeHttp(),
      parserRuleHub: hub,
      resourceSearch: search,
      platformFeatures: false,
      controlEnabled: false,
      announcementsUrl: '',
    );
    tester.view.physicalSize = const Size(430, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      await services.initialize();
      expect(api.tokens, isEmpty);
      expect(hub.starts, isEmpty);
      await tester.pumpWidget(
        Builder(
          builder: (_) {
            expect(api.tokens, isEmpty);
            expect(hub.starts, isEmpty);
            return AsterLinkApp(services);
          },
        ),
      );
      expect(find.byType(MainShell), findsOneWidget);
      expect(find.byType(ParsePage), findsOneWidget);
      expect(phases, [SchedulerPhase.postFrameCallbacks]);
      expect(hub.starts, isNotEmpty);
      expect(hub.starts, everyElement(SchedulerPhase.postFrameCallbacks));
      expect(api.recommendationCalls, hasLength(1));
      expect(api.catalogCalls, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('navigation-1')));
      await tester.pump();
      final parser = tester.widget<ParsePage>(
        find.byType(ParsePage, skipOffstage: false),
      );
      expect(parser.active, isFalse);
      expect(parser.resourceActive, isTrue);
      expect(api.catalogCalls, hasLength(1));
      expect(hub.refreshPending!.isCompleted, isFalse);
      expect(rules.isCompleted, isFalse);
      expect(recommendations.isCompleted, isFalse);
      expect(catalog.isCompleted, isFalse);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      hub.refreshPending!.complete(false);
      rules.complete();
      recommendations.complete([]);
      catalog.complete(const ResourceCatalog());
      await closeServices(tester, services);
      store.dispose();
    }
  });

  testWidgets(
    'standalone parser defers service startup until its first frame',
    (tester) async {
      final store = StateStore.memory();
      final root = Directory('test-fixture/startup-parser');
      final hub = _FrameHub(store, root);
      final services = AppServices(
        store: store,
        dataDirectory: root,
        cacheDirectory: Directory('${root.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${root.path}/files')),
        http: FakeHttp(),
        parserRuleHub: hub,
        platformFeatures: false,
        controlEnabled: false,
        announcementsUrl: '',
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (_) {
                expect(hub.starts, isEmpty);
                return Scaffold(body: ParsePage(services));
              },
            ),
          ),
        );
        expect(hub.starts, [SchedulerPhase.postFrameCallbacks]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await closeServices(tester, services);
        store.dispose();
      }
    },
  );

  test(
    'foreground preloads are deduplicated and refresh old data after five minutes',
    () async {
      var now = DateTime(2026, 10, 31);
      final api = _ConfigurationApi();
      var round = 1;
      api.discover = (exclude, refresh) async {
        expect(exclude, isEmpty);
        expect(refresh, isFalse);
        return [recommendation(round)];
      };
      api.catalogRespond = (section, exclude) async {
        expect(section, isEmpty);
        expect(exclude, isEmpty);
        return ResourceCatalog(popular: [recommendation(round)]);
      };
      final search = service(api, clock: () => now);
      final first = search.preload();
      expect(identical(search.preload(), first), isTrue);
      await first;
      now = now.add(const Duration(minutes: 4));
      await search.preload();
      expect(api.tokens, hasLength(1));
      now = now.add(const Duration(minutes: 1));
      round = 2;
      await search.preload();
      expect(api.tokens, hasLength(2));
      expect(api.catalogCalls, hasLength(2));
      expect(api.recommendationCalls, hasLength(2));
      expect(search.catalog.popular.single.recommendationId, 2);
      expect(search.recommendations.single.recommendationId, 2);
    },
  );

  test(
    'offline refresh keeps displayed cards and foreground retries after thirty seconds',
    () async {
      var now = DateTime(2026, 10, 31);
      final api = _ConfigurationApi();
      api.discover = (_, _) async => [recommendation(1)];
      api.catalogRespond = (_, _) async =>
          ResourceCatalog(popular: [recommendation(2)]);
      final search = service(api, clock: () => now);
      await search.preload();
      now = now.add(const Duration(minutes: 5));
      api.configure = (_) async => throw const SocketException('offline');
      api.discover = (_, _) async => throw const SocketException('offline');
      api.catalogRespond = (_, _) async =>
          throw const SocketException('offline');
      await search.preload();
      expect(search.catalog.popular.single.recommendationId, 2);
      expect(search.recommendations.single.recommendationId, 1);
      expect(search.catalogError, isNotEmpty);
      expect(search.recommendationsError, isNotEmpty);
      expect(search.catalogLoading, isEmpty);
      expect(search.recommendationsLoading, isFalse);
      now = now.add(const Duration(seconds: 29));
      await search.preload();
      expect(api.tokens, hasLength(2));
      now = now.add(const Duration(seconds: 1));
      api.configure = null;
      api.discover = (_, _) async => [recommendation(3)];
      api.catalogRespond = (_, _) async =>
          ResourceCatalog(popular: [recommendation(4)]);
      await search.preload();
      expect(api.tokens, hasLength(3));
      expect(search.recommendations.single.recommendationId, 3);
      expect(search.catalog.popular.single.recommendationId, 4);
      expect(search.catalogError, isEmpty);
      expect(search.recommendationsError, isEmpty);
    },
  );

  test(
    'page activation waits for startup data and manual sections keep other cards',
    () async {
      final api = _ConfigurationApi();
      final catalog = Completer<ResourceCatalog>();
      api.catalogRespond = (_, _) => catalog.future;
      final search = service(api);
      final startup = search.preload();
      var pageLoaded = false;
      final page = search.loadCatalog().then((_) => pageLoaded = true);
      await Future<void>.delayed(Duration.zero);
      expect(pageLoaded, isFalse);
      expect(api.catalogCalls, hasLength(1));
      catalog.complete(
        ResourceCatalog(
          popular: [recommendation(1)],
          categories: [
            ResourceCategory(id: 7, name: '学习', resources: [recommendation(2)]),
            ResourceCategory(id: 8, name: '课程', resources: [recommendation(3)]),
          ],
        ),
      );
      await Future.wait([startup, page]);
      api.catalogRespond = (section, exclude) async {
        expect(section, '7');
        expect(exclude, [2]);
        return ResourceCatalog(
          popular: [recommendation(99)],
          categories: [
            ResourceCategory(id: 7, name: '学习', resources: [recommendation(4)]),
          ],
        );
      };
      await search.loadCatalog(section: '7', refresh: true);
      expect(search.catalog.popular.single.recommendationId, 1);
      expect(search.catalog.categories[0].resources.single.recommendationId, 4);
      expect(search.catalog.categories[1].resources.single.recommendationId, 3);
    },
  );

  test('closing cancels entry requests and ignores late data', () async {
    final api = _ConfigurationApi();
    final rules = Completer<void>();
    final recommendations = Completer<List<ResourceSearchHit>>();
    final catalog = Completer<ResourceCatalog>();
    api.configure = (_) => rules.future;
    api.discover = (_, _) => recommendations.future;
    api.catalogRespond = (_, _) => catalog.future;
    final search = ResourceSearch(store: StateStore.memory(), api: api);
    final startup = search.preload();
    search.dispose();
    expect(api.tokens.single.isCancelled, isTrue);
    await startup;
    rules.complete();
    recommendations.complete([recommendation(1)]);
    catalog.complete(ResourceCatalog(popular: [recommendation(2)]));
    await Future<void>.delayed(Duration.zero);
    expect(search.catalogLoaded, isFalse);
    expect(search.recommendationsLoaded, isFalse);
    search.store.dispose();
  });

  test(
    'HTTP preload only fetches public data and signed rules without searching',
    () async {
      final store = StateStore.memory();
      final envelope = asJson(
        jsonDecode(
          File(
            'test/fixtures/client_search/online-release.json',
          ).readAsStringSync(),
        ),
      );
      final requests = <String>[];
      final http = FakeHttp((call) {
        expect(call.method, 'GET');
        expect(call.headers, isEmpty);
        requests.add(call.uri.path);
        return switch (call.uri.path) {
          '/api/v1/search/client/config' => jsonResponse(envelope),
          '/api/v1/resources/catalog' => jsonResponse({
            'success': true,
            'popular': [],
            'categories': [],
          }),
          '/api/v1/resources/recommendations' => jsonResponse({
            'success': true,
            'results': [],
          }),
          _ => throw StateError('unexpected startup request: ${call.uri.path}'),
        };
      });
      final api = HttpResourceSearchApi(
        http,
        endpoint: 'https://backend.example.test',
        store: store,
        localSearch: true,
      );
      final search = ResourceSearch(store: store, api: api);
      try {
        await search.preload();
        expect(
          requests,
          unorderedEquals([
            '/api/v1/search/client/config',
            '/api/v1/resources/catalog',
            '/api/v1/resources/recommendations',
          ]),
        );
        expect(api.clientSearch!.available, isTrue);
        expect(api.configurationRevision, isNotEmpty);
        expect(search.catalogError, isEmpty);
        expect(search.recommendationsError, isEmpty);
        await api.prepareSources(CancelToken());
        expect(requests, hasLength(3));
        final offline = ClientSearchEngine(
          store: store,
          endpoint: api.endpoint,
          fetch: (_) async => throw const SocketException('offline'),
        );
        await offline.prepare(CancelToken());
        expect(offline.revision, api.configurationRevision);
        expect(offline.available, isTrue);
      } finally {
        search.dispose();
        store.dispose();
      }
    },
  );
}
