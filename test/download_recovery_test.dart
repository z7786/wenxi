// Regressions for transient recovery, cancellable resolve and export reservations.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/download/space_budget.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/platform/file_access.dart';
import 'support.dart';

final work = Directory(
  p.join(Directory.systemTemp.path, 'asterlink-download-regressions'),
);

class _TransientAdapter implements HttpClientAdapter {
  _TransientAdapter({this.probeFailure = false, this.error});
  final bool probeFailure;
  final Object? error;
  int attempts = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    if (!probeFailure && options.path.endsWith('.m3u8')) {
      return ResponseBody.fromString(
        '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n',
        200,
        headers: {
          'content-type': ['application/vnd.apple.mpegurl'],
        },
      );
    }
    attempts++;
    if (attempts == 1) {
      if (error != null) {
        throw DioException(requestOptions: options, error: error);
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'synthetic temporary network reset',
      );
    }
    return ResponseBody.fromBytes([1, 2, 3, 4], 200);
  }

  @override
  void close({bool force = false}) {}
}

class _PlaylistHttp extends TransferHttp {
  _PlaylistHttp(Dio client) : super(client: client);
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(0, null, null), true);
}

class _LocalIo extends HttpOverrides {}

class _DelayedFiles extends FakeFiles {
  _DelayedFiles(super.directory);
  final entered = Completer<void>(), release = Completer<void>();
  bool first = true;
  String? saving;
  @override
  Future<void> cancelExport(String id) async {
    if (id == saving && !release.isCompleted) release.complete();
  }

  @override
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int, int)? onProgress,
  }) async {
    if (first) {
      first = false;
      saving = id;
      entered.complete();
      await release.future;
      checkpoint();
    }
    return super.save(
      id: id,
      source: source,
      name: name,
      relativePath: relativePath,
      destination: destination,
      checkpoint: checkpoint,
      onProgress: onProgress,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StateStore store;
  late FakeFiles files;
  DownloadManager? manager;
  GopeedEngine? engine;
  setUp(() async {
    root = await Directory(p.join(work.path, 'dart-probe-data'))
        .create(recursive: true)
        .then((directory) => directory.createTemp('case-'));
    store = StateStore.memory({
      'settings': {'retries': 3, 'downloadRetryPolicy': 1},
    });
    files = FakeFiles(Directory(p.join(root.path, 'saved')));
  });
  tearDown(() async {
    if (manager != null) {
      await manager!.close();
      manager!.dispose();
    } else {
      await engine?.close();
    }
    manager = null;
    engine = null;
    HttpOverrides.global = null;
    expect(p.isWithin(work.path, root.path), isTrue);
    await root.delete(recursive: true);
  });

  GopeedEngine makeEngine(NativeTransport native) => engine = GopeedEngine(
    native,
    store,
    Vault(store),
    Directory(p.join(root.path, 'native')),
    Directory(p.join(root.path, 'cache')),
  );
  DownloadManager makeManager(
    TransferHttp http,
    NativeTransport native, {
    Future<DownloadSpec> Function(DownloadSpec)? refresh,
  }) => manager = DownloadManager(
    store: store,
    engine: makeEngine(native),
    files: files,
    cleanups: CleanupOutbox(store, FakeHttp()),
    http: http,
    refreshSource:
        refresh ??
        (_) async => throw const AppException('unexpected source refresh'),
  );

  test('Cache and destination are budgeted on their own volumes', () async {
    const mib = 1024 * 1024;
    final available = {'cache': 700 * mib, 'target': 500 * mib};
    const plan = StoragePlan(
      StorageVolume('cache', 'cache'),
      StorageVolume('target', 'target'),
    );
    final budget = SpaceBudget(
      () async => available['cache']!,
      availableOnVolume: (id) async => available[id]!,
    );
    await expectLater(
      budget.reserveVolumes('file', plan.requirements(600 * mib, 0)),
      throwsA(isA<DownloadSpaceException>()),
    );
    available['target'] = 2000 * mib;
    await budget.reserveVolumes('file', plan.requirements(600 * mib, 0));
  });

  test(
    'A save does not hold the only network slot, and a queued save can be paused',
    () async {
      await store.put('settings', {'concurrent': 1});
      final delayed = _DelayedFiles(Directory(p.join(root.path, 'saved')));
      files = delayed;
      final native = FakeNative();
      final adapter = _TransientAdapter(probeFailure: true)..attempts = 1;
      final queue = makeManager(
        TransferHttp(
          client: Dio(BaseOptions(validateStatus: (_) => true))
            ..httpClientAdapter = adapter,
        ),
        native,
      );
      await queue.initialize();
      final first = await queue.enqueue(
        const DownloadSpec(
          url: 'https://fixture.invalid/a.bin',
          fileName: 'a.bin',
        ),
      );
      await delayed.entered.future.timeout(const Duration(seconds: 5));
      final second = await queue.enqueue(
        const DownloadSpec(
          url: 'https://fixture.invalid/b.bin',
          fileName: 'b.bin',
        ),
      );
      await until(
        () =>
            native.begins.length == 2 &&
            queue.task(second)?.phase == '等待校验 / 保存',
      );
      expect(delayed.savedCount, 0);
      await queue.pause(second).timeout(const Duration(seconds: 1));
      expect(queue.task(second)!.status, DownloadStatus.paused);
      expect(delayed.release.isCompleted, isFalse);
      if (!delayed.release.isCompleted) delayed.release.complete();
      await until(() => queue.task(first)!.status == DownloadStatus.completed);
      expect(delayed.savedCount, 1);
    },
  );

  test(
    'HLS retries a transient pre-header failure and saves the complete file',
    () async {
      final adapter = _TransientAdapter();
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter;
      final current = makeManager(_PlaylistHttp(dio), FakeNative());
      await current.initialize();
      final id = await current.enqueue(
        const DownloadSpec(
          url: 'https://fixture.invalid/video.m3u8',
          fileName: 'video.ts',
        ),
      );
      await until(
        () =>
            current.task(id)?.status == DownloadStatus.completed &&
            current.activeCount == 0,
      );
      expect(current.task(id)!.retries, 3);
      expect(adapter.attempts, 2);
      expect(files.savedCount, 1);
      debugPrint(
        'REGRESSION hlsConfiguredRetries=3 actualAttempts=${adapter.attempts} finalStatus=${current.task(id)!.status.name}',
      );
      dio.close(force: true);
    },
  );

  test('Initial HTTP probe recovers before starting native download', () async {
    final adapter = _TransientAdapter(probeFailure: true);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    final native = FakeNative();
    final current = makeManager(TransferHttp(client: dio), native);
    await current.initialize();
    final id = await current.enqueue(
      const DownloadSpec(
        url: 'https://fixture.invalid/file.bin',
        fileName: 'file.bin',
      ),
    );
    await until(
      () =>
          current.task(id)?.status == DownloadStatus.completed &&
          current.activeCount == 0,
    );
    expect(adapter.attempts, 2);
    expect(native.begins, hasLength(1));
    debugPrint(
      'REGRESSION initialProbeConfiguredRetries=3 actualAttempts=${adapter.attempts} nativeStarts=${native.begins.length}',
    );
    dio.close(force: true);
  });

  for (final (interruptedPath, retries, failures) in [
    ('/video.m3u8', 1, 1),
    ('/second.ts', 1, 1),
    ('/second.ts', 0, 1),
    ('/second.ts', 2, 3),
  ]) {
    test('HLS truncated body at $interruptedPath: retries=$retries', () async {
      await store.put('settings', {
        'retries': retries,
        'downloadRetryPolicy': 1,
      });
      HttpOverrides.global = _LocalIo();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String, int>{};
      server.listen((request) async {
        final path = request.uri.path;
        final count = requests.update(path, (n) => n + 1, ifAbsent: () => 1);
        final bytes = path == '/video.m3u8'
            ? '#EXTM3U\n#EXTINF:1,\nfirst.ts\n#EXTINF:1,\nsecond.ts\n#EXT-X-ENDLIST\n'
                  .codeUnits
            : path == '/first.ts'
            ? [1, 2, 3]
            : [4, 5, 6, 7];
        if (path == interruptedPath && count <= failures) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: ${bytes.length}\r\n\r\n',
          );
          socket.add(bytes.sublist(0, bytes.length ~/ 2));
          await socket.flush();
          socket.destroy();
        } else {
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        }
      });
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      final current = makeManager(_PlaylistHttp(dio), FakeNative());
      addTearDown(() async {
        dio.close(force: true);
        await server.close(force: true);
      });
      await current.initialize();
      final id = await current.enqueue(
        DownloadSpec(
          url: 'http://127.0.0.1:${server.port}/video.m3u8',
          fileName: 'video.ts',
        ),
      );
      await until(() => !current.task(id)!.active && current.activeCount == 0);
      if (failures > retries) {
        final failed = current.task(id)!;
        expect(failed.status, DownloadStatus.failed);
        expect(requests[interruptedPath], retries + 1);
        expect(files.savedCount, 0);
        expect(failed.hls.integer('index'), 1);
        expect(failed.hls.integer('bytes'), 3);
        await current.resume(id);
        await until(
          () => !current.task(id)!.active && current.activeCount == 0,
        );
      }
      final task = current.task(id)!;
      expect(task.status, DownloadStatus.completed, reason: task.error);
      expect(requests[interruptedPath], failures + 1);
      expect(requests['/first.ts'], 1);
      expect(await File(task.savedPath!).readAsBytes(), [1, 2, 3, 4, 5, 6, 7]);
    });
  }

  test('Pausing HLS during a retry cancels the pending request', () async {
    final adapter = _TransientAdapter();
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    final current = makeManager(_PlaylistHttp(dio), FakeNative());
    addTearDown(() => dio.close(force: true));
    await current.initialize();
    final id = await current.enqueue(
      const DownloadSpec(
        url: 'https://fixture.invalid/video.m3u8',
        fileName: 'video.ts',
      ),
    );
    await until(() => current.task(id)!.phase.contains('秒后重试'));
    await current.pause(id).timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(current.task(id)!.status, DownloadStatus.paused);
    expect(adapter.attempts, 1);
    expect(files.savedCount, 0);
  });

  for (final (interrupted, retries) in [(true, 1), (true, 0), (false, 1)]) {
    test(
      'Download TLS recovery: interrupted=$interrupted retries=$retries',
      () async {
        await store.put('settings', {'retries': retries});
        final adapter = _TransientAdapter(
          probeFailure: true,
          error: interrupted
              ? const HandshakeException(
                  'Connection terminated during handshake',
                )
              : const HandshakeException(
                  'Handshake error in client',
                  OSError('CERTIFICATE_VERIFY_FAILED'),
                ),
        );
        final dio = Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        final native = FakeNative();
        final current = makeManager(TransferHttp(client: dio), native);
        await current.initialize();
        final id = await current.enqueue(
          const DownloadSpec(
            url: 'https://fixture.invalid/file.bin',
            fileName: 'file.bin',
          ),
        );
        await until(
          () => !current.task(id)!.active && current.activeCount == 0,
        );
        final recovered = interrupted && retries > 0;
        expect(
          current.task(id)!.status,
          recovered ? DownloadStatus.completed : DownloadStatus.failed,
        );
        expect(adapter.attempts, recovered ? 2 : 1);
        expect(native.begins.length, recovered ? 1 : 0);
        if (recovered) {
          expect(await File(current.task(id)!.savedPath!).readAsBytes(), [
            1,
            2,
            3,
            4,
          ]);
        }
      },
    );
  }

  test(
    'native resolve 403 correctly triggers two bounded source refreshes',
    () async {
      HttpOverrides.global = _LocalIo();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0, refreshes = 0;
      server.listen((request) async {
        requests++;
        if (requests == 1) {
          request.response.statusCode = 206;
          request.response.headers.set('Content-Range', 'bytes 0-0/4');
          request.response.headers.set('ETag', '"same-local-file"');
          request.response.contentLength = 1;
          request.response.add([1]);
        } else {
          request.response.statusCode = 403;
          request.response.contentLength = 0;
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
      final dio = Dio(BaseOptions(validateStatus: (_) => true));
      final native = DesktopGopeedTransport(
        executable: File('native/bin/asterlink_gopeed.exe').absolute.path,
      );
      final current = makeManager(
        TransferHttp(client: dio),
        native,
        refresh: (previous) async {
          refreshes++;
          return previous;
        },
      );
      try {
        await current.initialize();
        final id = await current.enqueue(
          DownloadSpec(
            url: 'http://127.0.0.1:${server.port}/file.bin',
            fileName: 'file.bin',
            source: const {'platform': 'quark'},
          ),
        );
        await until(
          () =>
              current.task(id)?.status == DownloadStatus.failed &&
              current.activeCount == 0,
        );
        expect(requests, 4);
        expect(refreshes, 2);
        debugPrint(
          'REGRESSION probeThenNative403 httpRequests=$requests sourceRefreshes=$refreshes finalStatus=${current.task(id)!.status.name}',
        );
      } finally {
        dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'Pausing native resolve cancels the probe without waiting for response headers',
    () async {
      HttpOverrides.global = _LocalIo();
      final entered = Completer<void>(), release = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/slow') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        final range = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(request.headers.value('range') ?? '');
        final first = range == null ? 0 : int.parse(range[1]!);
        final last = range == null ? 3 : int.parse(range[2]!);
        request.response.statusCode = 206;
        request.response.headers.set('Content-Range', 'bytes $first-$last/4');
        request.response.contentLength = last - first + 1;
        request.response.add([1, 2, 3, 4].sublist(first, last + 1));
        try {
          await request.response.close();
        } catch (_) {}
      });
      final native = DesktopGopeedTransport(
        executable: File('native/bin/asterlink_gopeed.exe').absolute.path,
      );
      final current = makeEngine(native);
      Future<void> begin(String id) => current.begin({
        'id': id,
        'url': 'http://127.0.0.1:${server.port}/$id',
        'headers': <String, String>{},
        'connections': 1,
        'retries': 3,
        'speedLimit': 0,
      });
      try {
        await begin('first');
        for (var i = 0; i < 100; i++) {
          if ((await current.snapshot('first')).str('status') == 'done') break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect((await current.snapshot('first')).str('status'), 'done');
        await begin('slow');
        await entered.future.timeout(const Duration(seconds: 5));
        var pauseSlowFinished = false,
            snapshotFinished = false,
            pauseFirstFinished = false;
        final slowPause = current
            .pause('slow')
            .then((_) => pauseSlowFinished = true);
        final firstSnapshot = current
            .snapshot('first')
            .then((_) => snapshotFinished = true);
        final firstPause = current
            .pause('first')
            .then((_) => pauseFirstFinished = true);
        try {
          await Future.wait([
            slowPause,
            firstSnapshot,
            firstPause,
          ]).timeout(const Duration(seconds: 3));
          expect(release.isCompleted, isFalse);
          expect(pauseSlowFinished, isTrue);
          expect(snapshotFinished, isTrue);
          expect(pauseFirstFinished, isTrue);
          debugPrint(
            'REGRESSION realHelperPauseDuringResolve beforeResponseHeaders=true otherSnapshotBlocked=false otherPauseBlocked=false',
          );
        } finally {
          release.complete();
          await slowPause;
          await firstSnapshot;
          await firstPause;
        }
      } finally {
        if (!release.isCompleted) release.complete();
        await server.close(force: true);
      }
    },
  );

  test(
    'Export byte progress releases reservation without rejecting another task',
    () async {
      const size = 1024 * 1024, margin = 32 * 1024 * 1024;
      var available = 4 * size + 2 * margin;
      final budget = SpaceBudget(() async => available);
      await budget.reserve('copying', SpaceBudget.required(size, 0));
      await budget.reserve('downloading', SpaceBudget.required(size, 0));
      available -= size; // The first payload has reached its cache file.
      await budget.reserve(
        'copying',
        size,
      ); // Mirrors entry to FileAccess.save.
      available -=
          size ~/ 2; // Half of the exported copy is now on the same disk.
      budget.consume('copying', 'cache', size ~/ 2);
      final actualRemainingWithMargins =
          (size ~/ 2) + (2 * size) + (2 * margin);
      expect(available, actualRemainingWithMargins);
      await budget.reserve('downloading', SpaceBudget.required(size, 0));
      debugPrint(
        'REGRESSION simulatedSameVolumeCopy enoughForRemaining=true nextTaskSpaceCheckRejected=false',
      );
    },
  );
}
