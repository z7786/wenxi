import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/diagnostics/diagnostic_bundle.dart';
import 'package:asterlink/diagnostics/diagnostic_runtime.dart';
import 'package:asterlink/diagnostics/redaction.dart';

void main() {
  test(
    'Beijing display normalizes explicit offsets and crosses date boundary',
    () {
      expect(beijingLogTime('2026-09-19T23:45:12.345Z'), '2026-09-20 07:45:12');
      expect(
        beijingLogTime('2026-09-20T07:45:12+08:00'),
        '2026-09-20 07:45:12',
      );
      expect(beijingLogTime('2026-09-19T23:45:12'), '2026-09-20 07:45:12');
      expect(beijingLogTime('broken'), '时间未记录');
      final entry = LogEntry({'time': '2026-09-19T23:45:12.345Z'});
      expect(entry.displayDetail, contains('07:45:12（北京时间 UTC+08:00）'));
      expect(entry.time, '2026-09-19T23:45:12.345Z');
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Diagnostic privacy', () {
    test('Removes secrets from structured fields before serialization', () {
      final clean = LogRedactor.json({
        'Cookie': '__puus=private-cookie',
        'BDUSS': 'private-bduss',
        '__puus': 'private-puus',
        'pwd': 'private-code',
        'primary': 'private-primary',
        'capability': 'private-job-capability',
        'X-Parser-Job-Key': 'private-job-key',
        'parserState': '{"opaque":"private-parser-state"}',
        'nested': [
          {'Authorization': 'private-auth', 'accessToken': 'private-token'},
          {
            'fileName': 'private-movie.mkv',
            'body': {'anything': 'private-body'},
          },
        ],
        'status': 403,
        'connections': 512,
        'url': 'https://example.invalid/private-link?x=1',
      });
      expect(clean, isNot(contains('private-')));
      final parsed = jsonDecode(clean) as Map;
      expect(parsed['status'], 403);
      expect(parsed['connections'], 512);
    });

    test('Covers quoted and escaped credentials, links, paths and contacts', () {
      final input = [
        'Cookie: __puus=private-cookie; BDUSS=private-bduss',
        'Authorization: Bearer private-authorization',
        'X-Parser-Job-Key: private-job-key',
        'capability=private-job-capability; parserState="private-parser-state"',
        r'''{"access_token":"private-escaped\"private-tail", "pwd": "private-code"}''',
        'BDUSS=private-alone; __pus=private-pus; __puus=private-puus',
        '提取码 abcd; 访问码：efgh; password=private-password',
        'https://example.invalid/private-url?token=private-link',
        'magnet:?xt=urn:btih:private-magnet',
        'content://provider/private-document',
        r'''FileSystemException: Cannot open, path = 'D:\private-folder\file.mkv' (OS Error: 2)''',
        r'\\private-server\share\private-file',
        '/storage/emulated/0/Download/private-file',
        'private-user@example.invalid 13800138000 192.168.2.99',
      ].join('\n');
      final clean = LogRedactor.text(input);
      for (final secret in [
        'private-',
        'abcd',
        'efgh',
        '13800138000',
        '192.168.2.99',
      ]) {
        expect(clean, isNot(contains(secret)), reason: secret);
      }
      expect(clean, contains('FileSystemException'));
      expect(clean, contains('OS Error: 2'));
    });

    test('Bounds malformed input without losing usable stack frames', () {
      final stack = List.generate(
        150,
        (i) =>
            '#$i DownloadManager.transfer (package:asterlink/download.dart:$i)',
      ).join('\n');
      final clean =
          jsonDecode(
                LogRedactor.json({
                  'stack': stack,
                  'huge': '界' * 100000,
                  'infinite': double.infinity,
                  'nan': double.nan,
                  'deep': {
                    'a': {
                      'b': {
                        'c': {
                          'd': {
                            'e': {'f': 'private-hidden'},
                          },
                        },
                      },
                    },
                  },
                }),
              )
              as Map;
      expect((clean['stack'] as String).length, greaterThan(4096));
      expect(clean['stack'], contains('package:asterlink'));
      expect((clean['huge'] as String).length, lessThan(4200));
      expect(clean['nan'], 'NaN');
      expect(clean.toString(), isNot(contains('private-hidden')));
    });
  });

  group('Local diagnostic recorder', () {
    late Directory directory;
    late DiagnosticLog log;
    setUp(() {
      directory = Directory.systemTemp.createTempSync('asterlink-diagnostics-');
      log = DiagnosticLog.open(directory);
    });
    tearDown(() {
      log.close();
      DiagnosticLog.active = null;
      directory.deleteSync(recursive: true);
    });

    test('Persists a fatal stack and operation context across a restart', () {
      log.record(
        'download.remove',
        fields: {
          'task': DiagnosticLog.reference('user-task'),
          'deleteFile': false,
        },
      );
      log.record(
        'flutter.framework',
        level: 'fatal',
        error: StateError('Cookie: private-value'),
        stack: StackTrace.fromString(
          '#0 remove (package:asterlink/remove.dart:8)',
        ),
      );
      final resumed = DiagnosticLog.open(directory);
      expect(resumed.previousSessionInterrupted, isTrue);
      final entries = resumed.entries(errorsOnly: true);
      expect(entries.single.level, 'fatal');
      expect(entries.single.detail, contains('remove.dart:8'));
      expect(entries.single.detail, isNot(contains('private-value')));
      expect(resumed.exportFiles().values.join(), isNot(contains('user-task')));
      resumed.close();
      final cleanStart = DiagnosticLog.open(directory);
      expect(cleanStart.previousSessionInterrupted, isFalse);
      cleanStart.close();
    });

    test('Ordinary bursts defer disk access and flush in recorded order', () {
      fakeAsync((time) {
        log.clear();
        log.record('seed', flush: true);
        final file = directory.listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.jsonl'),
        );
        final initial = file.readAsBytesSync();
        for (var i = 0; i < 30; i++) {
          log.record('batch.$i');
        }
        expect(file.readAsBytesSync(), initial);
        time.elapse(const Duration(milliseconds: 249));
        expect(file.readAsBytesSync(), initial);
        time.elapse(const Duration(milliseconds: 1));
        final events = file.readAsLinesSync().map(
          (line) => (jsonDecode(line) as Map)['event'],
        );
        expect(events, ['seed', for (var i = 0; i < 30; i++) 'batch.$i']);
        log.close();
        expect(time.nonPeriodicTimerCount, 0);
      });
    });

    test('Errors persist earlier buffered context before returning', () {
      fakeAsync((time) {
        log.clear();
        log.record('prepare');
        log.record('open');
        log.record('decode.failed', level: 'error', error: 'Cookie: private');
        final file = directory.listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.jsonl'),
        );
        final rows = file
            .readAsLinesSync()
            .map((line) => jsonDecode(line) as Map)
            .toList();
        expect(rows.map((row) => row['event']), [
          'prepare',
          'open',
          'decode.failed',
        ]);
        expect(
          rows.map((row) => row['seq']),
          orderedEquals(rows.map((row) => row['seq']).toList()..sort()),
        );
        expect(file.readAsStringSync(), isNot(contains('private')));
        expect(time.nonPeriodicTimerCount, 0);
      });
    });

    test(
      'Clear cancels pending records and later events recreate a removed log',
      () {
        fakeAsync((time) {
          log.clear();
          log.record('discard');
          log.clear();
          time.elapse(const Duration(seconds: 1));
          expect(
            directory.listSync().whereType<File>().where(
              (file) => file.path.endsWith('.jsonl'),
            ),
            isEmpty,
          );
          log.record('first', flush: true);
          final file = directory.listSync().whereType<File>().singleWhere(
            (file) => file.path.endsWith('.jsonl'),
          );
          file.deleteSync();
          log.record('after.removal');
          time.elapse(const Duration(milliseconds: 250));
          expect(log.entries().map((entry) => entry.event), ['after.removal']);
          log.close();
          expect(time.nonPeriodicTimerCount, 0);
        });
      },
    );

    test('Disable and shutdown drain their pending operation context', () {
      fakeAsync((time) {
        log.clear();
        log.record('before.disable');
        log.setEnabled(false);
        expect(time.nonPeriodicTimerCount, 0);
        log.record('disabled');
        log.setEnabled(true);
        log.record('before.close');
        log.close();
        expect(time.nonPeriodicTimerCount, 0);
        final restarted = DiagnosticLog.open(directory);
        try {
          final events = restarted.entries().map((entry) => entry.event);
          expect(
            events,
            containsAll(['before.disable', 'before.close', 'session.close']),
          );
          expect(events, isNot(contains('disabled')));
          expect(restarted.previousSessionInterrupted, isFalse);
        } finally {
          restarted.close();
        }
      });
    });

    test('Deduplicates error storms but always preserves fatal events', () {
      var now = DateTime.now();
      log.close();
      log = DiagnosticLog.open(directory, clock: () => now);
      log.clear();
      for (var i = 0; i < 100; i++) {
        log.record('download.failed', level: 'error', error: 'same failure');
      }
      expect(log.entries(), hasLength(1));
      expect(log.suppressed, 99);
      now = now.add(const Duration(seconds: 4));
      log.record('download.failed', level: 'error', error: 'same failure');
      log.record('crash', level: 'fatal', error: 'same failure');
      log.record('crash', level: 'fatal', error: 'same failure');
      expect(log.entries(), hasLength(4));
      expect(log.entries().first.data['suppressedRepeats'], 99);
    });

    test(
      'Rotates at size limit, expires old files and clears only owned files',
      () {
        log.close();
        log = DiagnosticLog.open(directory, maxFileBytes: 2048, maxFiles: 3);
        final foreign = File('${directory.path}/keep.txt')
          ..writeAsStringSync('keep');
        final old = File('${directory.path}/app-123-ab-0.jsonl')
          ..writeAsStringSync('{"event":"old"}\n');
        old.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 8)),
        );
        for (var i = 0; i < 45; i++) {
          log.record('operation.$i', fields: {'info': 'a' * 350});
        }
        expect(old.existsSync(), isFalse);
        expect(log.exportFiles().length, lessThanOrEqualTo(3));
        expect(log.sizeBytes, lessThanOrEqualTo(3 * 2048));
        expect(log.entries().any((e) => e.event == 'operation.44'), isTrue);
        log.clear();
        expect(log.entries(), isEmpty);
        expect(foreign.readAsStringSync(), 'keep');
        log.record('after.clear');
        expect(log.entries().single.event, 'after.clear');
      },
    );

    test(
      'Skips an interrupted final write without leaking its raw contents',
      () {
        log.record('complete.entry');
        log.flush();
        final file = directory.listSync().whereType<File>().firstWhere(
          (f) => f.path.endsWith('.jsonl'),
        );
        file.writeAsStringSync(
          '{"Cookie":"private-truncated',
          mode: FileMode.append,
          flush: true,
        );
        final exported = log.exportFiles().values.join('\n');
        expect(exported, contains('complete.entry'));
        expect(exported, contains('log.partial'));
        expect(exported, isNot(contains('private-truncated')));
        for (final line in const LineSplitter().convert(exported)) {
          expect(jsonDecode(line), isA<Map>());
        }
      },
    );

    test(
      'Disabled preference survives restart and native preference reconciles it',
      () {
        log.clear();
        log.setEnabled(false);
        log.record('should.not.exist', level: 'fatal');
        log.close();
        log = DiagnosticLog.open(directory);
        expect(log.enabled, isFalse);
        expect(log.entries(), isEmpty);
        log.close();
        log = DiagnosticLog.open(directory, enabled: true);
        expect(log.enabled, isTrue);
        log.record('reenabled');
        expect(log.entries().any((e) => e.event == 'reenabled'), isTrue);
        log.close();
        log = DiagnosticLog.open(directory, enabled: false);
        expect(log.enabled, isFalse);
        expect(File('${directory.path}/disabled').existsSync(), isTrue);
      },
    );

    test(
      'Unwritable storage falls back to bounded memory and never throws from record',
      () {
        log.close();
        final blocked = File('${directory.path}/blocked')
          ..writeAsStringSync('not a directory');
        log = DiagnosticLog.open(Directory(blocked.path));
        for (var i = 0; i < 160; i++) {
          expect(
            () => log.record(
              'operation.$i',
              level: 'error',
              error: 'storage unavailable',
            ),
            returnsNormally,
          );
        }
        expect(log.persisted, isFalse);
        expect(log.storageError, isNotNull);
        expect(log.entries(), hasLength(100));
        expect(log.exportFiles().keys, contains('recent-memory.jsonl'));
      },
    );

    test('Memory fallback also expires records after seven days', () {
      var now = DateTime.now();
      log.close();
      log = DiagnosticLog.open(null, clock: () => now);
      log.record('before.expiry');
      expect(log.sizeBytes, greaterThan(0));
      now = now.add(const Duration(days: 8));
      expect(log.entries(), isEmpty);
      log.record('after.expiry');
      expect(log.entries().single.event, 'after.expiry');
    });
  });

  group('Diagnostic export', () {
    test(
      'ZIP has useful redacted records and a correct hash for every file',
      () async {
        final log = DiagnosticLog.open(null);
        addTearDown(log.close);
        log.record(
          'download.failed',
          level: 'error',
          error: 'pwd=private-value',
          fields: {'connections': 512},
        );
        final bundle = DiagnosticBundle(
          log,
          snapshot: () => {'taskCount': 3, 'Cookie': 'private-account'},
          nativeCall: (method, args) async => {
            'model': 'test-device',
            'reports': [
              {
                'content': jsonEncode({
                  'event': 'android.uncaught',
                  'stack': 'native.kt:42',
                  'token': 'private-native',
                }),
              },
              {'content': '{malformed private-partial'},
            ],
            'exits': [
              {'reason': 'low_memory', 'status': 9},
            ],
          },
        );
        final archive = ZipDecoder().decodeBytes(
          await bundle.build(
            note: '下载失败，提取码 abcd https://example.invalid/private-link',
          ),
        );
        final files = {
          for (final file in archive.files)
            file.name: file.content as List<int>,
        };
        expect(
          files.keys,
          containsAll([
            'README.txt',
            'diagnostics.json',
            'native/system.json',
            'native/error-0.json',
            'native/error-1.txt',
            'manifest.json',
          ]),
        );
        final all = files.values.map(utf8.decode).join('\n');
        expect(all, isNot(contains('private-')));
        expect(all, isNot(contains('abcd')));
        expect(all, contains('native.kt:42'));
        expect(all, contains('low_memory'));
        final manifest =
            jsonDecode(utf8.decode(files['manifest.json']!)) as Map;
        expect(manifest.length, files.length - 1);
        for (final entry in manifest.entries) {
          final bytes = files[entry.key]!;
          expect(entry.value['bytes'], bytes.length);
          expect(entry.value['sha256'], sha256.convert(bytes).toString());
        }
      },
    );

    test(
      'Failed native collection and broken app state still produce an export',
      () async {
        final log = DiagnosticLog.open(null);
        addTearDown(log.close);
        log.record('startup.failed', level: 'fatal', error: 'fixture');
        final bundle = DiagnosticBundle(
          log,
          snapshot: () => throw StateError('store failed'),
          nativeCall: (method, args) async =>
              throw PlatformException(code: 'fixture'),
        );
        final files = ZipDecoder().decodeBytes(await bundle.build()).files;
        final combined = files
            .map((f) => utf8.decode(f.content as List<int>))
            .join('\n');
        expect(combined, contains('startup.failed'));
        expect(combined, contains('stateSnapshotFailed'));
        expect(combined, contains('collectionFailed'));
      },
    );

    test('Failure to persist switch rolls native setting back', () async {
      final dir = Directory.systemTemp.createTempSync('asterlink-log-switch-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/blocked')..writeAsStringSync('blocked');
      final log = DiagnosticLog.open(Directory(file.path));
      addTearDown(log.close);
      final changes = <bool>[];
      final bundle = DiagnosticBundle(
        log,
        snapshot: () => {},
        nativeCall: (method, args) async {
          if (method == 'diagnosticEnabled') {
            changes.add(args['enabled'] as bool);
          }
          return null;
        },
      );
      await expectLater(
        bundle.setEnabled(false),
        throwsA(isA<FileSystemException>()),
      );
      expect(changes, [false, true]);
      expect(log.enabled, isTrue);
    });

    test(
      'Clear and disable apply to both log sources and preserve exported bytes',
      () async {
        final log = DiagnosticLog.open(null);
        addTearDown(log.close);
        final calls = <String>[];
        final bundle = DiagnosticBundle(
          log,
          snapshot: () => {},
          nativeCall: (method, args) async {
            calls.add(method);
            return {};
          },
        );
        final bytes = await bundle.build();
        await bundle.setEnabled(false);
        await bundle.clear();
        log.record('disabled.error', level: 'error');
        expect(log.entries(), isEmpty);
        expect(log.enabled, isFalse);
        expect(calls, [
          'diagnosticSnapshot',
          'diagnosticEnabled',
          'diagnosticClear',
        ]);
        expect(ZipDecoder().decodeBytes(bytes).files, isNotEmpty);
      },
    );
  });

  test('Global hooks retain prior handlers and are restored at shutdown', () {
    final log = DiagnosticLog.open(null);
    final originalFlutter = FlutterError.onError;
    final dispatcher = PlatformDispatcher.instance;
    final originalPlatform = dispatcher.onError;
    var frameworkCalled = false, platformCalled = false;
    FlutterError.onError = (_) => frameworkCalled = true;
    dispatcher.onError = (error, stack) {
      platformCalled = true;
      return false;
    };
    final previousFlutter = FlutterError.onError,
        previousPlatform = dispatcher.onError;
    final runtime = DiagnosticRuntime.attach(log);
    try {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: StateError('framework fixture'),
          stack: StackTrace.current,
          library: 'widget-test',
        ),
      );
      final handled = dispatcher.onError!(
        StateError('async fixture'),
        StackTrace.current,
      );
      runtime.didChangeAppLifecycleState(AppLifecycleState.inactive);
      runtime.didHaveMemoryPressure();
      expect(frameworkCalled, isTrue);
      expect(platformCalled, isTrue);
      expect(handled, isFalse);
      expect(
        log.entries().map((e) => e.event),
        containsAll([
          'flutter.framework',
          'flutter.unhandled_async',
          'lifecycle.inactive',
          'system.memory_pressure',
        ]),
      );
      runtime.dispose();
      expect(FlutterError.onError, same(previousFlutter));
      expect(dispatcher.onError, same(previousPlatform));
      expect(DiagnosticLog.active, isNull);
    } finally {
      runtime.dispose();
      FlutterError.onError = originalFlutter;
      dispatcher.onError = originalPlatform;
    }
  });
}
