import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'resource_search_test.dart' show SearchApiFixture;
import 'support.dart' show FakeHttp, jsonResponse;

ResourceSearchHit recommendation(int id) => ResourceSearchHit.fromRaw({
  'title': '学习资源 $id',
  'url': 'https://pan.quark.cn/s/rec$id',
  'recommendation_id': id,
  'category': '学习',
  'open_ticket': 'grant$id',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'refresh sends the current recommendation IDs and preserves old cards on failure',
    () async {
      final api = SearchApiFixture((_, _) => const Stream.empty());
      final service = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(service.dispose);
      api.discover = (_, _) async => [recommendation(1), recommendation(2)];
      await service.loadRecommendations();
      expect(service.recommendations.map((r) => r.category), ['学习', '学习']);
      await service.loadRecommendations();
      expect(api.recommendationCalls, hasLength(1));
      api.discover = (exclude, refresh) async {
        expect(exclude, [1, 2]);
        expect(refresh, isTrue);
        throw StateError('offline');
      };
      await service.loadRecommendations(refresh: true);
      expect(service.recommendations.map((r) => r.recommendationId), [1, 2]);
      expect(service.recommendationsError, isNotEmpty);
      expect(service.recommendationsLoading, isFalse);
      api.discover = (_, _) async => [recommendation(3)];
      await service.loadRecommendations(refresh: true);
      expect(service.recommendations.single.recommendationId, 3);
      expect(service.recommendationsError, isEmpty);
    },
  );

  test(
    'returning to recommendations cancels an active search and keeps the cards',
    () async {
      final controller = StreamController<ResourceSearchBatch>();
      addTearDown(controller.close);
      final api = SearchApiFixture((_, _) => controller.stream);
      api.discover = (_, _) async => [recommendation(1)];
      final service = ResourceSearch(store: StateStore.memory(), api: api);
      addTearDown(service.dispose);
      await service.loadRecommendations();
      final pending = service.search('学习');
      service.showRecommendations();
      expect(service.phase, ResourceSearchPhase.idle);
      expect(api.cancellations.single.isCancelled, isTrue);
      expect(service.keyword, isEmpty);
      expect(service.recommendations.single.recommendationId, 1);
      await controller.close();
      await pending;
    },
  );

  test(
    'public recommendation refresh is a read request with exclusions and fresh grants',
    () async {
      final http = FakeHttp((call) {
        final uri = Uri.parse(call.url);
        expect(call.method, 'GET');
        expect(uri.path, '/api/v1/resources/recommendations');
        expect(uri.queryParameters, {'refresh': '1', 'exclude': '1,2'});
        return jsonResponse({
          'success': true,
          'results': [
            {
              'title': '课程',
              'url': 'https://pan.quark.cn/s/abc',
              'recommendation_id': 3,
              'category': '学习',
              'open_ticket': 'fresh',
            },
          ],
        });
      });
      final api = HttpResourceSearchApi(http, endpoint: 'http://127.0.0.1:1');
      final rows = await api.recommendations(exclude: [1, 2], refresh: true);
      expect(rows.single.recommendationId, 3);
      expect(rows.single.openTicket, 'fresh');
    },
  );

  test(
    'anonymous device identity survives a new API instance and has no account credential',
    () async {
      final store = StateStore.memory();
      final identities = <String>[];
      final http = FakeHttp((call) {
        identities.add(call.headers['X-Resource-Client']!);
        expect(call.headers.keys, ['X-Resource-Client']);
        return jsonResponse({
          'success': true,
          'data': {'mode': 'original', 'reason': 'policy_disabled'},
        });
      });
      for (var i = 0; i < 2; i++) {
        await HttpResourceSearchApi(
          http,
          endpoint: 'http://127.0.0.1:1',
          store: store,
        ).open(
          recommendation(1),
          CancelToken(),
          selection: const ResourceSearchFileSelection(
            fileId: 'one',
            parentId: 'root',
            name: 'notes.txt',
            size: 3,
          ),
        );
      }
      expect(identities.first, matches(r'^[a-f0-9]{32}$'));
      expect(identities.toSet(), hasLength(1));
      expect(store.data['resourceClientId'], identities.first);
    },
  );
}
