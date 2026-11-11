import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/stream_proxy.dart';
import 'support.dart';

class _Io extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = gopeedTestExecutable();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
    'build/windows/x64/runner/Release/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;
  group(
    'Real download and player',
    () {
      late Directory root;
      late AppServices services;
      late HttpServer server;
      late Uint8List bytes;
      late String url;
      late Completer<void> continueDownloads;
      int rejected = 0;
      bool rejectPlayer = false;

      setUpAll(() => MediaKit.ensureInitialized(libmpv: library));
      setUp(() async {
        HttpOverrides.global = _Io();
        root = await Directory.systemTemp.createTemp('wenxi-growing-video-');
        bytes = await File('test/fixtures/player-sample.mkv').readAsBytes();
        continueDownloads = Completer<void>();
        rejected = 0;
        rejectPlayer = false;
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          try {
            if (request.headers.value('Cookie') !=
                'download-fixture=local-only') {
              rejected++;
              request.response.statusCode = 403;
              return;
            }
            if (rejectPlayer &&
                request.headers.value('X-Fixture-Reader') == 'player') {
              rejected++;
              request.response.statusCode = 403;
              return;
            }
            final match = RegExp(
              r'^bytes=(\d+)-(\d+)$',
            ).firstMatch(request.headers.value('Range') ?? '');
            final start = match == null ? 0 : int.parse(match[1]!);
            final end = match == null
                ? bytes.length - 1
                : math.min(bytes.length - 1, int.parse(match[2]!));
            if (start > end) {
              request.response.statusCode = 416;
              return;
            }
            request.response.bufferOutput = false;
            request.response.headers.set('ETag', '"local-video"');
            request.response.headers.set('Content-Type', 'video/x-matroska');
            request.response.contentLength = end - start + 1;
            if (match != null) {
              request.response.statusCode = 206;
              request.response.headers.set(
                'Content-Range',
                'bytes $start-$end/${bytes.length}',
              );
            }
            final split = math.min(end + 1, start + 32 * 1024);
            request.response.add(Uint8List.sublistView(bytes, start, split));
            await request.response.flush();
            // Both Gopeed and the player send If-Range. Only hold the original
            // download; playback must remain free to fetch missing ranges.
            if (split <= end &&
                request.headers.value('If-Range') != null &&
                request.headers.value('X-Fixture-Reader') != 'player') {
              await continueDownloads.future;
            }
            if (split <= end) {
              request.response.add(
                Uint8List.sublistView(bytes, split, end + 1),
              );
            }
          } catch (_) {
            // Cancellation is expected when probes and players close.
          } finally {
            try {
              await request.response.close();
            } catch (_) {}
          }
        });
        url = 'http://127.0.0.1:${server.port}/fixture.mkv';
        final transport = DesktopGopeedTransport(executable: executable);
        services = AppServices(
          controlEnabled: false,
          store: StateStore.memory({
            'settings': {'threads': 4, 'concurrent': 1, 'retries': 1},
          }),
          dataDirectory: root,
          cacheDirectory: Directory('${root.path}/cache'),
          transport: transport,
          files: PlatformFileAccess(transport, Directory('${root.path}/saved')),
          http: FakeHttp(),
          platformFeatures: false,
        );
        await services.downloads.initialize();
      });
      tearDown(() async {
        if (!continueDownloads.isCompleted) continueDownloads.complete();
        await services.close();
        await server.close(force: true);
        await root.delete(recursive: true);
        HttpOverrides.global = null;
      });

      for (final cachedOnly in [false, true]) {
        test(
          cachedOnly
              ? 'Real player starts and seeks from cache while playback URL returns 403'
              : 'Starts before completion, seeks, reuses cache and saves exact original bytes',
          () async {
            await services.downloads.enqueue(
              DownloadSpec(
                url: url,
                fileName: 'fixture.mkv',
                expectedSize: bytes.length,
                headers: const {'Cookie': 'download-fixture=local-only'},
                checksumType: 'sha256',
                checksumValue: sha256.convert(bytes).toString(),
              ),
            );
            final id = services.downloads.tasks.single.id;
            final cache = await services.downloads.acquirePlayback(id);
            await until(() => services.downloads.task(id)!.downloaded > 0);
            expect(services.downloads.task(id)!.status, DownloadStatus.running);
            expect(
              services.downloads.task(id)!.downloaded,
              lessThan(bytes.length),
            );
            const identity = RemoteIdentity(0, '"local-video"', null);
            final reference = RemoteIdentity(bytes.length, identity.etag, null);
            final prefix = await cache.read(0, 16383, reference);
            expect(prefix, bytes.sublist(0, 16384));
            final proxy = PlaybackStreamProxy(
              cache.source,
              connections: 2,
              chunkBytes: 16384,
              maxCacheBytes: 65536,
              readCache: cache.read,
            );
            final client = HttpClient();
            try {
              expect(await proxy.start(), isTrue);
              final request = await client.getUrl(proxy.uri);
              request.headers.set('Range', 'bytes=0-16383');
              final response = await request.close();
              final data = await response.fold<List<int>>(
                [],
                (all, next) => all..addAll(next),
              );
              expect(data, prefix);
              expect(
                proxy.diagnosticFields['reusedDownloadBytes'],
                greaterThan(0),
              );
            } finally {
              client.close(force: true);
              await proxy.close();
            }

            final player = Player(
              configuration: const PlayerConfiguration(
                title: 'Download playback test',
              ),
            );
            await (player.platform as NativePlayer).setProperty('ao', 'null');
            final backend = MediaKitBackend(
              video: false,
              player: player,
              downloadCache: (_, start, end, identity) =>
                  cache.readAvailable(start, end, identity),
              downloadSnapshot: (_) => cache.snapshot(),
            );
            try {
              rejectPlayer = cachedOnly;
              if (cachedOnly) {
                // Complete via the original downloader before requesting the
                // footer. The playback lease keeps the native payload readable.
                Timer(const Duration(milliseconds: 500), () {
                  if (!continueDownloads.isCompleted) {
                    continueDownloads.complete();
                  }
                });
              }
              await backend.open(
                DownloadSpec.fromJson({
                  ...cache.source.toJson(),
                  'headers': {
                    ...cache.source.headers,
                    'X-Fixture-Reader': 'player',
                  },
                }),
                Duration.zero,
              );
              await until(
                () => backend.state.duration >= const Duration(seconds: 8),
              );
              expect(backend.diagnosticFields['transport'], 'segmented');
              expect(
                (backend.diagnosticFields['proxy'] as Map)['probeResult'],
                'download_cache',
              );
              await backend.play();
              await until(
                () =>
                    backend.state.position > const Duration(milliseconds: 500),
              );
              if (!cachedOnly) {
                expect(
                  services.downloads.task(id)!.status,
                  DownloadStatus.running,
                );
              }
              await backend.seek(const Duration(seconds: 5));
              await until(
                () => backend.state.position >= const Duration(seconds: 5),
              );
              if (!continueDownloads.isCompleted) continueDownloads.complete();
              await until(
                () =>
                    services.downloads.task(id)!.status ==
                        DownloadStatus.completed &&
                    services.downloads.activeCount == 0,
              );
              final saved = File(services.downloads.task(id)!.savedPath!);
              expect(
                sha256.convert(await saved.readAsBytes()),
                sha256.convert(bytes),
              );
              expect(backend.failure, isNull);
              if (!cachedOnly) expect(rejected, 0);
            } finally {
              await backend.close();
              await cache.release();
            }
          },
        );
      }
    },
    skip:
        !Platform.isWindows ||
        !File(executable).existsSync() ||
        library == null,
  );
}
