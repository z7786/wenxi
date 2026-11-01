import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/pan115.dart';
import 'package:asterlink/data/providers/pan115_crypto.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'support.dart';

class _RealHttp extends HttpOverrides {}

// Only the encrypted API response is substituted. Requests still use m115;
// the repository, HTTP Range transport and libmpv all run normally.
class _ResponseCipher extends Pan115Cipher {
  _ResponseCipher(this.response, this.requests);
  final Json Function() response;
  final List<Json> requests;
  @override
  String encode(Json payload) {
    requests.add(Map.of(payload));
    return super.encode(payload);
  }

  @override
  Json decode(String encoded) => response();
}

class _QuietBackend extends MediaKitBackend {
  _QuietBackend() : super(video: false, hardwareAcceleration: false);
  DownloadSpec? openedSource;
  Duration? openedStart;
  @override
  Future<void> open(DownloadSpec source, Duration start) async {
    openedSource = source;
    openedStart = start;
    final native = player.platform as NativePlayer;
    await native.setProperty('ao', 'null');
    await native.setProperty('vo', 'null');
    await native.setProperty('vid', 'auto');
    await super.open(source, start);
  }
}

class _Pan115PlaybackFixture {
  static final credential = Credential('115 fixture A', {
    'primary': 'UID=12345_A1_fixture; CID=fixture-cid; SEID=fixture-seid',
  }, updatedAt: 42);
  late AppServices services;
  late HttpServer server;
  late List<int> bytes;
  late FakeHttp http;
  Json response = {};
  final payloads = <Json>[];
  final requests = <Map<String, String>>[];
  final userAgents = <int, String>{};
  int tickets = 0;
  bool expireFirst = false;
  final pending = <Future<void>>[];
  CloudFile get file => CloudFile(
    id: '987654321098765432',
    name: '115-playback-fixture.mkv',
    parentId: '0',
    token: 'pick1',
    size: bytes.length,
  );

  Future<void> start() async {
    bytes = await File('test/fixtures/player-sample.mkv').readAsBytes();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => pending.add(_serve(request)));
    http = FakeHttp((request) {
      expect(request.headers['Cookie'], credential.primary);
      final path = request.uri.path;
      if (path.endsWith('/downurl')) {
        final ticket = ++tickets;
        final share = path == '/app/share/downurl';
        expect(path, share ? '/app/share/downurl' : '/app/chrome/downurl');
        userAgents[ticket] = request.headers['User-Agent']!;
        final info = {
          'fid': file.id,
          'file_size': bytes.length,
          'pick_code': ticket == 1 ? 'pick1' : 'pick2',
          'url': {
            'url': 'http://127.0.0.1:${server.port}/$ticket/video.mkv?c=2&f=3',
          },
        };
        response = share ? info : {file.id: info};
        return HttpResult(200, '{"state":true,"data":"fixture"}', {
          'set-cookie': [
            'acw_tc=download-$ticket; Path=/; HttpOnly',
            'UID=must-not-reach-cdn; Path=/',
          ],
        });
      }
      final row = {
        'fid': file.id,
        'n': file.name,
        's': bytes.length,
        'pc': 'pick2',
      };
      if (path == '/files') {
        return jsonResponse({
          'state': true,
          'cid': '0',
          'count': 1,
          'data': [row],
        });
      }
      if (path == '/webapi/share/snap') {
        expect(request.uri.queryParameters['share_code'], 'fixture115');
        expect(request.uri.queryParameters['receive_code'], 'a1b2');
        return jsonResponse({
          'state': true,
          'data': {
            'count': 1,
            'list': [row],
          },
        });
      }
      throw StateError('Unexpected 115 API: $path');
    });
    final store = StateStore.memory();
    await Vault(store).putCredential(CloudPlatform.pan115, credential);
    services = AppServices(
      store: store,
      dataDirectory: Directory('test-fixture'),
      cacheDirectory: Directory('test-fixture/cache'),
      transport: FakeNative(),
      files: FakeFiles(Directory('test-fixture')),
      http: http,
      platformFeatures: false,
      controlEnabled: false,
    );
    services.cloud.connectors[CloudPlatform.pan115] = Pan115Connector(
      http,
      cipherFactory: () => _ResponseCipher(() => response, payloads),
    );
  }

  Future<BrowseSession> session(bool share) => share
      ? services.cloud.share(
          LinkParser.parse(
            'https://115cdn.com/s/fixture115?password=a1b2',
          ).single,
        )
      : services.cloud.personal(CloudPlatform.pan115);

  Future<void> _serve(HttpRequest request) async {
    final reply = request.response;
    try {
      final ticket = int.parse(request.uri.pathSegments.first);
      final headers = {
        for (final name in ['user-agent', 'cookie', 'referer', 'range'])
          name: request.headers.value(name) ?? '',
      };
      requests.add(headers);
      if (headers['user-agent'] != userAgents[ticket] ||
          headers['cookie'] != 'acw_tc=download-$ticket' ||
          headers['referer'] != 'https://115.com/' ||
          expireFirst && ticket == 1) {
        reply.statusCode = HttpStatus.forbidden;
        reply.contentLength = 0;
        return;
      }
      final range = RegExp(
        r'^bytes=(\d+)-(\d*)$',
      ).firstMatch(headers['range']!);
      final start = int.tryParse(range?[1] ?? '') ?? 0;
      final end = math.min(
        bytes.length - 1,
        int.tryParse(range?[2] ?? '') ?? bytes.length - 1,
      );
      if (start > end) {
        reply.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        reply.contentLength = 0;
        return;
      }
      reply.headers.set('Content-Type', 'video/x-matroska');
      reply.headers.set('Accept-Ranges', 'bytes');
      reply.headers.set('ETag', '"same-115-fixture"');
      if (range != null) {
        reply.statusCode = HttpStatus.partialContent;
        reply.headers.set('Content-Range', 'bytes $start-$end/${bytes.length}');
      }
      reply.contentLength = end - start + 1;
      if (request.method != 'HEAD') reply.add(bytes.sublist(start, end + 1));
    } catch (_) {
      // Probe cancellation, seeks and teardown can close a response early.
    } finally {
      try {
        await reply.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    await services.close();
    await server.close(force: true);
    await Future.wait(pending);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
    'build/windows/x64/runner/Release/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;

  group(
    '115 playback through real HTTP and libmpv',
    () {
      setUpAll(() => MediaKit.ensureInitialized(libmpv: library));
      late _Pan115PlaybackFixture fixture;
      setUp(() async {
        fixture = _Pan115PlaybackFixture();
        await fixture.start();
      });
      tearDown(() => fixture.close());

      for (final share in [false, true]) {
        final label = share ? 'Share' : 'Personal';
        test(
          '$label video decodes and seeks with its CDN authorization',
          () async {
            final session = await fixture.session(share);
            final controller = cloudPlayback(
              fixture.services,
              session,
              fixture.file,
              [fixture.file],
              backendFactory: (_, _) => _QuietBackend(),
            );
            addTearDown(controller.close);
            await HttpOverrides.runWithHttpOverrides(() async {
              await controller.load(
                0,
                startPosition: const Duration(seconds: 2),
                playWhenReady: false,
              );
              expect(controller.error, isEmpty);
              expect(controller.ready, isTrue);
              expect(controller.state.playing, isFalse);
              expect(controller.resumedFrom, const Duration(seconds: 2));
              final backend = controller.backend! as _QuietBackend;
              expect(backend.openedSource!.maxPlaybackConnections, 2);
              await backend.setConnections(128);
              expect(backend.diagnosticFields['sourceConnectionLimit'], 2);
              expect(backend.diagnosticFields['effectiveConnections'], 2);
              expect(backend.streamingDescription, contains('最多 2 个连接'));
              await controller.play();
              await until(
                () => controller.state.position.inMilliseconds >= 2300,
              );
              await controller.seek(const Duration(seconds: 6));
              await until(
                () => controller.state.position.inMilliseconds >= 5900,
              );
              expect(controller.state.width, 320);
              expect(controller.backend!.failure, isNull);
              expect(fixture.tickets, 1);
              expect(fixture.requests.length, greaterThanOrEqualTo(2));
              expect(
                fixture.requests.every(
                  (r) =>
                      r['cookie'] == 'acw_tc=download-1' &&
                      r['user-agent'] ==
                          (share
                              ? Pan115Connector.shareUa
                              : Pan115Connector.ua) &&
                      r['referer'] == 'https://115.com/' &&
                      r['range']!.startsWith('bytes='),
                ),
                isTrue,
              );
            }, _RealHttp());
          },
        );

        test(
          '$label expired link resumes under its original account',
          () async {
            fixture.expireFirst = true;
            final session = await fixture.session(share);
            final original = session.accountId;
            final backends = <_QuietBackend>[];
            final controller = cloudPlayback(
              fixture.services,
              session,
              fixture.file,
              [fixture.file],
              backendFactory: (_, _) {
                final backend = _QuietBackend();
                backends.add(backend);
                return backend;
              },
            );
            addTearDown(controller.close);
            final vault = fixture.services.vault;
            final other = await vault.createAccount(CloudPlatform.pan115);
            await vault.withAccount(
              CloudPlatform.pan115,
              other,
              () => vault.putCredential(
                CloudPlatform.pan115,
                Credential('115 fixture B', {
                  'primary':
                      'UID=99999_A1_other; CID=other-cid; SEID=other-seid',
                }, updatedAt: 99),
              ),
            );
            await vault.activate(CloudPlatform.pan115, other);
            await HttpOverrides.runWithHttpOverrides(() async {
              await controller.load(
                0,
                startPosition: const Duration(seconds: 3),
              );
              expect(controller.error, isEmpty);
              expect(controller.ready, isTrue);
              await until(
                () => controller.state.position.inMilliseconds >= 3300,
              );
              expect(fixture.tickets, 2);
              expect(backends, hasLength(2));
              expect(backends.last.openedStart, const Duration(seconds: 3));
              expect(backends.last.openedSource!.maxPlaybackConnections, 2);
              expect(controller.state.width, 320);
              final origin = DownloadOrigin.fromJson(
                backends.last.openedSource!.source!,
              );
              expect(origin.session.accountId, original);
              expect(origin.accountRevision, 42);
              expect(vault.activeAccountId(CloudPlatform.pan115), other);
              expect(fixture.requests.last['cookie'], 'acw_tc=download-2');
              expect(
                fixture.payloads.last,
                share
                    ? {
                        'share_code': 'fixture115',
                        'receive_code': 'a1b2',
                        'file_id': fixture.file.id,
                      }
                    : {'pickcode': 'pick2'},
              );
            }, _RealHttp());
          },
        );
      }
    },
    skip: library == null ? 'libmpv is not installed on this host' : false,
  );
}
