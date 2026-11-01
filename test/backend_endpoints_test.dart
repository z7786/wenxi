import 'dart:io';
import 'dart:typed_data';

import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/backend_endpoints.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Parser address migrates cached legacy addresses to the shared domain',
    () {
      for (final address in [
        BackendEndpoints.legacyParser,
        '${BackendEndpoints.legacyParser}/',
        '  ${BackendEndpoints.legacyParser}  ',
      ]) {
        expect(BackendEndpoints.parserUrl(address), BackendEndpoints.search);
      }
      for (final address in [
        'https://parser.example.test',
        'http://39.102.115.36:5174',
        '${BackendEndpoints.legacyParser}/custom',
        '',
      ]) {
        expect(BackendEndpoints.parserUrl(address), address);
      }
    },
  );

  test(
    'An old remote control publication cannot restore the migrated address',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'parser-address-',
      );
      final store = await StateStore.open(directory, testKey: Uint8List(32));
      final hub = ParserRuleHub(
        store: Vault(store),
        directory: directory,
        url: BackendEndpoints.legacyParser,
        apiKey: '',
        publicKey: '',
      );
      try {
        expect(hub.url, BackendEndpoints.parser);
        expect(
          hub.updateEndpoint(Uri.parse(BackendEndpoints.legacyParser)),
          false,
        );
        expect(hub.url, BackendEndpoints.parser);
        expect(
          hub.updateEndpoint(Uri.parse('https://other.example.test')),
          true,
        );
        expect(hub.url, 'https://other.example.test');
        expect(
          hub.updateEndpoint(Uri.parse(BackendEndpoints.legacyParser)),
          true,
        );
        expect(hub.url, BackendEndpoints.parser);
      } finally {
        await hub.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
