import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/ui/document_download_preview.dart';
import 'package:asterlink/ui/document_preview.dart';
import 'package:asterlink/ui/downloads_page.dart';
import 'package:asterlink/ui/preview_page.dart';
import 'package:asterlink/ui/text_preview.dart';
import 'package:asterlink/ui/transfer_widgets.dart';
import 'browser_test_support.dart';
import 'document_preview_support.dart';
import 'support.dart';

class _Services extends AppServices {
  _Services(
    Directory directory,
    StateStore store,
    FakeNative transport,
    TransferHttp http,
    FakeFiles files,
  ) : super(
        store: store,
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: transport,
        files: files,
        transferHttp: http,
        http: FakeHttp(),
        controlEnabled: false,
        platformFeatures: false,
      );
  bool failWeb = false;
  Completer<WebViewEnvironment?>? pendingWeb;
  @override
  Future<WebViewEnvironment?> webEnvironment() async {
    if (failWeb) throw StateError('Optional web component unavailable');
    if (pendingWeb != null) return pendingWeb!.future;
    return null;
  }
}

class _Http extends TransferHttp {
  _Http(this.size);
  final int size;
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      Probe(RemoteIdentity(size, '"fixture"', null), false);
}

class _Native extends FakeNative {
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'pause') {
      calls.add(method);
      writer = false;
      return null;
    }
    return super.call(method, args);
  }
}

class _Connector extends BrowserTestConnector {
  _Connector() : super(CloudPlatform.quark);
  List<CloudFile> documents = [];
  int prepared = 0;
  @override
  BrowseSession personalSession() => const BrowseSession(
    platform: CloudPlatform.quark,
    mode: BrowseMode.personal,
    title: 'fixture',
    rootId: 'root',
  );
  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async => documents;
  @override
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) async {
    prepared++;
    return DownloadSpec(
      url: 'https://document.example/local',
      fileName: file.name,
      expectedSize: file.size,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Services services;
  late FakeNative native;
  late FakeFiles files;
  late _Http http;
  late DocumentTestWebPlatform web;
  late _Connector connector;

  Future<void> setup(
    WidgetTester tester, {
    List<DownloadTask> tasks = const [],
    bool finished = true,
    bool text = false,
  }) async {
    directory = Directory.systemTemp.createTempSync(
      'asterlink-document-widget-',
    );
    await tester.runAsync(() async {
      native = _Native()..finish = finished;
      native.content
        ..clear()
        ..addAll(utf8.encode(text ? 'hello 本地文档' : '%PDF-1.7\nfixture\n%%EOF'));
      files = FakeFiles(Directory('${directory.path}/saved'));
      http = _Http(native.content.length);
      final store = StateStore.memory({
        'settings': {'threads': 1, 'retries': 0},
        'tasks': tasks.map((t) => t.toJson()).toList(),
        'credentials': {
          'Quark': Credential('fixture', {
            'primary': 'fixture-cookie',
          }, updatedAt: 1).toJson(),
        },
      });
      services = _Services(directory, store, native, http, files);
      connector = _Connector();
      services.cloud.connectors[CloudPlatform.quark] = connector;
      web = DocumentTestWebPlatform();
      InAppWebViewPlatform.instance = web;
      await services.initialize();
    });
  }

  void documentTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        // Downloads and their observers use both native I/O and frame timers.
        // Flush both while closing, before Flutter tears down its fake clock.
        var closed = false;
        final closing = services.close().whenComplete(() => closed = true);
        for (var i = 0; i < 150 && !closed; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(
          closed,
          true,
          reason: 'Preview services must release their resources',
        );
        await closing;
        http.dio.close(force: true);
        directory.deleteSync(recursive: true);
      }
    });
  }

  const session = BrowseSession(
    platform: CloudPlatform.quark,
    mode: BrowseMode.personal,
    title: 'fixture',
    rootId: 'root',
  );
  CloudFile file(String name) {
    final document = CloudFile(
      id: 'file',
      name: name,
      size: native.content.length,
    );
    connector.documents = [document];
    return document;
  }

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 150 && !condition(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      condition(),
      true,
      reason:
          'Tasks: ${services.downloads.tasks.map((t) => '${t.status.name}/${t.phase}/${t.error}').join('; ')}; '
          'Native: ${native.calls}; '
          'UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join('; ')}',
    );
  }

  Future<void> confirmDownload(WidgetTester tester) async {
    await pumpUntil(
      tester,
      () => find
          .byKey(const Key('document-download-confirm'))
          .evaluate()
          .isNotEmpty,
    );
    expect(services.downloads.tasks, isEmpty);
    expect(connector.prepared, 0);
    expect(native.begins, isEmpty);
    await tester.tap(find.byKey(const Key('document-download-confirm')));
    await tester.pump();
  }

  documentTest('opening and leaving a document never starts a download', (
    tester,
  ) async {
    await setup(tester);
    await tester.pumpWidget(
      MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
    );
    await tester.pump();
    await pumpUntil(tester, () => find.text('下载并预览').evaluate().isNotEmpty);
    await tester.pump(const Duration(seconds: 2));
    expect(services.downloads.tasks, isEmpty);
    expect(connector.prepared, 0);
    expect(native.begins, isEmpty);
    expect(web.views, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(services.downloads.tasks, isEmpty);
  });

  documentTest('cancelling the download location never enqueues a document', (
    tester,
  ) async {
    await setup(tester);
    await services.updateSettings({'askDownloadDestination': true});
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      // The preparation spinner remains behind the location dialog; wait for
      // that dialog rather than waiting for all animations to stop.
      await pumpUntil(tester, () => find.text('下载保存位置').evaluate().isNotEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('下载保存位置'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await pumpUntil(
        tester,
        () => find.textContaining('已取消下载').evaluate().isNotEmpty,
      );
      expect(services.downloads.tasks, isEmpty);
      expect(connector.prepared, 0);
      expect(native.begins, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  documentTest(
    'reopening a failed document observes its error without retrying it',
    (tester) async {
      await setup(tester);
      files.failSave = true;
      final document = file('report.pdf');
      final id = (await tester.runAsync(
        () => services.downloads.enqueue(
          services.cloud.planDownload(session, document),
        ),
      ))!;
      await pumpUntil(
        tester,
        () => services.downloads.task(id)?.status == DownloadStatus.failed,
      );
      final begins = native.begins.length;
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, document)),
      );
      await tester.pump();
      await pumpUntil(tester, () => find.text('文档下载失败').evaluate().isNotEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(services.downloads.task(id)?.status, DownloadStatus.failed);
      expect(native.begins, hasLength(begins));
      expect(services.downloads.tasks, hasLength(1));
    },
  );

  documentTest(
    'missing completed document asks before downloading a replacement',
    (tester) async {
      await setup(tester);
      final document = file('report.pdf');
      final id = (await tester.runAsync(
        () => services.downloads.enqueue(
          services.cloud.planDownload(session, document),
        ),
      ))!;
      await pumpUntil(
        tester,
        () => services.downloads.task(id)?.status == DownloadStatus.completed,
      );
      files.availability[services.downloads.task(id)!.savedPath!] =
          FileAvailability.missing;
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, document)),
      );
      await tester.pump();
      await pumpUntil(tester, () => find.text('下载并预览').evaluate().isNotEmpty);
      expect(services.downloads.tasks, hasLength(1));
      expect(connector.prepared, 1);
      expect(web.views, isEmpty);
      await tester.tap(find.byKey(const Key('document-download-confirm')));
      await tester.pump();
      await pumpUntil(tester, () => web.views.isNotEmpty);
      expect(services.downloads.tasks, hasLength(2));
      expect(connector.prepared, 2);
    },
  );

  documentTest(
    'remote document downloads after confirmation and then reuses its local file',
    (tester) async {
      await setup(tester);
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      await pumpUntil(tester, () => web.views.isNotEmpty);
      web.ready();
      await tester.pump();
      expect(services.downloads.tasks, hasLength(1));
      expect(services.downloads.tasks.single.status, DownloadStatus.completed);
      expect(files.savedCount, 1);
      expect(connector.prepared, 1);
      final view = web.views.first;
      expect(view.params.initialUrlRequest!.url!.host, '127.0.0.1');
      expect(view.params.initialSettings!.allowFileAccess, false);
      expect(view.params.initialSettings!.thirdPartyCookiesEnabled, false);
      expect(find.textContaining('第三方'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      final firstUrl = view.params.initialUrlRequest!.url!;
      await pumpUntil(
        tester,
        () =>
            web.views.any((v) => v.params.initialUrlRequest!.url! != firstUrl),
      );
      web.ready();
      await tester.pump();
      expect(services.downloads.tasks, hasLength(1));
      expect(connector.prepared, 1);
      expect(files.savedCount, 1);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  documentTest(
    'unfinished document shows pause/resume and leaving keeps the download task',
    (tester) async {
      await setup(tester, finished: false);
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      await pumpUntil(tester, () => native.begins.isNotEmpty);
      expect(find.text('下载完成后自动预览'), findsOneWidget);
      await tester.tap(find.byKey(const Key('document-download-control')));
      await pumpUntil(
        tester,
        () => services.downloads.tasks.single.status == DownloadStatus.paused,
      );
      await tester.pump();
      expect(find.text('下载已暂停'), findsOneWidget);
      await pumpUntil(
        tester,
        () =>
            tester
                .widget<TransferActionButton>(
                  find.byKey(const Key('document-download-control')),
                )
                .onPressed !=
            null,
      );
      native.finish = true;
      await tester.tap(find.byKey(const Key('document-download-control')));
      await pumpUntil(tester, () => web.views.isNotEmpty);
      expect(services.downloads.tasks, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(services.downloads.tasks.single.status, DownloadStatus.completed);
      expect(tester.takeException(), null);
    },
  );

  documentTest(
    'previewing a paused task keeps it paused until continue is explicitly tapped',
    (tester) async {
      await setup(tester, finished: false);
      final document = file('report.pdf');
      final id = (await tester.runAsync(
        () => services.downloads.enqueue(
          services.cloud.planDownload(session, document),
        ),
      ))!;
      await pumpUntil(tester, () => native.begins.isNotEmpty);
      await tester.runAsync(() => services.downloads.pause(id));
      native.finish = true;
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, document)),
      );
      await tester.pump();
      await pumpUntil(tester, () => find.text('下载已暂停').evaluate().isNotEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(services.downloads.task(id)?.status, DownloadStatus.paused);
      expect(web.views, isEmpty);
      expect(services.downloads.tasks, hasLength(1));
      await tester.tap(find.byKey(const Key('document-download-control')));
      await pumpUntil(tester, () => web.views.isNotEmpty);
      expect(services.downloads.tasks, hasLength(1));
      expect(services.downloads.tasks.single.id, id);
      expect(services.downloads.task(id)?.status, DownloadStatus.completed);
    },
  );

  documentTest(
    'download failure can retry in the viewer and leaving an active task retains it',
    (tester) async {
      await setup(tester);
      files.failSave = true;
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      await pumpUntil(
        tester,
        () => services.downloads.tasks.any(
          (t) => t.status == DownloadStatus.failed,
        ),
      );
      await tester.pump();
      expect(find.text('文档下载失败'), findsOneWidget);
      files.failSave = false;
      await tester.tap(find.byKey(const Key('document-download-control')));
      await pumpUntil(tester, () => web.views.isNotEmpty);
      expect(services.downloads.tasks, hasLength(1));
      expect(files.savedCount, 1);
    },
  );

  documentTest(
    'leaving download preview does not cancel an ordinary active download',
    (tester) async {
      await setup(tester, finished: false);
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      await pumpUntil(tester, () => native.begins.isNotEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(services.downloads.tasks.single.active, true);
      native.finish = true;
      await pumpUntil(
        tester,
        () =>
            services.downloads.tasks.single.status == DownloadStatus.completed,
      );
      expect(files.savedCount, 1);
    },
  );

  documentTest(
    'text preview uses saved download without sending file to a website',
    (tester) async {
      await setup(tester, text: true);
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('notes.txt'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      await pumpUntil(
        tester,
        () => find.byType(TextPreview).evaluate().isNotEmpty,
      );
      expect(
        tester.widget<TextPreview>(find.byType(TextPreview)).document.text,
        'hello 本地文档',
      );
      expect(services.downloads.tasks.single.status, DownloadStatus.completed);
      expect(web.views, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  documentTest(
    'document renderer failure retains completed download and offers external open',
    (tester) async {
      await setup(tester);
      services.failWeb = true;
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      await pumpUntil(tester, () => find.text('用其他应用打开').evaluate().isNotEmpty);
      expect(find.text('暂时无法预览'), findsOneWidget);
      expect(services.downloads.tasks.single.status, DownloadStatus.completed);
      expect(files.savedCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), null);
    },
  );

  documentTest(
    'downloads page opens PDF in-app and retains share and external open',
    (tester) async {
      await setup(tester);
      await tester.runAsync(() async {
        final id = await services.downloads.enqueue(
          services.cloud.planDownload(session, file('report.pdf')),
        );
        await until(
          () => services.downloads.task(id)?.status == DownloadStatus.completed,
        );
      });
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DownloadsPage(services))),
      );
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.byTooltip('预览文档').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('预览文档'));
      await tester.pump(const Duration(milliseconds: 500));
      await pumpUntil(tester, () => web.views.isNotEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      web.ready();
      await tester.pump();
      expect(find.byType(LocalDocumentPreviewPage), findsOneWidget);
      await tester.tap(find.byTooltip('文档操作'));
      await tester.pumpAndSettle();
      expect(find.text('分享文件'), findsOneWidget);
      expect(find.text('用其他应用打开'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  documentTest(
    'leaving while the optional web component starts releases the document page',
    (tester) async {
      await setup(tester);
      final pending = services.pendingWeb = Completer<WebViewEnvironment?>();
      await tester.pumpWidget(
        MaterialApp(home: PreviewPage(services, session, file('report.pdf'))),
      );
      await tester.pump();
      await confirmDownload(tester);
      await pumpUntil(
        tester,
        () => find.byType(LocalDocumentPreviewPage).evaluate().isNotEmpty,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      pending.complete(null);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(web.views, isEmpty);
      expect(services.downloads.tasks.single.status, DownloadStatus.completed);
      expect(tester.takeException(), null);
    },
  );

  for (final (size, brightness) in [
    (const Size(320, 640), Brightness.light),
    (const Size(1024, 768), Brightness.dark),
  ]) {
    documentTest(
      'document waiting page fits $size and $brightness at large text',
      (tester) async {
        await setup(tester, finished: false);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: DocumentDownloadPreview(
              services: services,
              session: session,
              file: file('用户下载的常见文档.pdf'),
            ),
          ),
        );
        await tester.pump();
        await confirmDownload(tester);
        await pumpUntil(
          tester,
          () => find
              .byKey(const Key('document-download-control'))
              .evaluate()
              .isNotEmpty,
        );
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(services.downloads.tasks, hasLength(1));
      },
    );
  }
}
