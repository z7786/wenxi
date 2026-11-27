import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/resource_search.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'resource_search_test.dart' show SearchApiFixture, searchHit;
import 'support.dart' show FakeHttp, jsonResponse;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'provider priority persists and preserves incoming relevance within a provider',
    () async {
      final store = StateStore.memory();
      final api = SearchApiFixture(
        (_, _) => Stream.value(
          ResourceSearchBatch([
            searchHit('b', url: 'https://pan.baidu.com/s/1b'),
            searchHit('q2'),
            searchHit('u', url: 'https://drive.uc.cn/s/u'),
            searchHit('q1'),
          ], complete: true),
        ),
      );
      final search = ResourceSearch(store: store, api: api);
      addTearDown(search.dispose);
      expect(search.cloudPriority.take(10), [
        CloudPlatform.quark,
        CloudPlatform.uc,
        CloudPlatform.tianyi,
        CloudPlatform.c139,
        CloudPlatform.wopan,
        CloudPlatform.guangya,
        CloudPlatform.xunlei,
        CloudPlatform.pan115,
        CloudPlatform.weiyun,
        CloudPlatform.pikpak,
      ]);
      await search.search('资料');
      expect(search.items.map((r) => r.identity), [
        'Quark:q2',
        'Quark:q1',
        'Uc:u',
        'Baidu:b',
      ]);
      expect(search.orderedClouds, [
        CloudPlatform.quark.label,
        CloudPlatform.uc.label,
        CloudPlatform.baidu.label,
      ]);
      await search.setCloudPriority([
        CloudPlatform.baidu,
        CloudPlatform.uc,
        CloudPlatform.baidu,
      ]);
      expect(search.items.first.platform, CloudPlatform.baidu);
      final restored = ResourceSearch(store: store, api: api);
      addTearDown(restored.dispose);
      expect(restored.cloudPriority.take(2), [
        CloudPlatform.baidu,
        CloudPlatform.uc,
      ]);
      expect(
        restored.cloudPriority.toSet(),
        CloudPlatform.values.where((p) => p != CloudPlatform.webdav).toSet(),
      );
    },
  );

  test(
    'catalog carries cover URLs, category IDs and open grants; refresh is scoped',
    () async {
      final http = FakeHttp((call) {
        final uri = Uri.parse(call.url);
        expect(call.method, 'GET');
        expect(uri.path, '/api/v1/resources/catalog');
        expect(uri.queryParameters, {'refresh_section': '7', 'exclude': '2,3'});
        return jsonResponse({
          'success': true,
          'popular': <dynamic>[],
          'categories': [
            {
              'id': 7,
              'name': '学习资料',
              'resources': [
                {
                  'title': '课程',
                  'url': 'https://pan.quark.cn/s/course',
                  'cover_url': 'https://example.com/cover.jpg',
                  'recommendation_id': 4,
                  'open_ticket': 'fresh',
                },
              ],
            },
          ],
        });
      });
      final catalog = await HttpResourceSearchApi(
        http,
        endpoint: 'https://example.test',
      ).catalog(refreshSection: '7', exclude: [2, 3]);
      expect(catalog.popular, isEmpty);
      expect(catalog.categories.single.id, 7);
      final hit = catalog.categories.single.resources.single;
      expect(hit.coverUrl, 'https://example.com/cover.jpg');
      expect(hit.recommendationId, 4);
      expect(hit.openTicket, 'fresh');
      expect(hit.merge(searchHit('course')).coverUrl, hit.coverUrl);
    },
  );

  test('old server falls back to recommendations on catalog 404', () async {
    final paths = <String>[];
    final http = FakeHttp((call) {
      paths.add(Uri.parse(call.url).path);
      return paths.length == 1
          ? jsonResponse({}, 404)
          : jsonResponse({
              'success': true,
              'results': [
                {'title': '已有资源', 'url': 'https://pan.quark.cn/s/old'},
              ],
            });
    });
    final catalog = await HttpResourceSearchApi(
      http,
      endpoint: 'https://example.test',
    ).catalog();
    expect(catalog.popular.single.title, '已有资源');
    expect(catalog.categories, isEmpty);
    expect(paths, [
      '/api/v1/resources/catalog',
      '/api/v1/resources/recommendations',
    ]);
  });

  test('untrusted images and oversized categories are rejected', () {
    for (final url in [
      'javascript:alert(1)',
      'file:///etc/a',
      'https://user:secret@example.com/a',
    ]) {
      expect(
        ResourceSearchHit.fromRaw({
          'title': 'a',
          'url': 'https://pan.quark.cn/s/a',
          'cover_url': url,
        }).coverUrl,
        isEmpty,
      );
    }
    expect(
      () => ResourceCatalog.fromJson({
        'popular': [],
        'categories': List.filled(33, {}),
      }),
      throwsException,
    );
  });
}
