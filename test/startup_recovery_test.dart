import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/startup_recovery.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Map<String, List<int>> original;
  late StateRecoveryRequired failure;
  late Uint8List backup;
  LocalStateKey keys([
    FlutterSecureStorage storage = StateStore.secureStorage,
  ]) => LocalStateKey(
    directory,
    storage,
    nativeAndroid: false,
    windowsFiles: false,
  );
  Future<StateStore> open() => StateStore.open(directory, localKey: keys());
  StartupRecovery recovery([
    FlutterSecureStorage storage = StateStore.secureStorage,
  ]) => StartupRecovery(failure, storage: storage, localKey: keys(storage));
  setUpAll(() async {
    final source = StateStore.memory();
    await Vault(source).putCredential(
      CloudPlatform.baidu,
      Credential('备份账号', {'primary': 'BDUSS=fixture'}),
    );
    await source.put('settings', {'theme': 'Dark'});
    backup = encryptBackup((
      decryptBackup((await BackupRepository(source).create(''), '')),
      'fixture-password',
    ));
    source.dispose();
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'aster-startup-recovery-',
    );
    FlutterSecureStorage.setMockInitialValues({
      'unrelated-secret': 'untouched',
    });
    original = {
      for (final suffix in ['', '.bak', '.tmp'])
        'state-v1.enc$suffix': CryptoBox.seal(
          CryptoBox.random(32),
          utf8.encode('{"schema":1,"old":true}'),
        ),
    };
    for (final entry in original.entries) {
      await File('${directory.path}/${entry.key}').writeAsBytes(entry.value);
    }
    failure = StateRecoveryRequired(directory, StateRecoveryCause.missingKey);
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> expectOriginals() async {
    for (final entry in original.entries) {
      expect(
        await File('${directory.path}/${entry.key}').readAsBytes(),
        entry.value,
      );
    }
  }

  test(
    'missing key is recoverable, leaves snapshots intact and creates no key',
    () async {
      await expectLater(
        open(),
        throwsA(
          isA<StateRecoveryRequired>().having(
            (e) => e.cause,
            'cause',
            StateRecoveryCause.missingKey,
          ),
        ),
      );
      await expectOriginals();
      expect(
        await StateStore.secureStorage.read(key: StateStore.keyName),
        isNull,
      );
      expect(
        StateStore.secureStorage.aOptions.toMap()['resetOnError'],
        'false',
      );
      expect(
        StateStore.secureStorage.aOptions.toMap()['migrateWithBackup'],
        'true',
      );
    },
  );

  test(
    'wrong backup password leaves all files and secure keys unchanged',
    () async {
      await expectLater(
        recovery().restore(backup, 'wrong-password'),
        throwsA(isA<AppException>()),
      );
      await expectOriginals();
      expect(
        await Directory('${directory.path}/state-recovery').exists(),
        isFalse,
      );
      expect(
        await StateStore.secureStorage.read(key: StateStore.keyName),
        isNull,
      );
    },
  );

  test(
    'malformed decrypted account payload is rejected before recovery touches disk',
    () async {
      final bad = encryptBackup((
        {
          'schema': 1,
          'package': 'com.asterlink.app',
          'cloudAccounts': [
            {'id': '../bad', 'platform': CloudPlatform.baidu.key},
          ],
          'activeCloudAccounts': {},
        },
        'fixture-password',
      ));
      await expectLater(
        recovery().restore(bad, 'fixture-password'),
        throwsA(isA<AppException>()),
      );
      await expectOriginals();
      expect(
        await Directory('${directory.path}/state-recovery').exists(),
        isFalse,
      );
    },
  );

  test(
    'backup recovery archives ciphertext and reopens plain accounts without a key',
    () async {
      final result = await recovery().restore(backup, 'fixture-password');
      expect(result.accounts, 1);
      for (final entry in original.entries) {
        expect(
          await File('${result.archive.path}/${entry.key}').readAsBytes(),
          entry.value,
        );
      }
      final reopened = await open();
      expect(
        Vault(reopened).credential(CloudPlatform.baidu)?.primary,
        'BDUSS=fixture',
      );
      expect(reopened.data.obj('settings').str('theme'), 'Dark');
      expect(reopened.data.boolean('legacyImported'), isTrue);
      expect(
        reopened.data.str('engineStorageGeneration'),
        matches(RegExp(r'^[a-f0-9]{32}$')),
      );
      expect(reopened.data.list('tasks'), isEmpty);
      expect(
        await StateStore.secureStorage.read(key: 'unrelated-secret'),
        'untouched',
      );
      final activeBytes = await File(
        '${directory.path}/state-v2.json',
      ).readAsBytes();
      expect(
        utf8.decode(activeBytes, allowMalformed: true),
        contains('BDUSS=fixture'),
      );
      reopened.dispose();
    },
  );

  test(
    'reinitialize preserves download payloads and old engine database; new state survives restart',
    () async {
      final engine = Directory('${directory.path}/gopeed');
      final cache = Directory('${directory.path}/downloads/task');
      await engine.create();
      await cache.create(recursive: true);
      await File(
        '${engine.path}/data',
      ).writeAsString('old encrypted engine data');
      await File('${cache.path}/video.mp4').writeAsString('existing download');
      final result = await recovery().reinitialize();
      final reopened = await open();
      expect(reopened.data.obj('credentials'), isEmpty);
      expect(reopened.data.boolean('legacyImported'), isTrue);
      expect(
        await File('${engine.path}/data').readAsString(),
        'old encrypted engine data',
      );
      expect(
        await File('${cache.path}/video.mp4').readAsString(),
        'existing download',
      );
      expect(
        await File('${result.archive.path}/state-v1.enc').readAsBytes(),
        original['state-v1.enc'],
      );
      await reopened.put('new-setting', true);
      reopened.dispose();
      final again = await open();
      expect(again.data.boolean('new-setting'), isTrue);
      again.dispose();
    },
  );

  test(
    'plain replacement write failure rolls back every snapshot and permits retry',
    () async {
      final blocker = Directory('${directory.path}/state-v2.json.tmp');
      await blocker.create();
      await expectLater(
        recovery().reinitialize(),
        throwsA(isA<FileSystemException>()),
      );
      await blocker.delete();
      await expectOriginals();
      expect(
        await StateStore.secureStorage.read(key: StateStore.keyName),
        isNull,
      );
      expect(
        await StateStore.secureStorage.read(key: 'unrelated-secret'),
        'untouched',
      );
      // A failed attempt must release the instance lock and allow retry.
      await recovery().reinitialize();
      (await open()).dispose();
    },
  );

  test(
    'the first download after recovery opens a fresh engine directory',
    () async {
      final oldDatabase = File('${directory.path}/gopeed/old.db');
      await oldDatabase.parent.create();
      await oldDatabase.writeAsString('encrypted with the missing old key');
      await recovery().reinitialize();
      final reopened = await open();
      final native = FakeNative();
      final services = AppServices(
        store: reopened,
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/downloads'),
        transport: native,
        files: FakeFiles(Directory('${directory.path}/saved')),
        http: FakeHttp(),
        platformFeatures: false,
        controlEnabled: false,
      );
      try {
        expect(
          services.engine.storage.path,
          endsWith('gopeed-${reopened.data.str('engineStorageGeneration')}'),
        );
        await services.engine.begin({'id': 'recovered-download'});
        expect(native.started, isTrue);
        expect(native.begins.single.str('id'), 'recovered-download');
        expect(services.vault.secret('flutter.gopeed.key'), isNull);
        expect(
          await oldDatabase.readAsString(),
          'encrypted with the missing old key',
        );
      } finally {
        await services.close();
        reopened.dispose();
      }
    },
  );

  test(
    'malformed secure key stays in its old backend after confirmed recovery',
    () async {
      await StateStore.secureStorage.write(
        key: StateStore.keyName,
        value: 'invalid-base64!',
      );
      await expectLater(
        open(),
        throwsA(
          isA<StateRecoveryRequired>().having(
            (e) => e.cause,
            'cause',
            StateRecoveryCause.invalidKey,
          ),
        ),
      );
      final result = await recovery().reinitialize();
      final values = await StateStore.secureStorage.readAll();
      expect(values[StateStore.keyName], 'invalid-base64!');
      expect(
        await File('${result.archive.path}/state-v1.enc').readAsBytes(),
        original['state-v1.enc'],
      );
      (await open()).dispose();
    },
  );

  test(
    'stale recovery request cannot replace readable data or a future schema',
    () async {
      final key = CryptoBox.random(32);
      await StateStore.secureStorage.write(
        key: StateStore.keyName,
        value: base64Encode(key),
      );
      final primary = File('${directory.path}/state-v1.enc');
      for (final schema in [1, 2]) {
        final bytes = CryptoBox.seal(
          key,
          utf8.encode('{"schema":$schema,"keep":true}'),
        );
        await primary.writeAsBytes(bytes);
        await expectLater(
          recovery().reinitialize(),
          throwsA(isA<AppException>()),
        );
        expect(await primary.readAsBytes(), bytes);
      }
      expect(
        await Directory('${directory.path}/state-recovery').exists(),
        isFalse,
      );
    },
  );

  test(
    'two simultaneous recovery actions cannot replace the successful result twice',
    () async {
      final outcomes = await Future.wait(
        List.generate(2, (_) async {
          try {
            await recovery().reinitialize();
            return true;
          } on AppException {
            return false;
          }
        }),
      );
      expect(outcomes.where((value) => value), hasLength(1));
      (await open()).dispose();
    },
  );

  test(
    'interruption after key persistence finishes using the replacement pending snapshot',
    () async {
      // Represents the on-disk state immediately before the recovery final rename.
      final key = CryptoBox.random(32);
      await File('${directory.path}/state-v1.enc.bak').delete();
      await File('${directory.path}/state-v1.enc.tmp').writeAsBytes(
        CryptoBox.seal(
          key,
          utf8.encode('{"schema":1,"legacyImported":true,"restored":true}'),
        ),
      );
      await StateStore.secureStorage.write(
        key: StateStore.keyName,
        value: base64Encode(key),
      );
      final reopened = await open();
      expect(reopened.data.boolean('restored'), isTrue);
      reopened.dispose();
      final again = await open();
      expect(again.data.boolean('restored'), isTrue);
      again.dispose();
    },
  );
}
