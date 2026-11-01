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

class _LocalIo extends HttpOverrides {}

class _SpaceTracingTransport extends DesktopGopeedTransport {
  _SpaceTracingTransport({required super.executable});
  final spaceChecks = <String>[];
  String? fullVolume;
  int? availableBytes;

  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'freeSpace') {
      final path = args.str('path');
      spaceChecks.add(path);
      if (p.rootPrefix(path).toLowerCase() == fullVolume) {
        return {'bytes': 0};
      }
      if (availableBytes != null) return {'bytes': availableBytes};
    }
    return super.call(method, args);
  }
}

// Reproduce a pre-upgrade task: its payload uses the app's private cache.
class _LegacyFiles extends PlatformFileAccess {
  _LegacyFiles(super.transport, super.defaultDirectory);
  @override
  Future<String?> downloadCacheRoot(String? destination) async => null;
}

void main() {
  final executable = gopeedTestExecutable();
  group(
    'real destination I/O',
    () {
      late Directory systemRoot, selectedRoot, cache, defaults;
      late HttpServer server;
      late StateStore store;
      late DownloadManager manager;
      late _SpaceTracingTransport transport;
      var closed = true;
      final key = Uint8List.fromList(List.filled(32, 5));
      final content = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => (i * 17 + i ~/ 79) % 251),
      );
      final ranges = <int>[];
      late Completer<void> secondSegment;
      var holdSecondSegment = false, firstRequests = 0;

      String url(String path) => 'http://127.0.0.1:${server.port}/$path';

      Future<void> handle(HttpRequest request) async {
        final response = request.response;
        try {
          if (request.uri.path == '/video.m3u8') {
            response.headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            );
            response.write(
              '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\n0.ts\n#EXTINF:5,\n1.ts\n#EXT-X-ENDLIST\n',
            );
            return;
          }
          if (request.uri.path.endsWith('.ts')) {
            final first = request.uri.path == '/0.ts';
            if (first) firstRequests++;
            if (!first && holdSecondSegment) await secondSegment.future;
            response.headers.contentType = ContentType('video', 'mp2t');
            response.add(
              first
                  ? content.sublist(0, content.length ~/ 2)
                  : content.sublist(content.length ~/ 2),
            );
            return;
          }
          var begin = 0, end = content.length - 1;
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range != null) {
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
            begin = int.parse(match.group(1)!);
            end = int.tryParse(match.group(2)!) ?? end;
            response.statusCode = 206;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $begin-$end/${content.length}',
            );
            ranges.add(begin);
          }
          response.headers.set(HttpHeaders.etagHeader, '"destination-fixture"');
          response.contentLength = end - begin + 1;
          response.add(content.sublist(begin, end + 1));
        } on HttpException {
          // A paused downloader closes its local socket.
        } on SocketException {
          // A probe consumes only the bytes it requested.
        } finally {
          try {
            await response.close();
          } catch (_) {}
        }
      }

      Future<void> open({bool legacy = false}) async {
        store = await StateStore.open(
          Directory(p.join(systemRoot.path, 'state')),
          testKey: key,
        );
        transport = _SpaceTracingTransport(executable: executable);
        manager = DownloadManager(
          store: store,
          engine: GopeedEngine(
            transport,
            store,
            Vault(store),
            Directory(p.join(systemRoot.path, 'native')),
            cache,
          ),
          files: legacy
              ? _LegacyFiles(transport, defaults)
              : PlatformFileAccess(transport, defaults),
          cleanups: CleanupOutbox(store, FakeHttp()),
          http: TransferHttp(),
          refreshSource: (spec) async => spec,
        );
        await manager.initialize();
        closed = false;
      }

      Future<void> close() async {
        if (closed) return;
        await manager.close();
        manager.dispose();
        closed = true;
      }

      DownloadSpec spec() => DownloadSpec(
        url: url('file'),
        fileName: '跨盘验证.bin',
        expectedSize: content.length,
        checksumType: 'sha256',
        checksumValue: sha256.convert(content).toString(),
      );

      void exhaustCacheVolume() {
        final cacheVolume = p.rootPrefix(cache.path).toLowerCase();
        if (cacheVolume != p.rootPrefix(selectedRoot.path).toLowerCase()) {
          transport.fullVolume = cacheVolume;
        }
      }

      void expectSelectedSpaceChecks() {
        expect(transport.spaceChecks, isNotEmpty);
        for (final path in transport.spaceChecks) {
          expect(
            p.rootPrefix(path).toLowerCase(),
            p.rootPrefix(selectedRoot.path).toLowerCase(),
          );
        }
      }

      Future<void> partial(String id) async {
        await until(
          () => manager.task(id)!.downloaded > 0 || !manager.task(id)!.active,
        );
        expect(
          manager.task(id)!.status,
          DownloadStatus.running,
          reason: manager.task(id)!.error,
        );
        expect(
          manager.task(id)!.downloaded,
          inExclusiveRange(0, content.length),
        );
      }

      Future<void> finish(String id) async {
        await until(
          () => !manager.task(id)!.active && manager.activeCount == 0,
          timeout: const Duration(seconds: 30),
        );
        final task = manager.task(id)!;
        expect(task.status, DownloadStatus.completed, reason: task.error);
        expect(p.isWithin(selectedRoot.path, task.savedPath!), isTrue);
        expect(
          sha256.convert(await File(task.savedPath!).readAsBytes()),
          sha256.convert(content),
        );
      }

      setUp(() async {
        HttpOverrides.global = _LocalIo();
        systemRoot = await Directory.systemTemp.createTemp(
          'aster-destination-native-',
        );
        final local = await Directory(
          '.local',
        ).absolute.create(recursive: true);
        selectedRoot = await local.createTemp('destination-native-');
        cache = Directory(p.join(systemRoot.path, 'old-cache'));
        defaults = Directory(p.join(systemRoot.path, 'default-downloads'));
        ranges.clear();
        firstRequests = 0;
        holdSecondSegment = false;
        secondSegment = Completer<void>();
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) => unawaited(handle(request)));
        await open();
        await store.put('settings', {
          'threads': 1,
          'concurrent': 1,
          'retries': 0,
          'speedLimit': 512 * 1024,
        });
      });

      tearDown(() async {
        if (!secondSegment.isCompleted) secondSegment.complete();
        await close();
        await server.close(force: true);
        for (final pair in [
          (systemRoot, Directory.systemTemp, 'aster-destination-native-'),
          (selectedRoot, Directory('.local').absolute, 'destination-native-'),
        ]) {
          final path = await pair.$1.resolveSymbolicLinks();
          require(
            p.isWithin(await pair.$2.resolveSymbolicLinks(), path) &&
                p.basename(path).startsWith(pair.$3),
            'unexpected test cleanup path',
          );
          await pair.$1.delete(recursive: true);
        }
        HttpOverrides.global = null;
      });

      test(
        'one payload fits when there is not enough room for a second copy',
        () async {
          await manager.changeDestination(selectedRoot.path);
          transport.availableBytes = 32 * 1024 * 1024 + content.length * 3 ~/ 2;
          final id = await manager.enqueue(spec());
          await finish(id);
          expectSelectedSpaceChecks();
          expect(
            await File(
              p.join(manager.engine.taskDirectory(id).path, 'payload.gopeed'),
            ).exists(),
            isFalse,
          );
        },
      );

      test(
        'new task resumes on the chosen volume after a complete process restart',
        () async {
          exhaustCacheVolume();
          await manager.changeDestination(selectedRoot.path);
          final id = await manager.enqueue(spec());
          await partial(id);
          await manager.pause(id);
          final savedProgress = manager.task(id)!.downloaded;
          final payload = File(
            p.join(manager.engine.taskDirectory(id).path, 'payload.gopeed'),
          );
          expect(p.isWithin(selectedRoot.path, payload.path), isTrue);
          expect(await Directory(p.join(cache.path, id)).exists(), isFalse);
          await close();
          await open();
          exhaustCacheVolume();
          expect(manager.task(id)!.downloaded, savedProgress);
          expect(manager.engine.taskDirectory(id).path, payload.parent.path);
          ranges.clear();
          await manager.resume(id);
          await finish(id);
          expectSelectedSpaceChecks();
          expect(ranges.any((start) => start > 0), isTrue);
          expect(await payload.exists(), isFalse);
          stdout.writeln(
            'DESTINATION_NATIVE ${jsonEncode({'case': 'newTask', 'cacheDrive': p.rootPrefix(payload.path), 'savedDrive': p.rootPrefix(manager.task(id)!.savedPath!), 'resumedAfterRestart': true, 'sha256Verified': true})}',
          );
        },
      );

      test(
        'an empty legacy task uses the chosen volume before capacity checks',
        () async {
          await close();
          const id = 'empty-legacy';
          await store.put('tasks', [
            DownloadTask(
              id: id,
              spec: spec(),
              createdAt: 1,
              status: DownloadStatus.paused,
              destination: selectedRoot.path,
            ).toJson(),
          ]);
          await open();
          exhaustCacheVolume();
          await manager.resume(id);
          await finish(id);
          expectSelectedSpaceChecks();
          expect(
            p.isWithin(
              selectedRoot.path,
              manager.engine.taskCacheRoot(id).path,
            ),
            isTrue,
          );
        },
      );

      test(
        'a complete legacy cache exports without free space on its old volume',
        () async {
          await close();
          const id = 'ready-legacy';
          final payload = File(p.join(cache.path, id, 'payload.gopeed'));
          await payload.parent.create(recursive: true);
          await payload.writeAsBytes(content);
          await store.put('tasks', [
            DownloadTask(
              id: id,
              spec: spec(),
              createdAt: 1,
              status: DownloadStatus.paused,
              destination: selectedRoot.path,
              total: content.length,
              downloaded: content.length,
              payloadReady: true,
            ).toJson(),
          ]);
          await open();
          exhaustCacheVolume();
          await manager.resume(id);
          await finish(id);
          expect(await payload.exists(), isFalse);
        },
      );

      test('a full selected volume reports the actual drive', () async {
        await manager.changeDestination(selectedRoot.path);
        transport.fullVolume = p.rootPrefix(selectedRoot.path).toLowerCase();
        final id = await manager.enqueue(spec());
        await until(
          () => !manager.task(id)!.active && manager.activeCount == 0,
        );
        expect(manager.task(id)!.status, DownloadStatus.failed);
        expectSelectedSpaceChecks();
        final disk = p
            .rootPrefix(selectedRoot.path)
            .replaceFirst(RegExp(r'[\\/]+$'), '');
        expect(manager.task(id)!.error, contains('下载目录所在磁盘（$disk）空间不足'));
        expect(manager.task(id)!.downloaded, 0);
      });

      test(
        'legacy partial data stays intact while its final destination changes',
        () async {
          await close();
          await open(legacy: true);
          final id = await manager.enqueue(spec());
          await partial(id);
          await manager.pause(id);
          final progress = manager.task(id)!.downloaded;
          final payload = File(p.join(cache.path, id, 'payload.gopeed'));
          expect(await payload.exists(), isTrue);
          await close();
          await open();
          await manager.changeDestination(
            selectedRoot.path,
            includeUnfinished: true,
          );
          expect(manager.engine.taskCacheRoot(id).path, cache.path);
          expect(manager.task(id)!.downloaded, progress);
          ranges.clear();
          await manager.resume(id);
          await finish(id);
          expect(ranges.any((start) => start > 0), isTrue);
          expect(await payload.exists(), isFalse);
          stdout.writeln(
            'DESTINATION_NATIVE ${jsonEncode({'case': 'legacyTask', 'cacheDrive': p.rootPrefix(payload.path), 'savedDrive': p.rootPrefix(manager.task(id)!.savedPath!), 'retainedPartialData': true, 'sha256Verified': true})}',
          );
        },
      );

      test('HLS caches and resumes segments in the chosen directory', () async {
        holdSecondSegment = true;
        await manager.changeDestination(selectedRoot.path);
        final id = await manager.enqueue(
          DownloadSpec.fromJson({
            ...spec().toJson(),
            'url': url('video.m3u8'),
            'fileName': 'video.m3u8',
          }),
        );
        await until(
          () =>
              manager.task(id)!.hls.integer('index') == 1 ||
              !manager.task(id)!.active,
        );
        await manager.pause(id);
        final payload = File(
          p.join(manager.engine.taskDirectory(id).path, 'payload.hls'),
        );
        expect(p.isWithin(selectedRoot.path, payload.path), isTrue);
        expect(await payload.length(), content.length ~/ 2);
        await close();
        await open();
        holdSecondSegment = false;
        secondSegment.complete();
        await manager.resume(id);
        await finish(id);
        expect(firstRequests, 1);
        expect(await payload.exists(), isFalse);
      });
    },
    skip: !Platform.isWindows || !File(executable).existsSync()
        ? 'Build the Windows Gopeed helper first.'
        : false,
  );
}
