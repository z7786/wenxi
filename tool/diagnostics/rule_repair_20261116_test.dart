import 'diagnostic_environment.dart';
import 'dart:convert';
import 'dart:io';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/client_search_engine.dart';
import 'package:asterlink/data/client_search_host.dart';
import 'package:asterlink/data/sources/runtime.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  requireDiagnosticRuntime();
  final root = requireDiagnosticBackend();
  final library = Platform.environment['ASTERLINK_JS_LIBRARY'];
  final available = library != null && File(library).existsSync();
  test(
    'Downstream rules fix headers on the existing App host and bind RSS links to titles',
    () async {
      final client = ClientSearchEngine(
        store: StateStore.memory(),
        endpoint: 'https://pan.dr7786.top',
        fetch: (_) async => {},
      );
      final envelope = asJson(
        jsonDecode(
          File(
            '${root.path}/reports/rule-repair-20261116/private/envelope-before.json',
          ).readAsStringSync(),
        ),
      );
      final manifest = client.verify(envelope);
      manifest['modules'] = {
        for (final file in Directory(
          '${root.path}/src/configs/client_search',
        ).listSync().whereType<File>().where((f) => f.path.endsWith('.js')))
          file.uri.pathSegments.last: file.readAsStringSync(),
      };
      final presets =
          (jsonDecode(
                    File(
                      '${root.path}/src/configs/presets/api_configs_preset.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .map(asJson)
              .toList();
      Json source(Json rule) => {
        'id': 'api:900',
        'name': 'repair fixture',
        'kind': 'rule',
        'hosts': ['example.com', 'mikanani.me', 'files.ptger.cn'],
        'timeout': 9,
        'rule': rule,
      };
      Future<List<Json>> run(
        Json rule,
        String body, {
        void Function(Json)? check,
      }) async {
        final descriptor = source(rule),
            package = client.package(source(rule), manifest);
        final host = ClientSearchHost(
          package,
          fetch: (p, options) async {
            // Use the unchanged production host's header validation, not a permissive mock.
            p.checkedHeaders(options['headers']);
            check?.call(options);
            return {'status': 200, 'text': body};
          },
        );
        try {
          final value = await SourceRuntime(libraryPath: library).run(
            package,
            'search',
            {'source': descriptor, 'keyword': 'Python', 'uuid': 'fixture'},
            (method, args) async {
              try {
                return await host.call(method, args);
              } catch (error) {
                stdout.writeln('fixture host failed: $method / $error');
                rethrow;
              }
            },
          );
          return value.list('results');
        } finally {
          await host.close();
        }
      }

      final headerRule = <String, dynamic>{
        'version': 1,
        'headers': {
          'aCcEpT': 'shared',
          'accept-language': 'zh-CN',
          'user-agent': 'fixture',
        },
        'steps': [
          {
            'id': 'search',
            'request': {
              'url': 'https://example.com/search',
              'headers': {'ACCEPT': 'step'},
            },
            'extract': {'type': 'json', 'path': 'items'},
          },
        ],
        'output': 'steps.search',
      };
      stdout.writeln('Checking headers');
      final headerRows = await run(
        headerRule,
        jsonEncode({
          'items': [
            {'title': 'Python first', 'url': 'https://pan.quark.cn/s/first'},
          ],
        }),
        check: (options) {
          final headers = options.obj('headers');
          expect(headers['Accept'], 'step');
          expect(
            headers.keys.where((k) => k.toLowerCase() == 'accept'),
            hasLength(1),
          );
          expect(
            headers.keys.where((k) => k.toLowerCase() == 'user-agent'),
            hasLength(1),
          );
        },
      );
      expect(headerRows, hasLength(1));
      stdout.writeln('Checking PTGer empty response');
      final ptger = presets
          .firstWhere((c) => c.obj('rule').str('key') == 'ptger')
          .obj('rule');
      expect(
        await run(ptger, jsonEncode({'code': 201, 'msg': '没有找到该文件内容,欢迎投稿反馈！'})),
        isEmpty,
      );
      stdout.writeln('Checking RSS item pairing');
      final rss = presets
          .firstWhere((c) => c.obj('rule').str('key') == 'kite_mikanani_me')
          .obj('rule');
      final a = List.filled(40, 'a').join(), b = List.filled(40, 'b').join();
      final body =
          '<rss><item><title>Python &amp; first</title><link>https://mikanani.me/Home/Episode/$a</link></item>'
          '<item><title>Python missing</title></item><item><title>Python second</title><link>https://mikanani.me/Home/Episode/$b</link></item></rss>';
      final rows = await run(rss, body);
      expect(rows, hasLength(2));
      expect(rows[0].str('title'), 'Python & first');
      expect(rows[0].str('url'), 'magnet:?xt=urn:btih:$a');
      expect(rows[1].str('url'), 'magnet:?xt=urn:btih:$b');
      File(
        '${root.path}/reports/rule-repair-20261116/app-replay-results.json',
      ).writeAsStringSync(
        jsonEncode({
          'success': true,
          'runtime': 'existing App native JS and unchanged HTTP host',
          'header_override_verified': true,
          'ptger_no_data_verified': true,
          'rss_ownership_verified': true,
        }),
      );
    },
    skip: !available,
  );
}
