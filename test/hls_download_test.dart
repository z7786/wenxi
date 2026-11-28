import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/hls.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _LocalHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final nested in [false, true]) {
    test(
      'HLS downloads relative segments after ${nested ? 'master and media' : 'media'} redirects',
      () async {
        HttpOverrides.global = _LocalHttp();
        final root = await Directory.systemTemp.createTemp('hls-redirect-');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final requests = <String>[];
        server.listen((request) async {
          try {
            final path = request.uri.path;
            requests.add(path);
            if (path == '/entry.m3u8') {
              request.response.statusCode = HttpStatus.found;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                nested ? './dispatch/forward' : '/media/index.m3u8',
              );
            } else if (path == '/dispatch/forward') {
              request.response.statusCode = HttpStatus.found;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '../master/index.m3u8',
              );
            } else if (path == '/master/index.m3u8') {
              request.response.headers.contentType = ContentType(
                'application',
                'vnd.apple.mpegurl',
              );
              request.response.write(
                '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n../variant.m3u8\n',
              );
            } else if (path == '/variant.m3u8') {
              request.response.statusCode = HttpStatus.temporaryRedirect;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '/media/index.m3u8?signature=local-test',
              );
            } else if (path == '/media/index.m3u8') {
              request.response.headers.contentType = ContentType(
                'application',
                'vnd.apple.mpegurl',
              );
              request.response.write(
                '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
                '#EXTINF:4,\npart.ts\n#EXTINF:4,\n../last.ts\n#EXT-X-ENDLIST\n',
              );
            } else if (path == '/media/part.ts') {
              request.response.add([1, 2, 3]);
            } else if (path == '/last.ts') {
              request.response.add([4, 5, 6]);
            } else {
              request.response.statusCode = HttpStatus.notFound;
            }
          } finally {
            await request.response.close();
          }
        });
        final store = StateStore.memory({
          'settings': {'retries': 0},
        });
        final native = FakeNative();
        final http = TransferHttp();
        final manager = DownloadManager(
          store: store,
          engine: GopeedEngine(
            native,
            store,
            Vault(store),
            Directory(p.join(root.path, 'native')),
            Directory(p.join(root.path, 'cache')),
          ),
          files: FakeFiles(Directory(p.join(root.path, 'saved'))),
          cleanups: CleanupOutbox(store, FakeHttp()),
          http: http,
          refreshSource: (_) async => throw StateError('No cloud source'),
        );
        addTearDown(() async {
          await manager.close();
          manager.dispose();
          http.dio.close(force: true);
          await server.close(force: true);
          await root.delete(recursive: true);
          HttpOverrides.global = null;
        });
        await manager.initialize();
        final id = await manager.enqueue(
          DownloadSpec(
            url: 'http://127.0.0.1:${server.port}/entry.m3u8',
            fileName: 'movie.m3u8',
          ),
        );
        await until(
          () => !manager.task(id)!.active && manager.activeCount == 0,
        );
        final task = manager.task(id)!;
        expect(task.status, DownloadStatus.completed, reason: task.error);
        expect(await File(task.savedPath!).readAsBytes(), [1, 2, 3, 4, 5, 6]);
        expect(task.spec.fileName, 'movie.ts');
        expect(requests, containsAll(['/media/part.ts', '/last.ts']));
        expect(requests, isNot(contains('/part.ts')));
        expect(native.begins, isEmpty);
      },
    );
  }

  test(
    'HLS probe recognizes a playlist extension on the final redirect',
    () async {
      HttpOverrides.global = _LocalHttp();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/download') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/asset/list.m3u8',
          );
        } else {
          request.response.headers.contentType = ContentType.binary;
          request.response.write(
            '#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n',
          );
        }
        await request.response.close();
      });
      final http = TransferHttp();
      addTearDown(() async {
        http.dio.close(force: true);
        await server.close(force: true);
        HttpOverrides.global = null;
      });
      final result = await http.probe(
        'http://127.0.0.1:${server.port}/download',
        {},
      );
      expect(result.hls, isTrue);
    },
  );

  test(
    'HLS refuses a separate audio track when AUDIO is the first attribute',
    () {
      expect(
        () => HlsPlaylist.choose(
          'https://example.com/master.m3u8',
          '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"\n'
              '#EXT-X-STREAM-INF:AUDIO="a",BANDWIDTH=1000\nvideo.m3u8\n',
        ),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'HLS variant selection distinguishes BANDWIDTH from AVERAGE-BANDWIDTH',
    () {
      expect(
        HlsPlaylist.choose(
          'https://example.com/master.m3u8',
          '#EXTM3U\n#EXT-X-STREAM-INF:AVERAGE-BANDWIDTH=900,BANDWIDTH=2000\nfirst.m3u8\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=1500\nsecond.m3u8\n',
        ),
        'https://example.com/first.m3u8',
      );
    },
  );

  test(
    'HLS reserves space ahead by step instead of under-reserving small chunks',
    () async {
      HttpOverrides.global = _LocalHttp();
      final root = await Directory.systemTemp.createTemp('hls-reserve-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          if (request.uri.path == '/index.m3u8') {
            request.response.headers.contentType = ContentType(
              'application',
              'vnd.apple.mpegurl',
            );
            request.response.write(
              '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
              '#EXTINF:4,\npart1.ts\n#EXTINF:4,\npart2.ts\n#EXT-X-ENDLIST\n',
            );
          } else {
            request.response.add([1, 2, 3, 4]);
          }
        } finally {
          await request.response.close();
        }
      });
      final store = StateStore.memory({
        'settings': {'retries': 0},
      });
      final files = _MeteredFiles(
        Directory(p.join(root.path, 'saved')),
        // Enough for 32 MiB margin + a few bytes, but below the 16 MiB
        // reserve-ahead window (plus destination copy + margin).
        available: 40 * 1024 * 1024,
      );
      final http = TransferHttp();
      final manager = DownloadManager(
        store: store,
        engine: GopeedEngine(
          FakeNative(),
          store,
          Vault(store),
          Directory(p.join(root.path, 'native')),
          Directory(p.join(root.path, 'cache')),
        ),
        files: files,
        cleanups: CleanupOutbox(store, FakeHttp()),
        http: http,
        refreshSource: (_) async => throw StateError('No cloud source'),
      );
      addTearDown(() async {
        await manager.close();
        manager.dispose();
        http.dio.close(force: true);
        await server.close(force: true);
        await root.delete(recursive: true);
        HttpOverrides.global = null;
      });
      await manager.initialize();
      final id = await manager.enqueue(
        DownloadSpec(
          url: 'http://127.0.0.1:${server.port}/index.m3u8',
          fileName: 'clip.m3u8',
        ),
      );
      await until(
        () => !manager.task(id)!.active && manager.activeCount == 0,
      );
      final task = manager.task(id)!;
      expect(task.status, DownloadStatus.failed);
      expect(task.error, contains('存储空间不足'));
      expect(files.freeBytesCalls, greaterThanOrEqualTo(1));
    },
  );
}

class _MeteredFiles extends FakeFiles {
  _MeteredFiles(super.directory, {required this.available});
  int available;
  int freeBytesCalls = 0;

  @override
  Future<int> freeBytes(String path) async {
    freeBytesCalls++;
    return available;
  }
}
