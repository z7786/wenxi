import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/uploads/upload_io.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

const _chunk = 8 * 1024 * 1024;
UploadFile _source({bool large = false}) => UploadFile(
  name: 'sample.bin',
  size: large ? _chunk + 5 : 5,
  read: (start, end) async* {
    for (var offset = start; offset < end;) {
      final stop = (offset + 65536).clamp(offset, end);
      if (large && offset < _chunk) {
        final boundary = stop.clamp(offset, _chunk);
        yield Uint8List(boundary - offset)..fillRange(0, boundary - offset, 65);
        offset = boundary;
      } else {
        yield utf8
            .encode('hello')
            .sublist(
              offset - (large ? _chunk : 0),
              stop - (large ? _chunk : 0),
            );
        offset = stop;
      }
    }
  },
);
Future<void> _upload(UploadIO io, {bool pathStyle = false}) => io.s3(
  endpoint: 'https://s3.example.test',
  bucket: 'bucket',
  object: 'folder/测试 +%.txt',
  access: 'fixture-access',
  secret: 'fixture-secret',
  token: 'temporary-session',
  region: 'xunlei',
  pathStyle: pathStyle,
);

void main() {
  final vectors =
      (jsonDecode(
                File(
                  'test/fixtures/s3-upload-signatures.json',
                ).readAsStringSync(),
              )
              as List)
          .map(asJson)
          .toList();
  for (final pathStyle in [false, true]) {
    for (final large in [false, true]) {
      test(
        'S3 signatures match botocore for encoded keys, multipart=$large pathStyle=$pathStyle',
        () async {
          var bytes = 0;
          final http = FakeHttp((r) async {
            final vector = vectors.singleWhere(
              (v) =>
                  v['pathStyle'] == pathStyle &&
                  v['method'] == r.method &&
                  v['url'] == r.url,
            );
            expect(
              r.headers['Authorization'],
              endsWith('Signature=${vector.str('signature')}'),
            );
            expect(r.headers['Cookie'], isNull);
            if (r.body is HttpUpload) {
              final content = await (r.body as HttpUpload)
                  .open()
                  .expand((c) => c)
                  .toList();
              expect(
                r.headers['x-amz-content-sha256'],
                sha256.convert(content).toString(),
              );
              bytes += content.length;
              return HttpResult(200, '', {
                'etag': ['"part-${r.uri.queryParameters['partNumber'] ?? 1}"'],
              });
            }
            if (r.uri.queryParameters.containsKey('uploads')) {
              return const HttpResult(
                200,
                '<InitiateMultipartUploadResult><UploadId>upload/id+=</UploadId></InitiateMultipartUploadResult>',
              );
            }
            expect(r.body, contains('&quot;part-2&quot;'));
            return const HttpResult(
              200,
              '<CompleteMultipartUploadResult><ETag>complete</ETag></CompleteMultipartUploadResult>',
            );
          });
          final source = _source(large: large);
          await _upload(
            UploadIO(
              http,
              source,
              null,
              clock: () => DateTime.utc(2026, 9, 25, 3, 4, 5),
            ),
            pathStyle: pathStyle,
          );
          expect(bytes, source.size);
          expect(http.calls, hasLength(large ? 4 : 1));
        },
      );
    }
  }
  test(
    'S3 completion errors inside HTTP 200 abort the upload instead of succeeding',
    () async {
      final http = FakeHttp((r) async {
        if (r.uri.queryParameters.containsKey('uploads')) {
          return const HttpResult(200, '<UploadId>upload</UploadId>');
        }
        if (r.body is HttpUpload) {
          await (r.body as HttpUpload).open().drain<void>();
          return const HttpResult(200, '', {
            'etag': ['"part"'],
          });
        }
        if (r.method == 'DELETE') return const HttpResult(204, '');
        return const HttpResult(
          200,
          '<Error xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Code>InvalidPart</Code></Error>',
        );
      });
      await expectLater(
        _upload(UploadIO(http, _source(large: true), null)),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.last.method, 'DELETE');
    },
  );
  test(
    'Cancelled multipart upload never reaches its completion request',
    () async {
      final scope = RequestScope();
      final http = FakeHttp((r) async {
        if (r.uri.queryParameters.containsKey('uploads')) {
          return const HttpResult(200, '<UploadId>upload</UploadId>');
        }
        await (r.body as HttpUpload).open().drain<void>();
        scope.cancel();
        return const HttpResult(200, '', {
          'etag': ['"part"'],
        });
      });
      await expectLater(
        scope.run(() => _upload(UploadIO(http, _source(large: true), null))),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.first.method, 'POST');
      expect(http.calls.skip(1).every((r) => r.method == 'PUT'), isTrue);
      expect(
        http.calls.where((r) => r.method == 'PUT').length,
        inInclusiveRange(1, 2),
      );
    },
  );
  for (final mergeSent in [false, true]) {
    test(
      'Multipart cleanup preserves save uncertainty only after merge, merge=$mergeSent',
      () async {
        final delegate = FakeHttp((r) async {
          if (r.uri.queryParameters.containsKey('uploads')) {
            return const HttpResult(200, '<UploadId>upload</UploadId>');
          }
          if (r.method == 'DELETE') {
            // Losing the abort response cannot create a saved user file.
            throw const HttpRequestFailure(
              'abort response lost',
              kind: 'receiveTimeout',
            );
          }
          if (r.body is HttpUpload) {
            await (r.body as HttpUpload).open().drain<void>();
            if (mergeSent || r.uri.queryParameters['partNumber'] == '1') {
              return const HttpResult(200, '', {
                'etag': ['"part"'],
              });
            }
          }
          throw const HttpRequestFailure(
            'response lost',
            kind: 'receiveTimeout',
          );
        });
        final attempt = WriteRequestScope();
        await expectLater(
          attempt.run(
            () => _upload(
              UploadIO(RetryingJsonHttp(delegate), _source(large: true), null),
            ),
          ),
          throwsA(isA<HttpRequestFailure>()),
        );
        expect(attempt.mayHaveWritten, mergeSent);
        expect(delegate.calls.last.method, 'DELETE');
        expect(
          delegate.calls.where(
            (r) =>
                r.method == 'POST' &&
                r.uri.queryParameters.containsKey('uploadId'),
          ),
          hasLength(mergeSent ? 1 : 0),
        );
      },
    );
  }
  test('Lost multipart initialization cannot save a file', () async {
    final delegate = FakeHttp((r) {
      expect(r.method, 'POST');
      expect(r.uri.queryParameters, {'uploads': ''});
      throw const HttpRequestFailure('offline', kind: 'receiveTimeout');
    });
    final attempt = WriteRequestScope();
    await expectLater(
      attempt.run(
        () => _upload(
          UploadIO(RetryingJsonHttp(delegate), _source(large: true), null),
        ),
      ),
      throwsA(isA<HttpRequestFailure>()),
    );
    expect(attempt.mayHaveWritten, isFalse);
    expect(delegate.calls, hasLength(1));
  });
}
