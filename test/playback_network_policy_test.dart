import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/download_network_policy.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/download/download_playback_cache.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'package:asterlink/playback/isolated_stream_proxy.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'package:asterlink/playback/stream_proxy.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'player_support.dart';

// Route approved test hostnames to a fixture after the application installs
// its policy factory. Real DNS/public-address checks have their own policy tests.
class _FixtureClient implements HttpClient {
  _FixtureClient(this.inner, this.calls);
  final HttpClient inner;
  final List<({Uri url, bool restricted})> calls;
  bool restricted = false;
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? factory,
  ) {
    restricted = factory != null;
    inner.connectionFactory = (uri, _, _) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, uri.port);
  }

  @override
  set findProxy(String Function(Uri)? value) => inner.findProxy = value;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  set autoUncompress(bool value) => inner.autoUncompress = value;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;
  @override
  set maxConnectionsPerHost(int? value) => inner.maxConnectionsPerHost = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    calls.add((url: url, restricted: restricted));
    return inner.openUrl(method, url);
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FixtureHttp extends HttpOverrides {
  final calls = <({Uri url, bool restricted})>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FixtureClient(super.createHttpClient(context), calls);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer origin;
  late _FixtureHttp http;
  late HttpOverrides? previous;
  late DownloadNetworkPolicy policy;
  final requests =
      <({String host, String path, Map<String, String?> headers})>[];
  var forbidden = false, playlistForbidden = false, reResolveForbidden = false;
  final bytes = Uint8List.fromList(List.generate(8192, (i) => i % 251));
  setUp(() async {
    previous = HttpOverrides.current;
    http = _FixtureHttp();
    HttpOverrides.global = http;
    requests.clear();
    forbidden = playlistForbidden = reResolveForbidden = false;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    policy = DownloadNetworkPolicy.fromJson({
      'hosts': ['origin.example.com', 'cdn.example.com'],
      'schemes': ['http'],
      'ports': [origin.port],
    });
    origin.listen((request) async {
      try {
        final path = request.uri.path;
        final host = request.headers.value('host')!.split(':').first;
        requests.add((
          host: host,
          path: path,
          headers: {
            for (final name in [
              'cookie',
              'authorization',
              'x-token',
              'referer',
              'user-agent',
            ])
              name: request.headers.value(name),
          },
        ));
        if (path == '/start' || path == '/cdn' || path == '/ticket') {
          request.response.statusCode = 302;
          request.response.headers.set(
            'Location',
            path == '/cdn'
                ? 'http://origin.example.com:${origin.port}/video'
                : 'http://${forbidden || reResolveForbidden ? '127.0.0.1' : 'cdn.example.com'}:${origin.port}/${path == '/ticket' ? 'expired' : 'cdn'}',
          );
        } else if (path == '/expired') {
          request.response.statusCode = reResolveForbidden ? 403 : 206;
          if (!reResolveForbidden) _range(request, bytes);
        } else if (path == '/playlist.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXTINF:1,\nhttp://${playlistForbidden ? '127.0.0.1' : 'cdn.example.com'}:${origin.port}/video\n#EXT-X-ENDLIST\n',
          );
        } else {
          _range(request, bytes);
        }
        await request.response.close();
      } catch (_) {
        /* Cancellation can interrupt response writes. */
      }
    });
  });
  tearDown(() async {
    await origin.close(force: true);
    HttpOverrides.global = previous;
  });
  DownloadSpec spec([String path = '/start']) => DownloadSpec(
    url: 'http://origin.example.com:${origin.port}$path',
    fileName: 'movie.mkv',
    networkPolicy: policy,
    headers: const {
      'Cookie': 'fixture=1',
      'Authorization': 'fixture-auth',
      'X-Token': 'fixture-secret',
      'Referer': 'http://origin.example.com/private',
      'User-Agent': 'fixture-agent',
    },
  );
  Future<List<int>> read(String url, {int start = 0, int end = 8191}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Range', 'bytes=$start-$end');
      final response = await request.close();
      final result = BytesBuilder(copy: false);
      await for (final data in response) {
        result.add(data);
      }
      return result.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  void checkedUpstream() {
    final calls = http.calls
        .where((c) => c.url.host.endsWith('example.com'))
        .toList();
    expect(calls, isNotEmpty);
    expect(calls.every((c) => c.restricted), isTrue);
    expect(requests.any((r) => r.host == '127.0.0.1'), isFalse);
  }

  void strippedCredentials() {
    expect(requests.first.headers['x-token'], 'fixture-secret');
    for (final request in requests.skip(1)) {
      for (final key in ['cookie', 'authorization', 'x-token', 'referer']) {
        expect(request.headers[key], isNull, reason: '${request.path}: $key');
      }
      expect(request.headers['user-agent'], 'fixture-agent');
    }
  }

  test(
    'Probe and range requests keep policy clients and strip cross-origin custom credentials',
    () async {
      final proxy = PlaybackStreamProxy(
        spec(),
        connections: 1,
        chunkBytes: 8192,
        maxCacheBytes: 16384,
      );
      try {
        expect(await proxy.start(), isTrue);
        expect(await read(proxy.uri.toString()), bytes);
        checkedUpstream();
        strippedCredentials();
      } finally {
        await proxy.close();
      }
    },
  );
  test(
    'Probe rejects an out-of-policy redirect without a direct fallback',
    () async {
      forbidden = true;
      final proxy = PlaybackStreamProxy(spec());
      try {
        await expectLater(
          proxy.start(),
          throwsA(
            isA<PlaybackFailure>().having(
              (e) => e.kind,
              'kind',
              PlaybackFailureKind.restricted,
            ),
          ),
        );
        expect(requests, hasLength(1));
        checkedUpstream();
      } finally {
        await proxy.close();
      }
    },
  );
  test(
    'Starting from cache still checks permissions on missing-byte requests',
    () async {
      forbidden = true;
      final identity = RemoteIdentity(bytes.length, '"stable"', null);
      final failures = <PlaybackFailure>[];
      final proxy = PlaybackStreamProxy(
        spec(),
        connections: 1,
        chunkBytes: 8192,
        maxCacheBytes: 16384,
        onFailure: failures.add,
        cacheSnapshot: () async => DownloadReadableState(identity, [(0, 2048)]),
        readCache: (start, end, _) async => start < 2048
            ? Uint8List.sublistView(bytes, start, math.min(2048, end + 1))
            : null,
      );
      try {
        expect(await proxy.start(), isTrue);
        expect(requests, isEmpty);
        await read(
          proxy.uri.toString(),
        ).then<void>((_) {}, onError: (Object _) {});
        expect(failures.single.kind, PlaybackFailureKind.restricted);
        expect(failures.single.refreshable, isFalse);
        checkedUpstream();
      } finally {
        await proxy.close();
      }
    },
  );
  test('CDN re-resolution cannot escape the original source policy', () async {
    final failures = <PlaybackFailure>[];
    final watched = PlaybackStreamProxy(
      spec('/ticket'),
      connections: 1,
      chunkBytes: 8192,
      maxCacheBytes: 16384,
      onFailure: failures.add,
    );
    try {
      expect(await watched.start(), isTrue);
      reResolveForbidden = true;
      await read(
        watched.uri.toString(),
      ).then<void>((_) {}, onError: (Object _) {});
      expect(failures.single.kind, PlaybackFailureKind.restricted);
      expect(requests.where((r) => r.path == '/ticket'), hasLength(2));
      checkedUpstream();
    } finally {
      await watched.close();
    }
  });
  for (final lan in [false, true]) {
    test('External relay enforces redirect policy (TV: $lan)', () async {
      final stream = lan
          ? ExternalPlaybackStream.lan(
              spec(),
              lanAddress: InternetAddress.loopbackIPv4,
            )
          : ExternalPlaybackStream(spec());
      try {
        await stream.start();
        expect(await read(stream.url), bytes);
        checkedUpstream();
        strippedCredentials();
        forbidden = true;
        requests.clear();
        expect(await read(stream.url), isEmpty);
        expect(requests, hasLength(1));
        checkedUpstream();
      } finally {
        await stream.close();
      }
    });
  }
  test(
    'HLS segments use policy headers and disallowed playlist resources are blocked',
    () async {
      final stream = ExternalPlaybackStream(spec('/playlist.m3u8'));
      try {
        await stream.start();
        final text = String.fromCharCodes(await read(stream.url));
        final local = text.split('\n').firstWhere((s) => s.startsWith('http'));
        expect(await read(local), bytes);
        checkedUpstream();
        strippedCredentials();
        playlistForbidden = true;
        requests.clear();
        expect(await read(stream.url), isEmpty);
        expect(requests, hasLength(1));
        checkedUpstream();
      } finally {
        await stream.close();
      }
    },
  );
  test(
    'Worker preserves non-refreshable policy failures on initial URLs',
    () async {
      final proxy = IsolatedPlaybackStreamProxy(
        DownloadSpec(
          url: 'http://127.0.0.1:${origin.port}/video',
          fileName: 'movie.mkv',
          networkPolicy: policy,
        ),
      );
      try {
        await expectLater(
          proxy.start(),
          throwsA(
            isA<PlaybackFailure>().having(
              (e) => e.kind,
              'kind',
              PlaybackFailureKind.restricted,
            ),
          ),
        );
        expect(requests, isEmpty);
      } finally {
        await proxy.close();
      }
    },
  );
  test('Restricted DASH cannot be handed directly to another player', () async {
    final stream = ExternalPlaybackStream(spec('/video.mpd'));
    try {
      await expectLater(stream.start(), throwsA(isA<AppException>()));
      expect(requests, isEmpty);
      expect(stream.url, isEmpty);
    } finally {
      await stream.close();
    }
  });
  test(
    'An external direct-link handoff cannot bypass signed source permissions',
    () async {
      final controller = PlaybackController(
        entries: const [
          PlaybackEntry(
            id: 'video',
            key: 'video',
            name: 'movie.mkv',
            video: true,
          ),
        ],
        initialIndex: 0,
        history: PlaybackStore(StateStore.memory()),
        prepare: (_, _) async => spec(),
        retain: (_) {},
        release: (_) async {},
        backendFactory: (entry, _) => FakePlaybackBackend(entry.id, []),
      );
      var launched = false;
      try {
        await controller.start();
        await expectLater(
          controller.openExternalPlayer((_, _, _) async {
            launched = true;
            return true;
          }, directLink: true),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('网络权限'),
            ),
          ),
        );
        expect(launched, isFalse);
        expect(controller.state.playing, isTrue);
        expect(controller.playingExternally, isFalse);
        expect(requests, isEmpty);
      } finally {
        await controller.close();
      }
    },
  );
}

void _range(HttpRequest request, Uint8List bytes) {
  final match = RegExp(
    r'bytes=(\d+)-(\d*)',
  ).firstMatch(request.headers.value('Range') ?? '');
  final start = match == null ? 0 : int.parse(match[1]!);
  final end = match == null || match[2]!.isEmpty
      ? bytes.length - 1
      : math.min(bytes.length - 1, int.parse(match[2]!));
  request.response.statusCode = match == null ? 200 : 206;
  request.response.headers.set('ETag', '"stable"');
  if (match != null) {
    request.response.headers.set(
      'Content-Range',
      'bytes $start-$end/${bytes.length}',
    );
  }
  request.response.contentLength = end - start + 1;
  request.response.add(Uint8List.sublistView(bytes, start, end + 1));
}
