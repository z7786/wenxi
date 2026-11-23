import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/quark_uc.dart';
import 'package:asterlink/data/uploads/upload_io.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

class _UploadFixture {
  _UploadFixture({
    this.platform = CloudPlatform.quark,
    this.size = 12,
    this.partSize = 4,
    this.concurrent = 1,
    this.date = '',
    this.preMime = 'application/octet-stream',
  });
  final CloudPlatform platform;
  final int size, partSize, concurrent;
  final String date, preMime;
  int authorizationCount = 0, merges = 0, finishes = 0;
  final attempts = <int, int>{};
  final ranges = <(int, int)>[];
  final signatures = <String, String>{};
  Future<HttpResult> Function(RecordedRequest)? authResponse;
  Future<HttpResult> Function(RecordedRequest, int, int)? partResponse;
  Future<HttpResult> Function(RecordedRequest)? mergeResponse;
  late final http = FakeHttp((request) async {
    if (request.uri.path.endsWith('file/upload/pre')) {
      return HttpResult(
        200,
        jsonEncode({
          'status': 200,
          'metadata': {'part_size': partSize, 'part_thread': concurrent},
          'data': {
            'task_id': 'fixture-task',
            'bucket': 'fixture-bucket',
            'obj_key': 'fixture/path',
            'upload_id': 'fixture-upload',
            'upload_url': 'https://oss.example',
            'auth_info': 'fixture-auth',
            'format_type': preMime,
            'callback': {'callbackUrl': 'https://callback.example'},
          },
        }),
        {
          if (date.isNotEmpty) 'date': [date],
        },
      );
    }
    if (request.uri.path.endsWith('file/update/hash')) {
      return jsonResponse({
        'status': 200,
        'data': {'finish': false},
      });
    }
    if (request.uri.path.endsWith('file/upload/auth')) {
      final key = 'fixture-${++authorizationCount}';
      signatures[key] = request.json.str('auth_meta');
      if (authResponse != null) return authResponse!(request);
      return jsonResponse({
        'status': 200,
        'data': {'auth_key': key},
      });
    }
    if (request.body is HttpUpload) {
      final part = int.parse(request.uri.queryParameters['partNumber']!);
      final attempt = attempts.update(
        part,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      final meta = signatures[request.headers['Authorization']]!;
      expect(meta, contains('PUT\n\n$preMime\n'));
      expect(meta, contains('x-oss-date:${request.headers['x-oss-date']}\n'));
      expect(meta, endsWith('?partNumber=$part&uploadId=fixture-upload'));
      expect(request.headers['Content-Type'], preMime);
      final upload = request.body as HttpUpload;
      final start = (part - 1) * partSize;
      final length = (size - start).clamp(0, partSize);
      expect(upload.length, length);
      var sent = 0;
      await for (final bytes in upload.open()) {
        sent += bytes.length;
      }
      expect(sent, length);
      upload.onProgress?.call(sent, sent);
      if (partResponse != null) return partResponse!(request, part, attempt);
      return HttpResult(200, '', {
        'etag': ['"part-$part"'],
      });
    }
    if (request.uri.host == 'fixture-bucket.oss.example') {
      merges++;
      if (mergeResponse != null) return mergeResponse!(request);
      return const HttpResult(200, '');
    }
    if (request.uri.path.endsWith('file/upload/finish')) {
      finishes++;
      return jsonResponse({'status': 200, 'data': {}});
    }
    expect(request.uri.path, endsWith('file/sort'));
    return jsonResponse({
      'status': 200,
      'data': {
        'list': [
          {'fid': 'saved', 'file_name': 'file.bin', 'size': size, 'dir': false},
        ],
      },
    });
  });

  Future<CloudFile> upload({
    List<UploadProgress>? progress,
    UploadFile? source,
  }) {
    final block = Uint8List(65536);
    final file = UploadFile(
      name: 'file.bin',
      size: size,
      mimeType: 'video/mp4',
      verifiedHashes: {
        'md5': size <= 12 ? md5.convert(Uint8List(size)).toString() : '0' * 32,
        'sha1': size <= 12
            ? sha1.convert(Uint8List(size)).toString()
            : '0' * 40,
      },
      read: (start, end) async* {
        ranges.add((start, end));
        for (var offset = start; offset < end; offset += block.length) {
          yield Uint8List.sublistView(
            block,
            0,
            (end - offset).clamp(0, block.length),
          );
        }
      },
    );
    return QuarkUcConnector(platform, RetryingJsonHttp(http)).upload(
      BrowseSession(
        platform: platform,
        mode: BrowseMode.personal,
        title: 'Files',
        rootId: '0',
      ),
      '0',
      source ?? file,
      Credential('fixture', {'primary': 'fixture-cookie'}),
      onProgress: progress?.add,
    );
  }
}

void main() {
  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    test(
      '$platform creates its upload session only after hashing finishes',
      () async {
        final fixture = _UploadFixture(platform: platform);
        final reading = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        final bytes = Uint8List.fromList(List.generate(12, (i) => i));
        final source = UploadFile(
          name: 'file.bin',
          size: bytes.length,
          read: (start, end) async* {
            if (!reading.isCompleted) {
              reading.complete();
              await release.future;
            }
            yield bytes.sublist(start, end);
          },
        );
        final pending = fixture.upload(source: source);
        await reading.future;
        final callsWhileReading = fixture.http.calls.length;
        release.complete();
        expect((await pending).id, 'saved');
        expect(callsWhileReading, 0);
        final hashes = fixture.http.calls
            .singleWhere((r) => r.uri.path.endsWith('file/update/hash'))
            .json;
        expect(hashes['md5'], md5.convert(bytes).toString());
        expect(hashes['sha1'], sha1.convert(bytes).toString());
      },
    );
  }

  for (final failure in ['unreadable', 'cancelled']) {
    test('$failure local hash does not create an upload session', () async {
      final fixture = _UploadFixture();
      final scope = RequestScope();
      final source = UploadFile(
        name: 'file.bin',
        size: 12,
        read: (start, end) async* {
          if (failure == 'cancelled') {
            scope.cancel();
            yield Uint8List(end - start);
          } else {
            throw const AppException('本地文件不可读');
          }
        },
      );
      await expectLater(
        scope.run(() => fixture.upload(source: source)),
        throwsA(isA<AppException>()),
      );
      expect(fixture.http.calls, isEmpty);
    });
  }

  test(
    '430 MiB upload keeps exact ranges, valid part numbers and ETag order',
    () async {
      final fixture = _UploadFixture(
        size: 430 * 1024 * 1024,
        partSize: 4 * 1024 * 1024,
        concurrent: 3,
      );
      final progress = <UploadProgress>[];
      expect((await fixture.upload(progress: progress)).id, 'saved');
      expect(fixture.attempts.length, 108);
      expect(fixture.attempts.values.every((value) => value == 1), isTrue);
      expect(
        fixture.ranges,
        contains((107 * 4 * 1024 * 1024, 430 * 1024 * 1024)),
      );
      expect(
        fixture.ranges.fold<int>(0, (sum, range) => sum + range.$2 - range.$1),
        fixture.size,
      );
      expect(fixture.merges, 1);
      expect(fixture.finishes, 1);
      expect(progress.last.sent, fixture.size);
      for (var i = 1; i < progress.length; i++) {
        if (progress[i].phase == UploadPhase.uploading &&
            progress[i - 1].phase == UploadPhase.uploading) {
          expect(progress[i].sent, greaterThanOrEqualTo(progress[i - 1].sent));
        }
      }
    },
  );

  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    test(
      '$platform uses server time, MIME and single-part concurrency advice',
      () async {
        final fixture = _UploadFixture(
          platform: platform,
          date: 'Wed, 01 Jan 2020 12:00:00 GMT',
          preMime: 'application/x-custom',
        );
        var active = 0, maxActive = 0;
        fixture.partResponse = (request, part, attempt) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(Duration.zero);
          active--;
          final date = HttpDate.parse(request.headers['x-oss-date']!);
          expect(date.year, 2020);
          expect(date.hour, 12);
          return HttpResult(200, '', {
            'etag': ['"part-$part"'],
          });
        };
        await fixture.upload();
        expect(maxActive, 1);
      },
    );
  }

  for (final failure in [
    'network',
    'RequestTimeTooSkewed',
    'RequestExpired',
    'SignatureDoesNotMatch',
    'SlowDown',
  ]) {
    test(
      'temporary $failure rejection renews just the failed part authorization',
      () async {
        final fixture = _UploadFixture();
        final keys = <String>[];
        fixture.partResponse = (request, part, attempt) async {
          if (part == 2) {
            keys.add(request.headers['Authorization']!);
            if (attempt == 1) {
              if (failure == 'network') {
                throw const HttpRequestFailure(
                  'offline',
                  kind: 'connectionError',
                  retryable: true,
                );
              }
              return HttpResult(
                failure == 'SlowDown' ? 503 : 400,
                '<Error><Code>$failure</Code></Error>',
                {
                  'date': ['Wed, 01 Jan 2020 12:00:00 GMT'],
                },
              );
            }
            if (failure != 'network') {
              expect(HttpDate.parse(request.headers['x-oss-date']!).year, 2020);
            }
          }
          return HttpResult(200, '', {
            'etag': ['"part-$part"'],
          });
        };
        await fixture.upload();
        expect(fixture.attempts, {1: 1, 2: 2, 3: 1});
        expect(keys.toSet().length, 2);
        expect(
          fixture.http.calls.where(
            (request) => request.uri.path.endsWith('file/upload/pre'),
          ),
          hasLength(1),
        );
        expect(fixture.merges, 1);
      },
    );
  }

  test('persistent rejection is bounded and never reaches merge', () async {
    final fixture = _UploadFixture(size: 4);
    fixture.partResponse = (request, part, attempt) async =>
        const HttpResult(400, '<Error><Code>RequestExpired</Code></Error>');
    await expectLater(fixture.upload(), throwsA(isA<UploadResponseFailure>()));
    expect(fixture.attempts, {1: 3});
    expect(fixture.merges, 0);
    expect(fixture.finishes, 0);
  });

  for (final persistent in [false, true]) {
    test(
      'part authorization network failures are bounded: $persistent',
      () async {
        final fixture = _UploadFixture(size: 4);
        fixture.authResponse = (_) async {
          if (persistent || fixture.authorizationCount == 1) {
            throw const HttpRequestFailure(
              'temporary connection failure',
              kind: 'connectionError',
              retryable: true,
            );
          }
          return jsonResponse({
            'status': 200,
            'data': {'auth_key': 'fixture-${fixture.authorizationCount}'},
          });
        };
        if (persistent) {
          await expectLater(
            fixture.upload(),
            throwsA(isA<HttpRequestFailure>()),
          );
          expect(fixture.authorizationCount, 3);
          expect(fixture.attempts, isEmpty);
          expect(fixture.merges, 0);
          expect(fixture.finishes, 0);
        } else {
          expect((await fixture.upload()).id, 'saved');
          expect(fixture.attempts, {1: 1});
          expect(fixture.merges, 1);
        }
        expect(
          fixture.http.calls.where(
            (r) => r.uri.path.endsWith('file/upload/pre'),
          ),
          hasLength(1),
        );
      },
    );
  }

  test(
    'unknown HTTP 400 stops without retries and records safe context',
    () async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      try {
        final fixture = _UploadFixture();
        fixture
            .partResponse = (request, part, attempt) async => const HttpResult(
          400,
          '<Error><Code>InvalidArgument</Code><Message>cookie=private-cookie '
          'https://private.example/object?signature=private-signature</Message></Error>',
        );
        await expectLater(
          fixture.upload(),
          throwsA(
            isA<UploadResponseFailure>().having(
              (error) => error.message,
              'message',
              '文件上传失败（HTTP 400，InvalidArgument）',
            ),
          ),
        );
        expect(fixture.attempts, {1: 1});
        expect(fixture.merges, 0);
        final entry = log.entries().singleWhere(
          (entry) => entry.event == 'upload.storage_rejected',
        );
        final fields = asJson(entry.data['fields']);
        expect(fields['storageCode'], 'InvalidArgument');
        expect(fields['partNumber'], 1);
        expect(fields['partBytes'], 4);
        expect(entry.detail, isNot(contains('private-cookie')));
        expect(entry.detail, isNot(contains('private-signature')));
      } finally {
        DiagnosticLog.active = null;
        log.close();
      }
    },
  );

  for (final correct in [true, false]) {
    test(
      'existing part receipt requires matching range digest: $correct',
      () async {
        final fixture = _UploadFixture(size: 4);
        final digest = correct
            ? md5.convert(Uint8List(4)).toString()
            : 'f' * 32;
        fixture.partResponse = (request, part, attempt) async => HttpResult(
          409,
          '<Error><Code>PartAlreadyExist</Code><PartEtag>"$digest"</PartEtag></Error>',
        );
        if (correct) {
          await fixture.upload();
          expect(fixture.merges, 1);
        } else {
          await expectLater(
            fixture.upload(),
            throwsA(isA<UploadResponseFailure>()),
          );
          expect(fixture.merges, 0);
        }
        expect(fixture.attempts, {1: 1});
      },
    );
  }

  test('cancellation during recovery prevents further requests', () async {
    final fixture = _UploadFixture();
    final scope = RequestScope();
    fixture.partResponse = (request, part, attempt) async {
      scope.cancel();
      return const HttpResult(503, '<Error><Code>SlowDown</Code></Error>');
    };
    await expectLater(scope.run(fixture.upload), throwsA(isA<AppException>()));
    expect(fixture.attempts, {1: 1});
    expect(fixture.merges, 0);
  });

  test('ambiguous merge is never replayed', () async {
    final fixture = _UploadFixture();
    fixture.mergeResponse = (request) async => throw const HttpRequestFailure(
      'lost',
      kind: 'receiveTimeout',
      retryable: true,
    );
    final write = WriteRequestScope();
    await expectLater(
      write.run(fixture.upload),
      throwsA(isA<HttpRequestFailure>()),
    );
    expect(fixture.merges, 1);
    expect(write.mayHaveWritten, isTrue);
    expect(fixture.finishes, 0);
  });

  test('error messages retain safe codes without response text', () {
    for (final body in [
      '<Error><Code>private-cookie=secret</Code></Error>',
      '{"code":"https://secret.example/"}',
      '<html>credentials</html>',
      '{broken',
    ]) {
      final error = UploadResponseFailure(HttpResult(400, body));
      expect(error.message, '文件上传失败（HTTP 400）');
    }
  });
}
