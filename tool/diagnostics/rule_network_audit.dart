import 'diagnostic_environment.dart';
// Opt-in live diagnostic. Uses the signed production modules and device HTTP.
// It never calls an admin test endpoint or changes source settings.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/client_search_engine.dart';
import 'package:asterlink/data/client_search_host.dart';
import 'package:asterlink/data/sources/host.dart';
import 'package:asterlink/data/sources/package.dart';
import 'package:asterlink/data/sources/runtime.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/resource_search.dart';

void runRuleNetworkAudit({
  required String flag,
  required String reportDirectory,
  required String defaultTag,
}) {
  requireLiveDiagnostic(flag);
  requireDiagnosticRuntime();
  final root = requireDiagnosticBackend();
  final out = Directory('${root.path}/reports/$reportDirectory');
  test(
    'Measure deployed rules with device HTTP and the native App runtime',
    () async {
      // No widget binding: Flutter widget tests otherwise replace HTTP with 400.
      final client = ClientSearchEngine(
        store: StateStore.memory(),
        endpoint: 'https://pan.dr7786.top',
        fetch: (_) async => {},
      );
      final envelope = asJson(
        jsonDecode(
          File('${out.path}/private/online-envelope.json').readAsStringSync(),
        ),
      );
      final manifest = client.verify(envelope);
      final selection = (Platform.environment['ASTERLINK_LATENCY_IDS'] ?? '')
          .split(',')
          .where((s) => s.isNotEmpty)
          .toSet();
      final sources = manifest
          .list('sources')
          .where(
            (s) =>
                s.str('kind') == 'rule' &&
                (selection.isEmpty || selection.contains(s.str('id'))),
          )
          .toList();
      // Likely slow multi-step rules first, while keeping only two sources active.
      sources.sort((a, b) {
        int rank(Json s) =>
            s.str('name').startsWith('谷哥') || s.str('name').startsWith('APP喵')
            ? 0
            : 1;
        return rank(a).compareTo(rank(b));
      });
      final samples = <Json>[];
      final tag = Platform.environment['ASTERLINK_LATENCY_TAG'] ?? defaultTag;
      final normalizeHeaders =
          Platform.environment['ASTERLINK_LATENCY_NORMALIZE_HEADERS'] == '1';
      final file = File('${out.path}/$tag-latency.json');
      void persist({bool complete = false}) => file.writeAsStringSync(
        jsonEncode({
          'network': 'windows-device',
          'runtime': 'App-native-JS-and-device-HTTP',
          'revision': manifest.str('revision'),
          'source_count': sources.length,
          'diagnostic_header_normalization': normalizeHeaders,
          'complete': complete,
          'samples': samples,
        }),
      );
      List<String> keywords(Json s) {
        final name = s.str('name');
        if (name.contains('短剧')) return ['总裁', '千金'];
        if (name.contains('APP喵')) return ['Chrome', 'Python'];
        if (name.contains('Mikan')) return ['Naruto', 'One Piece'];
        if (name.contains('Kite')) return ['Python', 'Naruto'];
        return ['熊出没', 'Python'];
      }

      Future<void> probe(Json source, int round) async {
        if (normalizeHeaders) {
          // Modify only this diagnostic copy; keep the deployed manifest intact.
          source = asJson(jsonDecode(jsonEncode(source)));
          void normalize(Json target) {
            final headers = target.obj('headers');
            const common = {
              'accept': 'Accept',
              'accept-language': 'Accept-Language',
              'user-agent': 'User-Agent',
              'referer': 'Referer',
            };
            target['headers'] = {
              for (final entry in headers.entries)
                common[entry.key.toLowerCase()] ?? entry.key: entry.value,
            };
          }

          final rule = source.obj('rule');
          normalize(rule);
          final steps = rule.list('steps');
          for (final step in steps) {
            final request = step.obj('request');
            normalize(request);
            step['request'] = request;
          }
          rule['steps'] = steps;
          source['rule'] = rule;
        }
        final keyword = keywords(source)[round];
        final package = client.package(source, manifest);
        final requests = <Json>[], calls = <Json>[];
        final watch = Stopwatch()..start();
        final browser = source
            .obj('rule')
            .obj('session')
            .obj('browser')
            .isNotEmpty;
        final host = ClientSearchHost(
          package,
          fetch: browser
              ? null
              : (_, options) async {
                  final started = watch.elapsedMilliseconds;
                  final uri = Uri.parse(options.str('url'));
                  final row = <String, dynamic>{
                    'start_ms': started,
                    'host': uri.host,
                    'path': uri.path,
                    'method': options.str('method'),
                    'timeout': options.integer('timeout'),
                  };
                  try {
                    final result = await SourceHost.request(package, options);
                    row['status'] = result.integer('status');
                    row['response_bytes'] = utf8
                        .encode(result.str('text'))
                        .length;
                    return result;
                  } catch (error) {
                    row['error'] = error is SourceError
                        ? error.code
                        : error.runtimeType.toString();
                    rethrow;
                  } finally {
                    row['end_ms'] = watch.elapsedMilliseconds;
                    row['elapsed_ms'] = watch.elapsedMilliseconds - started;
                    requests.add(row);
                  }
                },
        );
        var outcome = 'error', error = '', results = 0, valid = 0;
        try {
          final value =
              await SourceRuntime(
                libraryPath: Platform.environment['ASTERLINK_JS_LIBRARY'],
              ).run(
                package,
                'search',
                {
                  'source': source,
                  'keyword': keyword,
                  'uuid': await host.call('visitor', {}),
                },
                (method, args) async {
                  final started = watch.elapsedMilliseconds;
                  try {
                    return await host.call(method, args);
                  } finally {
                    calls.add({
                      'method': method,
                      'start_ms': started,
                      'elapsed_ms': watch.elapsedMilliseconds - started,
                      if (method == 'requestBatch')
                        'count': args.list('requests').length,
                    });
                  }
                },
              );
          final rows = value.list('results');
          results = rows.length;
          final identities = <String>{};
          for (final row in rows) {
            try {
              final hit = ResourceSearchHit.fromRaw(row);
              if (hit.link != null) identities.add(hit.identity);
            } catch (_) {}
          }
          valid = identities.length;
          outcome = rows.isEmpty
              ? (host.failedRequests > 0 ? 'error' : 'no_data')
              : 'success';
          if (outcome == 'error') error = 'SOURCE_REQUEST';
        } catch (failure) {
          error = failure is SourceError
              ? failure.code
              : failure.runtimeType.toString();
          if (browser) outcome = 'server_fallback';
        } finally {
          await host.close();
        }
        final row = <String, dynamic>{
          'id': source.str('id'),
          'name': source.str('name'),
          'round': round + 1,
          'keyword': keyword,
          'at': DateTime.now().toUtc().toIso8601String(),
          'wall_ms': watch.elapsedMilliseconds,
          'outcome': outcome,
          'error': error,
          'results': results,
          'unique_recognized_results': valid,
          'failed_requests': host.failedRequests,
          'network_requests': requests.length,
          'rule_timeout_seconds': source.integer('timeout'),
          'cached': false,
          'browser': browser,
          'requests': requests,
          'host_calls': calls,
        };
        samples.add(row);
        persist();
        stdout.writeln(
          jsonEncode({
            for (final key in [
              'name',
              'round',
              'wall_ms',
              'results',
              'outcome',
              'error',
            ])
              key: row[key],
          }),
        );
      }

      final rounds =
          int.tryParse(
            Platform.environment['ASTERLINK_LATENCY_ROUNDS'] ?? '',
          ) ??
          2;
      for (var round = 0; round < rounds; round++) {
        var next = 0;
        Future<void> worker() async {
          while (next < sources.length) {
            await probe(sources[next++], round);
          }
        }

        await Future.wait([worker(), worker()]);
      }
      persist(complete: true);
      expect(samples.length, sources.length * rounds);
      expect(samples.any((s) => s.str('outcome') == 'success'), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
