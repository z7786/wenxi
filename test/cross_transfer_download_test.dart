import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/transfer/cross_transfer_relay.dart';
import 'support.dart';

class _LocalIo extends HttpOverrides {}

class _Drive extends CloudConnector {
  _Drive(this.url, this.size);
  String url;
  final int size;
  int preparations = 0;
  String? checksum;
  String profile = 'weiyun';
  int? maximum;
  @override
  CloudPlatform get platform => CloudPlatform.weiyun;
  @override
  Future<BrowseSession> openPersonal(Credential credential) async =>
      const BrowseSession(
        platform: CloudPlatform.weiyun,
        mode: BrowseMode.personal,
        title: 'source',
        rootId: '0',
      );
  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parent,
    Credential? credential,
  ) async => [
    CloudFile(
      id: 'source-file',
      name: 'file.bin',
      size: size,
      parentId: '0',
      modifiedAt: 'fixture-v1',
    ),
  ];
  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    preparations++;
    return DownloadSpec(
      url: url,
      fileName: f.name,
      expectedSize: size,
      profile: profile,
      maxPlaybackConnections: maximum,
      checksumType: checksum == null ? null : 'sha256',
      checksumValue: checksum,
      headers: {
        'User-Agent': 'AsterLink-relay-test',
        'X-Fixture': 'relay-test-only',
      },
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Transport extends DesktopGopeedTransport {
  _Transport(String superExecutable) : super(executable: superExecutable);
  final begins = <Json>[];
  final removed = <String>[];
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'begin') begins.add(Map.of(args));
    if (method == 'remove') removed.add(args.str('id'));
    return super.call(method, args);
  }
}

void main() {
  final executable = gopeedTestExecutable();
  group(
    'cross transfer uses ordinary native download policy',
    () {
      late Directory root, cache;
      late HttpServer server;
      late _Transport transport;
      late GopeedEngine engine;
      late CrossTransferRelay relay;
      late TransferHttp http;
      late _Drive drive;
      late CloudRepository cloud;
      late BrowseSession session;
      late CloudFile file;
      late AppSettings options;
      final bytes = Uint8List.fromList(
        List.generate(4 * 1024 * 1024, (i) => (i * 17 + i ~/ 53) % 251),
      );
      final requests = <(String, int, int)>[];
      final handlers = <Future<void>>{};
      late Completer<void> release;
      var hold = false, ranges = true, etag = '"fixture-v1"';
      var active = 0,
          maximumActive = 0,
          expired = false,
          contentType = 'application/octet-stream';
      var firstRangeReads = 0, uploads = 0, downloaded = 0;

      Future<void> handle(HttpRequest request) async {
        final response = request.response;
        var counted = false;
        try {
          expect(request.headers.value('x-fixture'), 'relay-test-only');
          expect(request.headers.value('user-agent'), 'AsterLink-relay-test');
          if (expired && request.uri.path == '/file') {
            drive.url = 'http://127.0.0.1:${server.port}/fresh';
            response.statusCode = 403;
            return;
          }
          var first = 0, last = bytes.length - 1;
          final header = request.headers.value('range');
          if (header != null && ranges) {
            final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header)!;
            first = int.parse(match.group(1)!);
            last = int.tryParse(match.group(2)!) ?? last;
            response.statusCode = 206;
            response.headers.set(
              'Content-Range',
              'bytes $first-$last/${bytes.length}',
            );
          }
          response.headers.set('Content-Type', contentType);
          response.headers.set('ETag', etag);
          response.contentLength = last - first + 1;
          requests.add((request.uri.path, first, last));
          var nextByte = first;
          if (last - first > 1) {
            // An ignored probe range can still be closing when the transfer
            // starts. Count only transfer requests as download connections.
            if (header != 'bytes=0-0') {
              counted = true;
              active++;
              maximumActive = maximumActive < active ? active : maximumActive;
              if (first == 0) firstRangeReads++;
            }
            // The engine shares the first response's redirect after headers.
            // Hold the body only so every range can establish its connection.
            response.bufferOutput = false;
            response.add(bytes.sublist(first, first + 1));
            await response.flush();
            nextByte++;
            if (hold && first > 0) await release.future;
            // Keep range requests in flight together to measure concurrency.
            await Future<void>.delayed(const Duration(milliseconds: 80));
          }
          response.add(bytes.sublist(nextByte, last + 1));
        } on HttpException {
          // Probes and cancelled ranges close their connections.
        } on SocketException {
          // Probes and cancelled ranges close their connections.
        } finally {
          if (counted) active--;
          try {
            await response.close();
          } catch (_) {}
        }
      }

      setUp(() async {
        HttpOverrides.global = _LocalIo();
        root = await Directory.systemTemp.createTemp('aster-cross-native-');
        cache = Directory(p.join(root.path, 'relay'));
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        requests.clear();
        hold = false;
        ranges = true;
        expired = false;
        contentType = 'application/octet-stream';
        etag = '"fixture-v1"';
        active = maximumActive = firstRangeReads = uploads = downloaded = 0;
        release = Completer<void>();
        server.listen((request) {
          final pending = handle(request);
          handlers.add(pending);
          unawaited(pending.whenComplete(() => handlers.remove(pending)));
        });
        final store = StateStore.memory(), vault = Vault(store);
        await vault.putCredential(
          CloudPlatform.weiyun,
          Credential('source', {'primary': 'fixture'}, updatedAt: 1),
        );
        final jsonHttp = FakeHttp();
        cloud = CloudRepository(
          jsonHttp,
          vault,
          CleanupOutbox(store, jsonHttp),
        );
        drive = _Drive('http://127.0.0.1:${server.port}/file', bytes.length);
        cloud.connectors[drive.platform] = drive;
        session = cloud.bindSession(
          const BrowseSession(
            platform: CloudPlatform.weiyun,
            mode: BrowseMode.personal,
            title: 'source',
            rootId: '0',
          ),
        );
        file = CloudFile(
          id: 'source-file',
          name: 'file.bin',
          size: bytes.length,
          parentId: '0',
          modifiedAt: 'fixture-v1',
        );
        options = const AppSettings(threadOverrides: {'weiyun': 4}, retries: 0);
        transport = _Transport(executable);
        engine = GopeedEngine(
          transport,
          store,
          vault,
          Directory(p.join(root.path, 'native')),
          Directory(p.join(root.path, 'native-cache')),
        );
        http = TransferHttp();
        relay = CrossTransferRelay(
          cloud: cloud,
          http: http,
          cache: cache,
          engine: engine,
          settings: () => options,
          availableSpace: (_) async => 1 << 40,
        );
        relay.retainTasks(['task']);
      });

      tearDown(() async {
        if (!release.isCompleted) release.complete();
        await engine.close();
        http.dio.close(force: true);
        await server.close(force: true);
        await Future.wait(handlers.toList());
        await root.delete(recursive: true);
        HttpOverrides.global = null;
      });

      Future<void> transfer({bool failUpload = false}) => relay.transfer<void>(
        session,
        file,
        taskId: 'task',
        entryId: 'entry',
        expectedMd5: null,
        onProgress: (received, total) {
          downloaded = received;
        },
        upload: (payload, digest) async {
          final got = await payload.openRead().fold<BytesBuilder>(
            BytesBuilder(copy: false),
            (all, part) => all..add(part),
          );

          expect(sha256.convert(got.takeBytes()), sha256.convert(bytes));
          expect(digest, md5.convert(bytes).toString());
          expect(
            payload.verifiedHashes['sha1'],
            sha1.convert(bytes).toString(),
          );
          uploads++;
          if (failUpload) throw const AppException('fixture upload failed');
        },
      );

      Future<void> waitForPartial(RequestScope scope) async {
        try {
          await until(() => downloaded >= bytes.length ~/ 4);
        } catch (_) {
          scope.cancel();
          if (!release.isCompleted) release.complete();
          throw StateError(
            'No partial progress: $downloaded, requests=$requests, begins=${transport.begins}',
          );
        }
      }

      test(
        'provider override produces parallel ranges and passes speed/retry settings',
        () async {
          options = const AppSettings(
            threads: 7,
            threadOverrides: {'weiyun': 4},
            retries: 2,
            speedLimit: 2 * 1024 * 1024,
          );
          await transfer();
          expect(transport.begins.single['connections'], 4);
          expect(transport.begins.single['connectionProfile'], 'weiyun');
          expect(transport.begins.single['retries'], 2);
          expect(transport.begins.single['speedLimit'], 2 * 1024 * 1024);
          expect(maximumActive, greaterThan(1));
          expect(uploads, 1);
          expect(await cache.list().toList(), isEmpty);
          expect(
            await engine.cache
                .list()
                .where((f) => p.basename(f.path).startsWith('cross-'))
                .toList(),
            isEmpty,
          );
        },
      );

      test(
        'global inherited configuration and declared upstream limit are respected',
        () async {
          options = const AppSettings(
            threads: 3,
            threadOverrides: {'weiyun': 0},
            retries: 0,
          );
          drive.maximum = 2;
          await transfer();
          expect(transport.begins.single['connections'], 2);
          expect(maximumActive, lessThanOrEqualTo(2));
        },
      );

      test('default Xunlei profile is passed as eight connections', () async {
        drive.profile = 'xunlei';
        options = const AppSettings(retries: 0);
        await transfer();
        expect(transport.begins.single['connections'], 8);
        expect(transport.begins.single['connectionProfile'], 'xunlei');
      });

      test(
        'expired download URL refresh follows the configured retry budget',
        () async {
          expired = true;
          options = const AppSettings(
            threadOverrides: {'weiyun': 2},
            retries: 1,
          );
          await transfer();
          expect(drive.preparations, 2);
          expect(transport.begins.single['url'], endsWith('/fresh'));
          expect(uploads, 1);
        },
      );

      test('zero retries does not refresh an expired download URL', () async {
        expired = true;
        await expectLater(transfer(), throwsA(isA<AppException>()));
        expect(drive.preparations, 1);
        expect(transport.begins, isEmpty);
        expect(uploads, 0);
      });

      test('no Range support falls back to a complete single stream', () async {
        ranges = false;
        await transfer();
        expect(maximumActive, 1);
        expect(uploads, 1);
      });

      test(
        'cancel preserves checkpoint and resumes completed ranges after restart',
        () async {
          hold = true;
          final scope = RequestScope();
          final pending = scope.run(() => transfer());
          final failure = expectLater(pending, throwsA(isA<AppException>()));
          await waitForPartial(scope);
          scope.cancel();
          await failure;
          final readsBefore = firstRangeReads;
          expect(uploads, 0);
          expect(await cache.list().toList(), isNotEmpty);
          final checkpoint =
              (await cache
                          .list(recursive: true)
                          .where(
                            (v) =>
                                v is File && v.path.endsWith('download.json'),
                          )
                          .toList())
                      .single
                  as File;
          final saved = await checkpoint.readAsString();
          expect(saved, isNot(contains(drive.url)));
          expect(saved, isNot(contains('X-Fixture')));
          await engine.close();
          transport = _Transport(executable);
          engine = GopeedEngine(
            transport,
            engine.store,
            engine.vault,
            engine.storage,
            engine.cache,
          );
          relay = CrossTransferRelay(
            cloud: cloud,
            http: http,
            cache: cache,
            engine: engine,
            settings: () => options,
          );
          relay.retainTasks(['task']);
          hold = false;
          release.complete();
          await transfer();
          expect(firstRangeReads, readsBefore);
          expect(uploads, 1);
          expect(await cache.list().toList(), isEmpty);
        },
      );

      test(
        'changed remote identity restarts instead of mixing old and new ranges',
        () async {
          hold = true;
          final scope = RequestScope();
          final pending = scope.run(() => transfer());
          final failure = expectLater(pending, throwsA(isA<AppException>()));
          await waitForPartial(scope);
          scope.cancel();
          await failure;
          final readsBefore = firstRangeReads;
          etag = '"fixture-v2"';
          hold = false;
          release.complete();
          await transfer();
          expect(firstRangeReads, greaterThan(readsBefore));
          expect(uploads, 1);
        },
      );

      test(
        'verified file is reused after upload failure without redownload',
        () async {
          await expectLater(
            transfer(failUpload: true),
            throwsA(isA<AppException>()),
          );
          final before = requests.length;
          await transfer();
          expect(requests.length, before);
          expect(uploads, 2);
          expect(await cache.list().toList(), isEmpty);
        },
      );

      test('corrupt verified payload is downloaded again', () async {
        await expectLater(
          transfer(failUpload: true),
          throwsA(isA<AppException>()),
        );
        final payload =
            (await cache
                        .list(recursive: true)
                        .where(
                          (v) => v is File && p.basename(v.path) == 'payload',
                        )
                        .toList())
                    .single
                as File;
        await payload.writeAsBytes(List.filled(bytes.length, 0));
        final before = requests.length;
        await transfer();
        expect(requests.length, greaterThan(before));
        expect(uploads, 2);
      });

      test(
        'clearing a cancelled task removes native checkpoint and payload',
        () async {
          hold = true;
          final scope = RequestScope();
          final pending = scope.run(() => transfer());
          final failure = expectLater(pending, throwsA(isA<AppException>()));
          await waitForPartial(scope);
          scope.cancel();
          await failure;
          await relay.clearTask('task');
          expect(await cache.list().toList(), isEmpty);
          expect(
            await engine.cache
                .list()
                .where((f) => p.basename(f.path).startsWith('cross-'))
                .toList(),
            isEmpty,
          );
          expect(transport.removed, contains(transport.begins.single['id']));
        },
      );

      test(
        'checksum mismatch does not upload and clears all download state',
        () async {
          drive.checksum = '0' * 64;
          await expectLater(transfer(), throwsA(isA<AppException>()));
          expect(uploads, 0);
          expect(await cache.list().toList(), isEmpty);
          expect(
            await engine.cache
                .list()
                .where((f) => p.basename(f.path).startsWith('cross-'))
                .toList(),
            isEmpty,
          );
        },
      );

      test('login HTML is rejected before native download', () async {
        contentType = 'text/html';
        await expectLater(transfer(), throwsA(isA<AppException>()));
        expect(transport.begins, isEmpty);
        expect(uploads, 0);
      });
    },
    skip: !Platform.isWindows || !File(executable).existsSync(),
  );
}
