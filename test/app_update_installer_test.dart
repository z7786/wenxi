import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/platform/app_update_installer.dart';
import 'package:asterlink/platform/windows_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.asterlink.app/native');
  late Directory directory;
  late AppUpdateInstaller installer;
  RemoteUpdate release(List<int> bytes, {int? size, String? digest}) =>
      RemoteUpdate(
        '1.2.0',
        120,
        Uri.parse('https://example.test/setup.exe'),
        '',
        packageSha256: digest ?? sha256.convert(bytes).toString(),
        packageSize: size ?? bytes.length,
      );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aster-update-package-');
    installer = AppUpdateInstaller(
      platform: 'windows',
      windows: WindowsActions(supported: false),
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });
  Future<DownloadTask> file(String name, List<int> bytes) async {
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(bytes);
    return DownloadTask(
      id: 'update',
      createdAt: 1,
      total: bytes.length,
      status: DownloadStatus.completed,
      spec: DownloadSpec(url: 'https://example.test/$name', fileName: name),
      savedPath: file.path,
    );
  }

  for (final savedPath in [
    'content://media/external/downloads/245',
    'content://com.android.externalstorage.documents/tree/primary%3ADownload/document/primary%3ADownload%2Fapp.apk',
    'file:///storage/emulated/0/Download/app.apk',
    '/storage/emulated/0/Download/app.apk',
  ]) {
    test('Android checks the prepared APK for $savedPath', () async {
      installer = AppUpdateInstaller(
        platform: 'android',
        windows: WindowsActions(supported: false),
      );
      final bytes = List.generate(2048, (i) => i % 251);
      final prepared = await file('prepared.apk', bytes);
      final task = prepared.update({'savedPath': savedPath});
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            expect(call.method, 'prepareAppUpdate');
            expect(call.arguments, {
              'path': savedPath,
              'version': '1.2.0',
              'build': 120,
            });
            return prepared.savedPath;
          });

      // The existing native bridge handles document URIs and validates the
      // APK identity/signature even for older feeds without a SHA-256.
      expect(
        await installer.prepare(task, release(bytes, digest: '')),
        prepared.savedPath,
      );
      expect(await installer.prepare(task, release(bytes)), prepared.savedPath);
      expect(calls, ['prepareAppUpdate', 'prepareAppUpdate']);
      bytes.last ^= 1;
      await File(prepared.savedPath!).writeAsBytes(bytes);
      expect(
        () => installer.prepare(
          task,
          release(List.generate(2048, (i) => i % 251)),
        ),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('完整性校验失败'),
          ),
        ),
      );
      expect(
        () => installer.prepare(task, release(bytes, size: bytes.length + 1)),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('大小不一致'),
          ),
        ),
      );
    });
  }

  test(
    'Android reports an unreadable prepared copy and native errors',
    () async {
      installer = AppUpdateInstaller(
        platform: 'android',
        windows: WindowsActions(supported: false),
      );
      final bytes = [1, 2, 3, 4];
      final task = (await file(
        'app.apk',
        bytes,
      )).update({'savedPath': 'content://media/external/downloads/245'});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'prepareAppUpdate') {
              fail('Must not open installer');
            }
            return '${directory.path}/missing.apk';
          });
      await expectLater(
        installer.prepare(task, release(bytes)),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('无法读取更新安装包'),
          ),
        ),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'prepareAppUpdate') {
              fail('Must not open installer');
            }
            throw PlatformException(
              code: 'invalid_apk',
              message: '安装包签名与当前应用不一致',
            );
          });
      await expectLater(
        installer.prepare(task, release(bytes)),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('签名与当前应用不一致'),
          ),
        ),
      );
    },
  );

  test(
    'Windows EXE requires MZ and PE headers before opening an installer',
    () async {
      final bytes = Uint8List(132)
        ..[0] = 0x4d
        ..[1] = 0x5a;
      ByteData.sublistView(bytes).setUint32(0x3c, 128, Endian.little);
      bytes[128] = 0x50;
      bytes[129] = 0x45;
      final valid = await file('setup.exe', bytes);
      expect(await installer.prepare(valid, release(bytes)), valid.savedPath);
      bytes[128] = 0;
      expect(
        () async =>
            installer.prepare(await file('invalid.exe', bytes), release(bytes)),
        throwsA(isA<AppException>()),
      );
      expect(
        () async => installer.prepare(
          await file('webpage.exe', '<html>not an installer</html>'.codeUnits),
          release('<html>not an installer</html>'.codeUnits),
        ),
        throwsA(isA<AppException>()),
      );
    },
  );
  test('ZIP update remains an archive and rejects a renamed webpage', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('app/readme.txt', 15, 'fixture package'.codeUnits));
    final bytes = ZipEncoder().encode(archive);
    final zip = await file('app.zip', bytes);
    final update = release(bytes);
    expect(await installer.prepare(zip, update), zip.savedPath);
    await File(zip.savedPath!).writeAsBytes(bytes.take(4).toList());
    expect(() => installer.prepare(zip, update), throwsA(isA<AppException>()));
    expect(
      () async => installer.prepare(
        await file('page.zip', 'HTML'.codeUnits),
        release('HTML'.codeUnits),
      ),
      throwsA(isA<AppException>()),
    );
    expect(AppUpdateInstaller.supportsName('app.zip', 'android'), isFalse);
    expect(AppUpdateInstaller.supportsName('app.APK', 'android'), isTrue);
  });

  Uint8List executable() {
    final bytes = Uint8List.fromList(List.generate(2048, (i) => i % 251))
      ..[0] = 0x4d
      ..[1] = 0x5a;
    ByteData.sublistView(bytes).setUint32(0x3c, 128, Endian.little);
    bytes.setRange(128, 132, [0x50, 0x45, 0, 0]);
    return bytes;
  }

  test(
    'Windows checks the entire payload even when MZ/PE headers remain valid',
    () async {
      final bytes = executable();
      final task = await file('setup.exe', bytes);
      final update = release(bytes);
      expect(await installer.prepare(task, update), task.savedPath);
      bytes[1024] ^= 1;
      await File(task.savedPath!).writeAsBytes(bytes);
      expect(
        () => installer.prepare(task, update),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            contains('完整性校验失败'),
          ),
        ),
      );
    },
  );

  test(
    'Windows rejects truncation and inconsistent size despite valid headers or hash',
    () async {
      final bytes = executable();
      final truncated = await file('truncated.exe', bytes.take(512).toList());
      expect(
        () => installer.prepare(truncated, release(bytes)),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            contains('大小不一致'),
          ),
        ),
      );
      final task = await file('setup.exe', bytes);
      expect(
        () => installer.prepare(task, release(bytes, size: bytes.length + 1)),
        throwsA(isA<AppException>()),
      );
      expect(
        () => installer.prepare(
          task.update({'total': bytes.length + 2}),
          release(bytes),
        ),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Missing or malformed publication hashes block Windows installation',
    () async {
      final bytes = executable();
      final task = await file('setup.exe', bytes);
      for (final digest in ['', 'sha256:${'0' * 64}', 'invalid']) {
        expect(
          () => installer.prepare(task, release(bytes, digest: digest)),
          throwsA(
            isA<AppException>().having(
              (error) => error.message,
              'message',
              contains('浏览器更新'),
            ),
          ),
        );
      }
    },
  );

  test(
    'Every install attempt rechecks the file and accepts an uppercase release hash',
    () async {
      final bytes = executable();
      final task = await file('setup.exe', bytes);
      final update = release(
        bytes,
        digest: sha256.convert(bytes).toString().toUpperCase(),
      );
      expect(await installer.prepare(task, update), task.savedPath);
      bytes.last ^= 2;
      await File(task.savedPath!).writeAsBytes(bytes);
      expect(
        () => installer.prepare(task, update),
        throwsA(isA<AppException>()),
      );
    },
  );
}
