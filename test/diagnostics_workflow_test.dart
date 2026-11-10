import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/diagnostics/diagnostic_bundle.dart';
import 'package:asterlink/diagnostics/diagnostic_share.dart';
import 'package:asterlink/diagnostics/web_login_diagnostics.dart';
import 'package:asterlink/domain/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Clipboard and ZIP summaries include redacted native and web failures',
    () async {
      final now = DateTime.utc(2026, 9, 18, 2, 30);
      final log = DiagnosticLog.open(null, clock: () => now);
      addTearDown(log.close);
      log.record(
        'web_login.http_failed',
        level: 'error',
        fields: {
          'platform': 'quark',
          'stage': 'http',
          'httpStatus': 403,
          'url': 'https://example.invalid/private-link',
          'headers': {'Cookie': 'private-cookie'},
        },
      );
      final bundle = DiagnosticBundle(
        log,
        snapshot: () => {},
        nativeCall: (_, _) async => {
          'manufacturer': 'Fixture',
          'model': 'Test device',
          'api': 35,
          'android': '15',
          'reports': [
            {
              'content': jsonEncode({
                'time': now.millisecondsSinceEpoch,
                'event': 'android.uncaught',
                'causes': [
                  {
                    'type': 'ExampleException',
                    'message': 'Cookie: private-native',
                  },
                ],
              }),
            },
            {'content': 'broken private-report'},
          ],
          'exits': [
            {'time': now.millisecondsSinceEpoch, 'reason': 'low_memory'},
          ],
        },
      );
      const note =
          '白屏，password=private-password，链接 https://example.invalid/private-url';
      final summary = await bundle.summary(note: note);
      expect(summary, contains('网页登录 HTTP 错误'));
      expect(summary, contains('HTTP=403'));
      expect(summary, contains('Fixture Test device'));
      expect(summary, contains('ExampleException'));
      expect(summary, contains('系统内存回收'));
      expect(summary, isNot(contains('private-')));
      final zip = ZipDecoder().decodeBytes(await bundle.build(note: note));
      final zippedSummary = zip.files.singleWhere(
        (file) => file.name == 'summary.txt',
      );
      expect(utf8.decode(zippedSummary.content as List<int>), summary);
      final manifest =
          jsonDecode(
                utf8.decode(
                  zip.files
                          .singleWhere((file) => file.name == 'manifest.json')
                          .content
                      as List<int>,
                ),
              )
              as Map;
      expect(manifest, contains('summary.txt'));
    },
  );

  test(
    'An interrupted marker and missing native information do not invent a crash',
    () async {
      final log = DiagnosticLog.open(null);
      addTearDown(log.close);
      log.previousSessionInterrupted = true;
      final bundle = DiagnosticBundle(
        log,
        snapshot: () => {},
        nativeEnabled: false,
      );
      final summary = await bundle.summary();
      expect(summary, contains('不能据此认定崩溃'));
      expect(summary, contains('暂无保存的 Flutter 错误或警告'));
      expect(summary, isNot(contains('Java/Kotlin 崩溃')));
      expect(summary, isNot(contains('原生崩溃')));
    },
  );

  test(
    'Android symbolic crash trace and memory history survive ZIP export',
    () async {
      final log = DiagnosticLog.open(null);
      addTearDown(log.close);
      log.record(
        'player.memory_sample',
        fields: {
          'hwdecCurrent': 'mediacodec-copy',
          'memory': {'rssKb': 1355516, 'graphicsPrivateKb': 150000},
        },
      );
      const trace =
          '#00 pc 1234 libmpv.so (decoder_process+12) (BuildId: aabbccdd)';
      final bundle = DiagnosticBundle(
        log,
        snapshot: () => {},
        nativeCall: (_, _) async => {
          'api': 36,
          'exits': [
            {
              'time': DateTime.now().millisecondsSinceEpoch,
              'reason': 'native_crash',
              'signalName': 'SIGSEGV',
              'faultModule': 'libmpv.so',
              'faultOffset': '0x1234',
              'trace': trace,
            },
          ],
        },
      );
      final zip = ZipDecoder().decodeBytes(await bundle.build());
      final files = {
        for (final file in zip.files)
          file.name: utf8.decode(file.content as List<int>),
      };
      final native = jsonDecode(files['native/system.json']!) as Map;
      expect((native['exits'] as List).single['trace'], trace);
      expect(files['summary.txt'], contains('SIGSEGV'));
      expect(files['summary.txt'], contains('libmpv.so'));
      expect(
        files.entries
            .where((e) => e.key.startsWith('logs/'))
            .map((e) => e.value)
            .join(),
        contains('1355516'),
      );
    },
  );

  test(
    'Summary size and error count remain bounded with long failure messages',
    () async {
      final log = DiagnosticLog.open(null);
      addTearDown(log.close);
      for (var i = 0; i < 12; i++) {
        log.record(
          'fixture.error$i',
          level: 'error',
          error: 'message-${'界' * 10000}',
        );
      }
      final summary = await DiagnosticBundle(
        log,
        snapshot: () => {},
        nativeEnabled: false,
      ).summary(note: '说明' * 10000);
      expect(summary.length, lessThanOrEqualTo(10010));
      expect(RegExp(r'\[fixture\.error').allMatches(summary), hasLength(3));
    },
  );

  test(
    'Browser failures distinguish main pages, subresources and renderer termination',
    () {
      final log = DiagnosticLog.open(null);
      addTearDown(log.close);
      var millis = 0;
      final browser = WebLoginDiagnostics(
        CloudPlatform.c139,
        log: log,
        milliseconds: () => millis,
      );
      browser.pageStarted();
      millis = 125;
      browser.resourceFailed(isMainFrame: false, type: 'HOST_LOOKUP', code: -2);
      millis = 200;
      browser.httpFailed(isMainFrame: true, status: 503);
      millis = 230;
      browser.rendererGone(didCrash: false, priority: 1);
      browser.close(completed: false);
      browser.httpFailed(isMainFrame: true, status: 401);
      final entries = log.entries();
      final http = entries.singleWhere(
        (entry) => entry.event == 'web_login.http_failed',
      );
      expect(http.level, 'error');
      expect(http.data['fields'], containsPair('httpStatus', 503));
      expect(http.data['fields'], containsPair('pageElapsedMs', 200));
      expect(
        http.data['fields'],
        containsPair('platform', CloudPlatform.c139.key),
      );
      final resource = entries.singleWhere(
        (entry) => entry.event == 'web_login.resource_failed',
      );
      expect(resource.level, 'warning');
      final renderer = entries.singleWhere(
        (entry) => entry.event == 'web_login.renderer_gone',
      );
      expect(renderer.level, 'warning');
      expect(renderer.data['fields'], containsPair('didCrash', false));
      expect(
        entries.where((entry) => entry.event == 'web_login.closed'),
        hasLength(1),
      );
    },
  );

  test('Browser collection respects the recording switch', () {
    final log = DiagnosticLog.open(null)..clear();
    addTearDown(log.close);
    log.setEnabled(false);
    final browser = WebLoginDiagnostics(CloudPlatform.baidu, log: log);
    browser.pageStarted();
    browser.httpFailed(isMainFrame: true, status: 403);
    browser.rendererGone(didCrash: true);
    browser.close(completed: false);
    expect(log.entries(), isEmpty);
  });

  test(
    'Temporary sharing prunes only owned copies and keeps recent files readable',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'asterlink-share-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final now = DateTime.now();
      final directory = await Directory(
        '${root.path}/diagnostic-shares',
      ).create();
      final foreign = File('${directory.path}/keep.txt')
        ..writeAsStringSync('keep');
      for (var index = 0; index < 4; index++) {
        final file = File('${directory.path}/文析助手-logs-0.3.30-35-$index.zip');
        await file.writeAsBytes([index]);
        await file.setLastModified(now.subtract(Duration(hours: index)));
      }
      final expired = File('${directory.path}/文析助手-logs-0.3.30-35-9.zip');
      await expired.writeAsBytes([9]);
      await expired.setLastModified(now.subtract(const Duration(days: 2)));
      final result = await prepareDiagnosticShare(
        root,
        Uint8List.fromList([80, 75, 3, 4]),
        '文析助手-logs-0.3.30-35-10.zip',
        now: now,
      );
      expect(await result.readAsBytes(), [80, 75, 3, 4]);
      expect(await foreign.readAsString(), 'keep');
      expect(await expired.exists(), isFalse);
      expect(
        directory.listSync().whereType<File>().where(
          (f) => f.path.endsWith('.zip'),
        ),
        hasLength(3),
      );
      await expectLater(
        prepareDiagnosticShare(root, Uint8List(0), '../outside.zip'),
        throwsArgumentError,
      );
    },
  );
}
