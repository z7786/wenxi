import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/download/torrent_session.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/playback/playback_runtime.dart';

import 'support.dart';

class _LocalIo extends HttpOverrides {}

List<int> _bencode(Object value) {
  if (value is int) return ascii.encode('i${value}e');
  if (value is String) return _bencode(Uint8List.fromList(utf8.encode(value)));
  if (value is Uint8List) {
    return [...ascii.encode('${value.length}:'), ...value];
  }
  final map = value as Map<String, Object>;
  return [
    100,
    for (final key in map.keys.toList()..sort()) ...[
      ..._bencode(key),
      ..._bencode(map[key]!),
    ],
    101,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = gopeedTestExecutable();

  test(
    'failed player runtime still parses torrent and downloads verified bytes with real Gopeed',
    () async {
      final previousHttp = HttpOverrides.current;
      HttpOverrides.global = _LocalIo();
      final root = await Directory.systemTemp.createTemp(
        'asterlink-player-isolation-',
      );
      HttpServer? server;
      AppServices? app;
      TorrentSession? torrent;
      final store = StateStore.memory({
        'settings': {'threads': 4, 'concurrent': 1, 'retries': 1},
      });
      final bytes = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => (i * 37 + i ~/ 101) % 251),
      );
      try {
        final runtime = PlaybackRuntime(
          initialize: () async => throw TypeError(),
        );
        await expectLater(
          runtime.ensureInitialized(),
          throwsA(isA<PlaybackRuntimeUnavailable>()),
        );
        expect(runtime.ready, isFalse);

        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final response = request.response;
          try {
            final match = RegExp(
              r'^bytes=(\d+)-(\d*)$',
            ).firstMatch(request.headers.value('Range') ?? '');
            final start = match == null ? 0 : int.parse(match[1]!);
            final end = match == null
                ? bytes.length - 1
                : math.min(
                    bytes.length - 1,
                    int.tryParse(match[2]!) ?? bytes.length - 1,
                  );
            if (start > end) {
              response.statusCode = 416;
              return;
            }
            response.headers.set('Content-Type', 'application/octet-stream');
            response.headers.set('ETag', '"isolation-fixture"');
            response.headers.set('Accept-Ranges', 'bytes');
            if (match != null) {
              response.statusCode = 206;
              response.headers.set(
                'Content-Range',
                'bytes $start-$end/${bytes.length}',
              );
            }
            response.contentLength = end - start + 1;
            if (request.method != 'HEAD') {
              response.add(Uint8List.sublistView(bytes, start, end + 1));
            }
          } on SocketException {
            // Range probes can cancel after reading their headers.
          } on HttpException {
            // Range probes can cancel after reading their headers.
          } finally {
            try {
              await response.close();
            } catch (_) {}
          }
        });
        var pathReads = 0;
        final transport = DesktopGopeedTransport.lazy(
          executable: () {
            pathReads++;
            return executable;
          },
        );
        app = AppServices(
          store: store,
          dataDirectory: root,
          cacheDirectory: Directory(p.join(root.path, 'cache')),
          transport: transport,
          files: PlatformFileAccess(
            transport,
            Directory(p.join(root.path, 'saved')),
          ),
          http: FakeHttp(),
          platformFeatures: false,
          controlEnabled: false,
        );
        await app.initialize();
        expect(pathReads, 0);
        expect(transport.connected, isFalse);

        final info = <String, Object>{
          'name': 'isolation.bin',
          'length': bytes.length,
          'piece length': bytes.length,
          'pieces': Uint8List.fromList(sha1.convert(bytes).bytes),
        };
        torrent = TorrentSession(app.engine, app.transfer);
        await torrent.resolve(
          '$torrentDataPrefix${base64Encode(_bencode({'info': info}))}',
        );
        expect(torrent.error, isEmpty);
        expect(torrent.info!.files.single.path, 'isolation.bin');
        expect(torrent.info!.files.single.size, bytes.length);
        torrent.dispose();
        torrent = null;

        final id = await app.downloads.enqueue(
          DownloadSpec(
            url: 'http://127.0.0.1:${server.port}/isolation.bin',
            fileName: 'isolation.bin',
            expectedSize: bytes.length,
            checksumType: 'sha256',
            checksumValue: sha256.convert(bytes).toString(),
          ),
        );
        await until(
          () =>
              !app!.downloads.task(id)!.active &&
              app.downloads.activeCount == 0,
          timeout: const Duration(seconds: 30),
        );
        final task = app.downloads.task(id)!;
        expect(task.status, DownloadStatus.completed, reason: task.error);
        expect(await File(task.savedPath!).readAsBytes(), bytes);
        expect(pathReads, 1);
        expect(runtime.ready, isFalse);
      } finally {
        torrent?.dispose();
        await app?.close();
        await server?.close(force: true);
        store.dispose();
        await root.delete(recursive: true);
        HttpOverrides.global = previousHttp;
      }
    },
    skip: !File(executable).existsSync(),
  );
}
