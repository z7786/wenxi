import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/github_acceleration.dart';
import 'package:asterlink/playback/windows_player_components.dart';
import 'package:asterlink/ui/player_components_page.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final archiveBytes = List<int>.generate(4096, (i) => i % 251);
  final libraryBytes = List<int>.generate(8192, (i) => i % 239);
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'asterlink-player-components-',
    );
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  Future<HttpServer> server(void Function(HttpRequest) handle) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    addTearDown(() => server.close(force: true));
    return server;
  }

  PlayerComponentArtifact artifact(String url) => PlayerComponentArtifact(
    id: 'test-x64-v1',
    url: url,
    archiveBytes: archiveBytes.length,
    archiveHash: sha256.convert(archiveBytes).toString(),
    libraryBytes: libraryBytes.length,
    libraryHash: sha256.convert(libraryBytes).toString(),
  );
  Dio http() {
    final client = Dio(BaseOptions(validateStatus: (_) => true));
    client.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => _RealHttp().createHttpClient(null),
    );
    return client;
  }

  WindowsPlayerComponents components(
    String url, {
    PlayerComponentExtractor? extract,
    bool supported = true,
  }) {
    final value = WindowsPlayerComponents(
      directory: () async => root,
      artifact: artifact(url),
      supported: supported,
      http: http,
      extract:
          extract ??
          (archive, directory, cancel) async {
            expect(await archive.readAsBytes(), archiveBytes);
            await File(
              p.join(directory.path, 'libmpv-2.dll'),
            ).writeAsBytes(libraryBytes);
          },
    );
    addTearDown(value.close);
    return value;
  }

  Future<void> installed(String url) async {
    final file = File(p.join(root.path, artifact(url).id, 'libmpv-2.dll'));
    await file.parent.create();
    await file.writeAsBytes(libraryBytes);
  }

  const direct = GitHubAcceleration(mode: 'direct');

  test(
    'download installs verified data without silently enabling it; selection persists',
    () async {
      var requests = 0;
      final origin = await server((request) {
        requests++;
        request.response.contentLength = archiveBytes.length;
        request.response.add(archiveBytes);
        unawaited(request.response.close());
      });
      final url = 'http://127.0.0.1:${origin.port}/component';
      final value = components(url);
      final first = value.download(acceleration: direct);
      expect(identical(first, value.download(acceleration: direct)), isTrue);
      await first;
      expect(requests, 1);
      expect(value.error, isNull);
      expect(value.installed, isTrue);
      expect(value.selected, WindowsPlayerVariant.compact);
      expect(value.stage, PlayerComponentStage.idle);
      expect(await root.list().map((file) => p.basename(file.path)).toList(), [
        'test-x64-v1',
      ]);
      await value.select(WindowsPlayerVariant.full);
      expect(value.restartRequired, isTrue);
      final restarted = components(url);
      String? selectedPath;
      await restarted.initializeRuntime(
        (path) => selectedPath = path,
        bundledLibrary: 'compact.dll',
      );
      expect(selectedPath, p.join(root.path, 'test-x64-v1', 'libmpv-2.dll'));
      expect(restarted.active, WindowsPlayerVariant.full);
      expect(restarted.restartRequired, isFalse);
    },
  );

  test(
    'bad hash never replaces a working installation or changes its selection',
    () async {
      var extracted = false;
      final origin = await server((request) {
        request.response.contentLength = archiveBytes.length;
        request.response.add(List<int>.filled(archiveBytes.length, 0));
        unawaited(request.response.close());
      });
      final url = 'http://127.0.0.1:${origin.port}/component';
      await installed(url);
      final value = components(
        url,
        extract: (_, _, _) async => extracted = true,
      );
      await value.select(WindowsPlayerVariant.full);
      await value.download(acceleration: direct);
      expect(value.error, contains('校验失败'));
      expect(extracted, isFalse);
      expect(value.selected, WindowsPlayerVariant.full);
      expect(
        await File(
          p.join(root.path, 'test-x64-v1', 'libmpv-2.dll'),
        ).readAsBytes(),
        libraryBytes,
      );
      expect(
        await root
            .list()
            .where((file) => p.basename(file.path).startsWith('install-'))
            .isEmpty,
        isTrue,
      );
    },
  );

  test('wrong extracted DLL is rejected before publication', () async {
    final origin = await server((request) {
      request.response.add(archiveBytes);
      unawaited(request.response.close());
    });
    final value = components(
      'http://127.0.0.1:${origin.port}/component',
      extract: (_, directory, _) async {
        await File(
          p.join(directory.path, 'libmpv-2.dll'),
        ).writeAsBytes(List<int>.filled(libraryBytes.length, 0));
      },
    );
    await value.download(acceleration: direct);
    expect(value.installed, isFalse);
    expect(value.error, contains('组件校验失败'));
    expect(await root.list().isEmpty, isTrue);
  });

  test('cancel stops an unfinished body and cleans staging', () async {
    final reached = Completer<void>();
    final origin = await server((request) async {
      request.response.contentLength = archiveBytes.length;
      request.response.add(archiveBytes.take(100).toList());
      try {
        await request.response.flush();
      } catch (_) {}
      reached.complete();
    });
    final value = components('http://127.0.0.1:${origin.port}/component');
    final work = value.download(acceleration: direct);
    await reached.future;
    value.cancelDownload();
    await work.timeout(const Duration(seconds: 3));
    expect(value.error, isNull);
    expect(value.busy, isFalse);
    expect(value.installed, isFalse);
    expect(await root.list().isEmpty, isTrue);
  });

  test(
    'cancelling during the initial storage read prevents a request',
    () async {
      final reading = Completer<Directory>();
      var requests = 0;
      final origin = await server((request) {
        requests++;
        request.response.add(archiveBytes);
        unawaited(request.response.close());
      });
      final value = WindowsPlayerComponents(
        supported: true,
        directory: () => reading.future,
        artifact: artifact('http://127.0.0.1:${origin.port}/component'),
        http: http,
      );
      addTearDown(value.close);
      final work = value.download(acceleration: direct);
      expect(value.busy, isTrue);
      value.cancelDownload();
      reading.complete(root);
      await work;
      expect(requests, 0);
      expect(value.busy, isFalse);
      expect(value.error, isNull);
      expect(await root.list().isEmpty, isTrue);
    },
  );

  test(
    'selection is serialized with install and removal across pages',
    () async {
      final reading = Completer<Directory>();
      final value = WindowsPlayerComponents(
        supported: true,
        directory: () => reading.future,
        artifact: artifact('https://example.test/component'),
        http: http,
      );
      addTearDown(value.close);
      final choosing = value.select(WindowsPlayerVariant.compact);
      expect(
        () => value.select(WindowsPlayerVariant.full),
        throwsA(isA<AppException>()),
      );
      expect(
        () => value.download(acceleration: direct),
        throwsA(isA<AppException>()),
      );
      expect(value.remove, throwsA(isA<AppException>()));
      reading.complete(root);
      await choosing;
      expect(value.busy, isFalse);
      final work = value.download(acceleration: direct);
      expect(
        () => value.select(WindowsPlayerVariant.full),
        throwsA(isA<AppException>()),
      );
      value.cancelDownload();
      await work;
      expect(value.busy, isFalse);
    },
  );

  test(
    'missing/corrupt component falls back and repairs its preference',
    () async {
      final value = components('https://example.test/component');
      await File(
        p.join(root.path, 'selection.json'),
      ).writeAsString(jsonEncode({'variant': 'full'}));
      final loaded = <String?>[];
      await value.initializeRuntime(loaded.add, bundledLibrary: 'compact.dll');
      expect(loaded, ['compact.dll']);
      expect(value.active, WindowsPlayerVariant.compact);
      expect(value.selected, WindowsPlayerVariant.compact);
      expect(value.startupNotice, isNotNull);
      expect(
        jsonDecode(
          await File(p.join(root.path, 'selection.json')).readAsString(),
        )['variant'],
        'compact',
      );
    },
  );

  test(
    'failed full-library load falls back; a pending selection does not affect independent windows',
    () async {
      const url = 'https://example.test/component';
      await installed(url);
      final value = components(url);
      await value.select(WindowsPlayerVariant.full);
      final independent = components(url);
      final loaded = <String?>[];
      await independent.initializeRuntime(
        loaded.add,
        bundledLibrary: 'compact.dll',
        processVariant: WindowsPlayerVariant.compact,
      );
      expect(loaded, ['compact.dll']);
      expect(independent.selected, WindowsPlayerVariant.full);
      final restarted = components(url);
      await restarted.initializeRuntime((path) {
        if (path != 'compact.dll') {
          throw const FormatException('Unsupported library');
        }
      }, bundledLibrary: 'compact.dll');
      expect(restarted.active, WindowsPlayerVariant.compact);
      expect(restarted.startupNotice, isNotNull);
    },
  );

  test(
    'cannot remove or reinstall the DLL currently used by the process',
    () async {
      const url = 'https://example.test/component';
      await installed(url);
      final value = components(url);
      await value.select(WindowsPlayerVariant.full);
      await value.initializeRuntime((_) {}, bundledLibrary: 'compact.dll');
      await value.select(WindowsPlayerVariant.compact);
      expect(value.restartRequired, isTrue);
      await expectLater(value.remove(), throwsA(isA<AppException>()));
      await expectLater(
        value.download(acceleration: direct),
        throwsA(isA<AppException>()),
      );
      expect(
        await File(p.join(root.path, 'test-x64-v1', 'libmpv-2.dll')).exists(),
        isTrue,
      );
      final restarted = components(url);
      await restarted.initializeRuntime((_) {}, bundledLibrary: 'compact.dll');
      await restarted.remove();
      expect(
        await File(p.join(root.path, 'test-x64-v1', 'libmpv-2.dll')).exists(),
        isFalse,
      );
    },
  );

  test('other platforms do not access component storage at startup', () async {
    var reads = 0;
    final value = WindowsPlayerComponents(
      supported: false,
      directory: () async {
        reads++;
        return root;
      },
    );
    String? loaded = 'before';
    await value.initializeRuntime((path) => loaded = path);
    expect(reads, 0);
    expect(loaded, isNull);
    await value.close();
  });

  testWidgets('component entry is available on Windows and hidden on mobile', (
    tester,
  ) async {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: const Scaffold(body: PlayerComponentsTile()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('player-components-settings')),
        platform == TargetPlatform.windows &&
                WindowsPlayerComponents.isSupported
            ? findsOneWidget
            : findsNothing,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'both choices are shown; selecting an installed full library shows restart hint',
    (tester) async {
      const url = 'https://example.test/component';
      final value = components(url);
      await tester.runAsync(() async {
        await installed(url);
        await value.refresh();
      });
      await tester.pumpWidget(
        MaterialApp(home: PlayerComponentsPage(components: value)),
      );
      await tester.pumpAndSettle();
      expect(find.text('精简版 · 默认'), findsOneWidget);
      expect(find.text('完整版 · 已下载'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('player-component-full')));
        for (var i = 0; i < 100 && !value.restartRequired; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(value.selected, WindowsPlayerVariant.full);
      expect(find.byKey(const Key('player-component-restart')), findsOneWidget);
      expect(value.active, WindowsPlayerVariant.compact);
      expect(tester.takeException(), isNull);
    },
  );
}
