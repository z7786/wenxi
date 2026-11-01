import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/client_search_engine.dart';
import 'package:asterlink/data/client_search_host.dart';
import 'package:asterlink/data/sources/host.dart';
import 'package:asterlink/data/sources/runtime.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';

const root = 'test/fixtures/client_search';
Json signed() => asJson(jsonDecode(File('$root/one.json').readAsStringSync()));
String page(String file) => File('$root/$file').readAsStringSync();
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  final native = library != null && File(library).existsSync();
  final engine = ClientSearchEngine(
    store: StateStore.memory(),
    endpoint: 'https://backend.example.com',
    fetch: (_) async => signed(),
    publicKey: page('public-key.txt'),
  );
  final manifest = engine.verify(signed());
  final adapters = objects(jsonDecode(page('adapters.json')));
  Future<List<Json>> run(String name, String keyword, SourceFetch fetch) async {
    final source = adapters.firstWhere((s) => s.str('id') == 'plugin:$name');
    final host = ClientSearchHost(
      engine.package(source, manifest),
      fetch: fetch,
    );
    try {
      return (await SourceRuntime(libraryPath: library).run(
        engine.package(source, manifest),
        'search',
        {'source': source, 'keyword': keyword, 'uuid': 'test-visitor'},
        host.call,
      )).list('results');
    } finally {
      await host.close();
    }
  }

  Json response(String text) => {'status': 200, 'text': text};
  test('Mio stream preserves snapshots and stops at done', () async {
    final rows = await run(
      'miosou',
      '三体',
      (s, o) async => response(
        '${page('public_sources/miosou.sse')}event: error\ndata: {"message":"late"}\n\n',
      ),
    );
    expect(rows, hasLength(3));
    expect(rows.first.str('title'), contains('三体'));
    expect(rows.first.str('url'), startsWith('https://pan.quark.cn/s/'));
  }, skip: !native);
  test(
    'Mio rejects login HTML and explicit errors instead of caching empty success',
    () async {
      for (final body in [
        '<html>login</html>',
        'event: error\ndata: {"message":"limited"}\n\n',
        'event: done\ndata: {"total":3}\n\n',
      ]) {
        await expectLater(
          run('miosou', '三体', (s, o) async => response(body)),
          throwsA(isA<AppException>()),
        );
      }
    },
    skip: !native,
  );
  test(
    'Haitun inline JavaScript string preserves Chinese and passcodes',
    () async {
      final rows = await run(
        'haitunsou',
        '仙逆',
        (s, o) async => response(page('public_sources/haitunsou.html')),
      );
      expect(rows, hasLength(2));
      expect(ResourceSearchHit.fromRaw(rows.first).password, '6666');
      expect(rows.last.str('title'), contains('🗄'));
    },
    skip: !native,
  );
  test('URL database decodes JSON results without dropping metadata', () async {
    final rows = await run(
      'urldb',
      '电子书',
      (s, o) async => response(page('public_sources/urldb-search.json')),
    );
    expect(rows, hasLength(2));
    expect(rows.first.str('title'), '天下霸唱35本电子书');
    expect(rows.first.str('datetime'), '2026-10-08 07:22:20');
  }, skip: !native);
  test('Sousou matches search detail and share link', () async {
    final rows = await run(
      'sousou',
      '三体',
      (s, o) async => response(
        page(
          o.str('url').contains('/doc/')
              ? 'public_sources/sousou-detail.html'
              : 'public_sources/sousou-search.html',
        ),
      ),
    );
    expect(rows, isNotEmpty);
    expect(rows.first.str('title'), contains('三体'));
    expect(rows.first.str('url'), startsWith('https://pan.quark.cn/s/'));
  }, skip: !native);
  test(
    'Ruancang selects named software version and decodes plus as space',
    () async {
      var redirects = 0;
      final rows = await run('ruancang', 'Photoshop 2026', (s, o) async {
        final uri = Uri.parse(o.str('url'));
        if (uri.path == '/24.html') {
          return response(
            '<div class="post-content"><h3>Photoshop Elements 2026</h3></div>',
          );
        }
        if (uri.path == '/link') {
          expect(uri.queryParameters['_name'], 'Photoshop 2026');
          redirects++;
          return {
            'status': 302,
            'text': '',
            'headers': {
              'location': [
                'https://pan.baidu.com/s/1sample$redirects?pwd=aB12',
              ],
            },
          };
        }
        return response(
          page(
            uri.path == '/'
                ? 'non_video_sources/ruancang-home.html'
                : 'non_video_sources/ruancang-detail.html',
          ),
        );
      });
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.str('title')).toSet(), {'Photoshop 2026'});
      expect(redirects, 2);
    },
    skip: !native,
  );
  Future<List<Json>> rule(String name, SourceFetch fetch) async {
    final rules = objects(jsonDecode(page('production-rules.json')));
    final value = rules.firstWhere((r) => r.str('key') == name);
    final source = {
      'id': 'api:1',
      'name': name,
      'kind': 'rule',
      'hosts': [name == 'appmiu' ? 'www.appmiu.com' : 'pansoo.cn'],
      'timeout': 30,
      'rule': value,
    };
    final package = engine.package(source, manifest),
        host = ClientSearchHost(engine.package(source, manifest), fetch: fetch);
    try {
      return (await SourceRuntime(libraryPath: library).run(package, 'search', {
        'source': source,
        'keyword': 'Photoshop',
        'uuid': 'test-visitor',
      }, host.call)).list('results');
    } finally {
      await host.close();
    }
  }

  test(
    'current Appmiu rule handles all four steps, typed fields and restricted rows',
    () async {
      final paths = <String>[];
      final rows = await rule('appmiu', (s, o) async {
        final uri = Uri.parse(o.str('url'));
        paths.add(uri.path);
        if (uri.path.endsWith('/posts')) {
          expect(uri.queryParameters['search'], 'Photoshop');
          return response(
            jsonEncode([
              {
                'id': 12,
                'title': {'rendered': '<b>Photoshop</b>'},
                'link': 'https://www.appmiu.com/post/12',
                'content': {'rendered': '<div id="download-box"></div>'},
                'excerpt': {'rendered': '<p>简介</p>'},
                '_embedded': {
                  'wp:featuredmedia': [
                    {'source_url': 'https://img.example.com/photo.webp'},
                  ],
                },
                'date': '2026-10-30',
              },
            ]),
          );
        }
        if (uri.path.endsWith('getDownloadData')) {
          expect(o.obj('body')['post_id'], 12);
          return response(
            jsonEncode([
              {
                'current_user': {
                  'can': {'allow': true},
                },
                'button': [
                  {
                    'name': '夸克网盘',
                    'link': 'https://www.appmiu.com/download?index=0&i=1',
                  },
                ],
              },
              {
                'current_user': {
                  'can': {'allow': false},
                },
                'button': [
                  {
                    'name': '百度网盘',
                    'link': 'https://www.appmiu.com/download?index=0&i=2',
                  },
                ],
              },
            ]),
          );
        }
        if (uri.path.endsWith('getDownloadPageData')) {
          return response(
            jsonEncode({
              'current_user': {
                'can': {'allow': true},
              },
              'button': {
                'url': 'public token',
                'attr': {'tq': 'aB12', 'jy': 'archive'},
              },
            }),
          );
        }
        expect(uri.queryParameters['token'], 'public token');
        return response(
          'window.location.href="https://pan.quark.cn/s/example?x=1&amp;y=2";',
        );
      });
      expect(paths, hasLength(4));
      expect(rows, hasLength(1));
      expect(rows.single.str('title'), 'Photoshop');
      expect(rows.single.str('password'), 'aB12');
      expect(rows.single.str('url'), 'https://pan.quark.cn/s/example?x=1&y=2');
    },
    skip: !native,
  );
  test(
    'current Pansoo rule merges original links and grouped share resolution',
    () async {
      var resolved = 0;
      final rows = await rule('pansoo', (s, o) async {
        if (Uri.parse(o.str('url')).path.endsWith('cached_resources')) {
          return response(
            jsonEncode({
              'status': 'success',
              'resources': [
                {
                  'id': 1,
                  'pan_type': 2,
                  'title': 'Photoshop Quark',
                  'share_url': 'https://pan.quark.cn/s/original',
                },
                {'id': 2, 'pan_type': 1, 'title': 'Photoshop Baidu'},
                {'id': 3, 'pan_type': 2, 'title': 'Photoshop other'},
              ],
            }),
          );
        }
        expect(o.obj('headers').str('X-Pan-So-Visitor-Id'), 'test-visitor');
        resolved++;
        return response(
          jsonEncode({
            'status': 'success',
            'share_url': 'https://pan.quark.cn/s/resolved$resolved',
            'share_pwd': 'aB12',
          }),
        );
      });
      expect(rows, hasLength(3));
      expect(resolved, 2);
      expect(
        rows.map((r) => r.str('title')),
        containsAll(['Photoshop Quark', 'Photoshop Baidu', 'Photoshop other']),
      );
    },
    skip: !native,
  );
}
