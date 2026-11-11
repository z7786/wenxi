import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'package:asterlink/playback/cast/cast_session.dart';
import 'cast_support.dart';

void main() {
  test(
    'range worker 403 stays an expired source failure instead of a generic relay 502',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        if (request.headers.value('Range') == 'bytes=0-1023') {
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 0-1023/8388608');
          request.response.contentLength = 1024;
          request.response.add(List.filled(1024, 7));
        } else {
          request.response.statusCode = 403;
        }
        await request.response.close();
      });
      final failures = <int?>[];
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/video.mp4',
          fileName: 'movie.mp4',
        ),
        lanAddress: InternetAddress.loopbackIPv4,
        onFailure: (value) => failures.add(value.status),
      );
      addTearDown(stream.close);
      await stream.start();
      await stream.prepareMedia();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        Uri.parse(stream.url),
      )).close();
      await response.drain<void>();
      expect(stream.failure?.status, 403);
      expect(failures, contains(403));
      expect(failures, isNot(contains(502)));
    },
  );
  test(
    'relay diagnostics record source status and omit URLs, title and credentials',
    () async {
      final log = DiagnosticLog.open(null);
      final previous = DiagnosticLog.active;
      DiagnosticLog.active = log;
      addTearDown(() async {
        DiagnosticLog.active = previous;
        log.close();
      });
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        request.response.statusCode = 403;
        await request.response.close();
      });
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url:
              'http://127.0.0.1:${origin.port}/private-movie?signature=do-not-log',
          fileName: 'private-title.mp4',
          headers: const {'Cookie': 'private-cookie'},
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        Uri.parse(stream.url),
      )).close();
      await response.drain<void>();
      await stream.close();
      final records = log.entries();
      expect(records.any((e) => e.event == 'cast.relay_request'), isTrue);
      final detail = records.map((e) => e.detail).join();
      expect(detail, contains('403'));
      for (final value in [
        'do-not-log',
        'private-cookie',
        'private-title',
        'private-movie',
      ]) {
        expect(detail, isNot(contains(value)));
      }
    },
  );
  for (final limit in [1, 4]) {
    test(
      'prepared TV stream uses bounded parallel ranges, respects limit $limit and cancels abandoned reads',
      () async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => origin.close(force: true));
        const total = 8 * 1024 * 1024;
        var active = 0, peak = 0, upstreamBytes = 0;
        origin.listen((request) async {
          active++;
          if (active > peak) peak = active;
          try {
            expect(request.headers.value('Cookie'), 'account=private');
            final range = RegExp(
              r'bytes=(\d+)-(\d+)',
            ).firstMatch(request.headers.value('Range')!)!;
            final start = int.parse(range[1]!),
                end = int.parse(range[2]!).clamp(0, total - 1);
            request.response.statusCode = 206;
            request.response.headers.set(
              'content-range',
              'bytes $start-$end/$total',
            );
            request.response.headers.contentType = ContentType('video', 'mp4');
            request.response.contentLength = end - start + 1;
            for (var at = start; at <= end; at += 16 * 1024) {
              final size = (end - at + 1).clamp(0, 16 * 1024);
              request.response.add(List.filled(size, 7));
              upstreamBytes += size;
              await request.response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 3));
            }
          } catch (_) {
          } finally {
            active--;
            try {
              await request.response.close();
            } catch (_) {}
          }
        });
        final stream = ExternalPlaybackStream.lan(
          DownloadSpec(
            url: 'http://127.0.0.1:${origin.port}/movie.mp4',
            fileName: 'movie.mp4',
            headers: const {'Cookie': 'account=private'},
            maxPlaybackConnections: limit,
          ),
          lanAddress: InternetAddress.loopbackIPv4,
        );
        addTearDown(stream.close);
        await stream.start();
        await stream.prepareMedia(connections: 4);
        final uri = Uri.parse(stream.url);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final tv = await Socket.connect(uri.host, uri.port);
        final read = Completer<void>();
        var received = 0;
        tv.listen((bytes) {
          received += bytes.length;
          if (received > 512 * 1024 && !read.isCompleted) {
            tv.destroy();
            read.complete();
          }
        }, onError: (Object _) {});
        tv.write('GET ${uri.path}?tv=1 HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
        await tv.flush();
        await read.future.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final request = await client.getUrl(uri);
        request.headers.set('Range', 'bytes=1048576-1049599');
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        expect(response.statusCode, 206);
        expect(await response.expand((e) => e).toList(), List.filled(1024, 7));
        expect(peak, lessThanOrEqualTo(limit));
        if (limit > 1) expect(peak, greaterThan(1));
        expect(upstreamBytes, lessThan(total));
        expect(stream.mediaSize, total);
      },
    );
  }

  test(
    'extensionless HLS is identified before DIDL is sent to the TV',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        request.response.headers.contentType = ContentType.binary;
        request.response.write(
          '#EXTM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n',
        );
        await request.response.close();
      });
      final tv = TestTv();
      await tv.start();
      addTearDown(tv.close);
      final session = CastSession(
        tv.device,
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/manifest',
          fileName: 'movie.mp4',
        ),
        platform: TestCastPlatform(),
        pollInterval: const Duration(days: 1),
      );
      addTearDown(session.close);
      await session.start(
        title: 'movie',
        position: Duration.zero,
        duration: tv.duration,
      );
      expect(tv.metadata, contains('application/vnd.apple.mpegurl'));
      expect(tv.metadata, contains('DLNA.ORG_OP=00'));
    },
  );
  test(
    'abandoned TV stream cancels its upstream body and frees a single source slot',
    () async {
      final origin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(origin.close);
      final sockets = <Socket>[];
      final tasks = <Future<void>>[];
      var cancelled = false, sent = 0, requests = 0;
      origin.listen((socket) {
        sockets.add(socket);
        final task = () async {
          var started = false;
          final headers = Completer<void>();
          var input = '';
          final subscription = socket.listen(
            (bytes) {
              input += latin1.decode(bytes);
              if (!headers.isCompleted && input.contains('\r\n\r\n')) {
                headers.complete();
              }
            },
            onDone: () {
              cancelled = true;
            },
            onError: (Object _) {
              cancelled = true;
            },
          );
          try {
            await headers.future;
            requests++;
            if (requests > 1) {
              socket.add(
                ascii.encode(
                  'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n',
                ),
              );
              socket.add([1, 2, 3, 4]);
              await socket.flush();
            } else {
              started = true;
              socket.add(
                ascii.encode(
                  'HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 100663296\r\nConnection: close\r\n\r\n',
                ),
              );
              final block = List.filled(64 * 1024, 7);
              while (!cancelled && sent < 96 * 1024 * 1024) {
                socket.add(block);
                await socket.flush();
                sent += block.length;
                await Future<void>.delayed(const Duration(milliseconds: 4));
              }
            }
          } catch (_) {
            if (started) cancelled = true;
          } finally {
            await subscription.cancel();
            socket.destroy();
          }
        }();
        tasks.add(task);
      });
      addTearDown(() async {
        for (final socket in sockets) {
          socket.destroy();
        }
        await Future.wait(tasks);
      });
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/movie.mp4',
          fileName: 'movie.mp4',
          maxPlaybackConnections: 1,
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final uri = Uri.parse(stream.url);
      final tv = await Socket.connect(uri.host, uri.port);
      final read = Completer<void>();
      var received = 0;
      tv.listen((bytes) {
        received += bytes.length;
        if (received >= 1024 * 1024 && !read.isCompleted) {
          tv.destroy();
          read.complete();
        }
      }, onError: (Object _) {});
      tv.write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
      await tv.flush();
      await read.future.timeout(const Duration(seconds: 5));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        uri,
      )).close().timeout(const Duration(seconds: 2));
      expect(await response.expand((e) => e).toList(), [1, 2, 3, 4]);
      expect(cancelled, isTrue);
      expect(sent, lessThan(4 * 1024 * 1024));
    },
  );

  test(
    'TV query suffix is ignored and HEAD uses signed GET without draining the movie',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final seen = <String>[];
      origin.listen((request) async {
        seen.add('${request.method} ${request.uri}');
        request.response.statusCode = request.method == 'HEAD' ? 403 : 200;
        request.response.contentLength = 4;
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/movie.mp4?signature=private',
          fileName: 'movie.mp4',
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final uri = Uri.parse('${stream.url}?tv=1&url=http://untrusted.invalid/');
      final head = await (await client.headUrl(uri)).close();
      expect(head.statusCode, 200);
      expect(head.contentLength, 4);
      expect(await head.expand((e) => e).toList(), isEmpty);
      final get = await (await client.getUrl(uri)).close();
      expect(await get.expand((e) => e).toList(), [1, 2, 3, 4]);
      expect(seen, List.filled(2, 'GET /movie.mp4?signature=private'));
      expect(stream.lastError, isEmpty);
    },
  );
  test(
    'TV relay preserves the source Host for same-origin redirects and resets it for a CDN',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cdn = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      addTearDown(() => cdn.close(force: true));
      final sourceHosts = <String?>[], cdnHeaders = <Map<String, String?>>[];
      origin.listen((request) async {
        final host = request.headers.value('host');
        sourceHosts.add(host);
        if (host != 'storage.fixture.invalid') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            'location',
            request.uri.path == '/entry'
                ? '/same-origin/video'
                : 'http://127.0.0.1:${cdn.port}/video',
          );
        }
        await request.response.close();
      });
      cdn.listen((request) async {
        cdnHeaders.add({
          for (final name in ['host', 'cookie', 'authorization', 'user-agent'])
            name: request.headers.value(name),
        });
        if (request.headers.value('host') != '127.0.0.1:${cdn.port}') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.contentLength = 4;
          if (request.method == 'GET') request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/entry',
          fileName: 'movie.mp4',
          headers: const {
            'hOsT': 'storage.fixture.invalid',
            'Cookie': 'account=fixture',
            'Authorization': 'Bearer fixture',
            'User-Agent': 'CloudFixture',
          },
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      for (final method in ['HEAD', 'GET']) {
        final response = await (await client.openUrl(
          method,
          Uri.parse(stream.url),
        )).close();
        expect(response.statusCode, HttpStatus.ok);
        expect(response.contentLength, 4);
        expect(
          await response.expand((e) => e).toList(),
          method == 'GET' ? [1, 2, 3, 4] : isEmpty,
        );
      }
      expect(sourceHosts, List.filled(4, 'storage.fixture.invalid'));
      expect(cdnHeaders, hasLength(2));
      expect(
        cdnHeaders,
        everyElement({
          'host': '127.0.0.1:${cdn.port}',
          'cookie': null,
          'authorization': null,
          'user-agent': 'CloudFixture',
        }),
      );
    },
  );

  test(
    'TV relay obeys an upstream connection limit instead of causing concurrent 403s',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var active = 0, peak = 0;
      final handlers = <Future<void>>[];
      Future<void> serve(HttpRequest request) async {
        active++;
        if (active > peak) peak = active;
        try {
          if (active > 1) {
            request.response.statusCode = HttpStatus.forbidden;
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 80));
            request.response.headers.contentType = ContentType('video', 'mp4');
            request.response.add([1, 2, 3, 4]);
          }
          await request.response.close();
        } finally {
          active--;
        }
      }

      origin.listen((request) => handlers.add(serve(request)));
      addTearDown(() => Future.wait(handlers));
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/movie.mp4',
          fileName: 'movie.mp4',
          maxPlaybackConnections: 1,
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final client = HttpClient()..maxConnectionsPerHost = 8;
      addTearDown(() => client.close(force: true));
      await Future.wait([
        for (var i = 0; i < 4; i++)
          () async {
            final response = await (await client.getUrl(
              Uri.parse(stream.url),
            )).close();
            expect(response.statusCode, HttpStatus.ok);
            expect(await response.expand((e) => e).toList(), [1, 2, 3, 4]);
          }(),
      ]);
      expect(peak, 1);
    },
  );

  test(
    'TV relay detects an extensionless HLS playlist with a fragmented UTF-8 prefix',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      origin.listen((request) async {
        if (request.uri.path == '/manifest') {
          request.response.headers.contentType = ContentType.binary;
          for (final chunk in [
            [0xef],
            [0xbb, 0xbf, 0x0a],
            utf8.encode('#EX'),
            utf8.encode('TM3U\n#EXTINF:1,\npart.ts\n#EXT-X-ENDLIST\n'),
          ]) {
            request.response.add(chunk);
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        } else {
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/manifest',
          fileName: 'movie.mp4',
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        Uri.parse(stream.url),
      )).close();
      final playlist = await utf8.decoder.bind(response).join();
      expect(
        response.headers.contentType?.mimeType,
        'application/vnd.apple.mpegurl',
      );
      final segment = playlist
          .split('\n')
          .firstWhere((line) => line.startsWith('http'));
      expect(Uri.parse(segment).port, Uri.parse(stream.url).port);
      final payload = await (await client.getUrl(Uri.parse(segment))).close();
      expect(await payload.expand((e) => e).toList(), [1, 2, 3, 4]);
    },
  );

  test(
    'TV relay forwards cloud auth privately and supports HTTP HEAD/Range',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final payload = List.generate(256, (i) => i);
      final cookies = <String?>[], ranges = <String?>[];
      origin.listen((request) async {
        cookies.add(request.headers.value('Cookie'));
        ranges.add(request.headers.value('Range'));
        expect(request.headers.value('Referer'), 'https://drive.invalid/');
        final range = request.headers.value('Range');
        request.response.headers.contentType = ContentType.binary;
        request.response.headers.set('accept-ranges', 'bytes');
        if (range != null) {
          request.response.statusCode = 206;
          request.response.headers.set('content-range', 'bytes 100-109/256');
          request.response.contentLength = 10;
          request.response.add(payload.sublist(100, 110));
        } else {
          request.response.contentLength = payload.length;
          if (request.method == 'GET') request.response.add(payload);
        }
        await request.response.close();
      });
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/movie?private-signature=secret',
          fileName: '电影.mp4',
          headers: const {
            'Cookie': 'cloud=private',
            'Referer': 'https://drive.invalid/',
          },
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      expect(stream.url, isNot(contains('secret')));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final head = await (await client.headUrl(Uri.parse(stream.url))).close();
      expect(head.contentLength, 256);
      expect(head.headers.contentType!.mimeType, 'video/mp4');
      expect(head.headers.value('transferMode.dlna.org'), 'Streaming');
      await head.drain<void>();
      final request = await client.getUrl(Uri.parse(stream.url));
      request.headers.set('Range', 'bytes=100-109');
      request.headers.set('Cookie', 'tv=untrusted');
      final response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 100-109/256');
      expect(
        await response.expand((e) => e).toList(),
        payload.sublist(100, 110),
      );
      expect(cookies, ['cloud=private', 'cloud=private']);
      expect(ranges, [null, 'bytes=100-109']);
      final guessed = Uri.parse(stream.url).replace(path: '/missing/video');
      final missing = await (await client.getUrl(guessed)).close();
      expect(missing.statusCode, 404);
      await missing.drain<void>();
    },
  );

  test(
    'HLS manifests, key URLs and segments are reachable through the same LAN relay',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final paths = <String>[];
      origin.listen((request) async {
        expect(request.headers.value('Cookie'), 'cloud=private');
        paths.add(request.uri.path);
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.headers.set(
            'content-type',
            'application/vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="keys/secret.key"\n'
            '#EXTINF:6,\nsegments/first.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(
          url:
              'http://127.0.0.1:${origin.port}/video/index.m3u8?signature=private',
          fileName: '电影.m3u8',
          headers: const {'Cookie': 'cloud=private'},
        ),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final result = await (await client.getUrl(Uri.parse(stream.url))).close();
      final playlist = await utf8.decoder.bind(result).join();
      expect(playlist, isNot(contains('signature')));
      final urls = [
        RegExp(r'URI="([^"]+)"').firstMatch(playlist)![1]!,
        playlist.split('\n').firstWhere((line) => line.startsWith('http')),
      ];
      for (final url in urls) {
        expect(Uri.parse(url).port, Uri.parse(stream.url).port);
        final body = await (await client.getUrl(Uri.parse(url))).close();
        expect(await body.expand((e) => e).toList(), [1, 2, 3, 4]);
      }
      expect(paths, [
        '/video/index.m3u8',
        '/video/keys/secret.key',
        '/video/segments/first.ts',
      ]);
    },
  );

  test(
    'local files stream in bounded ranges including suffix, HEAD and invalid requests',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-cast-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/本地 视频.mp4');
      final bytes = List.generate(1000, (i) => i % 256);
      await file.writeAsBytes(bytes);
      final stream = ExternalPlaybackStream.lan(
        DownloadSpec(url: file.uri.toString(), fileName: '本地 视频.mp4'),
        lanAddress: InternetAddress.loopbackIPv4,
      );
      addTearDown(stream.close);
      await stream.start();
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      for (final entry in <(String?, int, int, int)>[
        (null, 200, 0, 1000),
        ('bytes=100-199', 206, 100, 200),
        ('bytes=-10', 206, 990, 1000),
        ('bytes=990-', 206, 990, 1000),
        ('bytes=1000-', 416, 0, 0),
        ('bytes=0-2,7-9', 416, 0, 0),
      ]) {
        final request = await client.getUrl(Uri.parse(stream.url));
        if (entry.$1 != null) request.headers.set('Range', entry.$1!);
        final response = await request.close();
        expect(response.statusCode, entry.$2);
        final body = await response.expand((e) => e).toList();
        expect(body, bytes.sublist(entry.$3, entry.$4));
      }
      final response = await (await client.headUrl(
        Uri.parse(stream.url),
      )).close();
      expect(response.contentLength, 1000);
      await response.drain<void>();
      await stream.close();
      await expectLater(
        () async => (await client.getUrl(Uri.parse(stream.url))).close(),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    },
  );

  test('cast rejects protected DASH with a user-facing explanation', () async {
    final stream = ExternalPlaybackStream.lan(
      const DownloadSpec(
        url: 'https://example.invalid/movie.mpd',
        fileName: 'movie.mpd',
        headers: {'Cookie': 'secret'},
      ),
      lanAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(stream.close);
    await expectLater(
      stream.start(),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('DASH'),
        ),
      ),
    );
  });
}
