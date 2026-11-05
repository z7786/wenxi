import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/parser_rules/hub.dart';
import 'package:asterlink/data/sources/catalog.dart';
import 'package:asterlink/data/sources/service.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/ui/app_theme.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'package:asterlink/ui/parse_page.dart';
import 'package:asterlink/ui/source_browser_page.dart';
import 'source_support.dart';
import 'support.dart';
import 'lanzou_folder_support.dart';

class _WidgetSources extends RemoteSources {
  _WidgetSources({required super.hub, required super.directory})
    : super(originFetch: sourceOrigin, clock: () => sourceTestNow);
  final catalog = SourceCatalog.verify(
    sourceEnvelope(),
    sourcePublicKey,
    sourceTestNow,
  );
  bool overlap = false;
  bool isReady = true;
  Future<bool>? refreshBarrier;
  int refreshCalls = 0;
  @override
  bool get ready => isReady;
  @override
  List<SourceRelease> get releases => ready ? catalog.releases : [];
  @override
  void start() {}
  @override
  Future<void> load() async {}
  @override
  Future<bool> refresh({bool force = false}) async {
    refreshCalls++;
    return await refreshBarrier ?? false;
  }

  @override
  List<SourceRelease> candidates(String url) =>
      ready && overlap ? [releases.first] : super.candidates(url);
}

class _SourceTransfer extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"source-fixture"', null), false);
}

class _SourceNative extends FakeNative {
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'version') {
      return {'taskCacheRoots': true, 'sourceNetworkPolicy': true};
    }
    return super.call(method, args);
  }
}

void main() {
  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final clock = Stopwatch()..start();
    while (!ready() && clock.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    expect(ready(), true);
    await tester.pump();
  }

  late AppServices services;
  late Directory root;
  late _WidgetSources sources;
  late FakeNative native;
  Future<void> prepare(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('aster-source-widget-');
      final store = StateStore.memory({
        'settings': {'destination': root.path},
      });
      final hub = ParserRuleHub(
        store: Vault(store),
        directory: root,
        url: 'https://hub.example.com',
        apiKey: 'fixture',
        publicKey: sourcePublicKey,
        http: FakeHttp(),
      );
      sources = _WidgetSources(hub: hub, directory: root);
      native = _SourceNative();
      services = AppServices(
        store: store,
        dataDirectory: root,
        cacheDirectory: root,
        transport: native,
        files: FakeFiles(root),
        http: FakeHttp(),
        transferHttp: _SourceTransfer(),
        platformFeatures: false,
        controlEnabled: false,
        parserRuleHub: hub,
        remoteSources: sources,
      );
      await services.downloads.initialize();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: ParsePage(services)),
      ),
    );
    await tester.enterText(find.byKey(const Key('parse-input')), jsonSourceUrl);
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    services.close().then((_) => closed = true);
    await waitFor(tester, () => closed);
    await tester.runAsync(() => root.delete(recursive: true));
  }

  testWidgets(
    'Supported cloud parsing proceeds during a pending source catalog refresh',
    (tester) async {
      await prepare(tester);
      final pending = Completer<bool>();
      try {
        sources.isReady = false;
        sources.refreshBarrier = pending.future;
        final fixture = LanzouFolderFixture();
        services.cloud.connectors[CloudPlatform.lanzou] = fixture.connector;
        await tester.enterText(
          find.byKey(const Key('parse-input')),
          lanzouFolderUrl,
        );
        await tester.pump();
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await waitFor(
          tester,
          () => find.byType(BrowserPage).evaluate().isNotEmpty,
        );
        expect(pending.isCompleted, isFalse);
        expect(sources.refreshCalls, greaterThan(0));
        expect(find.text('Example & 1.zip'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        pending.complete(false);
        await finish(tester);
      }
    },
  );

  testWidgets(
    'Unknown websites still wait for source discovery before choosing a route',
    (tester) async {
      await prepare(tester);
      final pending = Completer<bool>();
      try {
        sources.isReady = false;
        sources.refreshBarrier = pending.future;
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await waitFor(tester, () => sources.refreshCalls > 0);
        expect(find.text('选择打开方式'), findsNothing);
        expect(find.byKey(const Key('parse-stage')), findsOneWidget);
        sources.isReady = true;
        pending.complete(true);
        await waitFor(tester, () => find.text('选择打开方式').evaluate().isNotEmpty);
        expect(find.text('JSON 文件库'), findsOneWidget);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete(false);
        await finish(tester);
      }
    },
  );

  testWidgets(
    'A previously unknown website opens from a signed source and enters the existing download queue',
    (tester) async {
      await prepare(tester);
      try {
        expect(find.text('已识别：JSON 文件库'), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await waitFor(tester, () => find.text('选择打开方式').evaluate().isNotEmpty);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('选择打开方式'), findsOneWidget);
        expect(find.text('作为直链下载'), findsOneWidget);
        await tester.tap(find.text('JSON 文件库'));
        await waitFor(
          tester,
          () => find.byType(SourceBrowserPage).evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.text('样本.bin'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('source-download-one')));
        await waitFor(tester, () => services.downloads.tasks.isNotEmpty);
        final task = services.downloads.tasks.single;
        expect(task.spec.platform, isNull);
        expect(task.spec.source?['sourceId'], 'json_library');
        expect(task.spec.url, contains('/v1-one'));
        await waitFor(tester, () => native.begins.isNotEmpty);
        await waitFor(
          tester,
          () =>
              services.downloads.tasks.single.status ==
              DownloadStatus.completed,
        );
        final saved = services.downloads.tasks.single.savedPath;
        expect(saved, isNotNull);
        expect(await tester.runAsync(() => File(saved!).readAsBytes()), [
          1,
          2,
          3,
          4,
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
    skip: !hasSourceNative,
  );
  testWidgets(
    'An overlapping source keeps the existing cloud route available',
    (tester) async {
      await prepare(tester);
      try {
        sources.overlap = true;
        await tester.enterText(
          find.byKey(const Key('parse-input')),
          'https://pan.baidu.com/s/1fixture',
        );
        await tester.pump();
        await tester.ensureVisible(find.byKey(const Key('parse-start')));
        await tester.tap(find.byKey(const Key('parse-start')));
        await waitFor(tester, () => find.text('选择打开方式').evaluate().isNotEmpty);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('使用网盘解析'), findsOneWidget);
        expect(find.text('JSON 文件库'), findsOneWidget);
        expect(find.byType(SourceBrowserPage), findsNothing);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(find.byType(SourceBrowserPage), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await finish(tester);
      }
    },
  );
}
