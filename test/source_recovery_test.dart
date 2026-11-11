import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/client_search_engine.dart';
import 'package:asterlink/data/client_search_host.dart';
import 'package:asterlink/data/sources/runtime.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  final root = Directory(
    Platform.environment['ASTERLINK_BACKEND_ROOT'] ?? 'D:/.ls/pan-relay-main',
  );
  final native =
      library != null && File(library).existsSync() && root.existsSync();
  final modules = <String, dynamic>{
    for (final file
        in (root.existsSync()
                ? Directory('${root.path}/src/configs/client_search').listSync()
                : <FileSystemEntity>[])
            .whereType<File>())
      if (file.path.endsWith('.js'))
        file.uri.pathSegments.last: file.readAsStringSync(),
  };
  final client = ClientSearchEngine(
    store: StateStore.memory(),
    endpoint: 'https://backend.example.com',
    fetch: (_) async => {},
  );
  final manifest = <String, dynamic>{'modules': modules};
  Future<List<Json>> run(
    Json source,
    String keyword,
    Future<Json> Function(Object, Json) fetch,
  ) async {
    final package = client.package(source, manifest);
    final host = ClientSearchHost(package, fetch: fetch);
    final result = await SourceRuntime(libraryPath: library).run(
      package,
      'search',
      {'source': source, 'keyword': keyword, 'uuid': 'audit'},
      host.call,
    );
    return result.list('results');
  }

  test('rule rows containing several different links are rejected', () async {
    final source = <String, dynamic>{
      'id': 'api:quality',
      'name': 'quality',
      'kind': 'rule',
      'hosts': ['example.com'],
      'rule': {
        'steps': [
          {
            'id': 'search',
            'request': {'url': 'https://example.com/search'},
            'extract': {'type': 'json', 'path': 'items'},
          },
        ],
        'output': 'steps.search',
      },
    };
    final rows = await run(
      source,
      'Python',
      (_, _) async => {
        'status': 200,
        'text': jsonEncode({
          'items': [
            {'title': 'Python', 'url': 'https://pan.quark.cn/s/one'},
            {
              'title': 'mixed',
              'url': 'https://pan.quark.cn/s/one https://pan.baidu.com/s/two',
            },
          ],
        }),
      },
    );
    expect(rows.map((r) => r.str('title')), ['Python']);
  }, skip: !native);

  final replayPath =
      '${root.path}/reports/source-recovery-20261105/private/app-replay-private.json';
  final cases =
      (File(replayPath).existsSync()
              ? jsonDecode(File(replayPath).readAsStringSync()) as List
              : <dynamic>[])
          .map(asJson);
  final summary = <Json>[];
  for (final testcase in cases) {
    test(
      'native App replay pairs titles and links: ${testcase.str('name')}',
      () async {
        final captures = testcase.list('captures');
        var calls = 0;
        String requestKey(Uri uri) {
          final params = uri.queryParameters.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key));
          return '${uri.host}${uri.path}?${params.map((e) => '${e.key}=${e.value}').join('&')}';
        }

        final responses = <String, Json>{};
        for (final capture in captures) {
          final uri = Uri.parse(capture.str('request_url'));
          final params = <String, String>{
            ...uri.queryParameters,
            for (final e in capture.obj('params').entries)
              e.key: e.value.toString(),
          };
          responses[requestKey(uri.replace(queryParameters: params))] = capture;
        }
        final rows = await run(
          testcase.obj('source'),
          testcase.str('keyword'),
          (_, options) async {
            calls++;
            final capture =
                responses[requestKey(Uri.parse(options.str('url')))];
            if (capture == null) {
              throw StateError(
                'Missing captured page for ${testcase.str('name')}',
              );
            }
            return {
              'status': capture.integer('status'),
              'text': capture.str('text'),
              'url': capture.str('url'),
              'headers': {
                if (capture.obj('headers').str('location').isNotEmpty)
                  'location': [capture.obj('headers').str('location')],
              },
            };
          },
        );
        Map<String, ResourceSearchHit> hits(List<Json> values) => {
          for (final row in values)
            ResourceSearchHit.fromRaw(row).identity: ResourceSearchHit.fromRaw(
              row,
            ),
        };
        final actual = hits(rows), expected = hits(testcase.list('expected'));
        expect(
          actual.keys.toSet(),
          expected.keys.toSet(),
          reason: 'All per-resource share IDs must match backend replay',
        );
        for (final e in expected.entries) {
          expect(
            actual[e.key]!.title,
            e.value.title,
            reason: 'A link must retain its resource title',
          );
          expect(
            actual[e.key]!.password,
            e.value.password,
            reason: 'A code must stay with its link',
          );
        }
        summary.add({
          'name': testcase.str('name'),
          'keyword': testcase.str('keyword'),
          'results': actual.length,
          'title_link_password_pairs_match': true,
          'requests': calls,
        });
      },
      skip: !native,
    );
  }
  tearDownAll(() {
    if (root.existsSync()) {
      File(
        '${root.path}/reports/source-recovery-20261105/app-replay-results.json',
      ).writeAsStringSync(jsonEncode(summary));
    }
  });

  final online = File(
    '${root.path}/reports/source-recovery-20261105/private/online-envelope.json',
  );
  test(
    'deployed recovery manifest validates in App with bundled identity',
    () {
      final value = client.verify(
        asJson(jsonDecode(online.readAsStringSync())),
      );
      expect(
        value.obj('modules')['result_quality.js'],
        modules['result_quality.js'],
      );
      expect(value.obj('modules')['plugins.js'], modules['plugins.js']);
      final ids = value.list('sources').map((s) => s.str('id')).toSet();
      for (final name in [
        'pansearch',
        'duoduo',
        'shandian',
        'ruancang',
        'jutoushe',
        'zhizhen',
        'muou',
      ]) {
        expect(ids, contains('plugin:$name'));
      }
      expect(ids, isNot(contains('plugin:pansou_aggregator')));
    },
    skip: !online.existsSync(),
  );
}
