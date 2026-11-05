import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

// Local sockets only. Real I/O is necessary to exercise the packaged helper,
// including pipe framing, native checkpoints and Windows file operations.
class _LocalIo extends HttpOverrides {}

class _Server {
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024, (i) => (i * 37 + i ~/ 101) % 251),
  );
  late HttpServer server;
  bool expireOriginal = false;
  bool blockSecondSegment = false;
  final secondSegment = Completer<void>();
  int firstSegmentRequests = 0;
  final ranges = <(String, int)>[];
  int authorized = 0;
  String url(String path) => 'http://127.0.0.1:${server.port}/$path';
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      unawaited(handle(request));
    });
  }

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.headers.value('Cookie') !=
          'local-fixture-secret=only-tests') {
        response.statusCode = 401;
        return;
      }
      authorized++;
      if (request.uri.path == '/hls.m3u8') {
        response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        response.write(
          '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\n0.ts\n#EXTINF:5,\n1.ts\n#EXT-X-ENDLIST\n',
        );
        return;
      }
      if (request.uri.path == '/0.ts' || request.uri.path == '/1.ts') {
        final first = request.uri.path == '/0.ts';
        if (first) firstSegmentRequests++;
        if (!first && blockSecondSegment) await secondSegment.future;
        response.headers.set('Content-Type', 'video/mp2t');
        response.add(
          first
              ? bytes.sublist(0, bytes.length ~/ 2)
              : bytes.sublist(bytes.length ~/ 2),
        );
        return;
      }
      if (expireOriginal && request.uri.path == '/file') {
        response.statusCode = 403;
        return;
      }
      final empty = request.uri.path == '/empty';
      final total = empty ? 0 : bytes.length;
      final range = request.headers.value('range');
      var first = 0, last = total - 1;
      if (range != null) {
        final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
        if (match == null) {
          response.statusCode = 400;
          return;
        }
        first = int.parse(match.group(1)!);
        last = int.tryParse(match.group(2)!) ?? last;
        if (first >= total || first > last || last >= total) {
          response.statusCode = 416;
          response.headers.set('Content-Range', 'bytes */$total');
          return;
        }
        response.statusCode = 206;
        response.headers.set('Content-Range', 'bytes $first-$last/$total');
        ranges.add((request.uri.path, first));
      }
      response.headers.set('Content-Type', 'application/octet-stream');
      response.headers.set('ETag', '"local-fixture-v1"');
      response.headers.set('Last-Modified', 'Sun, 13 Sep 2026 00:00:00 GMT');
      response.contentLength = last - first + 1;
      if (!empty) response.add(bytes.sublist(first, last + 1));
    } on HttpException {
      // Probe cancellation and paused transfers intentionally close sockets.
    } on SocketException {
      // Probe cancellation and paused transfers intentionally close sockets.
    } finally {
      try {
        await response.close();
      } catch (_) {
        /* A client disconnected. */
      }
    }
  }
}

void main() {
  final executable = gopeedTestExecutable();
  group(
    'Packaged Windows Gopeed integration',
    () {
      late Directory root;
      late StateStore store;
      late _Server server;
      late DesktopGopeedTransport transport;
      late DownloadManager manager;
      late Process process;
      var refreshes = 0;
      var managerDisposed = false;

      Future<void> openManager() async {
        transport = DesktopGopeedTransport(
          executable: executable,
          launchProcess: (file) async {
            process = await Process.start(file, const [], runInShell: false);
            return process;
          },
        );
        final engine = GopeedEngine(
          transport,
          store,
          Vault(store),
          Directory(p.join(root.path, 'native')),
          Directory(p.join(root.path, 'cache')),
        );
        manager = DownloadManager(
          store: store,
          engine: engine,
          files: PlatformFileAccess(
            transport,
            Directory(p.join(root.path, 'saved')),
          ),
          cleanups: CleanupOutbox(store, FakeHttp()),
          http: TransferHttp(),
          refreshSource: (previous) async {
            refreshes++;
            return DownloadSpec.fromJson({
              ...previous.toJson(),
              'url': server.url('fresh'),
            });
          },
        );
        managerDisposed = false;
        await manager.initialize();
      }

      Future<void> closeManager() async {
        if (managerDisposed) return;
        await manager.close();
        manager.dispose();
        managerDisposed = true;
      }

      DownloadSpec spec({bool empty = false}) => DownloadSpec(
        url: server.url(empty ? 'empty' : 'file'),
        fileName: empty ? 'empty.bin' : 'fixture.bin',
        headers: {'Cookie': 'local-fixture-secret=only-tests'},
        expectedSize: empty ? 0 : server.bytes.length,
        checksumType: 'sha256',
        checksumValue: sha256
            .convert(empty ? <int>[] : server.bytes)
            .toString(),
        source: {'localFixture': true},
      );

      Future<DownloadTask> completed(String id) async {
        await until(
          () => !manager.task(id)!.active && manager.activeCount == 0,
          timeout: const Duration(seconds: 30),
        );
        final task = manager.task(id)!;
        expect(task.status, DownloadStatus.completed, reason: task.error);
        return task;
      }

      setUp(() async {
        HttpOverrides.global = _LocalIo();
        root = await Directory.systemTemp.createTemp('aster-native-fixture-');
        store = await StateStore.open(
          Directory(p.join(root.path, 'state')),
          testKey: Uint8List.fromList(List.filled(32, 7)),
        );
        await store.put('settings', {
          'threads': 4,
          'concurrent': 1,
          'retries': 1,
        });
        server = _Server();
        await server.start();
        refreshes = 0;
        await openManager();
      });
      tearDown(() async {
        if (!server.secondSegment.isCompleted) server.secondSegment.complete();
        await closeManager();
        await server.server.close(force: true);
        await root.delete(recursive: true);
        HttpOverrides.global = null;
      });

      test(
        'Downloads and hashes real files, preserves names and deletes only the selected export',
        () async {
          final first = await completed(await manager.enqueue(spec()));
          final second = await completed(await manager.enqueue(spec()));
          expect(await File(first.savedPath!).readAsBytes(), server.bytes);
          expect(await File(second.savedPath!).readAsBytes(), server.bytes);
          expect(p.basename(second.savedPath!), 'fixture (1).bin');
          expect(server.authorized, greaterThan(2));
          expect(server.ranges.any((r) => r.$2 > 0), isTrue);
          await manager.delete(first.id, deleteFile: true);
          expect(await File(first.savedPath!).exists(), isFalse);
          expect(await File(second.savedPath!).exists(), isTrue);
          expect(manager.task(first.id), isNull);
        },
      );

      test(
        'Paused native checkpoints survive process restart and expired URL refresh',
        () async {
          await store.put('settings', {
            'threads': 4,
            'concurrent': 1,
            'speedLimit': 512 * 1024,
          });
          final id = await manager.enqueue(spec());
          await until(
            () => manager.task(id)!.downloaded > 0 || !manager.task(id)!.active,
          );
          await manager.pause(id);
          final paused = manager.task(id)!;
          expect(paused.status, DownloadStatus.paused, reason: paused.error);
          expect(paused.downloaded, inExclusiveRange(0, server.bytes.length));
          await closeManager();
          final checkpoints = Directory(p.join(root.path, 'native'))
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => p.basename(file.path) == 'gopeed.db')
              .toList();
          expect(checkpoints, isNotEmpty);
          for (final file in checkpoints) {
            final raw = utf8.decode(
              await file.readAsBytes(),
              allowMalformed: true,
            );
            expect(raw, contains('asterlink-storage-format'));
            expect(
              raw,
              contains('local-fixture-secret=only-tests'),
              reason: p.basename(file.path),
            );
            expect(
              raw,
              contains(server.url('file')),
              reason: p.basename(file.path),
            );
          }
          final persisted = decodePlainState(await store.file!.readAsBytes());
          final saved = DownloadTask.fromJson(
            persisted
                .list('tasks')
                .map(asJson)
                .singleWhere((task) => task.str('id') == id),
          );
          expect(saved.status, DownloadStatus.paused);
          expect(saved.downloaded, paused.downloaded);
          expect(
            saved.spec.headers['Cookie'],
            'local-fixture-secret=only-tests',
          );
          expect(saved.spec.url, server.url('file'));
          server.expireOriginal = true;
          server.ranges.clear();
          await openManager();
          expect(manager.task(id)!.downloaded, paused.downloaded);
          await manager.resume(id);
          final task = await completed(id);
          expect(refreshes, 1);
          expect(
            server.ranges.any((r) => r.$1 == '/fresh' && r.$2 > 0),
            isTrue,
          );
          expect(await File(task.savedPath!).readAsBytes(), server.bytes);
        },
      );

      test(
        'Concurrent pipe requests and unexpected helper exit recover on retry',
        () async {
          final versions = await Future.wait(
            List.generate(24, (_) => transport.call('version')),
          );
          expect(
            versions.every((v) => asJson(v).str('version') == '1.8.1'),
            isTrue,
          );
          await store.put('settings', {
            'threads': 2,
            'concurrent': 1,
            'speedLimit': 512 * 1024,
          });
          final id = await manager.enqueue(spec());
          await until(
            () => manager.task(id)!.downloaded > 0 || !manager.task(id)!.active,
          );
          expect(
            manager.task(id)!.status,
            DownloadStatus.running,
            reason: manager.task(id)!.error,
          );
          final oldPid = process.pid;
          expect(process.kill(), isTrue);
          await process.exitCode;
          await until(
            () =>
                manager.task(id)!.status == DownloadStatus.failed &&
                manager.activeCount == 0,
          );
          await manager.resume(id);
          final task = await completed(id);
          expect(process.pid, isNot(oldPid));
          expect(await File(task.savedPath!).readAsBytes(), server.bytes);
        },
      );

      test(
        'HLS pause preserves segment boundaries without downloading them again',
        () async {
          server.blockSecondSegment = true;
          final id = await manager.enqueue(
            DownloadSpec.fromJson({
              ...spec().toJson(),
              'url': server.url('hls.m3u8'),
              'fileName': 'video.m3u8',
            }),
          );
          await until(
            () =>
                manager.task(id)!.hls.integer('index') == 1 ||
                !manager.task(id)!.active,
          );
          await manager.pause(id);
          expect(
            manager.task(id)!.status,
            DownloadStatus.paused,
            reason: manager.task(id)!.error,
          );
          expect(manager.task(id)!.hls.integer('index'), 1);
          server.blockSecondSegment = false;
          server.secondSegment.complete();
          await manager.resume(id);
          final task = await completed(id);
          expect(server.firstSegmentRequests, 1);
          expect(p.extension(task.savedPath!), '.ts');
          expect(await File(task.savedPath!).readAsBytes(), server.bytes);
        },
      );

      test(
        'Range probes and native transfer accept a valid empty file',
        () async {
          final task = await completed(
            await manager.enqueue(spec(empty: true)),
          );
          expect(task.total, 0);
          expect(await File(task.savedPath!).length(), 0);
        },
      );
    },
    skip: !Platform.isWindows || !File(executable).existsSync()
        ? 'Build the Windows Gopeed helper with tool/build-native-windows.ps1 first.'
        : false,
  );
}
