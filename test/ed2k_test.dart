import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/ed2k.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/clipboard_links.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'support.dart';

const hash = 'A448017AAF21D8525FC10AE87AA6729D';
const sample = 'ed2k://|file|%E8%B5%84%E6%96%99%20a+b.zip|4|$hash|/';

class _Ed2kNative extends FakeNative {
  bool supported = true;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'version') return {'ed2k': supported, 'taskCacheRoots': true};
    final result = await super.call(method, args);
    if (method == 'snapshot') {
      return {...asJson(result), 'activeConnections': 2, 'totalConnections': 5};
    }
    return result;
  }
}

class _NoHttp extends TransferHttp {
  int probes = 0;
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async {
    probes++;
    throw StateError('ED2K must never use HTTP probing');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ED2K recognizes Unicode, plus, source extensions and escaped pipes',
    () {
      final link = Ed2kLink.parse(sample);
      expect(link.name, '资料 a+b.zip');
      expect(link.size, 4);
      expect(link.hash, hash.toLowerCase());
      expect(Ed2kLink.parse(link.url).name, link.name);
      final source = '$sample|sources,127.0.0.1:4662|/';
      expect(
        LinkParser.parse(
          '文件 $source\nhttps://example.test/a',
        ).map((e) => e.kind),
        [LinkKind.ed2k, LinkKind.direct],
      );
      expect(
        LinkParser.parse(source).single.url,
        contains('|sources,127.0.0.1:4662|/'),
      );
      expect(Ed2kLink.parse(sample.replaceAll('|', '%7C')).name, link.name);
      expect(
        Ed2kLink.parse('ed2k://|file|a%7Cb.bin|4|$hash|/').name,
        'a|b.bin',
      );
      expect(LinkParser.parse('$sample $sample').length, 1);
      expect(ClipboardLinkSuggestion.fromText(sample), isNotNull);
      final hit = ResourceSearchHit.fromRaw({
        'title': 'ED2K',
        'links': [
          {'url': sample},
        ],
      });
      expect(hit.canParse, isTrue);
      expect(hit.identity, 'ed2k:${hash.toLowerCase()}:4');
    },
  );
  test('ED2K rejects broken links and sizes', () {
    for (final input in [
      sample.replaceFirst('|4|', '|0|'),
      sample.replaceFirst('|4|', '|274877906945|'),
      sample.replaceFirst(hash, '123'),
      sample.substring(0, sample.length - 2),
      sample.replaceFirst('a+b', 'a%00b'),
      sample.replaceFirst('a+b', 'a%XXb'),
      'ed2k://|server|127.0.0.1|4661|/',
    ]) {
      expect(() => Ed2kLink.parse(input), throwsA(isA<AppException>()));
    }
  });
  group('ED2K queue', () {
    late Directory root;
    late StateStore store;
    late _Ed2kNative native;
    late GopeedEngine engine;
    late DownloadManager manager;
    late _NoHttp http;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('aster-ed2k-');
      store = StateStore.memory({
        'settings': {'concurrent': 3},
      });
      native = _Ed2kNative();
      http = _NoHttp();
      engine = GopeedEngine(
        native,
        store,
        Vault(store),
        Directory(p.join(root.path, 'native')),
        Directory(p.join(root.path, 'cache')),
      );
      manager = DownloadManager(
        store: store,
        engine: engine,
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        cleanups: CleanupOutbox(store, FakeHttp()),
        http: http,
        refreshSource: (_) async => throw StateError('No ED2K resolver'),
      );
      await manager.initialize();
    });
    tearDown(() async {
      await manager.close();
      manager.dispose();
      await root.delete(recursive: true);
    });
    test('downloads and publishes with no HTTP request', () async {
      final id = await manager.enqueue(
        const DownloadSpec(url: sample, fileName: '资料.zip'),
      );
      await until(
        () =>
            manager.task(id)?.status == DownloadStatus.completed ||
            manager.task(id)?.status == DownloadStatus.failed,
      );
      expect(manager.task(id)!.error, isEmpty);
      expect(manager.task(id)!.status, DownloadStatus.completed);
      expect(manager.task(id)!.total, 4);
      expect(http.probes, 0);
      expect(
        await File(manager.task(id)!.savedPath!).readAsBytes(),
        native.content,
      );
      expect(
        native.calls.indexOf('pause'),
        lessThan(native.calls.lastIndexOf('remove')),
      );
    });
    test(
      'ED2K tasks queue serially and pause releases the next task',
      () async {
        native.finish = false;
        final ids = await manager.enqueueAll([
          const DownloadSpec(url: sample, fileName: 'a.zip'),
          DownloadSpec(
            url: sample.replaceFirst(hash, 'b' * 32),
            fileName: 'b.zip',
          ),
        ]);
        await until(() => native.begins.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 600));
        expect(native.begins.length, 1);
        expect(manager.task(ids[1])!.status, DownloadStatus.pending);
        expect(manager.httpConnections(ids[0]), (active: 2, total: 5));
        await manager.pause(ids[0]);
        await until(() => native.begins.length == 2);
        expect(http.probes, 0);
      },
    );
    test('old native component is rejected before begin', () async {
      native.supported = false;
      await expectLater(
        engine.begin({'id': 'old', 'url': sample}),
        throwsA(isA<AppException>()),
      );
      expect(native.begins, isEmpty);
    });
    test('duplicate ED2K files keep the existing resume record', () async {
      native.finish = false;
      await manager.enqueue(const DownloadSpec(url: sample, fileName: 'a.zip'));
      await expectLater(
        manager.enqueue(const DownloadSpec(url: sample, fileName: 'b.zip')),
        throwsA(isA<AppException>()),
      );
      expect(manager.tasks.length, 1);
    });
  });
  testWidgets(
    'ED2K dialog uses the file name and does not offer HTTP controls',
    (tester) async {
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('aster-ed2k-widget-'),
      ))!;
      final native = _Ed2kNative()..finish = false;
      final services = AppServices(
        controlEnabled: false,
        store: StateStore.memory(),
        dataDirectory: root,
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        transport: native,
        files: FakeFiles(Directory(p.join(root.path, 'saved'))),
        http: FakeHttp(),
        platformFeatures: false,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        var closed = false;
        final closing = services.close().whenComplete(() => closed = true);
        for (var i = 0; i < 100 && !closed; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(closed, isTrue);
        await closing;
        services.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    directDownloadDialog(context, services, initial: sample),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('direct-download-name')))
            .controller!
            .text,
        '资料 a+b.zip',
      );
      expect(
        find.byKey(const Key('direct-download-connections')),
        findsNothing,
      );
      expect(find.text('自定义请求头'), findsNothing);
      await tester.tap(find.byKey(const Key('direct-download-submit')));
      for (var i = 0; i < 50 && services.downloads.tasks.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(services.downloads.tasks.single.spec.isEd2k, isTrue);
      expect(services.downloads.tasks.single.total, 4);
      final stopping = services.downloads.pauseAll();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await stopping;
    },
  );
}
