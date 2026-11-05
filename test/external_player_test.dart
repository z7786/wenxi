import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'player_support.dart';
import 'support.dart' show until;

void main() {
  test(
    'independent window releases the parent decoder and preserves its own progress and source lease',
    () async {
      final fixture = PlaybackFixture(count: 1);
      final controller = fixture.controller;
      await controller.start();
      await controller.seek(const Duration(seconds: 120));
      controller.floating = true;
      expect(
        await controller.openExternalPlayer((_, _, _) async => true),
        isTrue,
      );
      final decoder = fixture.current;
      controller.retireIndependentDecoder();
      expect(controller.backend, isNull);
      await until(() => decoder.closed && fixture.leases.values.single == 1);
      expect(controller.playingExternally, isTrue);
      expect(controller.closed, isFalse);
      await controller.saveIndependentProgress(
        PlaybackBookmark(
          name: controller.current.name,
          source: controller.current.source,
          position: const Duration(seconds: 345),
          duration: const Duration(minutes: 10),
          completed: false,
          updatedAt: 1,
        ),
      );
      await controller.close(force: true);
      expect(decoder.closes, 1);
      expect(fixture.leases.values, everyElement(0));
      expect(
        fixture.history.bookmark(controller.current.key)!.position,
        const Duration(seconds: 345),
      );
      fixture.store.dispose();
    },
  );
  test(
    'External playback pauses internal audio, retains its lease and survives background',
    () async {
      final fixture = PlaybackFixture(count: 1);
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      await controller.seek(const Duration(seconds: 123));
      late String address;
      expect(
        await controller.openExternalPlayer((url, title, position) async {
          address = url;
          expect(title, controller.current.name);
          expect(position, const Duration(seconds: 123));
          expect(controller.state.playing, isFalse);
          expect(fixture.leases.values.single, 2);
          return true;
        }),
        isTrue,
      );
      expect(Uri.parse(address).host, '127.0.0.1');
      expect(address, isNot(contains('fixture-secret')));
      await controller.background(pictureInPicture: false);
      controller.foreground();
      expect(controller.playingExternally, isTrue);
      expect(controller.state.playing, isFalse);
      expect(fixture.leases.values.single, 2);
      await controller.play();
      expect(controller.playingExternally, isFalse);
      expect(controller.state.playing, isTrue);
      expect(fixture.leases.values.single, 1);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      await expectLater(
        client.getUrl(Uri.parse(address)),
        throwsA(isA<SocketException>()),
      );
    },
  );

  for (final wasPlaying in [true, false]) {
    for (final fails in [true, false]) {
      test(
        'Cancel/failure restores only the previous state: playing=$wasPlaying, failure=$fails',
        () async {
          final fixture = PlaybackFixture(count: 1);
          final controller = fixture.controller;
          addTearDown(controller.close);
          await controller.start();
          if (!wasPlaying) await controller.pause();
          final opened = controller.openExternalPlayer((
            url,
            title,
            position,
          ) async {
            if (fails) throw const AppException('no player');
            return false;
          });
          if (fails) {
            await expectLater(opened, throwsA(isA<AppException>()));
          } else {
            expect(await opened, isFalse);
          }
          expect(controller.state.playing, wasPlaying);
          expect(controller.playingExternally, isFalse);
          expect(controller.openingExternalPlayer, isFalse);
          expect(fixture.leases.values.single, 1);
        },
      );
    }
  }

  test(
    'A cancelled chooser does not resume internal playback while the app is backgrounded',
    () async {
      final fixture = PlaybackFixture(count: 1);
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      await fixture.controller.openExternalPlayer((_, _, _) async {
        await fixture.controller.background(pictureInPicture: false);
        return false;
      });
      expect(fixture.controller.state.playing, isFalse);
    },
  );

  test(
    'Switching videos closes the handed-off transport before releasing its source',
    () async {
      final fixture = PlaybackFixture();
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      final old = fixture.current.openedSource!;
      await controller.openExternalPlayer((_, _, _) async => true);
      await controller.next();
      expect(controller.playingExternally, isFalse);
      expect(fixture.leases[old.url], 0);
      expect(fixture.leases.values.where((count) => count > 0).single, 1);
      await controller.close();
      expect(fixture.leases.values, everyElement(0));
    },
  );

  test(
    'Closing during app selection rejects a late selection and releases exactly once',
    () async {
      final fixture = PlaybackFixture();
      final controller = fixture.controller;
      await controller.start();
      final entered = Completer<void>(), selection = Completer<bool>();
      final opening = controller.openExternalPlayer((_, _, _) {
        entered.complete();
        return selection.future;
      });
      final checked = expectLater(opening, throwsA(isA<AppException>()));
      await entered.future;
      await expectLater(
        controller.openExternalPlayer((_, _, _) async => true),
        throwsA(isA<AppException>()),
      );
      await controller.close();
      selection.complete(true);
      await checked;
      expect(fixture.leases.values, everyElement(0));
      expect(controller.playingExternally, isFalse);
    },
  );

  test('Local content is left for Android read-grant conversion', () async {
    final stream = ExternalPlaybackStream(
      const DownloadSpec(
        url: 'content://fixture/video/1',
        fileName: 'movie.mkv',
      ),
    );
    addTearDown(stream.close);
    await stream.start();
    expect(stream.url, 'content://fixture/video/1');
  });

  test(
    'Signed DASH links stay direct and account headers are never handed to another app',
    () async {
      final direct = ExternalPlaybackStream(
        const DownloadSpec(
          url: 'https://example.invalid/movie.mpd?signature=fixture',
          fileName: 'movie.mpd',
        ),
      );
      final protected = ExternalPlaybackStream(
        const DownloadSpec(
          url: 'https://example.invalid/movie.mpd',
          fileName: 'movie.mpd',
          headers: {'Cookie': 'account=fixture'},
        ),
      );
      addTearDown(direct.close);
      addTearDown(protected.close);
      await direct.start();
      expect(direct.url, direct.source.url);
      await expectLater(protected.start(), throwsA(isA<AppException>()));
    },
  );

  test(
    'A decoder initialization error still permits handing the valid source to another player',
    () async {
      final fixture = PlaybackFixture(count: 1)
        ..configureBackend = (backend) {
          backend.failOpen = true;
        };
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      expect(fixture.controller.error, isNotEmpty);
      expect(
        await fixture.controller.openExternalPlayer((_, _, _) async => true),
        isTrue,
      );
      expect(fixture.controller.playingExternally, isTrue);
    },
  );

  Future<HttpServer> origin(FutureOr<void> Function(HttpRequest) serve) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await serve(request);
      } finally {
        await request.response.close();
      }
    });
    addTearDown(() => server.close(force: true));
    return server;
  }

  HttpClient client() {
    final value = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    addTearDown(() => value.close(force: true));
    return value;
  }

  Future<ExternalPlaybackStream> relay(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final stream = ExternalPlaybackStream(
      DownloadSpec(url: url, headers: headers, fileName: 'movie.mp4'),
    );
    addTearDown(stream.close);
    await stream.start();
    return stream;
  }

  test(
    'Relay preserves Range, HEAD, bytes and required upstream headers without exposing them',
    () async {
      final seen = <Map<String, String?>>[];
      final server = await origin((request) {
        seen.add({
          for (final name in [
            'cookie',
            'user-agent',
            'referer',
            'range',
            'if-range',
          ])
            name: request.headers.value(name),
        });
        request.response.headers.set('content-type', 'video/mp4');
        request.response.headers.set('accept-ranges', 'bytes');
        if (request.method == 'HEAD') {
          request.response.contentLength = 20;
        } else {
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 4-7/20');
          request.response.contentLength = 4;
          request.response.add([4, 5, 6, 7]);
        }
      });
      final stream = await relay(
        'http://127.0.0.1:${server.port}/private.mp4?ticket=secret',
        headers: {
          'Cookie': 'account=fixture',
          'User-Agent': 'CloudDesktopFixture',
          'Referer': 'https://drive.example/',
        },
      );
      final http = client(), uri = Uri.parse(stream.url);
      final head = await (await http.headUrl(uri)).close();
      expect(head.contentLength, 20);
      await head.drain<void>();
      for (var i = 0; i < 2; i++) {
        final request = await http.getUrl(uri);
        request.headers.set('Range', 'bytes=4-7');
        request.headers.set('If-Range', '"fixture"');
        request.headers.set('Cookie', 'attacker=ignored');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(response.headers.value('content-range'), 'bytes 4-7/20');
        expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
          4,
          5,
          6,
          7,
        ]);
      }
      expect(seen.every((h) => h['cookie'] == 'account=fixture'), isTrue);
      expect(seen.last['range'], 'bytes=4-7');
      expect(seen.last['if-range'], '"fixture"');
      expect(seen.last['user-agent'], 'CloudDesktopFixture');
      expect(seen.last['referer'], 'https://drive.example/');
      expect(stream.url, isNot(contains('secret')));
    },
  );

  test(
    'HLS rewrites nested playlists, separate audio, keys and byte-range segments',
    () async {
      final paths = <String>[];
      final cookies = <String?>[];
      final server = await origin((request) {
        paths.add(request.uri.toString());
        cookies.add(request.headers.value('cookie'));
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.headers.set(
            'content-type',
            'application/vnd.apple.mpegurl',
          );
          if (request.uri.path == '/master.m3u8') {
            request.response.write(
              '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO="a"\nvideo/index.m3u8?token=signed\n',
            );
          } else {
            request.response.write(
              '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="../key.bin?key=secret"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:10,\n#EXT-X-BYTERANGE:4@4\nsegment.mp4?token=signed\n#EXT-X-ENDLIST\n',
            );
          }
        } else {
          request.response.add([9, 8, 7, 6]);
        }
      });
      final stream = await relay(
        'http://127.0.0.1:${server.port}/master.m3u8',
        headers: {'Cookie': 'account=fixture'},
      );
      final http = client();
      Future<String> text(String url) async => utf8.decoder
          .bind(await (await http.getUrl(Uri.parse(url))).close())
          .join();
      final master = await text(stream.url);
      expect(master, isNot(contains('signed')));
      expect(master, isNot(contains('${server.port}')));
      final audio = RegExp('URI="([^"]+)"').firstMatch(master)![1]!;
      final nestedUrl = master
          .split('\n')
          .firstWhere((line) => line.startsWith('http'));
      final nested = await text(nestedUrl);
      await text(audio);
      for (final match in RegExp('URI="([^"]+)"').allMatches(nested)) {
        await text(match[1]!);
      }
      final segment = nested
          .split('\n')
          .firstWhere((line) => line.startsWith('http'));
      await text(segment);
      expect(nested, contains('#EXT-X-BYTERANGE:4@4'));
      expect(nested, isNot(contains('secret')));
      expect(
        paths,
        containsAll([
          '/video/index.m3u8?token=signed',
          '/audio.m3u8',
          '/key.bin?key=secret',
          '/video/init.mp4',
          '/video/segment.mp4?token=signed',
        ]),
      );
      expect(cookies.every((cookie) => cookie == 'account=fixture'), isTrue);
    },
  );

  test(
    'Redirected manifests resolve from their final URL and do not leak credentials to another origin',
    () async {
      final received = <Map<String, String?>>[];
      final cdn = await origin((request) {
        received.add({
          for (final name in ['cookie', 'authorization', 'user-agent'])
            name: request.headers.value(name),
        });
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.headers.set(
            'content-type',
            'application/vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          expect(request.uri.path, '/cdn/part.ts');
          request.response.write('segment');
        }
      });
      final dispatcher = await origin((request) {
        request.response.statusCode = 302;
        request.response.headers.set(
          'location',
          'http://127.0.0.1:${cdn.port}/cdn/index.m3u8',
        );
      });
      final stream = await relay(
        'http://127.0.0.1:${dispatcher.port}/entry.m3u8',
        headers: {
          'Cookie': 'private=fixture',
          'Authorization': 'Bearer fixture',
          'User-Agent': 'DesktopFixture',
        },
      );
      final http = client();
      final list = await utf8.decoder
          .bind(await (await http.getUrl(Uri.parse(stream.url))).close())
          .join();
      final segment = list
          .split('\n')
          .firstWhere((line) => line.startsWith('http'));
      await (await (await http.getUrl(
        Uri.parse(segment),
      )).close()).drain<void>();
      expect(received.length, 2);
      expect(
        received.every(
          (h) =>
              h['cookie'] == null &&
              h['authorization'] == null &&
              h['user-agent'] == 'DesktopFixture',
        ),
        isTrue,
      );
    },
  );

  test(
    'Relay rejects unknown paths, supplied upstream URLs and non-read requests',
    () async {
      var accesses = 0;
      final server = await origin((request) {
        accesses++;
        request.response.write('video');
      });
      final stream = await relay('http://127.0.0.1:${server.port}/movie');
      final http = client(), uri = Uri.parse(stream.url);
      for (final invalid in [
        uri.replace(path: '/unknown'),
        uri.replace(query: 'url=https://example.com'),
      ]) {
        final response = await (await http.getUrl(invalid)).close();
        expect(response.statusCode, 404);
        await response.drain<void>();
      }
      final post = await (await http.postUrl(uri)).close();
      expect(post.statusCode, 405);
      await post.drain<void>();
      expect(accesses, 0);
    },
  );

  test(
    'Gzip HLS is decoded with a bounded buffer before URI rewriting',
    () async {
      final server = await origin((request) {
        request.response.headers.set(
          'content-type',
          'application/vnd.apple.mpegurl',
        );
        request.response.headers.set('content-encoding', 'gzip');
        request.response.add(
          gzip.encode(
            utf8.encode('#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n'),
          ),
        );
      });
      final stream = await relay('http://127.0.0.1:${server.port}/movie.m3u8');
      final response = await (await client().getUrl(
        Uri.parse(stream.url),
      )).close();
      expect(response.headers.value('content-encoding'), isNull);
      final playlist = await utf8.decoder.bind(response).join();
      expect(playlist, startsWith('#EXTM3U\n'));
      expect(playlist, contains('http://127.0.0.1:'));
      expect(playlist, isNot(contains('part.ts')));
    },
  );

  test(
    'Switching players repeatedly closes a blocked slow-reader transport and retains one source lease',
    () async {
      final chunk = Uint8List(256 * 1024);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final active = <Future<void>>{};
      var sentBytes = 0;
      server.listen((request) {
        final task = () async {
          try {
            request.response.headers.contentType = ContentType('video', 'mp4');
            request.response.contentLength = chunk.length * 512;
            for (var i = 0; i < 512; i++) {
              request.response.add(chunk);
              await request.response.flush();
              sentBytes += chunk.length;
            }
          } catch (_) {
            // Replacing the external player intentionally aborts this request.
          } finally {
            try {
              await request.response.close();
            } catch (_) {}
          }
        }();
        active.add(task);
        task.then((_) => active.remove(task));
      });
      final http = client();
      final readers = <StreamSubscription<List<int>>>[];
      final fixture = PlaybackFixture(
        count: 1,
        externalStreamFactory: (source) => ExternalPlaybackStream(
          DownloadSpec(
            url: 'http://127.0.0.1:${server.port}/movie.mp4',
            fileName: source.fileName,
          ),
        ),
      );
      addTearDown(() async {
        http.close(force: true);
        for (final reader in readers) {
          await reader.cancel();
        }
        await fixture.controller.close();
        await server.close(force: true);
        await Future.wait(active.toList());
        fixture.store.dispose();
      });
      await fixture.controller.start();
      var address = '';
      Future<bool> choose(String url, String _, Duration _) async {
        address = url;
        return true;
      }

      await fixture.controller.openExternalPlayer(choose);
      for (var i = 0; i < 3; i++) {
        final oldAddress = address;
        final previousBytes = sentBytes;
        final response = await (await http.getUrl(Uri.parse(address))).close();
        readers.add(response.listen((_) {}, onError: (Object _) {})..pause());
        // Let socket buffers fill while the external app stops consuming video.
        final watch = Stopwatch()..start();
        while (sentBytes <= previousBytes + chunk.length * 4) {
          if (watch.elapsed > const Duration(seconds: 3)) {
            fail('The fixture origin never started sending video');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          await fixture.controller
              .openExternalPlayer(choose)
              .timeout(const Duration(seconds: 2)),
          isTrue,
        );
        expect(address, isNot(oldAddress));
        expect(fixture.leases.values.single, 2);
        expect(fixture.controller.state.playing, isFalse);
        await expectLater(
          http.getUrl(Uri.parse(oldAddress)),
          throwsA(isA<SocketException>()),
        );
      }
      await fixture.controller.close().timeout(const Duration(seconds: 2));
      expect(fixture.leases.values, everyElement(0));
    },
  );
}
