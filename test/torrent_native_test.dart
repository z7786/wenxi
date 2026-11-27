import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/download/torrent_session.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

class _LocalIo extends HttpOverrides {}

List<int> _bencode(Object value) {
  if (value is int) return ascii.encode('i${value}e');
  if (value is String) return _bencode(Uint8List.fromList(utf8.encode(value)));
  if (value is Uint8List) {
    return [...ascii.encode('${value.length}:'), ...value];
  }
  if (value is List) {
    return [108, for (final item in value) ..._bencode(item), 101];
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
  group(
    'BT through packaged Gopeed helper',
    () {
      late Directory root;
      late HttpServer server;
      late AppServices services;
      late StateStore store;
      late TorrentInfo metadata;
      final content = Uint8List.fromList(
        List.generate(2 * 1024 * 1024, (i) => (i * 41 + i ~/ 97) % 251),
      );
      final skipped = Uint8List.fromList(utf8.encode('unselected file\n'));
      Future<void> open() async {
        final transport = DesktopGopeedTransport(executable: executable);
        services = AppServices(
          controlEnabled: false,
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
        );
        await services.downloads.initialize();
      }

      setUp(() async {
        HttpOverrides.global = _LocalIo();
        root = await Directory.systemTemp.createTemp('aster-bt-native-');
        store = await StateStore.open(
          Directory(p.join(root.path, 'state')),
          testKey: Uint8List.fromList(List.filled(32, 9)),
        );
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((r) async {
          try {
            final bytes = r.uri.path == '/collection/selected.bin'
                ? content
                : r.uri.path == '/collection/skip.txt'
                ? skipped
                : Uint8List(0);
            var begin = 0, end = bytes.length - 1;
            final range = r.headers.value('range');
            if (range != null) {
              final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
              begin = int.parse(match[1]!);
              end = int.tryParse(match[2]!) ?? end;
              r.response.statusCode = 206;
              r.response.headers.set(
                'Content-Range',
                'bytes $begin-$end/${bytes.length}',
              );
            }
            r.response.contentLength = end - begin + 1;
            r.response.headers.set('Content-Type', 'application/octet-stream');
            if (end >= begin) r.response.add(bytes.sublist(begin, end + 1));
          } on SocketException {
            // Pausing intentionally closes active requests.
          } on HttpException {
            // Pausing intentionally closes active requests.
          } finally {
            try {
              await r.response.close();
            } catch (_) {}
          }
        });
        const pieceLength = 16384;
        final bytes = Uint8List.fromList([...content, ...skipped]);
        final pieces = <int>[];
        for (var start = 0; start < bytes.length; start += pieceLength) {
          pieces.addAll(
            sha1
                .convert(
                  bytes.sublist(
                    start,
                    (start + pieceLength).clamp(0, bytes.length),
                  ),
                )
                .bytes,
          );
        }
        final info = <String, Object>{
          'name': 'collection',
          'piece length': pieceLength,
          'pieces': Uint8List.fromList(pieces),
          'private': 1,
          'files': [
            {
              'length': content.length,
              'path': ['selected.bin'],
            },
            {
              'length': skipped.length,
              'path': ['skip.txt'],
            },
            {
              'length': 0,
              'path': ['empty.txt'],
            },
          ],
        };
        final data =
            '$torrentDataPrefix${base64Encode(_bencode({
              'info': info,
              'url-list': ['http://127.0.0.1:${server.port}/'],
            }))}';
        await open();
        final session = TorrentSession(services.engine, services.transfer);
        await session.resolve(data);
        expect(session.error, isEmpty);
        metadata = session.info!;
        expect(metadata.hash, sha1.convert(_bencode(info)).toString());
        expect(metadata.files.map((f) => f.size), [
          content.length,
          skipped.length,
          0,
        ]);
        session.dispose();
      });
      tearDown(() async {
        await services.close();
        await server.close(force: true);
        await root.delete(recursive: true);
        HttpOverrides.global = null;
      });
      Future<void> completed(List<String> ids) async {
        await until(
          () =>
              ids.every((id) => !services.downloads.task(id)!.active) &&
              services.downloads.activeCount == 0,
          timeout: const Duration(seconds: 35),
        );
        for (final id in ids) {
          expect(
            services.downloads.task(id)!.status,
            DownloadStatus.completed,
            reason: services.downloads.task(id)!.error,
          );
        }
      }

      test(
        'Downloads only selected files, verifies bytes, exports empty file and deletes safely',
        () async {
          final ids = await services.downloads.enqueueTorrent(metadata, [0, 2]);
          await completed(ids);
          final first = services.downloads.task(ids.first)!;
          final empty = services.downloads.task(ids.last)!;
          expect(await File(first.savedPath!).readAsBytes(), content);
          expect(await File(empty.savedPath!).length(), 0);
          expect(
            Directory(
              p.join(root.path, 'saved'),
            ).listSync(recursive: true).whereType<File>().length,
            2,
          );
          await services.downloads.delete(first.id, deleteFile: true);
          expect(await File(first.savedPath!).exists(), isFalse);
          expect(await File(empty.savedPath!).exists(), isTrue);
          expect(services.store.data.obj('torrents'), isNotEmpty);
        },
      );
      test(
        'BT metadata and partial queue survive restart and resume verified payload',
        () async {
          await store.put('settings', {
            'speedLimit': 512 * 1024,
            'concurrent': 1,
          });
          final id = (await services.downloads.enqueueTorrent(metadata, [
            0,
          ])).single;
          await until(
            () =>
                services.downloads.task(id)!.downloaded > 0 ||
                !services.downloads.task(id)!.active,
          );
          await services.downloads.pause(id);
          final paused = services.downloads.task(id)!;
          expect(paused.downloaded, inExclusiveRange(0, content.length));
          await services.close();
          await open();
          expect(services.downloads.task(id)!.status, DownloadStatus.paused);
          expect(
            store.data.obj('torrents').obj(metadata.hash).str('data'),
            metadata.data,
          );
          await services.downloads.resume(id);
          await completed([id]);
          expect(
            await File(services.downloads.task(id)!.savedPath!).readAsBytes(),
            content,
          );
        },
      );
    },
    skip: !Platform.isWindows || !File(executable).existsSync()
        ? 'Windows helper is required.'
        : false,
  );
}
