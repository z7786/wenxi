import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final source = File('/app/Library/downloads/payload');
  late PlatformFileAccess files;
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    files = PlatformFileAccess(
      FakeNative(),
      Directory('/app/Documents/Downloads'),
      android: false,
      ios: true,
    );
  });
  tearDown(() => messenger.setMockMethodCallHandler(nativeChannel, null));

  test(
    'iOS keeps new incomplete downloads out of the selected Files provider',
    () async {
      expect(await files.downloadCacheRoot('/provider/Downloads'), isNull);
      expect(files.directDownloads, isFalse);
    },
  );

  test(
    'save waits for coordinated publication and filters stale progress',
    () async {
      final publication = Completer<String>();
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        calls.add(call);
        return publication.future;
      });
      final progress = <(int, int)>[];
      var finished = false;
      final saving = files
          .save(
            id: 'one',
            source: source,
            name: 'video.mp4',
            relativePath: '../episode',
            destination: '/provider/Downloads',
            checkpoint: () {},
            onProgress: (copied, total) => progress.add((copied, total)),
          )
          .then((path) {
            finished = true;
            return path;
          });
      await until(() => calls.isNotEmpty);
      final args = asJson(calls.single.arguments);
      expect(calls.single.method, 'saveDownloadedFile');
      expect(args.str('relativePath'), 'episode');
      expect(args.str('defaultDirectory'), '/app/Documents/Downloads');
      files.exportProgress({
        'id': 'one',
        'token': args.integer('token') - 1,
        'copied': 5,
        'total': 10,
      });
      expect(progress, isEmpty);
      files.exportProgress({
        'id': 'one',
        'token': args.integer('token'),
        'copied': 10,
        'total': 10,
      });
      expect(progress, [(10, 10)]);
      expect(finished, isFalse);
      publication.complete('/provider/Downloads/episode/video.mp4');
      expect(await saving, '/provider/Downloads/episode/video.mp4');
      files.exportProgress({
        'id': 'one',
        'token': args.integer('token'),
        'copied': 10,
        'total': 10,
      });
      expect(progress.length, 1);
    },
  );

  test(
    'cancel can interrupt native saving and provider failures remain retryable',
    () async {
      final publication = Completer<Object?>();
      messenger.setMockMethodCallHandler(nativeChannel, (call) async {
        calls.add(call);
        if (call.method == 'saveDownloadedFile') return publication.future;
        if (call.method == 'fileAvailability') return 'inaccessible';
        return null;
      });
      final saving = files.save(
        id: 'cancel',
        source: source,
        name: 'file.bin',
        relativePath: '',
        checkpoint: () {},
      );
      final failure = expectLater(
        saving,
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('下载内容已保留'),
          ),
        ),
      );
      await until(() => calls.isNotEmpty);
      await files.cancelExport('cancel');
      expect(calls.last.method, 'cancelExport');
      publication.completeError(
        PlatformException(code: 'cancelled', message: '文件保存已取消，下载内容已保留'),
      );
      await failure;
      expect(
        await files.inspect('/provider/Downloads/file.bin'),
        FileAvailability.inaccessible,
      );
      expect(calls.where((c) => c.method == 'deleteFile'), isEmpty);
    },
  );
}
