import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/resource_pool_preview.dart';
import 'package:asterlink/data/resource_search_api.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'support.dart';

// Opt-in: pairs the actual Flutter HTTP client and preview mapping with the
// isolated Python backend. The external cloud transfer/provider are fixtures.
const endpoint = String.fromEnvironment('TRANSFER_AUDIT_URL');
const sourceFile = CloudFile(
  id: 'picked-file',
  parentId: 'source-folder',
  name: 'lesson.bin',
  size: 123,
);
const original = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.share,
  rootId: 'source-folder',
  title: 'HTTP contract',
);

class _Connector extends CloudConnector {
  @override
  CloudPlatform get platform => CloudPlatform.quark;
  final opened = <ParsedLink>[];
  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    opened.add(link);
    return const BrowseSession(
      platform: CloudPlatform.quark,
      mode: BrowseMode.share,
      rootId: 'new-root',
      title: 'HTTP contract',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async => [
    const CloudFile(
      id: 'new-file-id',
      parentId: 'new-root',
      name: 'lesson.bin',
      size: 123,
    ),
  ];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final scenario in [
    'signed',
    'native',
    'policy_probability',
    'insufficient_space',
    'no_account',
  ]) {
    test(
      'real backend HTTP preview: $scenario',
      () async {
        final transport = DioJsonHttp();
        final directory = Directory.systemTemp.createTempSync(
          'asterlink-transfer-http-',
        );
        final services = AppServices(
          store: StateStore.memory(),
          dataDirectory: directory,
          cacheDirectory: Directory('${directory.path}/cache'),
          transport: FakeNative(),
          files: FakeFiles(directory),
          http: FakeHttp(),
          platformFeatures: false,
          controlEnabled: false,
        );
        final connector = _Connector();
        services.cloud.connectors[CloudPlatform.quark] = connector;
        try {
          final setup = await transport.request(
            'POST',
            '$endpoint/audit/setup',
            body: jsonEncode({
              'scenario': {'signed', 'native'}.contains(scenario)
                  ? 'transfer'
                  : scenario,
            }),
          );
          expect(setup.status, 200);
          final raw = setup.json;
          if (scenario != 'signed') raw.remove('open_ticket');
          final api = HttpResourceSearchApi(transport, endpoint: endpoint);
          final pool = ResourcePoolPreview(
            source: ResourceSearchHit.fromRaw(raw),
            api: api,
            cloud: services.cloud,
          );
          final result = await pool.resolve(
            original,
            sourceFile,
            [],
            RequestScope(),
          );
          if ({'signed', 'native'}.contains(scenario)) {
            expect(result.file.id, 'new-file-id');
            expect(result.session.sourceLink!.shareId, 'httpnew');
            expect(connector.opened.single.passcode, 'nEw2');
            final repeated = await pool.resolve(
              original,
              sourceFile,
              [],
              RequestScope(),
            );
            expect(repeated.file.id, 'new-file-id');
            expect(connector.opened, hasLength(1));
          } else {
            expect(result.session, same(original));
            expect(result.file, same(sourceFile));
            expect(connector.opened, isEmpty);
          }
          final evidence = (await transport.get(
            '$endpoint/audit/evidence',
          )).json;
          final transferred = {'signed', 'native'}.contains(scenario);
          expect(evidence['transfers'], transferred ? 1 : 0);
          expect(evidence['changed_single_file_records'], transferred ? 1 : 0);
          if (transferred) {
            expect(evidence['selection'], {
              'file_id': 'picked-file',
              'parent_id': 'source-folder',
              'name': 'lesson.bin',
              'size': 123,
            });
            expect((evidence['events'] as List).map((e) => e['outcome']), [
              'transferred',
              'reused',
            ]);
          } else {
            expect((evidence['events'] as List).single['reason'], scenario);
          }
        } finally {
          transport.dio.close(force: true);
          await services.close();
          directory.deleteSync(recursive: true);
        }
      },
      skip: endpoint.isEmpty
          ? 'Set TRANSFER_AUDIT_URL to the isolated Python audit server.'
          : false,
    );
  }
}
