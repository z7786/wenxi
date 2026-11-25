import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  for (final (mode, testing, marker) in [
    ('stale', true, 'stale-pointer-ignored'),
    ('hot-restart', false, 'hot-restart-preserved'),
  ]) {
    test('Debug reference buffer: $mode', () async {
      final config = File('.dart_tool/package_config.json').absolute;
      final packages = jsonDecode(await config.readAsString()) as Map;
      final flutter = (packages['packages'] as List).cast<Map>().singleWhere(
        (entry) => entry['name'] == 'flutter_test',
      );
      final flutterRoot = config.uri.resolve(flutter['rootUri'] as String);
      final executable = p.normalize(
        p.join(
          p.fromUri(flutterRoot),
          '..',
          '..',
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      expect(File(executable).existsSync(), isTrue);
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-native-reference-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final environment = {
        ...Platform.environment,
        'TEMP': directory.path,
        'TMP': directory.path,
        'TMPDIR': directory.path,
      }..remove('FLUTTER_TEST');
      if (testing) environment['FLUTTER_TEST'] = 'true';
      final result = await Process.run(
        executable,
        [
          '--packages=${config.path}',
          File(
            'test/fixtures/native_reference_holder_probe.dart',
          ).absolute.path,
          mode,
        ],
        environment: environment,
        includeParentEnvironment: false,
      ).timeout(const Duration(seconds: 15));
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains(marker));
    });
  }
}
