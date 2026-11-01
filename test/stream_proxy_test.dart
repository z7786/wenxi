import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/playback/stream_proxy.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'support.dart';

class _Origin {
  _Origin({int length = 512 * 1024})
    : bytes = Uint8List.fromList(List.generate(length, (i) => i % 251));
  final Uint8List bytes;
  final calls = <(int, int)>[];
  final cookies = <String?>[];
  final authorizations = <String?>[], proxyAuthorizations = <String?>[];
  String etag = '"stable"';
  late HttpServer server;
  int active = 0, peak = 0;
  bool ignoreRange = false, wrongIdentity = false, playlist = false;
  bool truncateFirstRange = false;
  int faults = 0;
  int Function(int start, int end, int attempt)? statusFor;
  Future<void>? firstRangeBarrier;
  Future<void> Function(int start, int end)? rangeBarrier;
  int? firstPacketBytes;
  Future<void>? bodyRemainderBarrier;
  Duration delay = const Duration(milliseconds: 10);
  Uri get uri => Uri.parse(
    'http://127.0.0.1:${server.port}/video.mkv?token=private-test-token',
  );
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      active++;
      peak = math.max(active, peak);
      try {
        request.response.bufferOutput = false;
        final match = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(request.headers.value('range') ?? '')!;
        final start = int.parse(match[1]!),
            end = math.min(bytes.length - 1, int.parse(match[2]!));
        calls.add((start, end));
        cookies.add(request.headers.value('cookie'));
        authorizations.add(request.headers.value('authorization'));
        proxyAuthorizations.add(request.headers.value('proxy-authorization'));
        await Future<void>.delayed(delay);
        await rangeBarrier?.call(start, end);
        if (start == 0 && end > 1023) await firstRangeBarrier;
        final status =
            statusFor?.call(
              start,
              end,
              calls.where((range) => range == (start, end)).length,
            ) ??
            0;
        if (status != 0) {
          faults++;
          request.response.statusCode = status;
          request.response.contentLength = 0;
          await request.response.close();
          return;
        }
        if (ignoreRange) {
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        } else {
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-$end/${bytes.length}',
          );
          request.response.headers.set('Content-Type', 'video/mp4');
          request.response.headers.set(
            'ETag',
            wrongIdentity && end > 1023 ? '"changed"' : etag,
          );
          if (truncateFirstRange && start == 0 && end > 1023) {
            truncateFirstRange = false;
            // A complete chunked response whose Range payload is truncated.
            request.response.add(
              bytes.sublist(start, start + (end - start + 1) ~/ 2),
            );
            await request.response.close();
            return;
          }
          request.response.contentLength = end - start + 1;
          if (playlist) {
            final prefix =
                '#EXTM3U\n#EXTINF:10\nrelative-segment.ts\n'.codeUnits;
            request.response.add([
              ...prefix,
              ...List.filled(end - start + 1 - prefix.length, 32),
            ]);
          } else {
            final prefix = firstPacketBytes;
            if (prefix != null && end - start + 1 > prefix) {
              request.response.add(
                Uint8List.sublistView(bytes, start, start + prefix),
              );
              await request.response.flush();
              await bodyRemainderBarrier;
              request.response.add(
                Uint8List.sublistView(bytes, start + prefix, end + 1),
              );
            } else {
              request.response.add(
                Uint8List.sublistView(bytes, start, end + 1),
              );
            }
          }
        }
        await request.response.close();
      } catch (_) {
        try {
          await request.response.close();
        } catch (_) {}
      } finally {
        active--;
      }
    });
  }

  Future<void> close() async {
    await server.close(force: true);
  }
}

class _TicketDispatcher {
  _TicketDispatcher(this.target);
  final Uri target;
  late HttpServer server;
  int calls = 0, status = HttpStatus.found;
  final cookies = <String?>[], authorizations = <String?>[];
  Future<void>? barrier;
  void Function()? onResolve;
  Uri get uri => Uri.parse('http://127.0.0.1:${server.port}/signed-source');
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      calls++;
      cookies.add(request.headers.value('cookie'));
      authorizations.add(request.headers.value('authorization'));
      try {
        await barrier;
        onResolve?.call();
        request.response.statusCode = status;
        if (status == HttpStatus.found) {
          request.response.headers.set('Location', target.toString());
        }
        request.response.contentLength = 0;
        await request.response.close();
      } catch (_) {
        // Cancellation and teardown can close a pending refresh connection.
      }
    });
  }

  Future<void> close() => server.close(force: true);
}

void main() {
  late _Origin origin;
  late PlaybackStreamProxy proxy;
  late HttpClient client;
  final failures = <PlaybackFailure>[];
  setUp(() async {
    failures.clear();
    origin = _Origin();
    await origin.start();
    proxy = PlaybackStreamProxy(
      DownloadSpec(
        url: origin.uri.toString(),
        fileName: 'movie.mkv',
        headers: const {
          'Cookie': 'fixture=private',
          'Referer': 'https://example.invalid/',
        },
      ),
      connections: 4,
      chunkBytes: 8192,
      maxCacheBytes: 32768,
      onFailure: failures.add,
    );
    client = HttpClient();
  });
  tearDown(() async {
    client.close(force: true);
    await proxy.close();
    await origin.close();
  });
  Future<Uint8List> read(int start, int end) async {
    final request = await client.getUrl(proxy.uri);
    request.headers.set('Range', 'bytes=$start-$end');
    final response = await request.close();
    if (response.statusCode != 206) {
      throw HttpException('Unexpected ${response.statusCode}');
    }
    final builder = BytesBuilder(copy: false);
    await for (final bytes in response) {
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  test(
    'Playback reuses matching downloaded ranges and fetches only holes',
    () async {
      await proxy.close();
      const cacheIdentity = RemoteIdentity(512 * 1024, '"stable"', null);
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 1,
        chunkBytes: 8192,
        maxCacheBytes: 16384,
        readCache: (start, end, identity) async =>
            cacheIdentity.canResume(identity) && end < 8192
            ? Uint8List.sublistView(origin.bytes, start, end + 1)
            : null,
      );
      expect(await proxy.start(), isTrue);
      expect(await read(0, 8191), origin.bytes.sublist(0, 8192));
      expect(origin.calls, [(0, 1023)]);
      expect(await read(8192, 16383), origin.bytes.sublist(8192, 16384));
      expect(origin.calls, [(0, 1023), (8192, 16383)]);
      expect(proxy.diagnosticFields['reusedDownloadBytes'], 8192);
    },
  );

  test(
    'Cache budget can shrink between reads without corrupting later ranges',
    () async {
      expect(await proxy.start(), isTrue);
      expect(await read(0, 32767), origin.bytes.sublist(0, 32768));
      await until(() => proxy.activeRequests == 0);
      expect(proxy.resizeCache(16384), isTrue);
      expect(proxy.bufferedBytes, lessThanOrEqualTo(16384));
      expect(proxy.maxCacheBytes, 16384);
      expect(await read(131072, 147455), origin.bytes.sublist(131072, 147456));
      expect(failures, isEmpty);
      expect(proxy.bufferedBytes, lessThanOrEqualTo(16384));
    },
  );

  test('Shrinking refuses to discard bytes reserved by active reads', () async {
    expect(await proxy.start(), isTrue);
    final gate = Completer<void>();
    origin.firstPacketBytes = 1024;
    origin.bodyRemainderBarrier = gate.future;
    final reading = read(131072, 163839);
    await until(() => proxy.activeRequests >= 2);
    expect(proxy.resizeCache(8192), isFalse);
    expect(proxy.maxCacheBytes, 32768);
    gate.complete();
    expect(await reading, origin.bytes.sublist(131072, 163840));
    expect(failures, isEmpty);
  });

  Future<_TicketDispatcher> useTicketDispatcher({int connections = 4}) async {
    final dispatcher = _TicketDispatcher(origin.uri);
    await dispatcher.start();
    addTearDown(dispatcher.close);
    await proxy.close();
    proxy = PlaybackStreamProxy(
      DownloadSpec(
        url: dispatcher.uri.toString(),
        fileName: 'movie.mkv',
        headers: const {
          'Cookie': 'private=fixture',
          'Authorization': 'Bearer fixture',
          'Proxy-Authorization': 'Basic fixture',
        },
      ),
      connections: connections,
      chunkBytes: 8192,
      maxCacheBytes: 32768,
      onFailure: failures.add,
    );
    expect(await proxy.start(), isTrue);
    return dispatcher;
  }

  for (final status in [401, 403, 404, 410]) {
    test(
      'A rejected CDN ticket ($status) renews through the signed source',
      () async {
        final dispatcher = await useTicketDispatcher();
        expect(await read(0, 8191), origin.bytes.sublist(0, 8192));
        var expired = true;
        origin.statusFor = (_, _, _) => expired ? status : 0;
        dispatcher.onResolve = () => expired = false;
        expect(await read(16384, 24575), origin.bytes.sublist(16384, 24576));
        expect(dispatcher.calls, 2);
        expect(failures, isEmpty);
        expect(dispatcher.cookies, everyElement('private=fixture'));
        expect(dispatcher.authorizations, everyElement('Bearer fixture'));
        expect(origin.cookies, everyElement(isNull));
        expect(origin.authorizations, everyElement(isNull));
        expect(origin.proxyAuthorizations, everyElement(isNull));
      },
    );
  }

  test(
    'Concurrent rejected ranges share ticket renewal, including later expiry',
    () async {
      final dispatcher = await useTicketDispatcher();
      var expired = true;
      origin.statusFor = (_, _, _) => expired ? 403 : 0;
      final gate = Completer<void>();
      dispatcher.barrier = gate.future;
      dispatcher.onResolve = () => expired = false;
      final first = read(16384, 24575);
      final second = read(32768, 40959);
      try {
        await until(() => origin.faults == 2 && dispatcher.calls >= 2);
        gate.complete();
        final bytes = await Future.wait([first, second]);
        expect(bytes[0], origin.bytes.sublist(16384, 24576));
        expect(bytes[1], origin.bytes.sublist(32768, 40960));
        expect(dispatcher.calls, 2);
        expired = true;
        expect(await read(49152, 57343), origin.bytes.sublist(49152, 57344));
        expect(dispatcher.calls, 3);
        expect(failures, isEmpty);
        expect(proxy.bufferedBytes, lessThanOrEqualTo(proxy.maxCacheBytes));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await Future.wait([
          first.then<void>((_) {}, onError: (Object _) {}),
          second.then<void>((_) {}, onError: (Object _) {}),
        ]);
      }
    },
  );

  test(
    'Renewing a ticket still rejects a changed file before serving bytes',
    () async {
      final dispatcher = await useTicketDispatcher(connections: 1);
      var expired = true;
      origin.statusFor = (_, _, _) => expired ? 403 : 0;
      dispatcher.onResolve = () {
        expired = false;
        origin.etag = '"different-file"';
      };
      await expectLater(read(16384, 24575), throwsA(isA<HttpException>()));
      expect(dispatcher.calls, 2);
      expect(failures.single.kind, PlaybackFailureKind.changed);
      expect(proxy.diagnosticFields['servedBytes'], 0);
    },
  );

  test('An expired signed source stops renewal after one attempt', () async {
    final dispatcher = await useTicketDispatcher(connections: 1);
    origin.statusFor = (_, _, _) => 403;
    dispatcher.status = 403;
    await expectLater(read(16384, 24575), throwsA(isA<HttpException>()));
    expect(dispatcher.calls, 2);
    expect(failures.single.kind, PlaybackFailureKind.expired);
  });

  test(
    'A short read followed by ticket expiry resumes only the missing bytes',
    () async {
      final dispatcher = await useTicketDispatcher(connections: 1);
      origin.truncateFirstRange = true;
      origin.statusFor = (start, _, _) =>
          start == 4096 && dispatcher.calls == 1 ? 403 : 0;
      expect(await read(0, 8191), origin.bytes.sublist(0, 8192));
      expect(dispatcher.calls, 2);
      expect(origin.calls.where((range) => range == (0, 8191)), hasLength(1));
      expect(
        origin.calls.where((range) => range == (4096, 8191)),
        hasLength(2),
      );
      expect(failures, isEmpty);
    },
  );

  test(
    'Incremental playback receives a verified prefix before the rest of a segment arrives',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      StreamIterator<List<int>>? body;
      try {
        final request = await client.getUrl(proxy.uri);
        request.headers.set('Range', 'bytes=0-32767');
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        body = StreamIterator(response);
        expect(
          await body.moveNext().timeout(const Duration(seconds: 2)),
          isTrue,
        );
        final bytes = <int>[...body.current];
        expect(bytes, origin.bytes.sublist(0, 1024));
        expect(proxy.diagnosticFields['completedSegments'], 0);
        gate.complete();
        while (await body.moveNext()) {
          bytes.addAll(body.current);
        }
        expect(bytes, origin.bytes.sublist(0, 32768));
        expect(failures, isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await body?.cancel();
      }
    },
  );

  test(
    'Footer metadata reads only the requested tail instead of a whole preceding segment',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final start = origin.bytes.length - 128, end = origin.bytes.length - 1;
      try {
        expect(
          await read(start, end).timeout(const Duration(seconds: 2)),
          origin.bytes.sublist(start),
        );
        expect(origin.calls, [(0, 1023), (start, end)]);
        expect(proxy.generation, 0);
      } finally {
        gate.complete();
      }
    },
  );

  test(
    'An expired URL during the Range probe preserves its status instead of falling back silently',
    () async {
      origin.statusFor = (_, _, _) => 403;
      await expectLater(
        proxy.start(),
        throwsA(
          isA<PlaybackFailure>()
              .having((e) => e.kind, 'kind', PlaybackFailureKind.expired)
              .having((e) => e.status, 'status', 403),
        ),
      );
      expect(proxy.supported, isFalse);
      expect(origin.calls, hasLength(1));
      expect(proxy.diagnosticFields['probeResult'], 'http_error');
      expect(proxy.diagnosticFields['probeStatus'], 403);
    },
  );

  test(
    'A demanded expired segment reports an actionable source failure once',
    () async {
      expect(await proxy.start(), isTrue);
      origin.statusFor = (_, _, _) => 403;
      await expectLater(read(0, 7000), throwsA(isA<HttpException>()));
      expect(failures.single.status, 403);
      expect(failures.single.refreshable, isTrue);
      expect(origin.calls.where((range) => range == (0, 7000)), hasLength(1));
      expect(proxy.diagnosticFields['upstreamStatus'], 403);
      expect(proxy.diagnosticFields['segmentFailures'], 1);
      expect(proxy.diagnosticFields['servedBytes'], 0);
    },
  );

  test(
    'Diagnostics distinguish waiting for an upstream segment from failed or delivered data without exposing its source',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      origin.firstRangeBarrier = gate.future;
      final pending = read(0, 8191);
      await until(() => origin.calls.length == 2);
      final waiting = proxy.diagnosticFields;
      expect(waiting['probeResult'], 'ready');
      expect(waiting['probeStatus'], 206);
      expect(waiting['requests'], 1);
      expect(waiting['activeRequests'], 1);
      expect(waiting['upstreamAttempts'], 1);
      expect(waiting['completedSegments'], 0);
      expect(waiting['segmentFailures'], 0);
      expect(waiting['servedBytes'], 0);
      gate.complete();
      expect(await pending, origin.bytes.sublist(0, 8192));
      await until(() => proxy.diagnosticFields['servedBytes'] == 8192);
      final delivered = proxy.diagnosticFields;
      expect(delivered['completedSegments'], 1);
      expect(delivered['upstreamStatus'], 206);
      expect(delivered['segmentFailures'], 0);
      final serialized = jsonEncode(delivered);
      for (final secret in [
        'private-test-token',
        'fixture=private',
        'movie.mkv',
        '127.0.0.1',
        'example.invalid',
      ]) {
        expect(serialized, isNot(contains(secret)));
      }
    },
  );

  for (final truncated in [false, true]) {
    test(
      '${truncated ? 'A truncated Range body' : 'A temporary HTTP 503'} retries once and yields exact bytes',
      () async {
        expect(await proxy.start(), isTrue);
        if (truncated) {
          origin.truncateFirstRange = true;
        } else {
          origin.statusFor = (start, _, attempt) =>
              start == 0 && attempt == 1 ? 503 : 0;
        }
        expect(await read(0, 64000), origin.bytes.sublist(0, 64001));
        expect(
          origin.calls.where((range) => range == (0, 8191)),
          hasLength(truncated ? 1 : 2),
        );
        if (truncated) {
          expect(
            origin.calls.where((range) => range == (4096, 8191)),
            hasLength(1),
          );
        }
        expect(failures, isEmpty);
      },
    );
  }

  test(
    'A changed validator on a resumed partial body never appends bytes from the replacement',
    () async {
      expect(await proxy.start(), isTrue);
      origin.truncateFirstRange = true;
      origin.statusFor = (start, _, _) {
        if (start == 4096) origin.wrongIdentity = true;
        return 0;
      };
      await expectLater(read(0, 64000), throwsA(isA<HttpException>()));
      expect(origin.calls, contains((4096, 8191)));
      expect(failures.single.kind, PlaybackFailureKind.changed);
    },
  );

  test(
    'Footer metadata preempts speculative work within a two-connection limit',
    () async {
      proxy.connections = 2;
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final playback = read(
        0,
        origin.bytes.length - 1,
      ).then<Object>((value) => value, onError: (Object error) => error);
      try {
        await until(() => proxy.activeRequests == 2);
        final start = origin.bytes.length - 128;
        expect(
          await read(
            start,
            origin.bytes.length - 1,
          ).timeout(const Duration(seconds: 2)),
          origin.bytes.sublist(start),
        );
        expect(proxy.activeRequests, lessThanOrEqualTo(2));
        expect(proxy.bufferedBytes, lessThanOrEqualTo(proxy.maxCacheBytes));
        expect(proxy.generation, 0);
        expect(failures, isEmpty);
      } finally {
        gate.complete();
        await playback;
      }
    },
  );

  test(
    'Partial delivery expands the connection window before its first segment completes',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 4,
        chunkBytes: 65536,
        maxCacheBytes: 262144,
        warmupBytes: 4096,
      );
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 8192;
      origin.bodyRemainderBarrier = gate.future;
      final transfer = read(0, origin.bytes.length - 1);
      try {
        await until(
          () => proxy.activeRequests == 4 && origin.peak == 4,
          timeout: const Duration(seconds: 2),
        );
        expect(proxy.diagnosticFields['completedSegments'], 0);
        expect(
          proxy.diagnosticFields['servedBytes'],
          greaterThanOrEqualTo(4096),
        );
        expect(proxy.bufferedBytes, lessThanOrEqualTo(262144));
        expect(origin.peak, 4);
      } finally {
        gate.complete();
        expect(await transfer, origin.bytes);
      }
    },
  );

  test(
    'A seek after a partial delivery cancels old bytes while the new range stays exact',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final playback = read(
        0,
        origin.bytes.length - 1,
      ).then<Object>((value) => value, onError: (Object error) => error);
      try {
        await until(() => (proxy.diagnosticFields['servedBytes'] as int) > 0);
        proxy.prepareSeek();
        origin.firstPacketBytes = null;
        expect(
          await read(300000, 330000),
          origin.bytes.sublist(300000, 330001),
        );
        expect(
          await playback.timeout(const Duration(seconds: 2)),
          isA<HttpException>(),
        );
        expect(proxy.generation, 1);
        expect(failures, isEmpty);
      } finally {
        gate.complete();
      }
    },
  );

  test(
    'A failed speculative segment followed by a seek does not report a playback failure',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstRangeBarrier = gate.future;
      origin.statusFor = (start, _, _) => start == 8192 ? 403 : 0;
      final pending = read(
        0,
        64000,
      ).then<Object>((bytes) => bytes, onError: (Object error) => error);
      await until(() => origin.faults == 1);
      expect(failures, isEmpty);
      proxy.prepareSeek();
      final sought = read(300000, 330000);
      await until(() => proxy.generation == 1);
      gate.complete();
      expect(await sought, origin.bytes.sublist(300000, 330001));
      await pending;
      expect(failures, isEmpty);
    },
  );

  test(
    'Parallel ranges reconstruct exact bytes, bound the cache and protect origin credentials',
    () async {
      expect(await proxy.start(), isTrue);
      expect(proxy.uri.host, '127.0.0.1');
      expect(proxy.uri.toString(), isNot(contains('private-test-token')));
      final result = await read(5000, 180000);
      expect(result, origin.bytes.sublist(5000, 180001));
      expect(origin.peak, greaterThan(1));
      expect(origin.peak, lessThanOrEqualTo(4));
      expect(proxy.cachedBytes, lessThanOrEqualTo(32768));
      expect(origin.cookies, everyElement('fixture=private'));
      final count = origin.calls.length;
      expect(await read(172100, 175000), origin.bytes.sublist(172100, 175001));
      expect(
        origin.calls.length,
        count,
        reason: 'A nearby seek reuses bounded cached segments',
      );
      final request = await client.getUrl(
        proxy.uri.replace(path: '/untrusted'),
      );
      final response = await request.close();
      expect(response.statusCode, 403);
      expect(response.headers.value('cookie'), isNull);
      expect(response.headers.value('location'), isNull);
      await response.drain<void>();
      expect(origin.calls.length, count);
    },
  );

  test('HEAD, suffix ranges and invalid ranges obey the file length', () async {
    expect(await proxy.start(), isTrue);
    final head = await (await client.headUrl(proxy.uri)).close();
    expect(head.contentLength, origin.bytes.length);
    await head.drain<void>();
    expect(origin.calls.length, 1);
    final suffix = await client.getUrl(proxy.uri);
    suffix.headers.set('Range', 'bytes=-127');
    final response = await suffix.close();
    final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes, origin.bytes.sublist(origin.bytes.length - 127));
    for (final range in [
      'bytes=2-1',
      'bytes=99999999-',
      'bytes=0-1,3-4',
      'bytes=-0',
    ]) {
      final request = await client.getUrl(proxy.uri);
      request.headers.set('Range', range);
      final invalid = await request.close();
      expect(invalid.statusCode, 416);
      await invalid.drain<void>();
    }
  });

  test(
    'Pausing stops new requests after the small in-flight window; resuming completes',
    () async {
      expect(await proxy.start(), isTrue);
      final transfer = read(0, origin.bytes.length - 1);
      await until(() => origin.calls.length >= 5);
      proxy.setPaused(true);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final paused = origin.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(origin.calls.length, paused);
      expect(paused * 8192, lessThan(origin.bytes.length));
      expect(proxy.cachedBytes, lessThanOrEqualTo(proxy.maxCacheBytes));
      proxy.setPaused(false);
      expect(await transfer, origin.bytes);
    },
  );

  test(
    'Distant concurrent media ranges remain exact without cancelling each other',
    () async {
      expect(await proxy.start(), isTrue);
      origin.delay = const Duration(milliseconds: 50);
      final first = read(0, origin.bytes.length - 1);
      await until(() => origin.calls.length > 1);
      final second = await read(400000, 420000);
      expect(second, origin.bytes.sublist(400000, 420001));
      expect(await first, origin.bytes);
      expect(proxy.generation, 0);
      expect(origin.peak, lessThanOrEqualTo(4));
      expect(proxy.cachedBytes, lessThanOrEqualTo(proxy.maxCacheBytes));
    },
  );

  test(
    'Distant open-ended audio and video reads both finish within the shared budget',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstRangeBarrier = gate.future;
      final video = read(0, origin.bytes.length - 1);
      try {
        await until(() => origin.calls.length > 1);
        final audio = read(400000, origin.bytes.length - 1);
        await until(() => proxy.diagnosticFields['readers'] == 2);
        expect(proxy.generation, 0);
        expect(proxy.bufferedBytes, lessThanOrEqualTo(proxy.maxCacheBytes));
        gate.complete();
        final results = await Future.wait([video, audio]);
        expect(results[0], origin.bytes);
        expect(results[1], origin.bytes.sublist(400000));
        expect(proxy.generation, 0);
        expect(origin.peak, lessThanOrEqualTo(4));
        expect(failures, isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'A reopened nearby range reuses its partial chunk after a distant audio read',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final socket = await Socket.connect(proxy.uri.host, proxy.uri.port);
      var received = 0;
      final incoming = socket.listen((bytes) => received += bytes.length);
      try {
        socket.write(
          'GET ${proxy.uri.path} HTTP/1.1\r\n'
          'Host: ${proxy.uri.host}\r\n'
          'Range: bytes=65536-\r\n\r\n',
        );
        await socket.flush();
        await until(() => received > 1024);
        socket.destroy();
        await until(() => proxy.diagnosticFields['readers'] == 0);
        expect(proxy.activeRequests, greaterThan(0));
        expect(
          await read(400000, 400511),
          origin.bytes.sublist(400000, 400512),
        );
        final nearby = read(66560, 71536);
        await until(() => proxy.diagnosticFields['interleavedReads'] == true);
        expect(proxy.generation, 0);
        expect(proxy.bufferedBytes, lessThanOrEqualTo(proxy.maxCacheBytes));
        gate.complete();
        expect(await nearby, origin.bytes.sublist(66560, 71537));
        expect(origin.calls.where((r) => r.$1 == 66560), isEmpty);
        expect(origin.calls.where((r) => r == (65536, 73727)), hasLength(1));
        expect(failures, isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        socket.destroy();
        await incoming.cancel();
      }
    },
  );

  test(
    'A disconnected demuxer read releases blocked ranges before their bodies arrive',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      final requested = Completer<void>();
      origin.rangeBarrier = (start, end) async {
        if (end > 1023) {
          if (!requested.isCompleted) requested.complete();
          await gate.future;
        }
      };
      final socket = await Socket.connect(proxy.uri.host, proxy.uri.port);
      try {
        socket.write(
          'GET ${proxy.uri.path} HTTP/1.1\r\n'
          'Host: ${proxy.uri.host}\r\n'
          'Range: bytes=0-\r\n\r\n',
        );
        await socket.flush();
        await requested.future;
        expect(proxy.activeRequests, greaterThan(0));
        socket.destroy();
        await until(() => proxy.activeRequests == 0);
        expect(proxy.diagnosticFields['readers'], 0);
        expect(proxy.diagnosticFields['queuedSegments'], 0);
        expect(proxy.bufferedBytes, 0);
        origin.rangeBarrier = null;
        expect(
          await read(400000, 410000),
          origin.bytes.sublist(400000, 410001),
        );
        expect(failures, isEmpty);
      } finally {
        socket.destroy();
        gate.complete();
      }
    },
  );

  test(
    'Closing a paused reader cancels blocked work and drops cached media',
    () async {
      expect(await proxy.start(), isTrue);
      final transfer = read(
        0,
        origin.bytes.length - 1,
      ).then<Object>((data) => data, onError: (Object e) => e);
      await until(() => origin.calls.length > 1);
      proxy.setPaused(true);
      await proxy.close().timeout(const Duration(seconds: 2));
      await transfer.timeout(const Duration(seconds: 2));
      expect(proxy.cachedBytes, 0);
      expect(proxy.supported, isFalse);
    },
  );

  test(
    'A changed resource is rejected instead of splicing ranges from different files',
    () async {
      expect(await proxy.start(), isTrue);
      origin.wrongIdentity = true;
      await expectLater(read(0, 64000), throwsA(isA<HttpException>()));
      expect(proxy.cachedBytes, 0);
    },
  );

  test(
    'Servers ignoring Range and playlists use the original playback path',
    () async {
      origin.ignoreRange = true;
      expect(await proxy.start(), isFalse);
      expect(proxy.supported, isFalse);
      await proxy.close();
      origin.ignoreRange = false;
      origin.playlist = true;
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'stream'),
      );
      expect(await proxy.start(), isFalse);
      expect(proxy.supported, isFalse);
    },
  );

  test(
    'Closing during the probe cannot create an orphaned local server',
    () async {
      origin.delay = const Duration(milliseconds: 300);
      final opening = proxy.start();
      await until(() => origin.calls.isNotEmpty);
      await proxy.close();
      expect(await opening, isFalse);
      expect(proxy.supported, isFalse);
    },
  );

  test(
    'Concurrent header and tail probes share work without retiring playback',
    () async {
      expect(await proxy.start(), isTrue);
      origin.delay = const Duration(milliseconds: 35);
      final playback = read(0, 180000);
      await until(() => origin.calls.length >= 2);
      final header = read(0, 1023);
      final tail = read(origin.bytes.length - 512, origin.bytes.length - 1);
      final results = await Future.wait([playback, header, tail]);
      expect(results[0], origin.bytes.sublist(0, 180001));
      expect(results[1], origin.bytes.sublist(0, 1024));
      expect(results[2], origin.bytes.sublist(origin.bytes.length - 512));
      expect(proxy.generation, 0);
      expect(origin.calls.where((range) => range == (0, 8191)), hasLength(1));
      expect(origin.peak, lessThanOrEqualTo(4));
    },
  );

  test(
    'Warmup uses two requests, then concurrent demand ramps to the configured budget',
    () async {
      await proxy.close();
      await origin.close();
      origin = _Origin(length: 8 * 1024 * 1024);
      await origin.start();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 8,
        chunkBytes: 256 * 1024,
        maxCacheBytes: 3 * 1024 * 1024,
      );
      expect(await proxy.start(), isTrue);
      origin.delay = const Duration(milliseconds: 30);
      final transfer = read(0, origin.bytes.length - 1);
      await until(() => origin.calls.length == 3);
      expect(origin.peak, 2);
      expect(proxy.activeRequests, 2);
      expect(await transfer, origin.bytes);
      expect(origin.peak, greaterThan(2));
      expect(origin.peak, lessThanOrEqualTo(8));
    },
  );

  test(
    'A slow leading range does not leave free connections idle before the cache is full',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 2,
        chunkBytes: 8192,
        maxCacheBytes: 65536,
        warmupBytes: 0,
      );
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstRangeBarrier = gate.future;
      final transfer = read(0, origin.bytes.length - 1);
      try {
        await until(() => proxy.diagnosticFields['completedSegments'] == 7);
        expect(proxy.activeRequests, 1);
        expect(proxy.bufferedBytes, 65536);
        expect(origin.peak, lessThanOrEqualTo(2));
        final filled = origin.calls.length;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(origin.calls.length, filled);
        gate.complete();
        expect(await transfer, origin.bytes);
        final ranges = origin.calls.where((range) => range.$2 > 1023).toList();
        expect(ranges, hasLength(origin.bytes.length ~/ 8192));
        expect(ranges.toSet(), hasLength(ranges.length));
        expect(proxy.bufferedBytes, lessThanOrEqualTo(65536));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await transfer;
      }
    },
  );

  test(
    'Increasing connections dispatches new ranges while the current bodies are still arriving',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 2,
        chunkBytes: 8192,
        maxCacheBytes: 65536,
        warmupBytes: 0,
      );
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final transfer = read(131072, 450559);
      try {
        await until(() => proxy.activeRequests == 2);
        proxy.connections = 4;
        await until(() => origin.peak == 4);
        expect(proxy.activeRequests, 4);
        expect(proxy.diagnosticFields['completedSegments'], 0);
        expect(proxy.bufferedBytes, lessThanOrEqualTo(65536));
        gate.complete();
        expect(await transfer, origin.bytes.sublist(131072, 450560));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await transfer;
      }
    },
  );

  test(
    'Signed source cap bounds parallel reads after runtime thread changes',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(
          url: origin.uri.toString(),
          fileName: 'movie.mkv',
          maxPlaybackConnections: 2,
        ),
        connections: 8,
        chunkBytes: 8192,
        maxCacheBytes: 65536,
        warmupBytes: 0,
        onFailure: failures.add,
      );
      expect(proxy.connections, 2);
      expect(await proxy.start(), isTrue);
      origin.statusFor = (_, _, _) => origin.active > 2 ? 403 : 0;
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final transfer = read(131072, 450559);
      try {
        await until(() => proxy.activeRequests == 2);
        proxy.connections = 128;
        expect(proxy.connections, 2);
        gate.complete();
        expect(await transfer, origin.bytes.sublist(131072, 450560));
        expect(origin.peak, 2);
        expect(origin.faults, 0);
        expect(failures, isEmpty);
        expect(proxy.segmentFailures, 0);
        proxy.connections = 1;
        expect(proxy.connections, 1);
        proxy.connections = 8;
        expect(proxy.connections, 2);
        expect(await read(0, 32767), origin.bytes.sublist(0, 32768));
        expect(
          await read(458752, 491519),
          origin.bytes.sublist(458752, 491520),
        );
        expect(origin.peak, 2);
        expect(origin.faults, 0);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await transfer;
      }
    },
  );

  test(
    'An unaligned seek starts at the requested byte on a slow capped source',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(
          url: origin.uri.toString(),
          fileName: 'movie.mkv',
          maxPlaybackConnections: 2,
        ),
        connections: 8,
        chunkBytes: 8192,
        maxCacheBytes: 65536,
        onFailure: failures.add,
      );
      expect(await proxy.start(), isTrue);
      const start = 139000, end = 450559;
      final gate = Completer<void>();
      origin.rangeBarrier = (first, _) async {
        if (first < start) await gate.future;
      };
      proxy.prepareSeek();
      final transfer = read(start, end);
      try {
        expect(
          await transfer.timeout(const Duration(seconds: 3)),
          origin.bytes.sublist(start, end + 1),
        );
        expect(origin.calls[1], (start, 139263));
        expect(
          origin.calls.skip(1).every((range) => range.$1 >= start),
          isTrue,
        );
        expect(origin.peak, lessThanOrEqualTo(2));
        expect(failures, isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await transfer;
      }
    },
  );

  test(
    'Reducing concurrency keeps partially downloaded ranges for later consumption',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 4,
        chunkBytes: 8192,
        maxCacheBytes: 65536,
        warmupBytes: 0,
      );
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final transfer = read(0, origin.bytes.length - 1);
      try {
        await until(() => proxy.receivedBytes >= 4 * 1024);
        proxy.connections = 1;
        gate.complete();
        expect(await transfer, origin.bytes);
        final ranges = origin.calls.where((range) => range.$2 > 1023).toList();
        expect(ranges.toSet(), hasLength(ranges.length));
        expect(proxy.bufferedBytes, lessThanOrEqualTo(65536));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await transfer;
      }
    },
  );

  test(
    'Cache resizing preserves data when blocked and keeps nearby ready ranges when it succeeds',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 4,
        chunkBytes: 8192,
        maxCacheBytes: 65536,
        warmupBytes: 0,
      );
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.rangeBarrier = (start, end) async {
        if (start == 0 && end > 1023 || start == 8192) await gate.future;
      };
      final transfer = read(0, origin.bytes.length - 1);
      try {
        await until(() => proxy.diagnosticFields['completedSegments'] == 6);
        expect(proxy.bufferedBytes, 65536);
        expect(proxy.resizeCache(8192), isFalse);
        expect(proxy.maxCacheBytes, 65536);
        expect(proxy.cachedBytes, 6 * 8192);
        expect(proxy.resizeCache(32768), isTrue);
        expect(proxy.bufferedBytes, 32768);
        gate.complete();
        expect(await transfer, origin.bytes);
        // The two nearest completed ranges were retained during repartition.
        for (final start in [16384, 24576]) {
          expect(
            origin.calls.where((range) => range == (start, start + 8191)),
            hasLength(1),
          );
        }
        expect(proxy.bufferedBytes, lessThanOrEqualTo(32768));
      } finally {
        if (!gate.isCompleted) gate.complete();
        await transfer;
      }
    },
  );

  test(
    'The byte budget includes in-flight segments even at 128 configured connections',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 128,
        chunkBytes: 8192,
        maxCacheBytes: 32768,
        warmupBytes: 0,
      );
      expect(proxy.connections, 128);
      proxy.connections = 96;
      expect(proxy.connections, 96);
      expect(await proxy.start(), isTrue);
      var peakBytes = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        peakBytes = math.max(peakBytes, proxy.bufferedBytes);
      });
      addTearDown(timer.cancel);
      expect(await read(0, origin.bytes.length - 1), origin.bytes);
      timer.cancel();
      expect(peakBytes, greaterThan(0));
      expect(peakBytes, lessThanOrEqualTo(32768));
      expect(origin.peak, lessThanOrEqualTo(4));
    },
  );

  test(
    'High connection limits dispatch beyond 32 when the byte budget allows',
    () async {
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(url: origin.uri.toString(), fileName: 'movie.mkv'),
        connections: 128,
        chunkBytes: 8192,
        maxCacheBytes: 64 * 8192,
        warmupBytes: 0,
      );
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.rangeBarrier = (start, end) async {
        if (end > 1023) await gate.future;
      };
      final transfer = read(0, origin.bytes.length - 1);
      try {
        await until(() => origin.active > 32);
        expect(origin.peak, greaterThan(32));
        expect(proxy.bufferedBytes, lessThanOrEqualTo(64 * 8192));
      } finally {
        gate.complete();
        expect(await transfer, origin.bytes);
      }
    },
  );

  test(
    'A new metadata request cannot silently resume a paused stream',
    () async {
      expect(await proxy.start(), isTrue);
      final transfer = read(0, origin.bytes.length - 1);
      await until(() => origin.calls.length >= 4);
      proxy.setPaused(true);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      final count = origin.calls.length;
      final tail = read(origin.bytes.length - 128, origin.bytes.length - 1);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(origin.calls.length, count);
      proxy.setPaused(false);
      expect(await tail, origin.bytes.sublist(origin.bytes.length - 128));
      expect(await transfer, origin.bytes);
    },
  );

  test(
    'An explicit seek supersedes pending data when a replacement range arrives',
    () async {
      expect(await proxy.start(), isTrue);
      origin.delay = const Duration(milliseconds: 40);
      final old = read(
        0,
        origin.bytes.length - 1,
      ).then<Object>((bytes) => bytes, onError: (Object error) => error);
      await until(() => origin.calls.length > 1);
      proxy.prepareSeek();
      expect(proxy.generation, 0);
      expect(await read(300000, 330000), origin.bytes.sublist(300000, 330001));
      expect(await old, isA<HttpException>());
      expect(proxy.generation, 1);
      expect(proxy.bufferedBytes, lessThanOrEqualTo(proxy.maxCacheBytes));
    },
  );

  test(
    'A cached seek preserves the existing stream when mpv makes no replacement request',
    () async {
      expect(await proxy.start(), isTrue);
      final gate = Completer<void>();
      origin.firstPacketBytes = 1024;
      origin.bodyRemainderBarrier = gate.future;
      final playback = read(0, 64000);
      try {
        await until(() => (proxy.diagnosticFields['servedBytes'] as int) > 0);
        proxy.prepareSeek();
        expect(proxy.generation, 0);
        expect(proxy.activeRequests, greaterThan(0));
        gate.complete();
        expect(await playback, origin.bytes.sublist(0, 64001));
        expect(failures, isEmpty);
        expect(proxy.generation, 0);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test(
    'A paused cached seek does not spend a preview window on the old stream',
    () async {
      expect(await proxy.start(), isTrue);
      final playback = read(
        0,
        origin.bytes.length - 1,
      ).then<Object>((value) => value, onError: (Object error) => error);
      await until(() => origin.calls.length >= 3);
      proxy.setPaused(true);
      await until(() => proxy.activeRequests == 0);
      final previous = origin.calls.length;
      proxy.prepareSeek();
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(origin.calls.length, previous);
      expect(await read(300000, 301000), origin.bytes.sublist(300000, 301001));
      expect(await playback, isA<HttpException>());
      expect(failures, isEmpty);
    },
  );

  test(
    'Redirects to another origin strip cookie and authorization before probing and streaming',
    () async {
      final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => redirect.close(force: true));
      redirect.listen((request) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set('Location', origin.uri.toString());
        await request.response.close();
      });
      await proxy.close();
      proxy = PlaybackStreamProxy(
        DownloadSpec(
          url: 'http://127.0.0.1:${redirect.port}/video',
          fileName: 'movie.mkv',
          headers: const {
            'Cookie': 'private=fixture',
            'Authorization': 'Bearer fixture',
          },
        ),
        chunkBytes: 8192,
        maxCacheBytes: 32768,
      );
      expect(await proxy.start(), isTrue);
      expect(await read(5000, 50000), origin.bytes.sublist(5000, 50001));
      expect(origin.cookies, everyElement(isNull));
    },
  );
}
