import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'support.dart';

class _LocalIo extends HttpOverrides {}

class _FailureAdapter implements HttpClientAdapter {
  _FailureAdapter(
    this.type, {
    this.recover = false,
    this.error = const SocketException('private-address'),
  });
  final DioExceptionType type;
  final bool recover;
  final Object error;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (++calls > 1 && recover) return ResponseBody.fromString('{}', 200);
    throw DioException(
      requestOptions: options,
      type: type,
      message: 'private-cookie private-token ${options.uri}',
      error: error,
    );
  }

  @override
  void close({bool force = false}) {}
}

ReadRetryScope _scope({
  int retries = 3,
  List<Duration>? delays,
  void Function()? checkpoint,
}) => ReadRetryScope(
  retries: retries,
  checkpoint: checkpoint ?? RequestScope.checkpoint,
  wait: (delay) async => delays?.add(delay),
);

void main() {
  for (final peek in [false, true]) {
    test(
      'Preparation retries a truncated ${peek ? 'peek' : 'GET'} response',
      () async {
        HttpOverrides.global = _LocalIo();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var requests = 0;
        server.listen((request) async {
          if (++requests == 1) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{"url":',
            );
            await socket.flush();
            socket.destroy();
          } else {
            request.response.write('{"url":"x"}');
            await request.response.close();
          }
        });
        final dio = Dio();
        addTearDown(() async {
          dio.close(force: true);
          await server.close(force: true);
          HttpOverrides.global = null;
        });
        final http = RetryingJsonHttp(DioJsonHttp(client: dio));
        final url = 'http://127.0.0.1:${server.port}/read';
        final delays = <Duration>[];
        final result = await _scope(
          retries: 1,
          delays: delays,
        ).run(() => peek ? http.peek(url, const {}) : http.get(url));
        expect(result.json.str('url'), 'x');
        expect(requests, 2);
        expect(delays, [const Duration(seconds: 2)]);
      },
    );
  }

  for (final interrupted in [true, false]) {
    test(
      'TLS ${interrupted ? 'connection interruption retries' : 'certificate failure is not retried'}',
      () async {
        final adapter = _FailureAdapter(
          DioExceptionType.unknown,
          recover: true,
          error: interrupted
              ? const HandshakeException(
                  'Connection terminated during handshake',
                )
              : const HandshakeException(
                  'Handshake error in client',
                  OSError('CERTIFICATE_VERIFY_FAILED: private-address'),
                ),
        );
        final dio = Dio()..httpClientAdapter = adapter;
        addTearDown(() => dio.close(force: true));
        final http = RetryingJsonHttp(DioJsonHttp(client: dio));
        final pending = _scope(
          retries: 1,
        ).run(() => http.get('https://example.test/read'));
        if (interrupted) {
          expect((await pending).status, 200);
          expect(adapter.calls, 2);
        } else {
          await expectLater(
            pending,
            throwsA(
              isA<HttpRequestFailure>().having(
                (error) => error.retryable,
                'retryable',
                false,
              ),
            ),
          );
          expect(adapter.calls, 1);
        }
      },
    );
  }

  for (final (message, retryable) in [
    ('Connection closed before full header was received', true),
    ('Invalid header field name', false),
    ('Redirect limit exceeded', false),
  ]) {
    test('Preparation handles HTTP connection error: $message', () async {
      final adapter = _FailureAdapter(
        DioExceptionType.unknown,
        recover: true,
        error: HttpException(
          message,
          uri: Uri.parse('https://private-host.example/?token=private-token'),
        ),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final http = RetryingJsonHttp(DioJsonHttp(client: dio));
      final pending = _scope(
        retries: 1,
      ).run(() => http.get('https://example.test/read'));
      if (retryable) {
        expect((await pending).status, 200);
        expect(adapter.calls, 2);
      } else {
        await expectLater(
          pending,
          throwsA(
            isA<HttpRequestFailure>()
                .having((error) => error.retryable, 'retryable', false)
                .having(
                  (error) => error.toString(),
                  'redacted',
                  isNot(contains('private-')),
                ),
          ),
        );
        expect(adapter.calls, 1);
      }
    });
  }

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.receiveTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.unknown,
  ]) {
    test('Real Dio $type failures retain a safe, retryable category', () async {
      final adapter = _FailureAdapter(type, recover: true);
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final http = RetryingJsonHttp(DioJsonHttp(client: dio));
      final attempts = <ReadRetryAttempt>[];
      final scope = ReadRetryScope(
        retries: 1,
        checkpoint: RequestScope.checkpoint,
        wait: (_) async {},
        onRetry: (attempt) async => attempts.add(attempt),
      );
      final result = await scope.run(
        () => http.get('https://private-host.example/file?token=private-token'),
      );
      expect(result.status, 200);
      expect(adapter.calls, 2);
      expect(attempts.single.failure.kind, type.name);
      expect(attempts.single.failure.retryable, isTrue);
      expect(attempts.single.failure.toString(), isNot(contains('private-')));
    });
  }

  for (final type in [
    DioExceptionType.badCertificate,
    DioExceptionType.cancel,
  ]) {
    test('Real Dio $type failures are not retried', () async {
      final adapter = _FailureAdapter(type);
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final http = RetryingJsonHttp(DioJsonHttp(client: dio));
      await expectLater(
        _scope().run(() => http.get('https://example.test/read')),
        throwsA(
          isA<HttpRequestFailure>().having(
            (e) => e.retryable,
            'retryable',
            false,
          ),
        ),
      );
      expect(adapter.calls, 1);
    });
  }

  for (final status in [408, 425, 429, 500, 502, 503, 504]) {
    test(
      'HTTP $status is retried before attempting to parse its body',
      () async {
        var requests = 0;
        final transport = FakeHttp(
          (_) => ++requests == 1
              ? HttpResult(status, '<html>temporarily unavailable</html>')
              : jsonResponse({'value': 'ready'}),
        );
        final delays = <Duration>[];
        final result = await _scope(delays: delays).run(
          () => RetryingJsonHttp(transport).get('https://example.test/read'),
        );
        expect(result.json['value'], 'ready');
        expect(requests, 2);
        expect(delays, [const Duration(seconds: 2)]);
      },
    );
  }

  test(
    'Retry-After seconds and dates take precedence over normal backoff',
    () async {
      for (final retryAfter in [
        '30',
        HttpDate.format(
          DateTime.now().toUtc().add(const Duration(seconds: 90)),
        ),
      ]) {
        var requests = 0;
        final transport = FakeHttp(
          (_) => ++requests == 1
              ? HttpResult(429, '{}', {
                  'retry-after': [retryAfter],
                })
              : jsonResponse({}),
        );
        final delays = <Duration>[];
        await _scope(delays: delays).run(
          () => RetryingJsonHttp(transport).get('https://example.test/read'),
        );
        expect(delays.single.inSeconds, inInclusiveRange(29, 90));
      }
    },
  );

  test('The retry budget is shared by the entire preparation', () async {
    final counts = <String, int>{};
    final transport = FakeHttp((request) {
      final count = counts.update(
        request.uri.path,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      return request.uri.path == '/first' && count == 2
          ? jsonResponse({})
          : const HttpResult(503, '{}');
    });
    final delays = <Duration>[];
    final http = RetryingJsonHttp(transport);
    await expectLater(
      _scope(retries: 2, delays: delays).run(() async {
        await http.get('https://example.test/first');
        await http.get('https://example.test/second');
      }),
      throwsA(isA<HttpRequestFailure>().having((e) => e.status, 'status', 503)),
    );
    expect(counts, {'/first': 2, '/second': 2});
    expect(delays, [const Duration(seconds: 2), const Duration(seconds: 5)]);
  });

  test(
    'Zero retries and calls outside a preparation each send only once',
    () async {
      final transport = FakeHttp((_) => const HttpResult(503, '{}'));
      final http = RetryingJsonHttp(transport);
      expect((await http.get('https://example.test/plain')).status, 503);
      await expectLater(
        _scope(retries: 0).run(() => http.get('https://example.test/scoped')),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(transport.calls, hasLength(2));
    },
  );

  test(
    'Authentication, access, and missing-file responses are not retried',
    () async {
      for (final status in [400, 401, 403, 404]) {
        final transport = FakeHttp((_) => HttpResult(status, '{}'));
        final response = await _scope().run(
          () => RetryingJsonHttp(transport).get('https://example.test/read'),
        );
        expect(response.status, status);
        expect(transport.calls, hasLength(1));
      }
    },
  );

  test(
    'Mutation POSTs are never replayed, explicitly read-only POSTs recover',
    () async {
      final transport = FakeHttp((_) => const HttpResult(503, '{}'));
      final http = RetryingJsonHttp(transport);
      expect(
        (await _scope().run(
          () => http.postJson('https://example.test/create', {}),
        )).status,
        503,
      );
      await expectLater(
        _scope(
          retries: 1,
        ).run(() => http.postJsonRead('https://example.test/link', {})),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(
        transport.calls.where((r) => r.uri.path == '/create'),
        hasLength(1),
      );
      expect(transport.calls.where((r) => r.uri.path == '/link'), hasLength(2));
    },
  );

  test(
    'A read marker does not make a nested token-refresh POST retryable',
    () async {
      late RetryingJsonHttp http;
      final transport = FakeHttp((request) async {
        if (request.uri.path == '/link') {
          expect(
            (await http.postJson('https://example.test/token', {})).status,
            503,
          );
          return jsonResponse({});
        }
        return const HttpResult(503, '{}');
      });
      http = RetryingJsonHttp(transport);
      await _scope().run(
        () => http.postFormRead('https://example.test/link', 'id=1'),
      );
      expect(transport.calls.map((r) => r.uri.path), ['/link', '/token']);
    },
  );

  test('Bounded probes participate in the same read retry scope', () async {
    var attempts = 0;
    final transport = FakeHttp((request) {
      expect(request.headers['Range'], 'bytes=0-31');
      return ++attempts == 1
          ? const HttpResult(503, '')
          : const HttpResult(206, 'ready');
    });
    final response = await _scope().run(
      () => RetryingJsonHttp(
        transport,
      ).peek('https://example.test/file', {}, maxBytes: 32),
    );
    expect(response.body, 'ready');
    expect(attempts, 2);
  });

  test('Pausing immediately interrupts a long Retry-After wait', () async {
    final transport = FakeHttp(
      (_) => const HttpResult(429, '{}', {
        'retry-after': ['3600'],
      }),
    );
    final waiting = Completer<void>();
    final requestScope = RequestScope();
    final work = requestScope.run(
      () => ReadRetryScope(
        retries: 3,
        checkpoint: RequestScope.checkpoint,
        onRetry: (_) async => waiting.complete(),
      ).run(() => RetryingJsonHttp(transport).get('https://example.test/read')),
    );
    final check = expectLater(work, throwsA(isA<AppException>()));
    await waiting.future;
    requestScope.cancel();
    await check.timeout(const Duration(seconds: 1));
    expect(transport.calls, hasLength(1));
  });

  test('An invalidated account cannot send the next retry', () async {
    var valid = true;
    final transport = FakeHttp((_) => const HttpResult(503, '{}'));
    final scope = ReadRetryScope(
      retries: 3,
      checkpoint: () => require(valid, 'account changed'),
      wait: (_) async => valid = false,
    );
    await expectLater(
      scope.run(
        () => RetryingJsonHttp(transport).get('https://example.test/read'),
      ),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          'account changed',
        ),
      ),
    );
    expect(transport.calls, hasLength(1));
  });
}
