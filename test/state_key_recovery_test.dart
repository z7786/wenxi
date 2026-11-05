import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_fixture.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/startup_recovery.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';

// Each facade represents a fresh process. Only the device's persisted records
// are shared; different devices have independent maps and Android namespaces.
class _DeviceStorage extends FlutterSecureStorage {
  _DeviceStorage(this.records, {Set<String>? blocked})
    : blocked = blocked ?? {};
  final Map<String, String> records;
  final Set<String> blocked;
  int temporaryReadFailures = 0;
  bool dropWrites = false, denyWrites = false;

  String namespace(AndroidOptions? options) =>
      (options?.toMap()['storageNamespace'] ?? '').ifEmpty('legacy');
  String address(String key, AndroidOptions? options) =>
      '${namespace(options)}|$key';
  _DeviceStorage restart() => _DeviceStorage(records, blocked: blocked);

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (temporaryReadFailures > 0) {
      temporaryReadFailures--;
      throw PlatformException(code: 'temporarily-locked');
    }
    if (blocked.contains(namespace(aOptions))) {
      throw PlatformException(code: 'invalidated-keystore');
    }
    return records[address(key, aOptions)];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (denyWrites || blocked.contains(namespace(aOptions))) {
      throw PlatformException(code: 'secure-write-unavailable');
    }
    if (dropWrites) return;
    if (value == null) {
      records.remove(address(key, aOptions));
    } else {
      records[address(key, aOptions)] = value;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const password = 'fixture-password';
  late Uint8List backup;
  late String sourceKey;
  late Directory directory;
  late _DeviceStorage storage;
  late StateStore store;
  const primary = 'legacy|${StateStore.keyName}';
  const copy = '$primary.copy';
  // These fixtures deliberately cover the legacy OS store on every test host.
  LocalStateKey keys([Directory? target, FlutterSecureStorage? device]) =>
      LocalStateKey(
        target ?? directory,
        device ?? storage,
        nativeAndroid: false,
        windowsFiles: false,
      );

  setUpAll(() async {
    final sourceDirectory = await Directory.systemTemp.createTemp(
      'state-device-a-',
    );
    final sourceStorage = _DeviceStorage({});
    final source = await LegacyStateFixture.open(
      sourceDirectory,
      storage: sourceStorage,
      localKey: LocalStateKey(
        sourceDirectory,
        sourceStorage,
        nativeAndroid: false,
        windowsFiles: false,
      ),
    );
    try {
      sourceKey = sourceStorage.records[primary]!;
      await Vault(source).putCredential(
        CloudPlatform.baidu,
        Credential('A账号', {'primary': 'BDUSS=device-a-fixture'}),
      );
      await source.put('settings', {'theme': 'Dark'});
      backup = await LegacyBackupFixture(source).create(password);
    } finally {
      source.dispose();
      await sourceDirectory.delete(recursive: true);
    }
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('state-device-b-');
    storage = _DeviceStorage({});
    store = await LegacyStateFixture.open(
      directory,
      storage: storage,
      localKey: keys(),
    );
    await store.put('engineStorageGeneration', 'existing-engine');
    await store.put('tasks', [
      {'id': 'before-import'},
    ]);
  });
  tearDown(() async {
    store.dispose();
    await directory.delete(recursive: true);
  });
  File local(String name) => File('${directory.path}/$name');
  StartupRecovery recovery() => StartupRecovery(
    StateRecoveryRequired(directory, StateRecoveryCause.missingKey),
    storage: storage,
    localKey: keys(),
  );
  Future<void> reopen() async {
    final nextStorage = storage.restart();
    final next = await LegacyStateFixture.open(
      directory,
      storage: nextStorage,
      localKey: keys(directory, nextStorage),
    );
    store.dispose();
    store = next;
  }

  Future<String> activeNamespace() async => asJson(
    jsonDecode(await local(LocalStateKey.locationName).readAsString()),
  ).str('namespace');

  test(
    'cancelling export during encryption never opens the save destination',
    () async {
      final encrypted = await local('state-v1.enc').readAsBytes();
      final scope = RequestScope();
      var saveCalled = false;
      final export = scope.run(
        () => LegacyBackupFixture(store).exportTo(password, (_) async {
          saveCalled = true;
          return true;
        }),
      );
      scope.cancel();
      await expectLater(export, throwsA(isA<AppException>()));
      expect(saveCalled, isFalse);
      expect(await local('state-v1.enc').readAsBytes(), encrypted);
      expect(await local(LocalStateKey.recoveryName).exists(), isFalse);
    },
  );

  test(
    'first launch persists credentials across repeated reopen without import',
    () async {
      final originalKey = storage.records[primary];
      await Vault(store).putCredential(
        CloudPlatform.quark,
        Credential('首次登录', {'primary': 'cookie=first-launch-fixture'}),
      );
      await store.put('settings', {'theme': 'Dark'});
      for (var restart = 0; restart < 3; restart++) {
        await reopen();
        expect(storage.records[primary], originalKey);
        expect(storage.records[copy], originalKey);
        expect(
          Vault(store).credential(CloudPlatform.quark)?.primary,
          'cookie=first-launch-fixture',
        );
        expect(store.data.obj('settings').str('theme'), 'Dark');
        expect(await keys().canUnlock(), isFalse);
        await store.put('restartCount', restart + 1);
      }
      await reopen();
      expect(store.data.integer('restartCount'), 3);
    },
  );

  test(
    'unpersisted first key cannot create orphaned encrypted state',
    () async {
      final freshDirectory = await Directory.systemTemp.createTemp(
        'state-first-write-',
      );
      final freshStorage = _DeviceStorage({})..dropWrites = true;
      try {
        await expectLater(
          LegacyStateFixture.open(
            freshDirectory,
            storage: freshStorage,
            localKey: keys(freshDirectory, freshStorage),
          ),
          throwsA(isA<AppException>()),
        );
        expect(await freshDirectory.list().toList(), isEmpty);
        freshStorage.dropWrites = false;
        final first = await LegacyStateFixture.open(
          freshDirectory,
          storage: freshStorage,
          localKey: keys(freshDirectory, freshStorage),
        );
        try {
          await first.put('savedAfterRetry', true);
        } finally {
          first.dispose();
        }
        final reopened = await LegacyStateFixture.open(
          freshDirectory,
          storage: freshStorage.restart(),
          localKey: keys(freshDirectory, freshStorage.restart()),
        );
        try {
          expect(reopened.data.boolean('savedAfterRetry'), isTrue);
        } finally {
          reopened.dispose();
        }
      } finally {
        await freshDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'cross-device import keeps B key and survives repeated process reopen and edits',
    () async {
      final deviceKey = storage.records[primary]!;
      expect(deviceKey, isNot(sourceKey));
      await LegacyBackupFixture(store).restore(backup, password);
      for (var restart = 0; restart < 3; restart++) {
        await reopen();
        expect(
          Vault(store).credential(CloudPlatform.baidu)?.primary,
          'BDUSS=device-a-fixture',
        );
        expect(store.data.obj('settings').str('theme'), 'Dark');
        expect(store.data.str('engineStorageGeneration'), 'existing-engine');
        expect(base64Encode((await keys().read()).keys.single), deviceKey);
        await store.put('after-restart', restart);
      }
      await reopen();
      expect(store.data.integer('after-restart'), 2);
      final wrapper = await local(LocalStateKey.recoveryName).readAsString();
      expect(wrapper, isNot(contains(password)));
      expect(wrapper, isNot(contains(deviceKey)));
      expect(wrapper, isNot(contains(sourceKey)));
      expect(wrapper, isNot(contains('BDUSS')));
    },
  );

  test(
    'lost secure storage unlocks latest data without reimporting or replacing engine keys',
    () async {
      await LegacyBackupFixture(store).restore(backup, password);
      await Vault(store).putCredential(
        CloudPlatform.uc,
        Credential('导入后新增', {'primary': 'cookie=device-b-fixture'}),
      );
      await Vault(
        store,
      ).putSecret('flutter.gopeed.key', 'existing-engine-secret');
      await store.put('tasks', [
        {'id': 'after-import', 'done': 12345},
      ]);
      final expected = jsonEncode(store.data);
      final bytes = await local('state-v1.enc').readAsBytes();
      storage.records.clear();
      await expectLater(reopen(), throwsA(isA<StateRecoveryRequired>()));
      expect(await recovery().canUnlock(), isTrue);
      await recovery().unlock(password);
      expect(await local('state-v1.enc').readAsBytes(), bytes);
      await reopen();
      expect(jsonEncode(store.data), expected);
      await store.put('after-unlock', true);
      await reopen();
      expect(store.data.boolean('after-unlock'), isTrue);
      expect(
        Vault(store).secret('flutter.gopeed.key'),
        'existing-engine-secret',
      );
    },
  );

  test(
    'successful export protects later edits without importing a backup',
    () async {
      final repository = LegacyBackupFixture(store);
      final originalState = await local('state-v1.enc').readAsBytes();
      final originalRecords = Map<String, String>.from(storage.records);
      Uint8List? exported;
      expect(await recovery().canUnlock(), isFalse);
      expect(
        await repository.exportTo(password, (bytes) async {
          exported = bytes;
          return true;
        }),
        isTrue,
      );
      expect(exported, isNotNull);
      expect(await recovery().canUnlock(), isTrue);
      expect(await local('state-v1.enc').readAsBytes(), originalState);
      expect(storage.records, originalRecords);
      final envelope = await local(LocalStateKey.recoveryName).readAsString();
      expect(envelope, isNot(contains(password)));
      expect(envelope, isNot(contains(originalRecords[primary]!)));
      await store.put('tasks', [
        {'id': 'created-after-export', 'done': 7654321},
      ]);
      await Vault(store).putCredential(
        CloudPlatform.uc,
        Credential('导出后新增', {'primary': 'cookie=after-export-fixture'}),
      );
      final latest = jsonEncode(store.data);
      final latestState = await local('state-v1.enc').readAsBytes();
      storage.records.clear();
      await expectLater(reopen(), throwsA(isA<StateRecoveryRequired>()));
      await recovery().unlock(password);
      await reopen();
      expect(jsonEncode(store.data), latest);
      expect(await local('state-v1.enc').readAsBytes(), latestState);
    },
  );

  test(
    'cancelled or failed export cannot replace the recovery password',
    () async {
      final repository = LegacyBackupFixture(store);
      expect(await repository.exportTo(password, (_) async => false), isFalse);
      expect(await recovery().canUnlock(), isFalse);
      await repository.exportTo(password, (_) async => true);
      final envelope = await local(LocalStateKey.recoveryName).readAsBytes();
      expect(
        await repository.exportTo('cancelled-password', (_) async => false),
        isFalse,
      );
      await expectLater(
        repository.exportTo('failed-password', (_) async {
          throw const FileSystemException('Fixture destination unavailable');
        }),
        throwsA(isA<FileSystemException>()),
      );
      expect(await local(LocalStateKey.recoveryName).readAsBytes(), envelope);
      storage.records.clear();
      await recovery().unlock(password);
      await reopen();
      expect(store.data.str('engineStorageGeneration'), 'existing-engine');
    },
  );

  test(
    'protection write failure preserves the prior password and saved backup',
    () async {
      final repository = LegacyBackupFixture(store);
      await repository.exportTo(password, (_) async => true);
      final envelope = await local(LocalStateKey.recoveryName).readAsBytes();
      final state = await local('state-v1.enc').readAsBytes();
      await Directory('${local(LocalStateKey.recoveryName).path}.tmp').create();
      Uint8List? exported;
      await expectLater(
        repository.exportTo('next-password', (bytes) async {
          exported = bytes;
          return true;
        }),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('备份文件已导出'),
          ),
        ),
      );
      final portable = StateStore.memory();
      try {
        await LegacyBackupFixture(portable).restore(exported!, 'next-password');
      } finally {
        portable.dispose();
      }
      expect(await local(LocalStateKey.recoveryName).readAsBytes(), envelope);
      expect(await local('state-v1.enc').readAsBytes(), state);
    },
  );

  test(
    'unlocked process can establish recovery after system storage fails',
    () async {
      storage.denyWrites = true;
      storage.blocked.add('legacy');
      final originalState = await local('state-v1.enc').readAsBytes();
      expect(
        await LegacyBackupFixture(store).exportTo(password, (_) async => true),
        isTrue,
      );
      expect(await local('state-v1.enc').readAsBytes(), originalState);
      await expectLater(reopen(), throwsA(isA<StateRecoveryRequired>()));
      storage.denyWrites = false;
      await recovery().unlock(password);
      await reopen();
      expect(store.data.str('engineStorageGeneration'), 'existing-engine');
    },
  );

  test(
    'first-launch export persists an empty snapshot before enabling recovery',
    () async {
      final emptyDirectory = await Directory.systemTemp.createTemp(
        'state-export-empty-',
      );
      final emptyStorage = _DeviceStorage({});
      final empty = await LegacyStateFixture.open(
        emptyDirectory,
        storage: emptyStorage,
        localKey: keys(emptyDirectory, emptyStorage),
      );
      try {
        expect(
          await File('${emptyDirectory.path}/state-v1.enc').exists(),
          isFalse,
        );
        await LegacyBackupFixture(empty).exportTo(password, (_) async => true);
        final reopened = await LegacyStateFixture.open(
          emptyDirectory,
          storage: emptyStorage.restart(),
          localKey: keys(emptyDirectory, emptyStorage.restart()),
        );
        expect(reopened.data, empty.data);
        reopened.dispose();
      } finally {
        empty.dispose();
        await emptyDirectory.delete(recursive: true);
      }
    },
  );

  test(
    'missing malformed and wrong valid primary records repair from authenticated copy',
    () async {
      final expected = storage.records[primary]!;
      for (final damaged in [
        null,
        'malformed!',
        base64Encode(CryptoBox.random(32)),
      ]) {
        if (damaged == null) {
          storage.records.remove(primary);
        } else {
          storage.records[primary] = damaged;
        }
        await reopen();
        expect(storage.records[primary], expected);
        expect(storage.records[copy], expected);
        expect(store.data.str('engineStorageGeneration'), 'existing-engine');
      }
    },
  );

  test(
    'valid copy is tried against primary data before an older key can select backup',
    () async {
      final wrong = CryptoBox.random(32);
      storage.records[primary] = base64Encode(wrong);
      await local('state-v1.enc.bak').writeAsBytes(
        CryptoBox.seal(wrong, utf8.encode('{"schema":1,"oldData":true}')),
      );
      await reopen();
      expect(store.data.str('engineStorageGeneration'), 'existing-engine');
      expect(store.data['oldData'], isNull);
      expect(storage.records[primary], storage.records[copy]);
    },
  );

  test(
    'brief system storage failure retries without data replacement',
    () async {
      storage.temporaryReadFailures = 2;
      final next = await LegacyStateFixture.open(
        directory,
        storage: storage,
        localKey: keys(),
      );
      expect(next.data.str('engineStorageGeneration'), 'existing-engine');
      next.dispose();
      expect(storage.temporaryReadFailures, 0);
    },
  );

  test(
    'invalidated backend is preserved then password recovery binds a new namespace',
    () async {
      await LegacyBackupFixture(store).restore(backup, password);
      final oldNamespace = await activeNamespace();
      final savedRecords = Map<String, String>.from(storage.records);
      final encrypted = await local('state-v1.enc').readAsBytes();
      storage.blocked.add(oldNamespace);
      await expectLater(
        reopen(),
        throwsA(
          isA<StateRecoveryRequired>().having(
            (e) => e.cause,
            'reason',
            StateRecoveryCause.secureStorageUnavailable,
          ),
        ),
      );
      expect(await local('state-v1.enc').readAsBytes(), encrypted);
      expect(storage.records, savedRecords);
      await recovery().unlock(password);
      expect(await activeNamespace(), isNot(oldNamespace));
      for (final e in savedRecords.entries) {
        expect(storage.records[e.key], e.value);
      }
      await reopen();
      expect(store.data.str('engineStorageGeneration'), 'existing-engine');
    },
  );

  test(
    'wrong password tampering and stale key envelopes cannot change current data or keys',
    () async {
      await LegacyBackupFixture(store).restore(backup, password);
      final wrapper = await local(LocalStateKey.recoveryName).readAsBytes();
      final encrypted = await local('state-v1.enc').readAsBytes();
      final pointer = await local(LocalStateKey.locationName).readAsBytes();
      storage.records.clear();
      await expectLater(
        recovery().unlock('wrong-password'),
        throwsA(isA<AppException>()),
      );
      await local(LocalStateKey.recoveryName).writeAsString('{}', flush: true);
      await expectLater(
        recovery().unlock(password),
        throwsA(isA<AppException>()),
      );
      await local(
        LocalStateKey.recoveryName,
      ).writeAsBytes(wrapper, flush: true);
      // The old wrapper still decrypts .bak, but must not roll back newer state.
      final newer = CryptoBox.seal(
        CryptoBox.random(32),
        utf8.encode('{"schema":1,"newer":true}'),
      );
      await local('state-v1.enc.bak').writeAsBytes(encrypted);
      await local('state-v1.enc').writeAsBytes(newer);
      await expectLater(
        recovery().unlock(password),
        throwsA(isA<AppException>()),
      );
      expect(storage.records, isEmpty);
      expect(await local('state-v1.enc').readAsBytes(), newer);
      expect(await local(LocalStateKey.locationName).readAsBytes(), pointer);
    },
  );

  test(
    'backup recovery works even when legacy keystore cannot read or write',
    () async {
      storage.blocked.add('legacy');
      await recovery().restore(backup, password);
      await reopen();
      expect(Vault(store).credential(CloudPlatform.baidu), isNotNull);
      expect(await local('state-v2.json').exists(), isTrue);
      expect(await recovery().canUnlock(), isFalse);
      storage.records.clear();
      await reopen();
      expect(Vault(store).credential(CloudPlatform.baidu), isNotNull);
    },
  );

  test(
    'failed secure persistence does not report an import or change local data',
    () async {
      final original = await local('state-v1.enc').readAsBytes();
      final data = jsonEncode(store.data);
      storage.dropWrites = true;
      await expectLater(
        LegacyBackupFixture(store).restore(backup, password),
        throwsA(isA<AppException>()),
      );
      expect(await local('state-v1.enc').readAsBytes(), original);
      expect(jsonEncode(store.data), data);
      expect(await keys().canUnlock(), isFalse);
      expect(await local(LocalStateKey.locationName).exists(), isFalse);
      storage.dropWrites = false;
      await reopen();
      expect(jsonEncode(store.data), data);
    },
  );

  test(
    'state write failure rolls back namespace capsule and in-memory import',
    () async {
      final original = await local('state-v1.enc').readAsBytes();
      final data = jsonEncode(store.data);
      await Directory('${directory.path}/state-v1.enc.tmp').create();
      await expectLater(
        LegacyBackupFixture(store).restore(backup, password),
        throwsA(isA<FileSystemException>()),
      );
      expect(await local('state-v1.enc').readAsBytes(), original);
      expect(jsonEncode(store.data), data);
      expect(await keys().canUnlock(), isFalse);
      expect(await local(LocalStateKey.locationName).exists(), isFalse);
      await reopen();
      expect(jsonEncode(store.data), data);
    },
  );

  test(
    'denied recovery writes preserve capsule and data and allow a later retry',
    () async {
      await LegacyBackupFixture(store).restore(backup, password);
      storage.records.clear();
      final bytes = await local('state-v1.enc').readAsBytes();
      final pointer = await local(LocalStateKey.locationName).readAsBytes();
      final wrapper = await local(LocalStateKey.recoveryName).readAsBytes();
      storage.denyWrites = true;
      await expectLater(
        recovery().unlock(password),
        throwsA(isA<PlatformException>()),
      );
      expect(await local('state-v1.enc').readAsBytes(), bytes);
      expect(await local(LocalStateKey.locationName).readAsBytes(), pointer);
      expect(await local(LocalStateKey.recoveryName).readAsBytes(), wrapper);
      storage.denyWrites = false;
      await recovery().unlock(password);
      await reopen();
      expect(Vault(store).credential(CloudPlatform.baidu), isNotNull);
    },
  );

  test(
    'interrupted namespace switch leaves original key usable; lost data is never reset',
    () async {
      await local(
        '${LocalStateKey.locationName}.tmp',
      ).writeAsString('incomplete');
      await reopen();
      expect(store.data.str('engineStorageGeneration'), 'existing-engine');
      await LegacyBackupFixture(store).restore(backup, password);
      for (final suffix in ['', '.bak', '.tmp']) {
        final file = local('state-v1.enc$suffix');
        if (await file.exists()) await file.delete();
      }
      await expectLater(reopen(), throwsA(isA<StateRecoveryRequired>()));
      await expectLater(
        recovery().unlock(password),
        throwsA(isA<AppException>()),
      );
      expect(await local('state-v1.enc').exists(), isFalse);
    },
  );

  test('latest successful import password replaces recovery password', () async {
    await LegacyBackupFixture(store).restore(backup, password);
    const nextPassword = 'next-fixture-password';
    final nextBackup = await LegacyBackupFixture(store).create(nextPassword);
    await LegacyBackupFixture(store).restore(nextBackup, nextPassword);
    await store.put('after-second-import', true);
    storage.records.clear();
    // A corrupt location file also permits password recovery into fresh storage.
    await local(LocalStateKey.locationName).writeAsString('{}', flush: true);
    await expectLater(
      recovery().unlock(password),
      throwsA(isA<AppException>()),
    );
    expect(storage.records, isEmpty);
    await recovery().unlock(nextPassword);
    await reopen();
    expect(store.data.boolean('after-second-import'), isTrue);
    expect(store.data.str('engineStorageGeneration'), 'existing-engine');
  });

  test(
    'reinitialize archives old password recovery file instead of leaving it active',
    () async {
      await LegacyBackupFixture(store).restore(backup, password);
      final oldWrapper = await local(LocalStateKey.recoveryName).readAsBytes();
      storage.records.clear();
      final result = await recovery().reinitialize();
      expect(await recovery().canUnlock(), isFalse);
      expect(
        await File(
          '${result.archive.path}/${LocalStateKey.recoveryName}',
        ).readAsBytes(),
        oldWrapper,
      );
      await reopen();
      expect(Vault(store).credential(CloudPlatform.baidu), isNull);
      expect(
        store.data.str('engineStorageGeneration'),
        isNot('existing-engine'),
      );
    },
  );
}
