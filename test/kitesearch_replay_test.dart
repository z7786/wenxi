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
  final root = Directory(Platform.environment['ASTERLINK_BACKEND_ROOT'] ?? 'D:/.ls/pan-relay-main');
  if (!Directory('${root.path}/src/configs/client_search').existsSync() ||
      !File('${root.path}/reports/kitesearch-20261108/private/app-replay-private.json').existsSync()) {
    test('Kite native replay requires private captured fixtures', () {},
        skip: 'Private replay fixtures are unavailable');
    return;
  }
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  final client = ClientSearchEngine(store: StateStore.memory(), endpoint: 'https://backend.example.com', fetch: (_) async => {});
  final modules = <String, dynamic>{
    for (final file in Directory('${root.path}/src/configs/client_search').listSync().whereType<File>())
      if (file.path.endsWith('.js')) file.uri.pathSegments.last: file.readAsStringSync(),
  };
  final file = File('${root.path}/reports/kitesearch-20261108/private/app-replay-private.json');
  final online = File('${root.path}/reports/kitesearch-20261108/private/online-envelope.json');
  final deployed = online.existsSync() ? client.verify(asJson(jsonDecode(online.readAsStringSync()))).list('sources') : <Json>[];
  final cases = (jsonDecode(file.readAsStringSync()) as List).map(asJson);
  final summary = <Json>[];
  for (final testcase in cases) {
    test('Kite native replay ${testcase.str('network')} ${testcase.obj('source').str('name')} ${testcase.str('keyword')}', () async {
      final capturedSource = testcase.obj('source');
      final source = deployed.where((s) => s.obj('rule').str('key') == capturedSource.obj('rule').str('key')).firstOrNull ?? capturedSource;
      final package = client.package(source, {'modules': modules});
      String key(String method, Uri uri, Object? body) {
        final query = uri.queryParameters.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
        return jsonEncode([method.toUpperCase(), uri.host, uri.path, query.map((e) => [e.key, e.value]).toList(), body]);
      }
      final responses = <String, Json>{};
      for (final capture in testcase.list('captures')) {
        final uri = Uri.parse(capture.str('request_url'));
        final params = {...uri.queryParameters, for (final e in capture.obj('params').entries) e.key: e.value.toString()};
        responses[key(capture.str('method'), uri.replace(queryParameters: params), capture['json'])] = capture;
      }
      var calls = 0;
      final host = ClientSearchHost(package, fetch: (_, options) async {
        calls++;
        final capture = responses[key(options.str('method'), Uri.parse(options.str('url')), options['body'])];
        if (capture == null) throw StateError('Missing captured page');
        return {'status': capture.integer('status'), 'text': capture.str('text'), 'url': capture.str('url'), 'headers': {}};
      });
      final result = await SourceRuntime(libraryPath: library).run(package, 'search', {'source': source, 'keyword': testcase.str('keyword'), 'uuid': 'audit'}, host.call);
      Map<String, ResourceSearchHit> hits(List<Json> rows) => {for (final row in rows) ResourceSearchHit.fromRaw(row).identity: ResourceSearchHit.fromRaw(row)};
      final actual = hits(result.list('results')), expected = hits(testcase.list('expected'));
      expect(actual.keys.toSet(), expected.keys.toSet());
      for (final entry in expected.entries) {
        // BeautifulSoup inserts spaces around inline highlights; Dart joins them.
        String compact(String value) => value.replaceAll(RegExp(r'\s+'), '');
        expect(compact(actual[entry.key]!.title), compact(entry.value.title));
        expect(actual[entry.key]!.password, entry.value.password);
      }
      summary.add({'key': source.obj('rule').str('key'), 'network': testcase.str('network'), 'keyword': testcase.str('keyword'), 'results': actual.length, 'requests': calls, 'title_link_pairs_match': true});
    });
  }
  test('Kite deployed manifest verifies with the App bundled public key', () {
    final value = client.verify(asJson(jsonDecode(online.readAsStringSync())));
    expect(value.obj('modules')['rules.js'], modules['rules.js']);
    expect(value.list('sources').where((s) => s.obj('rule').str('key').startsWith('kite_')), isNotEmpty);
  }, skip: !online.existsSync());
  tearDownAll(() {
    File('${root.path}/reports/kitesearch-20261108/app-replay-results.json').writeAsStringSync(jsonEncode(summary));
  });
}
