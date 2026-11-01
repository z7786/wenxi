import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/playback/torrent_playback.dart';
import 'support.dart';

class _RealNetwork extends HttpOverrides {}

List<int> _encode(Object value) {
  if (value is int) return ascii.encode('i${value}e');
  if (value is String) return _encode(Uint8List.fromList(utf8.encode(value)));
  if (value is Uint8List) {
    return [...ascii.encode('${value.length}:'), ...value];
  }
  if (value is List) {
    return [108, for (final item in value) ..._encode(item), 101];
  }
  final map = value as Map<String, Object>;
  return [
    100,
    for (final key in map.keys.toList()..sort()) ...[
      ..._encode(key),
      ..._encode(map[key]!),
    ],
    101,
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = gopeedTestExecutable();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;
  group(
    'Real Gopeed BT streaming through libmpv',
    () {
      setUpAll(() => MediaKit.ensureInitialized(libmpv: library));
      tearDownAll(() async {
        // media_kit destroys native handles five seconds after dispose. Keep
        // the test isolate alive through that destruction and queued wakeups.
        await Future<void>.delayed(const Duration(seconds: 6));
      });
      for (final (name, geometry) in [
        ('player-sample.mkv', const VideoGeometry(320, 180)),
        ('player-rotated.mov', const VideoGeometry(180, 320)),
      ]) {
        test(
          '$name loads container metadata, plays and seeks without a cloud proxy',
          () async {
            HttpOverrides.global = _RealNetwork();
            final root = await Directory.systemTemp.createTemp(
              'wenxi-bt-player-native-',
            );
            final bytes = await File('test/fixtures/$name').readAsBytes();
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            var requests = 0;
            server.listen((request) async {
              try {
                requests++;
                var start = 0, end = bytes.length - 1;
                final range = request.headers.value('range');
                if (range != null) {
                  final match = RegExp(
                    r'^bytes=(\d+)-(\d*)$',
                  ).firstMatch(range)!;
                  start = int.parse(match[1]!);
                  end = (int.tryParse(match[2]!) ?? end).clamp(start, end);
                  request.response.statusCode = 206;
                  request.response.headers.set(
                    'Content-Range',
                    'bytes $start-$end/${bytes.length}',
                  );
                }
                request.response.contentLength = end - start + 1;
                request.response.headers.set('Accept-Ranges', 'bytes');
                if (request.method != 'HEAD') {
                  request.response.add(bytes.sublist(start, end + 1));
                }
                await request.response.close();
              } on SocketException {
                // Closing playback cancels an in-flight webseed request.
              } on HttpException {
                // Closing playback cancels an in-flight webseed request.
              }
            });
            const pieceLength = 16384;
            final pieces = <int>[];
            for (var offset = 0; offset < bytes.length; offset += pieceLength) {
              pieces.addAll(
                sha1
                    .convert(
                      bytes.sublist(
                        offset,
                        (offset + pieceLength).clamp(0, bytes.length),
                      ),
                    )
                    .bytes,
              );
            }
            final info = <String, Object>{
              'name': name,
              'length': bytes.length,
              'piece length': pieceLength,
              'pieces': Uint8List.fromList(pieces),
              'private': 1,
            };
            final metadata = TorrentInfo(
              sha1.convert(_encode(info)).toString(),
              name,
              '$torrentDataPrefix${base64Encode(_encode({
                'info': info,
                'url-list': ['http://127.0.0.1:${server.port}/'],
              }))}',
              [TorrentFile(0, name, bytes.length)],
              pieceLength: pieceLength,
            );
            final services = AppServices(
              controlEnabled: false,
              store: StateStore.memory(),
              dataDirectory: root,
              cacheDirectory: Directory('${root.path}/cache'),
              transport: DesktopGopeedTransport(executable: executable),
              files: FakeFiles(Directory('${root.path}/saved')),
              http: FakeHttp(),
              platformFeatures: false,
            );
            final player = Player(
              configuration: const PlayerConfiguration(
                title: 'BT playback test',
              ),
            );
            await (player.platform as NativePlayer).setProperty('ao', 'null');
            await (player.platform as NativePlayer).setProperty('vo', 'null');
            // No Flutter texture is attached in this test. Enable the actual
            // decoder explicitly, including files without an audio track.
            await (player.platform as NativePlayer).setProperty('vid', 'auto');
            late TorrentMediaBackend backend;
            final controller = torrentPlayback(
              services,
              metadata,
              metadata.files.single,
              backendFactory: (entry, hardware) =>
                  backend = TorrentMediaBackend(
                    services.engine,
                    video: false,
                    player: player,
                  ),
            );
            // Independent teardown callbacks preserve the original assertion
            // when a separate cleanup operation also reports an error.
            addTearDown(() => HttpOverrides.global = null);
            addTearDown(() => root.delete(recursive: true));
            addTearDown(() => server.close(force: true));
            addTearDown(services.close);
            addTearDown(controller.close);
            await controller.start().timeout(const Duration(seconds: 20));
            expect(controller.error, isEmpty);
            await until(
              () =>
                  backend.videoGeometry != null &&
                  player.state.duration > Duration.zero,
            );
            void expectGeometry() {
              final actual = backend.videoGeometry;
              expect(
                (actual?.width, actual?.height),
                (geometry.width, geometry.height),
                reason:
                    '${player.state.videoParams}\n${player.state.tracks.video}',
              );
            }

            expectGeometry();
            await until(() => player.state.videoParams.w != null);
            expectGeometry();
            expect(requests, greaterThan(0));
            await controller.pause();
            await until(() => !player.state.playing);
            await controller.seek(player.state.duration ~/ 2);
            await until(() => player.state.position.inMilliseconds > 500);
            await backend.setRate(1.5);
            await controller.play();
            await until(() => player.state.playing && player.state.rate == 1.5);
            await controller.close().timeout(const Duration(seconds: 5));
            // Surface a backend-disposal error instead of only reporting
            // the controller's deliberate cache-retention fallback.
            await backend.close();
            expect(
              await Directory(
                '${root.path}/cache/.bt-stream-cache',
              ).list().toList(),
              isEmpty,
            );
          },
        );
      }
    },
    skip:
        !Platform.isWindows || library == null || !File(executable).existsSync()
        ? 'Windows Gopeed helper and libmpv test runtime are required.'
        : false,
  );
}
