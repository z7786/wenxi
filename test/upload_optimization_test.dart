import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/uploads/upload_concurrency.dart';
import 'package:asterlink/data/uploads/upload_io.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

UploadFile _source(
  Uint8List bytes, {
  void Function()? onRead,
  int chunk = 131099,
  Map<String, String> verified = const {},
  Future<void> Function()? validate,
}) => UploadFile(
  name: 'sample.bin',
  size: bytes.length,
  verifiedHashes: verified,
  validate: validate,
  read: (start, end) async* {
    onRead?.call();
    for (var offset = start; offset < end; offset += chunk) {
      yield Uint8List.sublistView(bytes, offset, math.min(end, offset + chunk));
    }
  },
);

void main() {
  for (final size in [0, 17, 600001, 77777 * 8, 77777 * 9 + 13]) {
    test(
      'single pass hashes match whole, part and prefix digests: $size bytes',
      () async {
        final bytes = Uint8List.fromList(
          List.generate(size, (i) => (i * 19 + 5) % 251),
        );
        var reads = 0;
        final io = UploadIO(
          FakeHttp(),
          _source(bytes, onRead: () => reads++),
          null,
        );
        final result = await io.hashes(
          whole: ['md5', 'sha1'],
          partAlgorithm: 'md5',
          partSize: 77777,
          prefixAlgorithm: 'md5',
          prefixSize: 256000,
        );
        expect(result.whole, {
          'md5': md5.convert(bytes).toString(),
          'sha1': sha1.convert(bytes).toString(),
        });
        expect(
          result.prefix,
          md5
              .convert(
                Uint8List.sublistView(bytes, 0, math.min(bytes.length, 256000)),
              )
              .toString(),
        );
        final count = math.max(1, (size / 77777).ceil());
        expect(result.parts, [
          for (var i = 0; i < count; i++)
            md5
                .convert(
                  Uint8List.sublistView(
                    bytes,
                    i * 77777,
                    math.min(bytes.length, (i + 1) * 77777),
                  ),
                )
                .toString(),
        ]);
        expect(reads, 1);
        expect(await io.digest(md5), result.whole['md5']);
        expect(await io.digest(sha1), result.whole['sha1']);
        expect(
          await io.digest(md5, end: math.min(size, 256000)),
          result.prefix,
        );
        for (var i = 0; i < count; i++) {
          expect(
            await io.digest(
              md5,
              start: i * 77777,
              end: math.min(size, (i + 1) * 77777),
            ),
            result.parts[i],
          );
        }
        expect(reads, 1);
      },
    );
  }

  test(
    'verified relay hashes are reused together without opening the source',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final hashes = {
        'md5': md5.convert(bytes).toString(),
        'sha1': sha1.convert(bytes).toString(),
      };
      var reads = 0, validations = 0;
      final io = UploadIO(
        FakeHttp(),
        _source(
          bytes,
          onRead: () => reads++,
          verified: hashes,
          validate: () async => validations++,
        ),
        null,
      );
      expect((await io.hashes(whole: ['md5', 'sha1'])).whole, hashes);
      expect(reads, 0);
      expect(validations, 1);
    },
  );

  test(
    'range signing uses the background worker and checks cancellation after each block',
    () async {
      final bytes = Uint8List(2 * 1024 * 1024 + 5);
      var reads = 0;
      final io = UploadIO(
        FakeHttp(),
        _source(bytes, onRead: () => reads++, chunk: 12345),
        null,
      );
      expect(
        await io.digest(sha256, start: 3, end: bytes.length - 2),
        sha256
            .convert(Uint8List.sublistView(bytes, 3, bytes.length - 2))
            .toString(),
      );
      expect(reads, 1);
      final scope = RequestScope();
      var blocks = 0;
      final cancelled = UploadIO(FakeHttp(), _source(bytes, chunk: 65536), (
        progress,
      ) {
        if (++blocks == 1) scope.cancel();
      });
      await expectLater(
        scope.run(() => cancelled.hashes(whole: ['md5', 'sha1'])),
        throwsA(isA<AppException>()),
      );
      expect(blocks, 1);
      expect(
        await io.digest(sha256, start: 3, end: bytes.length - 2),
        isNotEmpty,
      );
      final next = UploadIO(FakeHttp(), _source(bytes), null);
      expect(await next.digest(md5), md5.convert(bytes).toString());
    },
  );

  test(
    'guarded source validates once before and once after each read',
    () async {
      var validations = 0;
      final source = _source(
        Uint8List.fromList([1, 2, 3]),
        validate: () async => validations++,
      ).guarded(() {});
      await source.openRead().drain<void>();
      expect(validations, 2);
    },
  );

  test(
    'parallel part progress sums sent bytes even when later parts finish first',
    () async {
      final first = Completer<void>(), later = Completer<void>();
      final progress = <UploadProgress>[];
      final http = FakeHttp((request) async {
        final upload = request.body as HttpUpload;
        final index = int.parse(request.uri.pathSegments.last);
        if (index == 0) {
          upload.onProgress!(2, 4);
          await first.future;
        } else {
          upload.onProgress!(4, 4);
          later.complete();
        }
        await upload.open().drain<void>();
        return const HttpResult(200, '');
      });
      final io = UploadIO(http, _source(Uint8List(8)), progress.add);
      final sent = io.parts(
        2,
        (i) => io
            .send(
              'https://upload.example/$i',
              start: i * 4,
              end: (i + 1) * 4,
              commitsFile: false,
            )
            .then((_) {}),
      );
      await later.future;
      expect(progress.last.sent, 6);
      expect(progress.last.fraction, .75);
      first.complete();
      await sent;
      expect(progress.last.sent, 8);
      expect(
        progress.map((p) => p.sent),
        orderedEquals(progress.map((p) => p.sent).toList()..sort()),
      );
    },
  );

  test(
    'failed parts cancel siblings, release connection slots, and preserve final write uncertainty',
    () async {
      final active = Completer<void>();
      var settled = false;
      final delegate = FakeHttp((request) async {
        if (request.uri.path == '/part/1') {
          active.complete();
          try {
            await RequestScope.cancellable(Completer<void>().future);
          } finally {
            settled = true;
          }
        }
        await active.future;
        throw const HttpRequestFailure('part failed', kind: 'receiveTimeout');
      });
      final write = WriteRequestScope();
      write.markSent();
      final io = UploadIO(
        RetryingJsonHttp(delegate),
        _source(Uint8List(8)),
        null,
      );
      await expectLater(
        write.run(
          () => io.parts(
            2,
            (i) => io
                .send(
                  'https://upload.example/part/$i',
                  start: i * 4,
                  end: (i + 1) * 4,
                  retry: false,
                  commitsFile: false,
                )
                .then((_) {}),
          ),
        ),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(settled, isTrue);
      expect(write.mayHaveWritten, isTrue);
      final next = UploadIO(FakeHttp(), _source(Uint8List(3)), null);
      await next.parts(
        1,
        (_) => next
            .send('https://upload.example/next', commitsFile: false)
            .then((_) {}),
      );
    },
  );

  test(
    'all files share a six-connection limit and each file uses at most three',
    () async {
      final release = Completer<void>();
      var active = 0, maximum = 0;
      final perFile = <String, int>{}, maxPerFile = <String, int>{};
      final http = FakeHttp((request) async {
        final file = request.uri.pathSegments.first;
        active++;
        maximum = math.max(maximum, active);
        perFile[file] = (perFile[file] ?? 0) + 1;
        maxPerFile[file] = math.max(maxPerFile[file] ?? 0, perFile[file]!);
        try {
          await release.future;
          await (request.body as HttpUpload).open().drain<void>();
          return const HttpResult(200, '');
        } finally {
          active--;
          perFile[file] = perFile[file]! - 1;
        }
      });
      final uploads = [
        for (var f = 0; f < 4; f++)
          (() {
            final io = UploadIO(http, _source(Uint8List(20)), null);
            return io.parts(
              5,
              (i) => io
                  .send(
                    'https://upload.example/$f/$i',
                    start: i * 4,
                    end: (i + 1) * 4,
                    commitsFile: false,
                  )
                  .then((_) {}),
            );
          })(),
      ];
      await until(() => active == 6);
      expect(maximum, 6);
      release.complete();
      await Future.wait(uploads);
      expect(maximum, 6);
      expect(maxPerFile.values.every((count) => count <= 3), isTrue);
      expect(http.calls, hasLength(20));
    },
  );

  test(
    'a cancelled waiter never starts work and does not leak a slot',
    () async {
      final limiter = UploadWorkLimiter(1), release = Completer<void>();
      final first = limiter.run(() => release.future);
      final scope = RequestScope();
      var started = false;
      final next = scope.run(() => limiter.run(() async => started = true));
      scope.cancel();
      await expectLater(next, throwsA(isA<AppException>()));
      release.complete();
      await first;
      expect(started, isFalse);
      expect(await limiter.run(() async => 'free'), 'free');
    },
  );

  test(
    'direct form uploads and multipart workers share the same connection pool',
    () async {
      final release = Completer<void>();
      var active = 0, maximum = 0;
      final http = RetryingJsonHttp(
        FakeHttp((request) async {
          active++;
          maximum = math.max(maximum, active);
          try {
            await release.future;
            await (request.body as HttpUpload).open().drain<void>();
            return const HttpResult(200, '');
          } finally {
            active--;
          }
        }),
      );
      final parts = [
        for (var i = 0; i < 2; i++)
          (() {
            final io = UploadIO(http, _source(Uint8List(12)), null);
            return io.parts(
              3,
              (part) => io
                  .send(
                    'https://upload.example/parts/$i/$part',
                    start: part * 4,
                    end: (part + 1) * 4,
                    commitsFile: false,
                  )
                  .then((_) {}),
            );
          })(),
      ];
      await until(() => active == 6);
      final forms = [
        for (var i = 0; i < 3; i++)
          http.request(
            'POST',
            'https://upload.example/form/$i',
            body: HttpUpload(
              open: () => Stream.value([1]),
              length: 1,
              fields: const {},
            ),
          ),
      ];
      expect(active, 6);
      release.complete();
      await Future.wait<void>([
        ...parts,
        ...forms.map((request) => request.then((_) {})),
      ]);
      expect(maximum, 6);
    },
  );

  test(
    'acknowledged blocks seed progress without reading or inflating sent bytes',
    () async {
      final progress = <UploadProgress>[];
      final io = UploadIO(FakeHttp(), _source(Uint8List(12)), progress.add);
      io.reusePart(0, 4);
      await io.parts(
        2,
        (i) => io
            .send(
              'https://upload.example/$i',
              start: (i + 1) * 4,
              end: (i + 2) * 4,
              commitsFile: false,
            )
            .then((_) {}),
      );
      expect(progress.first.sent, 4);
      expect(progress.last.sent, 12);
    },
  );

  test('an empty hash plan completes without reading the source', () async {
    var reads = 0;
    final io = UploadIO(
      FakeHttp(),
      _source(Uint8List(10), onRead: () => reads++),
      null,
    );
    final result = await io.hashes();
    expect(result.whole, isEmpty);
    expect(result.parts, isEmpty);
    expect(reads, 0);
  });
}
