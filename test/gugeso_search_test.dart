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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  final root = Directory(
    Platform.environment['ASTERLINK_BACKEND_ROOT'] ?? 'D:/.ls/pan-relay-main',
  );
  final native = library != null && File(library).existsSync();
  final out = Directory('${root.path}/reports/gugeso-20261106');
  final modules = <String, dynamic>{
    for (final file
        in (Directory('${root.path}/src/configs/client_search').existsSync()
                ? Directory('${root.path}/src/configs/client_search').listSync()
                : <FileSystemEntity>[])
            .whereType<File>())
      if (file.path.endsWith('.js'))
        file.uri.pathSegments.last: file.readAsStringSync(),
  };
  final client = ClientSearchEngine(
    store: StateStore.memory(),
    endpoint: 'https://pan.dr7786.top',
    fetch: (_) async => {},
  );
  final localManifest = <String, dynamic>{'modules': modules};
  final summary = <Json>[];

  Future<List<Json>> run(
    Json source,
    String keyword,
    SourceFetch fetch, {
    Json? manifest,
  }) async {
    final package = client.package(source, manifest ?? localManifest);
    final host = ClientSearchHost(package, fetch: fetch);
    try {
      final result = await SourceRuntime(libraryPath: library).run(
        package,
        'search',
        {'source': source, 'keyword': keyword, 'uuid': 'fixture'},
        host.call,
      );
      return result.list('results');
    } finally {
      await host.close();
    }
  }

  Json sourceWith(List<Json> steps, String output) => {
    'id': 'api:gugeso',
    'name': '谷哥搜测试',
    'kind': 'rule',
    'hosts': ['gugeso.com'],
    'rule': {'version': 1, 'steps': steps, 'output': output},
  };

  test('SSE events preserve escaped titles, CRLF and multiline JSON', () async {
    final source = sourceWith([
      {
        'id': 'search',
        'request': {'url': 'https://gugeso.com/search'},
        'extract': {'type': 'sse'},
      },
    ], 'steps.search');
    final first = {
      'title': 'Python "中文"\\书',
      'url': 'https://pan.quark.cn/s/first',
    };
    final text =
        '\uFEFF: keepalive\r\nid: 1\r\ndata: ${jsonEncode(first)}\r\n\r\n'
        'event: message\ndata: {"title":\ndata: "Python 2", "url":"https://pan.baidu.com/s/second?pwd=Ab12"}\n\n'
        'data: [DONE]\n\ndata: {broken}\n\n';
    final rows = await run(
      source,
      'Python',
      (_, _) async => {'status': 200, 'text': text},
    );
    expect(rows.map((r) => r.str('title')), [first['title'], 'Python 2']);
  }, skip: !native);

  test('empty stream returns no resources and invalid streams fail', () async {
    final source = sourceWith([
      {
        'id': 'search',
        'request': {'url': 'https://gugeso.com/search'},
        'extract': {'type': 'sse'},
      },
    ], 'steps.search');
    expect(
      await run(
        source,
        'Python',
        (_, _) async => {
          'status': 200,
          'text': ': heartbeat\n\ndata: [DONE]\n\n',
        },
      ),
      isEmpty,
    );
    for (final text in [
      'data: {broken}\n\n',
      'data: {"title":',
      'event: error\ndata: {"message":"failed"}\n\n',
    ]) {
      await expectLater(
        run(source, 'Python', (_, _) async => {'status': 200, 'text': text}),
        throwsA(isA<AppException>()),
      );
    }
  }, skip: !native);

  test(
    'decode retains null positions and codes, rejects count mismatch',
    () async {
      final source = sourceWith([
        {
          'id': 'search',
          'request': {'url': 'https://gugeso.com/search'},
          'extract': {'type': 'json'},
        },
        {
          'id': 'decode',
          'request': {
            'url': 'https://gugeso.com/decode',
            'method': 'POST',
            'json': {'urls': '[[map(&url, steps.search)]]'},
          },
          'extract': {
            'type': 'json',
            'path': 'urls',
            'zip': 'steps.search',
            'fields': {
              'title': {'template': '[[paired.title]]'},
              'url': '@',
              'password': {'template': '[[paired.password]]'},
            },
          },
        },
      ], 'steps.decode[?url]');
      final originals = [
        {'title': 'first', 'url': 'a', 'password': 'Ab12'},
        {'title': 'middle', 'url': 'b'},
        {'title': 'last', 'url': 'c', 'password': 'Zy98'},
      ];
      var mismatch = false;
      Future<Json> fetch(Object _, Json options) async => {
        'status': 200,
        'text': jsonEncode(
          options.str('url').endsWith('/search')
              ? originals
              : {
                  'urls': mismatch
                      ? ['https://pan.quark.cn/s/first']
                      : [
                          'https://pan.quark.cn/s/first',
                          null,
                          'https://pan.baidu.com/s/last',
                        ],
                },
        ),
      };
      final rows = await run(source, 'Python', fetch);
      expect(rows.map((r) => r.str('title')), ['first', 'last']);
      expect(rows.map((r) => r.str('password')), ['Ab12', 'Zy98']);
      mismatch = true;
      await expectLater(
        run(source, 'Python', fetch),
        throwsA(isA<AppException>()),
      );
    },
    skip: !native,
  );

  for (final tag in ['local', 'server']) {
    final file = File('${out.path}/private/$tag-replay-private.json');
    final cases = file.existsSync()
        ? (jsonDecode(file.readAsStringSync()) as List).map(asJson).toList()
        : <Json>[];
    for (final testcase in cases) {
      test(
        'actual native rule replay: $tag ${testcase.str('keyword')}',
        () async {
          final captures = testcase.list('captures');
          var requests = 0;
          Future<Json> fetch(Object _, Json options) async {
            requests++;
            final uri = Uri.parse(options.str('url'));
            final capture = captures.firstWhere((c) {
              final recorded = Uri.parse(c.str('request_url'));
              if (recorded.path != uri.path) return false;
              if (uri.path.endsWith('/web_search')) {
                return c.obj('params').str('is_type') ==
                        uri.queryParameters['is_type'] &&
                    c.obj('params').str('title') ==
                        uri.queryParameters['title'];
              }
              if (uri.path.endsWith('/decrypt_urls')) {
                return jsonEncode(c.obj('json')['urls']) ==
                    jsonEncode(options.obj('body')['urls']);
              }
              return true;
            });
            return {
              'status': capture.integer('status'),
              'text': capture.str('text'),
              'url': capture.str('url'),
            };
          }

          final rows = await run(
            testcase.obj('source'),
            testcase.str('keyword'),
            fetch,
          );
          Map<String, ResourceSearchHit> hits(List<Json> values) => {
            for (final row in values)
              ResourceSearchHit.fromRaw(row).identity:
                  ResourceSearchHit.fromRaw(row),
          };
          final actual = hits(rows),
              expected = hits(testcase.list('expected_normalized'));
          expect(
            actual.keys.toSet(),
            expected.keys.toSet(),
            reason: 'Per-resource share IDs must match backend output',
          );
          for (final e in expected.entries) {
            expect(actual[e.key]!.title, e.value.title);
            expect(actual[e.key]!.password, e.value.password);
          }
          summary.add({
            'network': tag,
            'keyword': testcase.str('keyword'),
            'results': actual.length,
            'requests': requests,
            'title_link_password_pairs_match': true,
          });
        },
        skip: !native,
      );
    }
  }

  final online = File('${out.path}/private/online-envelope.json');
  test(
    'deployed rule verifies with App bundled signing identity',
    () {
      final value = client.verify(
        asJson(jsonDecode(online.readAsStringSync())),
      );
      final source = value
          .list('sources')
          .singleWhere((s) => s.obj('rule').str('key') == 'gugeso');
      expect(source.str('kind'), 'rule');
      expect(source['hosts'], ['gugeso.com']);
      expect(value.obj('modules')['rules.js'], modules['rules.js']);
      File('${out.path}/app-signature-verification.json').writeAsStringSync(
        jsonEncode({
          'success': true,
          'id': source.str('id'),
          'revision': value.str('revision'),
        }),
      );
    },
    skip: !online.existsSync(),
  );

  tearDownAll(() {
    if (summary.isNotEmpty) {
      File(
        '${out.path}/app-replay-results.json',
      ).writeAsStringSync(jsonEncode(summary));
    }
  });
}
