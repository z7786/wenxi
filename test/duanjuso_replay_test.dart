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
  final root = Directory(Platform.environment['ASTERLINK_BACKEND_ROOT'] ?? 'D:/.ls/pan-relay-main');
  final out = Directory('${root.path}/reports/duanjuso-20261113');
  final fixture = File('${out.path}/private/local-captures.json');
  if (!fixture.existsSync()) {
    test('Duanjuso native replay requires captured fixtures', () {}, skip: 'Private fixtures unavailable');
    return;
  }
  final client = ClientSearchEngine(store: StateStore.memory(), endpoint: 'https://backend.example.com', fetch: (_) async => {});
  final online = File('${out.path}/private/online-envelope.json');
  final deployed = online.existsSync() ? client.verify(asJson(jsonDecode(online.readAsStringSync()))) : <String, dynamic>{};
  final localModules = <String, dynamic>{
    for (final file in Directory('${root.path}/src/configs/client_search').listSync().whereType<File>())
      if (file.path.endsWith('.js')) file.uri.pathSegments.last: file.readAsStringSync(),
  };
  final modules = online.existsSync() ? deployed.obj('modules') : localModules;
  final summary = <Json>[];
  final cases = <Json>[
    for (final name in ['local', 'server'])
      if (File('${out.path}/private/$name-captures.json').existsSync())
        ...(jsonDecode(File('${out.path}/private/$name-captures.json').readAsStringSync()) as List).map(asJson),
  ];
  for (final testcase in cases) {
    test('Duanjuso native ${testcase.str('network')} ${testcase.str('keyword')}', () async {
      final source = deployed.list('sources').where((s) => s.obj('rule').str('key') == 'duanjuso').firstOrNull ?? testcase.obj('source');
      final package = client.package(source, {'modules': modules});
      var calls = 0;
      final host = ClientSearchHost(package, fetch: (_, options) async {
        calls++;
        final uri = Uri.parse(options.str('url'));
        expect(options.str('method'), 'GET');
        expect(uri.host, 'duanjuso.online');
        expect(uri.path, '/api/search');
        expect(uri.queryParameters['q'], testcase.str('keyword'));
        expect(uri.queryParameters['page'], '1');
        expect(uri.queryParameters['page_size'], '20');
        return {'status': 200, 'text': testcase.str('text'), 'url': uri.toString(), 'headers': {}};
      });
      final result = await SourceRuntime(libraryPath: Platform.environment['ASTERLINK_JS_LIBRARY']).run(package, 'search', {'source': source, 'keyword': testcase.str('keyword'), 'uuid': 'audit'}, host.call);
      Map<String, ResourceSearchHit> hits(List<Json> rows) => {for (final row in rows) ResourceSearchHit.fromRaw(row).identity: ResourceSearchHit.fromRaw(row)};
      final actual = hits(result.list('results')), expected = hits(testcase.list('expected'));
      expect(actual.keys.toSet(), expected.keys.toSet());
      for (final entry in expected.entries) {
        expect(actual[entry.key]!.title, entry.value.title);
        expect(actual[entry.key]!.password, entry.value.password);
      }
      expect(calls, 1);
      summary.add({'network': testcase.str('network'), 'keyword': testcase.str('keyword'), 'results': actual.length, 'requests': calls, 'success': true});
    });
  }
  test('Duanjuso live envelope verifies with the App public key', () {
    expect(deployed.list('sources').where((s) => s.obj('rule').str('key') == 'duanjuso').length, 1);
    expect(modules.keys.toSet(), localModules.keys.toSet());
    for (final entry in localModules.entries) {
      expect(modules[entry.key].toString().replaceAll('\r\n', '\n'), entry.value.toString().replaceAll('\r\n', '\n'));
    }
  }, skip: !online.existsSync());
  test('Duanjuso App uses the device HTTP network', () async {
    final source = cases.first.obj('source');
    final package = client.package(source, {'modules': modules});
    final host = ClientSearchHost(package);
    final result = await SourceRuntime(libraryPath: Platform.environment['ASTERLINK_JS_LIBRARY']).run(package, 'search', {'source': source, 'keyword': '总裁', 'uuid': 'audit'}, host.call);
    final rows = result.list('results');
    expect(rows, isNotEmpty);
    expect(rows.every((r) => r.str('title').contains('总裁')), isTrue);
    File('${out.path}/app-live-result.json').writeAsStringSync(jsonEncode({'success': true, 'keyword': '总裁', 'results': rows.length, 'failed_requests': host.failedRequests}));
  }, skip: Platform.environment['ASTERLINK_LIVE_SEARCH'] != '1');
  tearDownAll(() { File('${out.path}/app-replay-results.json').writeAsStringSync(jsonEncode(summary)); });
}
