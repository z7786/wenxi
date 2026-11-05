import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/external_stream.dart';

void main() {
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
