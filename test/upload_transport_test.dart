import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/uploads/upload_io.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:crypto/crypto.dart';
import 'support.dart';

class _Network extends HttpOverrides {}

void main() {
  test(
    'Write tracking excludes reads and requests that were never sent',
    () async {
      for (final requestNotSent in [true, false]) {
        final delegate = FakeHttp((r) {
          throw HttpRequestFailure(
            'network failure',
            kind: 'connectionError',
            retryable: true,
            requestNotSent: requestNotSent,
          );
        });
        final http = RetryingJsonHttp(delegate), attempt = WriteRequestScope();
        await expectLater(
          attempt.run(() => http.postJsonRead('https://example.test/list', {})),
          throwsA(isA<HttpRequestFailure>()),
        );
        expect(attempt.mayHaveWritten, isFalse);
        await expectLater(
          attempt.run(() => http.postJson('https://example.test/create', {})),
          throwsA(isA<HttpRequestFailure>()),
        );
        expect(attempt.mayHaveWritten, !requestNotSent);
      }
    },
  );
  test(
    'Explicit rejection and temporary preflight leave a write retryable',
    () async {
      final delegate = FakeHttp(
        (r) => HttpResult(r.uri.path == '/create' ? 200 : 429, '{}'),
      );
      final http = RetryingJsonHttp(delegate), attempt = WriteRequestScope();
      await attempt.run(() async {
        await http.mutationRequest('GET', 'https://example.test/init');
        expect(attempt.mayHaveWritten, isFalse);
        await http.postJson('https://example.test/create', {});
        expect(attempt.mayHaveWritten, isTrue);
        attempt.notSavedYet();
        expect(attempt.mayHaveWritten, isFalse);
      });
    },
  );
  test(
    'Intermediate payload can retry while a final payload stays uncertain',
    () async {
      final file = UploadFile(
        name: 'parts.bin',
        size: 6,
        read: (start, end) => Stream.value(List.filled(end - start, 1)),
      );
      for (final finalPart in [false, true]) {
        final delegate = FakeHttp((r) {
          if (r.uri.path == '/init') return const HttpResult(200, '{}');
          throw const HttpRequestFailure(
            'response lost',
            kind: 'receiveTimeout',
          );
        });
        final http = RetryingJsonHttp(delegate), attempt = WriteRequestScope();
        await expectLater(
          attempt.run(() async {
            await http.postJson('https://example.test/init', {});
            await UploadIO(http, file, null).send(
              'https://example.test/payload',
              method: 'POST',
              start: finalPart ? 3 : 0,
              end: finalPart ? 6 : 3,
              retry: false,
            );
          }),
          throwsA(isA<HttpRequestFailure>()),
        );
        expect(attempt.mayHaveWritten, finalPart);
      }
    },
  );
  test(
    'Successful payload does not replay an uncertain final commit',
    () async {
      final delegate = FakeHttp((r) {
        if (r.uri.path == '/commit') {
          throw const HttpRequestFailure(
            'response lost',
            kind: 'receiveTimeout',
          );
        }
        return const HttpResult(200, '{}');
      });
      final http = RetryingJsonHttp(delegate), attempt = WriteRequestScope();
      final file = UploadFile(
        name: 'file.bin',
        size: 3,
        read: (_, _) => Stream.value([1, 2, 3]),
      );
      await expectLater(
        attempt.run(() async {
          final io = UploadIO(http, file, null);
          await io.send('https://example.test/payload');
          io.notSavedYet();
          await http.postJson('https://example.test/commit', {});
        }),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(attempt.mayHaveWritten, isTrue);
      expect(
        delegate.calls.where((r) => r.uri.path == '/commit'),
        hasLength(1),
      );
    },
  );
  test(
    'An uncommitted last multipart part stays retryable until final merge',
    () async {
      final file = UploadFile(
        name: 'multipart.bin',
        size: 6,
        read: (start, end) => Stream.value(List.filled(end - start, 1)),
      );
      final delegate = FakeHttp((r) {
        if (r.uri.path == '/init') return const HttpResult(200, '{}');
        throw const HttpRequestFailure('response lost', kind: 'receiveTimeout');
      });
      final http = RetryingJsonHttp(delegate), attempt = WriteRequestScope();
      await expectLater(
        attempt.run(() async {
          await http.postJson('https://example.test/init', {});
          await UploadIO(http, file, null).send(
            'https://example.test/part',
            start: 3,
            end: 6,
            commitsFile: false,
            retry: false,
          );
        }),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(attempt.mayHaveWritten, isFalse);
      expect(delegate.calls.where((r) => r.uri.path == '/part'), hasLength(1));
      await expectLater(
        attempt.run(() => http.postJson('https://example.test/merge', {})),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(attempt.mayHaveWritten, isTrue);
    },
  );
  test('Lost temporary authorization leaves the write retryable', () async {
    final delegate = FakeHttp((r) {
      throw const HttpRequestFailure('offline', kind: 'receiveTimeout');
    });
    final attempt = WriteRequestScope(), http = RetryingJsonHttp(delegate);
    final file = UploadFile(
      name: 'temporary.bin',
      size: 3,
      read: (_, _) => const Stream.empty(),
    );
    await expectLater(
      attempt.run(
        () => UploadIO(
          http,
          file,
          null,
        ).temporary(() => http.postJson('https://example.test/authorize', {})),
      ),
      throwsA(isA<HttpRequestFailure>()),
    );
    expect(attempt.mayHaveWritten, isFalse);
    expect(delegate.calls, hasLength(1));
  });
  test(
    'Accepted ID is retained before failed directory confirmation',
    () async {
      var accepted = '';
      final attempt = WriteRequestScope(
        onAcceptedId: (id) async => accepted = id,
      );
      final file = UploadFile(
        name: 'saved.bin',
        size: 3,
        read: (_, _) => const Stream.empty(),
      );
      await expectLater(
        attempt.run(
          () => UploadIO(FakeHttp(), file, null).confirm(
            () async =>
                throw const HttpRequestFailure('offline', kind: 'network'),
            id: 'saved-id',
          ),
        ),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(accepted, 'saved-id');
      expect(attempt.mayHaveWritten, isTrue);
    },
  );
  test('Only an unestablished connection makes a POST upload replayable', () {
    final options = RequestOptions(path: 'https://upload.example/file');
    final tls = HttpRequestFailure.network(
      DioException(
        requestOptions: options,
        error: const HandshakeException(
          'Connection terminated during handshake',
        ),
      ),
    );
    final reset = HttpRequestFailure.network(
      DioException(
        requestOptions: options,
        error: const SocketException('Connection reset during upload'),
      ),
    );
    expect(tls.requestNotSent, true);
    expect(reset.requestNotSent, false);
  });
  test(
    'POST uploads retry TLS establishment but never replay an ambiguous write',
    () async {
      for (final requestNotSent in [true, false]) {
        var attempts = 0, reads = 0;
        final http = FakeHttp((r) async {
          if (attempts++ == 0) {
            throw HttpRequestFailure(
              'network failure',
              kind: 'network',
              retryable: true,
              requestNotSent: requestNotSent,
            );
          }
          await (r.body as HttpUpload).open().drain<void>();
          return jsonResponse({'ok': true});
        });
        final file = UploadFile(
          name: 'sample.txt',
          size: 3,
          read: (start, end) async* {
            reads++;
            yield [1, 2, 3];
          },
        );
        final request = UploadIO(
          http,
          file,
          null,
        ).send('https://upload.example/file', method: 'POST', fields: const {});
        if (requestNotSent) {
          expect((await request).json['ok'], true);
          expect(attempts, 2);
          expect(reads, 1);
        } else {
          await expectLater(request, throwsA(isA<HttpRequestFailure>()));
          expect(attempts, 1);
          expect(reads, 0);
        }
      }
    },
  );
  test(
    'Plain JSON remains parseable and streamed uploads preserve exact bytes',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final http = DioJsonHttp();
        final uploaded = <List<int>>[];
        server.listen((request) async {
          uploaded.add(
            await request.fold<List<int>>([], (a, b) => a..addAll(b)),
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'ok': true, 'method': request.method}),
          );
          await request.response.close();
        });
        final address = 'http://127.0.0.1:${server.port}/upload';
        try {
          expect((await http.get(address)).json, {'ok': true, 'method': 'GET'});
          final bytes = List.generate(131099, (i) => i % 256);
          final file = UploadFile(
            name: 'test.bin',
            size: bytes.length,
            read: (start, end) async* {
              for (var i = start; i < end; i += 8192) {
                yield bytes.sublist(i, (i + 8192).clamp(i, end));
              }
            },
          );
          final io = UploadIO(http, file, null);
          expect(await io.digest(md5), md5.convert(bytes).toString());
          expect(await io.digest(sha1), sha1.convert(bytes).toString());
          expect(
            (await io.send(
              address,
              start: 13,
              end: bytes.length - 7,
            )).json['ok'],
            true,
          );
          expect(uploaded.last, bytes.sublist(13, bytes.length - 7));
          await io.send(address, method: 'POST', fields: {'name': 'value'});
          final multipart = latin1.decode(uploaded.last);
          expect(multipart, contains('name="name"'));
          expect(multipart, contains('filename="test.bin"'));
          expect(multipart.contains(latin1.decode(bytes)), true);
        } finally {
          http.dio.close(force: true);
          await server.close(force: true);
        }
      }, _Network());
    },
  );

  test('Short local reads fail before a caller can commit an upload', () async {
    final source = UploadFile(
      name: 'changed.txt',
      size: 3,
      read: (a, b) => Stream.value([1, 2]),
    );
    await expectLater(
      source.openRead().drain<void>(),
      throwsA(isA<AppException>()),
    );
  });

  test(
    'Cancellation and account guards stop subsequent upload requests',
    () async {
      final scope = RequestScope()..cancel();
      final http = DioJsonHttp();
      try {
        await expectLater(
          scope.run(() => http.postJson('http://127.0.0.1:1/commit', {})),
          throwsA(isA<AppException>()),
        );
        await expectLater(
          RequestScope.guarded(
            () => http.postJson('http://127.0.0.1:1/commit', {}),
            () => throw const AppException('账号已变化'),
          ),
          throwsA(isA<AppException>()),
        );
      } finally {
        http.dio.close(force: true);
      }
    },
  );
}
