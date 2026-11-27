import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/uploads/upload_io.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

UploadFile _file({int size = 3}) => UploadFile(
  name: 'file.bin',
  size: size,
  read: (start, end) async* {
    for (var offset = start; offset < end; offset += 65536) {
      yield Uint8List((end - offset).clamp(0, 65536));
    }
  },
);
const _offline = HttpRequestFailure(
  'offline',
  kind: 'connectionError',
  retryable: true,
);

void main() {
  for (final wrapped in [false, true]) {
    for (final hint in ['5', 'Mon, 23 Nov 2026 12:00:06 GMT', 'invalid']) {
      test(
        'part Retry-After is respected: wrapped=$wrapped hint=$hint',
        () async {
          final waits = <Duration>[];
          var attempts = 0;
          final http = FakeHttp(
            (r) => ++attempts == 1
                ? HttpResult(503, '', {
                    'retry-after': [hint],
                  })
                : const HttpResult(200, ''),
          );
          final io = UploadIO(
            http,
            _file(),
            null,
            clock: () => DateTime.utc(2026, 11, 23, 12),
          );
          Future<HttpResult> send() => io.send(
            'https://upload.example/part',
            commitsFile: false,
            retry: !wrapped,
          );
          await runZoned(
            () => wrapped ? io.retryPart(send) : send(),
            zoneSpecification: ZoneSpecification(
              createTimer: (self, parent, zone, delay, callback) {
                waits.add(delay);
                return parent.createTimer(zone, Duration.zero, callback);
              },
            ),
          );
          expect(
            waits,
            contains(
              Duration(
                seconds: hint == '5'
                    ? 5
                    : hint == 'invalid'
                    ? 1
                    : 6,
              ),
            ),
          );
          expect(attempts, 2);
        },
      );
    }
  }
  for (final status in [408, 429, 500, 502, 503, 504]) {
    test(
      'temporary PUT part recovers HTTP $status with identical bytes',
      () async {
        final payloads = <List<int>>[];
        final http = FakeHttp((r) async {
          payloads.add(
            await (r.body as HttpUpload).open().expand((b) => b).toList(),
          );
          return HttpResult(payloads.length == 1 ? status : 200, '');
        });
        await UploadIO(
          http,
          _file(),
          null,
        ).send('https://upload.example/part', commitsFile: false);
        expect(payloads, [
          [0, 0, 0],
          [0, 0, 0],
        ]);
      },
    );
  }
  for (final mode in ['permanent', 'direct', 'post', 'disabled', 'cancel']) {
    test('$mode rejection never blindly retries a payload', () async {
      final scope = RequestScope();
      final http = FakeHttp((r) {
        if (mode == 'cancel') scope.cancel();
        return HttpResult(mode == 'permanent' ? 403 : 503, '');
      });
      await expectLater(
        scope.run(
          () => UploadIO(http, _file(), null).send(
            'https://upload.example/part',
            method: mode == 'post' ? 'POST' : 'PUT',
            commitsFile: mode == 'direct',
            retry: mode != 'disabled',
          ),
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls, hasLength(1));
    });
  }
  test('persistent part rejection stops after three attempts', () async {
    final http = FakeHttp((r) => const HttpResult(503, ''));
    await expectLater(
      UploadIO(
        http,
        _file(),
        null,
      ).send('https://upload.example/part', commitsFile: false),
      throwsA(isA<UploadResponseFailure>()),
    );
    expect(http.calls, hasLength(3));
  });

  for (final kind in ['oss', 's3']) {
    test(
      '$kind re-signs only the failed part under the original upload ID',
      () async {
        var clock = DateTime.utc(2026, 11, 23, 12);
        final attempts = <String, int>{}, signatures = <String>[];
        final http = FakeHttp((r) async {
          if (r.uri.queryParameters.containsKey('uploads')) {
            return const HttpResult(200, '<UploadId>same-upload</UploadId>');
          }
          if (r.body is HttpUpload) {
            expect(r.uri.queryParameters['uploadId'], 'same-upload');
            final part = r.uri.queryParameters['partNumber']!;
            final n = attempts.update(part, (n) => n + 1, ifAbsent: () => 1);
            await (r.body as HttpUpload).open().drain<void>();
            if (part == '1') {
              signatures.add(r.headers['Authorization']!);
              if (n == 1) {
                clock = clock.add(const Duration(minutes: 20));
                throw _offline;
              }
              final stamp = kind == 's3'
                  ? r.headers['x-amz-date']!
                  : HttpDate.parse(r.headers['Date']!).toIso8601String();
              expect(stamp, contains(kind == 's3' ? '122000' : '12:20:00'));
            }
            return const HttpResult(200, '', {
              'etag': ['"part"'],
            });
          }
          return const HttpResult(200, '<CompleteMultipartUploadResult/>');
        });
        final io = UploadIO(
          http,
          _file(size: 8 * 1024 * 1024 + 3),
          null,
          clock: () => clock,
        );
        if (kind == 's3') {
          await io.s3(
            endpoint: 'https://s3.example',
            bucket: 'bucket',
            object: 'object',
            access: 'fixture',
            secret: 'fixture-secret',
            region: 'test',
          );
        } else {
          await io.oss(
            endpoint: 'https://oss.example',
            bucket: 'bucket',
            object: 'object',
            access: 'fixture',
            secret: 'fixture-secret',
          );
        }
        expect(attempts, {'1': 2, '2': 1});
        expect(signatures.toSet(), hasLength(2));
        expect(http.calls.where((r) => r.method == 'POST'), hasLength(2));
      },
    );
  }
  test('S3 signing time is sampled after a slow hash read', () async {
    var clock = DateTime.utc(2026, 11, 23, 12);
    final source = UploadFile(
      name: 'file.bin',
      size: 3,
      read: (start, end) async* {
        clock = clock.add(const Duration(minutes: 20));
        yield [0, 0, 0];
      },
    );
    final http = FakeHttp((r) {
      expect(r.headers['x-amz-date'], '20261123T122000Z');
      return const HttpResult(200, '');
    });
    await UploadIO(http, source, null, clock: () => clock).s3(
      endpoint: 'https://s3.example',
      bucket: 'bucket',
      object: 'object',
      access: 'fixture',
      secret: 'fixture-secret',
      region: 'test',
    );
  });

  test(
    'lost confirmation read retries without uploading the file again',
    () async {
      var reads = 0, accepted = '';
      final http = FakeHttp();
      final io = UploadIO(http, _file(), null);
      final write = WriteRequestScope(
        onAcceptedId: (id) async => accepted = id,
      );
      final result = await write.run(
        () => io.confirm(() async {
          if (++reads == 1) throw _offline;
          return [const CloudFile(id: 'saved', name: 'file.bin', size: 3)];
        }, id: 'saved'),
      );
      expect(result.id, 'saved');
      expect(accepted, 'saved');
      expect(reads, 2);
      expect(http.calls, isEmpty);
      expect(write.mayHaveWritten, isTrue);
    },
  );
  for (final kind in ['persistent', 'login', 'cancel']) {
    test(
      'confirmation $kind preserves receipt and has a bounded read budget',
      () async {
        var reads = 0, accepted = '';
        final scope = RequestScope();
        final write = WriteRequestScope(
          onAcceptedId: (id) async => accepted = id,
        );
        await expectLater(
          scope.run(
            () => write.run(
              () => UploadIO(FakeHttp(), _file(), null).confirm(() async {
                reads++;
                if (kind == 'cancel') scope.cancel();
                if (kind == 'login') {
                  throw const AccountLoginRequired('expired');
                }
                throw _offline;
              }, id: 'saved'),
            ),
          ),
          throwsA(isA<AppException>()),
        );
        expect(reads, kind == 'persistent' ? 8 : 1);
        expect(accepted, 'saved');
        expect(write.mayHaveWritten, isTrue);
      },
    );
  }
}
