import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/android_download_file.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const locator = '/proc/self/fd/1000000000';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<int> stored;
  late List<Json> requests;
  late File file;
  var leaseValid = true, published = false;
  var maxRead = AndroidDownloadFile.chunkSize;
  Completer<void>? readBlocked;

  setUp(() async {
    stored = [];
    requests = [];
    leaseValid = true;
    published = false;
    maxRead = AndroidDownloadFile.chunkSize;
    readBlocked = null;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      final args = asJson(call.arguments);
      if (call.method == 'openDownloadTarget') {
        expect(args.str('id'), 'download');
        return {
          'uri': 'content://fixture/document/download',
          'key': 'document-key',
          'lease': 'grant-token',
          'path': locator,
        };
      }
      expect(call.method, 'downloadTargetIo');
      expect(args.str('id'), 'download');
      expect(args.str('lease'), 'grant-token');
      requests.add(args);
      if (!leaseValid) {
        throw PlatformException(code: 'lease', message: '下载目标凭据已失效');
      }
      final operation = args.str('operation');
      if (published && (operation == 'write' || operation == 'truncate')) {
        throw PlatformException(code: 'published', message: '文件已进入完成处理');
      }
      switch (operation) {
        case 'exists':
          return true;
        case 'length':
          return stored.length;
        case 'read':
          await readBlocked?.future;
          final start = args.integer('offset');
          final size = args.integer('length');
          expect(size, inInclusiveRange(0, AndroidDownloadFile.chunkSize));
          final end = math
              .min(stored.length, start + math.min(size, maxRead))
              .toInt();
          return Uint8List.fromList(
            start >= end ? [] : stored.sublist(start, end),
          );
        case 'write':
          final data = args['data'] as Uint8List;
          expect(data.length, lessThanOrEqualTo(AndroidDownloadFile.chunkSize));
          final offset = args.integer('offset');
          if (offset + data.length > stored.length) {
            stored.addAll(List.filled(offset + data.length - stored.length, 0));
          }
          stored.setRange(offset, offset + data.length, data);
          return data.length;
        case 'truncate':
          final length = args.integer('length');
          stored = length < stored.length
              ? stored.sublist(0, length)
              : [...stored, ...List.filled(length - stored.length, 0)];
          return null;
        case 'flush':
          return null;
        default:
          throw StateError('Unexpected operation: $operation');
      }
    });
    final platform = PlatformFileAccess(
      FakeNative(),
      Directory.systemTemp,
      android: true,
    );
    final target = await platform.openDownloadTarget(
      id: 'download',
      name: 'download.bin',
      relativePath: '',
    );
    file = target.file;
    expect(file, isA<AndroidDownloadFile>());
    expect(await File(locator).exists(), isFalse);
  });

  tearDown(() {
    if (readBlocked != null && !readBlocked!.isCompleted) {
      readBlocked!.complete();
    }
    messenger.setMockMethodCallHandler(nativeChannel, null);
  });

  test('native digest sends only grant and returns validated hash', () async {
    final digest = 'a' * 64;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      expect(call.method, 'verifyDownloadTarget');
      final args = asJson(call.arguments);
      expect(args.str('id'), 'download');
      expect(args.str('lease'), 'grant-token');
      expect(args.str('algorithm'), 'sha256');
      expect(args.integer('token'), greaterThan(0));
      expect(args.containsKey('data'), isFalse);
      return digest;
    });
    expect(
      await (file as AndroidDownloadFile).digest(
        'sha256',
        cancelled: Completer<void>().future,
      ),
      digest,
    );
    expect(requests, isEmpty);
  });

  test(
    'unsupported host falls back but invalid or failed hashes do not',
    () async {
      final target = file as AndroidDownloadFile;
      final cancelled = Completer<void>().future;
      messenger.setMockMethodCallHandler(
        nativeChannel,
        (_) async => throw MissingPluginException(),
      );
      expect(await target.digest('md5', cancelled: cancelled), isNull);
      for (final bad in [null, 'xyz', 'a' * 63]) {
        messenger.setMockMethodCallHandler(nativeChannel, (_) async => bad);
        await expectLater(
          target.digest('sha256', cancelled: cancelled),
          throwsA(isA<FileSystemException>()),
        );
      }
      messenger.setMockMethodCallHandler(
        nativeChannel,
        (_) async => throw PlatformException(code: 'lease', message: '凭据失效'),
      );
      await expectLater(
        target.digest('md5', cancelled: cancelled),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test('cancelling digest waits for the native reader to exit', () async {
    final entered = Completer<void>(), cancelled = Completer<void>();
    final cancelSent = Completer<void>(), exited = Completer<String>();
    int? token;
    messenger.setMockMethodCallHandler(nativeChannel, (call) async {
      final args = asJson(call.arguments);
      if (call.method == 'verifyDownloadTarget') {
        token = args.integer('token');
        entered.complete();
        return exited.future;
      }
      expect(call.method, 'cancelDownloadVerification');
      expect(args.str('id'), 'download');
      expect(args.integer('token'), token);
      cancelSent.complete();
      return null;
    });
    var finished = false;
    final result = (file as AndroidDownloadFile).digest(
      'md5',
      cancelled: cancelled.future,
    );
    final checked = expectLater(
      result,
      throwsA(isA<FileSystemException>()),
    ).then((_) => finished = true);
    await entered.future;
    cancelled.complete();
    await cancelSent.future;
    expect(finished, isFalse);
    exited.completeError(
      PlatformException(code: 'cancelled', message: '校验已暂停'),
    );
    await checked;
    expect(finished, isTrue);
  });

  test('large writes and bounded stream reads use the granted file', () async {
    final wanted = List.generate(
      AndroidDownloadFile.chunkSize * 2 + 31,
      (i) => i % 251,
    );
    final handle = await file.open(mode: FileMode.write);
    await handle.writeFrom(wanted);
    await handle.flush();
    expect(await handle.position(), wanted.length);
    expect(await file.length(), wanted.length);
    await handle.close();
    expect(stored, wanted);
    expect(
      requests.where((item) => item.str('operation') == 'write'),
      hasLength(3),
    );
    final read = await file
        .openRead(13, wanted.length - 7)
        .expand((chunk) => chunk)
        .toList();
    expect(read, wanted.sublist(13, wanted.length - 7));
    expect(await file.readAsBytes(), wanted);
    expect(await file.exists(), isTrue);
  });

  test(
    'independent readers and short reads preserve offsets during playback',
    () async {
      stored = List.generate(17, (i) => i + 1);
      maxRead = 2;
      final first = await file.open();
      final second = await file.open();
      await second.setPosition(8);
      final results = await Future.wait([first.read(5), second.read(4)]);
      expect(results[0], [1, 2, 3, 4, 5]);
      expect(results[1], [9, 10, 11, 12]);
      expect(await first.position(), 5);
      expect(await second.position(), 12);
      await first.close();
      expect(await second.readByte(), 13);
      final buffer = List.filled(8, 0);
      expect(await second.readInto(buffer, 1, 8), 4);
      expect(buffer, [0, 14, 15, 16, 17, 0, 0, 0]);
      expect(await second.readByte(), -1);
      await second.close();
    },
  );

  test(
    'resume truncates incomplete tail and writes at an explicit position',
    () async {
      stored = [1, 2, 99, 98];
      final handle = await file.open(mode: FileMode.append);
      expect(stored, [1, 2, 99, 98]);
      expect(await handle.position(), 4);
      await handle.truncate(2);
      await handle.setPosition(2);
      await handle.writeFrom([99, 3, 4, 98], 1, 3);
      expect(stored, [1, 2, 3, 4]);
      await handle.close();
      final overwrite = await file.open(mode: FileMode.write);
      expect(stored, isEmpty);
      await overwrite.writeString('下载');
      await overwrite.close();
      expect(await file.readAsString(), '下载');
    },
  );

  test(
    'read-only and closed handles reject mutation without changing bytes',
    () async {
      stored = [1, 2, 3];
      final reader = await file.open();
      await expectLater(
        reader.writeByte(9),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        reader.truncate(0),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        requests.where((item) => item.str('operation') == 'write'),
        isEmpty,
      );
      await reader.close();
      await expectLater(reader.read(1), throwsA(isA<FileSystemException>()));
      expect(stored, [1, 2, 3]);
    },
  );

  test(
    'expired grants fail and completed files remain readable but not writable',
    () async {
      stored = [1, 2, 3];
      final writer = await file.open(mode: FileMode.append);
      published = true;
      expect(await file.readAsBytes(), [1, 2, 3]);
      await expectLater(
        writer.writeByte(9),
        throwsA(isA<FileSystemException>()),
      );
      leaseValid = false;
      await expectLater(
        file.readAsBytes(),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(file.length(), throwsA(isA<FileSystemException>()));
      await writer.close();
      expect(stored, [1, 2, 3]);
    },
  );

  test(
    'one handle cannot be closed or repositioned during an outstanding read',
    () async {
      stored = [1, 2, 3];
      final reader = await file.open();
      readBlocked = Completer<void>();
      final pending = reader.read(2);
      await expectLater(
        reader.setPosition(1),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(reader.close(), throwsA(isA<FileSystemException>()));
      readBlocked!.complete();
      expect(await pending, [1, 2]);
      await reader.close();
    },
  );
}
