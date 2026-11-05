import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_fixture.dart';
import 'package:pointycastle/export.dart';

import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/startup_recovery.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/platform/windows_legacy_state_key.dart';

class _ForbiddenStorage extends FlutterSecureStorage {
  int calls = 0;
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
    calls++;
    throw StateError('Windows must not call the destructive storage plugin');
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
    calls++;
    throw StateError('Windows must not write OS keys');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, directory;
  late _ForbiddenStorage storage;
  late Map<String, String> legacyValues;
  late Map<String, Uint8List> credentials;
  late bool broken;
  late int unprotectCalls;
  File file(String name) => File('${directory.path}/$name');
  File legacyFile() =>
      File('${root.path}/${WindowsLegacyStateKey.encryptedFileName}');
  WindowsLegacyStateKey reader() => WindowsLegacyStateKey(
    root,
    unprotect: (_) async {
      unprotectCalls++;
      if (broken) {
        throw PlatformException(
          code: 'windows_state_key',
          details: {'stage': 'unprotect', 'code': 11},
        );
      }
      return Uint8List.fromList(utf8.encode(jsonEncode(legacyValues)));
    },
    readCredential: (name) async {
      final value = credentials[name];
      return value == null ? null : Uint8List.fromList(value);
    },
  );
  LocalStateKey keys() => LocalStateKey(
    directory,
    storage,
    nativeAndroid: false,
    windowsFiles: true,
    windowsLegacy: reader(),
  );
  Future<StateStore> open() =>
      LegacyStateFixture.open(directory, localKey: keys());
  Future<Json> pointer() async =>
      asJson(jsonDecode(await file(LocalStateKey.locationName).readAsString()));
  File privateKey(String namespace, {bool copy = false}) => file(
    '${LocalStateKey.privateDirectoryName}/$namespace/${copy ? 'copy' : 'primary'}.bin',
  );
  StartupRecovery recovery() => StartupRecovery(
    StateRecoveryRequired(
      directory,
      StateRecoveryCause.secureStorageUnavailable,
    ),
    storage: storage,
    localKey: keys(),
  );
  Future<Uint8List> seedLegacy({bool namespace = false}) async {
    final key = CryptoBox.random(32);
    const fixtureNamespace = 'state_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final suffix = namespace ? '.$fixtureNamespace' : '';
    legacyValues = {
      '${LocalStateKey.name}$suffix': base64Encode(key),
      '${LocalStateKey.name}$suffix.copy': base64Encode(key),
      'other-secret': 'preserved',
    };
    await legacyFile().writeAsBytes([1, 2, 3, 4], flush: true);
    if (namespace) {
      await file(
        LocalStateKey.locationName,
      ).writeAsString(jsonEncode({'namespace': fixtureNamespace}));
    }
    final store = await LegacyStateFixture.open(directory, testKey: key);
    await store.put('favorite', 'previous');
    await store.put('favorite', 'latest');
    await store.put('tasks', [
      {'id': 'kept', 'done': 12345},
    ]);
    await store.put('secrets', {'flutter.gopeed.key': 'engine-fixture'});
    store.dispose();
    return key;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('windows-key-');
    directory = await Directory('${root.path}/AsterLink').create();
    storage = _ForbiddenStorage();
    legacyValues = {};
    credentials = {};
    broken = false;
    unprotectCalls = 0;
  });
  tearDown(() async {
    expect(storage.calls, 0);
    await root.delete(recursive: true);
  });

  test(
    'new installation never calls DPAPI and survives process restarts',
    () async {
      broken = true;
      final first = await open();
      await first.put('cookie', 'fixture-cookie');
      first.dispose();
      final location = await pointer();
      expect(location.str('backend'), LocalStateKey.windowsPrivateBackend);
      final namespace = location.str('namespace');
      expect(
        await privateKey(namespace).readAsBytes(),
        await privateKey(namespace, copy: true).readAsBytes(),
      );
      expect(
        await file('${LocalStateKey.locationName}.bak').readAsBytes(),
        await file(LocalStateKey.locationName).readAsBytes(),
      );
      for (var i = 0; i < 4; i++) {
        final reopened = await open();
        expect(reopened.data.str('cookie'), 'fixture-cookie');
        await reopened.put('restart', i);
        reopened.dispose();
      }
      expect(await pointer(), location);
      expect(unprotectCalls, 0);
      expect(
        utf8.decode(
          await file('state-v1.enc').readAsBytes(),
          allowMalformed: true,
        ),
        isNot(contains('fixture-cookie')),
      );
    },
  );

  for (final namespace in [false, true]) {
    test(
      'legacy key migrates after authentication without changing data (namespace=$namespace)',
      () async {
        final key = await seedLegacy(namespace: namespace);
        final encrypted = await file('state-v1.enc').readAsBytes();
        final original = await legacyFile().readAsBytes();
        final migrated = await open();
        expect(migrated.data.str('favorite'), 'latest');
        expect(
          migrated.data.obj('secrets').str('flutter.gopeed.key'),
          'engine-fixture',
        );
        migrated.dispose();
        expect(
          await privateKey((await pointer()).str('namespace')).readAsBytes(),
          key,
        );
        expect(await file('state-v1.enc').readAsBytes(), encrypted);
        expect(await legacyFile().readAsBytes(), original);
        expect(unprotectCalls, 1);
        broken = true;
        for (var i = 0; i < 3; i++) {
          (await open()).dispose();
        }
        expect(unprotectCalls, 1);
      },
    );
  }

  for (final damage in ['missing', 'truncated', 'wrong-key']) {
    test(
      'one damaged key file repairs from the authenticated copy: $damage',
      () async {
        final first = await open();
        await first.put('favorite', 'latest');
        first.dispose();
        final namespace = (await pointer()).str('namespace');
        final key = await privateKey(namespace, copy: true).readAsBytes();
        final encrypted = await file('state-v1.enc').readAsBytes();
        if (damage == 'missing') {
          await privateKey(namespace).delete();
        } else {
          await privateKey(
            namespace,
          ).writeAsBytes(damage == 'truncated' ? [1, 2] : CryptoBox.random(32));
        }
        final next = await open();
        expect(next.data.str('favorite'), 'latest');
        next.dispose();
        final repaired = (await pointer()).str('namespace');
        expect(repaired, isNot(namespace));
        expect(await privateKey(repaired).readAsBytes(), key);
        expect(await privateKey(repaired, copy: true).readAsBytes(), key);
        expect(await file('state-v1.enc').readAsBytes(), encrypted);
        expect(await privateKey(namespace, copy: true).readAsBytes(), key);
        expect(unprotectCalls, 0);
      },
    );
  }

  for (final damage in ['missing', 'corrupt']) {
    test(
      'damaged location metadata recovers using its second copy: $damage',
      () async {
        final first = await open();
        await first.put('favorite', 'latest');
        first.dispose();
        final encrypted = await file('state-v1.enc').readAsBytes();
        if (damage == 'missing') {
          await file(LocalStateKey.locationName).delete();
        } else {
          await file(LocalStateKey.locationName).writeAsString('incomplete');
        }
        broken = true;
        final next = await open();
        expect(next.data.str('favorite'), 'latest');
        next.dispose();
        expect(await file('state-v1.enc').readAsBytes(), encrypted);
        expect(
          await file(LocalStateKey.locationName).readAsBytes(),
          await file('${LocalStateKey.locationName}.bak').readAsBytes(),
        );
        expect(unprotectCalls, 0);
      },
    );
  }

  test(
    'DPAPI failure preserves legacy key files and enters recovery on every retry',
    () async {
      await seedLegacy();
      final encrypted = await file('state-v1.enc').readAsBytes();
      final original = await legacyFile().readAsBytes();
      broken = true;
      for (var i = 0; i < 2; i++) {
        await expectLater(
          open(),
          throwsA(
            isA<StateRecoveryRequired>().having(
              (e) => e.cause,
              'cause',
              StateRecoveryCause.secureStorageUnavailable,
            ),
          ),
        );
      }
      expect(await legacyFile().readAsBytes(), original);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      expect(await file(LocalStateKey.locationName).exists(), isFalse);
      expect(
        await Directory(file(LocalStateKey.privateDirectoryName).path).exists(),
        isFalse,
      );
    },
  );

  test(
    'both damaged key files keep ciphertext instead of resetting data',
    () async {
      final first = await open();
      await first.put('favorite', 'latest');
      first.dispose();
      final namespace = (await pointer()).str('namespace');
      final encrypted = await file('state-v1.enc').readAsBytes();
      await privateKey(namespace).writeAsBytes([1]);
      await privateKey(namespace, copy: true).writeAsBytes([2]);
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      expect((await pointer()).str('namespace'), namespace);
      expect(await privateKey(namespace).readAsBytes(), [1]);
      expect(await privateKey(namespace, copy: true).readAsBytes(), [2]);
      expect(unprotectCalls, 0);
    },
  );

  test('fresh key publication failure cannot create orphaned state', () async {
    final blocker = Directory(
      file('${LocalStateKey.locationName}.bak.tmp').path,
    );
    await blocker.create();
    await expectLater(open(), throwsA(isA<FileSystemException>()));
    expect(await file('state-v1.enc').exists(), isFalse);
    expect(await file(LocalStateKey.locationName).exists(), isFalse);
    await blocker.delete();
    final next = await open();
    await next.put('after-retry', true);
    next.dispose();
    final restarted = await open();
    expect(restarted.data.boolean('after-retry'), isTrue);
    restarted.dispose();
    expect(unprotectCalls, 0);
  });

  test(
    'stale backup pointer cannot authenticate an older state and overwrite the current one',
    () async {
      final first = await open();
      await first.put('favorite', 'latest');
      first.dispose();
      final encrypted = await file('state-v1.enc').readAsBytes();
      const oldNamespace = 'state_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final oldKey = CryptoBox.random(32);
      await privateKey(oldNamespace).parent.create(recursive: true);
      await privateKey(oldNamespace).writeAsBytes(oldKey);
      await privateKey(oldNamespace, copy: true).writeAsBytes(oldKey);
      await file('state-v1.enc.bak').writeAsBytes(
        CryptoBox.seal(oldKey, utf8.encode('{"schema":1,"favorite":"stale"}')),
      );
      final backup = jsonEncode({
        'namespace': oldNamespace,
        'backend': LocalStateKey.windowsPrivateBackend,
      });
      await file('${LocalStateKey.locationName}.bak').writeAsString(backup);
      await file(LocalStateKey.locationName).writeAsString('broken');
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      expect(
        await file('${LocalStateKey.locationName}.bak').readAsString(),
        backup,
      );
      expect(await file(LocalStateKey.locationName).readAsString(), 'broken');
      expect(unprotectCalls, 0);
    },
  );

  test(
    'valid second key wins before a wrong key can read older state',
    () async {
      final first = await open();
      await first.put('favorite', 'latest');
      first.dispose();
      final namespace = (await pointer()).str('namespace');
      final wrongKey = CryptoBox.random(32);
      await privateKey(namespace).writeAsBytes(wrongKey);
      await file('state-v1.enc.bak').writeAsBytes(
        CryptoBox.seal(
          wrongKey,
          utf8.encode('{"schema":1,"favorite":"stale"}'),
        ),
      );
      final next = await open();
      expect(next.data.str('favorite'), 'latest');
      next.dispose();
    },
  );

  for (final damage in ['missing', 'corrupt']) {
    test(
      'healthy primary repairs its damaged pointer backup: $damage',
      () async {
        final first = await open();
        await first.put('favorite', 'latest');
        first.dispose();
        final backup = file('${LocalStateKey.locationName}.bak');
        if (damage == 'missing') {
          await backup.delete();
        } else {
          await backup.writeAsString('broken');
        }
        final next = await open();
        expect(next.data.str('favorite'), 'latest');
        next.dispose();
        expect(
          await backup.readAsBytes(),
          await file(LocalStateKey.locationName).readAsBytes(),
        );
      },
    );
  }

  test(
    'published backup completes migration when the old DPAPI pointer becomes unreadable',
    () async {
      await seedLegacy(namespace: true);
      final encrypted = await file('state-v1.enc').readAsBytes();
      final blocker = Directory(file('${LocalStateKey.locationName}.tmp').path);
      await blocker.create();
      final first = await open();
      expect(first.data.str('favorite'), 'latest');
      first.dispose();
      expect((await pointer()).str('backend'), isEmpty);
      expect(await file('${LocalStateKey.locationName}.bak').exists(), isTrue);
      await blocker.delete();
      broken = true;
      final recovered = await open();
      expect(recovered.data.str('favorite'), 'latest');
      recovered.dispose();
      expect(
        (await pointer()).str('backend'),
        LocalStateKey.windowsPrivateBackend,
      );
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      final calls = unprotectCalls;
      (await open()).dispose();
      expect(unprotectCalls, calls);
    },
  );

  test(
    'wrong legacy key cannot migrate or replace the current snapshot',
    () async {
      await seedLegacy();
      final encrypted = await file('state-v1.enc').readAsBytes();
      final wrong = base64Encode(CryptoBox.random(32));
      legacyValues[LocalStateKey.name] = wrong;
      legacyValues['${LocalStateKey.name}.copy'] = wrong;
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file(LocalStateKey.locationName).exists(), isFalse);
      expect(
        await Directory(file(LocalStateKey.privateDirectoryName).path).exists(),
        isFalse,
      );
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
    },
  );

  test(
    'failed migration publication retains usable old state until a later retry',
    () async {
      await seedLegacy();
      final original = await legacyFile().readAsBytes();
      final encrypted = await file('state-v1.enc').readAsBytes();
      final blocker = Directory(
        file('${LocalStateKey.locationName}.bak.tmp').path,
      );
      await blocker.create();
      final readable = await open();
      expect(readable.data.str('favorite'), 'latest');
      readable.dispose();
      expect(await legacyFile().readAsBytes(), original);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      expect(await file(LocalStateKey.locationName).exists(), isFalse);
      await blocker.delete();
      (await open()).dispose();
      expect(
        (await pointer()).str('backend'),
        LocalStateKey.windowsPrivateBackend,
      );
    },
  );

  test(
    'password recovery keeps current state and engine keys without DPAPI',
    () async {
      final first = await open();
      await first.put('favorite', 'latest');
      await first.put('secrets', {'flutter.gopeed.key': 'existing-engine'});
      await first.protectRecovery('fixture-password');
      final encrypted = await file('state-v1.enc').readAsBytes();
      final namespace = (await pointer()).str('namespace');
      first.dispose();
      await privateKey(namespace).delete();
      await privateKey(namespace, copy: true).delete();
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      await recovery().unlock('fixture-password');
      final next = await open();
      expect(next.data.str('favorite'), 'latest');
      expect(
        next.data.obj('secrets').str('flutter.gopeed.key'),
        'existing-engine',
      );
      next.dispose();
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      expect(unprotectCalls, 0);
    },
  );

  test(
    'old backup restores after DPAPI failure and migrates to file storage',
    () async {
      await seedLegacy();
      final encrypted = await file('state-v1.enc').readAsBytes();
      final source = StateStore.memory({'favorite': 'backup'});
      await Vault(source).putCredential(
        CloudPlatform.quark,
        Credential('fixture', {'primary': 'fixture-cookie'}),
      );
      final backup = await LegacyBackupFixture(
        source,
      ).create('fixture-password');
      source.dispose();
      broken = true;
      final restored = await recovery().restore(backup, 'fixture-password');
      expect(
        await File('${restored.archive.path}/state-v1.enc').readAsBytes(),
        encrypted,
      );
      final next = await open();
      expect(
        Vault(next).credential(CloudPlatform.quark)?.primary,
        'fixture-cookie',
      );
      next.dispose();
      expect(await file('state-v2.json').exists(), isTrue);
      expect(await legacyFile().exists(), isTrue);
    },
  );

  test(
    'AES-GCM legacy records migrate without modifying credential storage',
    () async {
      final key = await seedLegacy();
      await legacyFile().delete();
      final aes = CryptoBox.random(16), nonce = CryptoBox.random(12);
      credentials['key_${WindowsLegacyStateKey.credentialPrefix}'] = aes;
      for (final suffix in ['', '.copy']) {
        final cipher = GCMBlockCipher(AESEngine())
          ..init(
            true,
            AEADParameters(KeyParameter(aes), 128, nonce, Uint8List(0)),
          );
        final encrypted = cipher.process(
          Uint8List.fromList(utf8.encode('${base64Encode(key)}\x00')),
        );
        await File(
          '${root.path}/${WindowsLegacyStateKey.credentialPrefix}${LocalStateKey.name}$suffix.secure',
        ).writeAsBytes([
          ...nonce,
          ...encrypted.sublist(encrypted.length - 16),
          ...encrypted.sublist(0, encrypted.length - 16),
        ]);
      }
      final next = await open();
      expect(next.data.str('favorite'), 'latest');
      next.dispose();
      expect(credentials['key_${WindowsLegacyStateKey.credentialPrefix}'], aes);
      expect(
        await privateKey((await pointer()).str('namespace')).readAsBytes(),
        key,
      );
    },
  );

  test(
    'old Credential Manager values migrate without writing the OS store',
    () async {
      final key = await seedLegacy();
      await legacyFile().delete();
      for (final suffix in ['', '.copy']) {
        credentials['${WindowsLegacyStateKey.credentialPrefix}${LocalStateKey.name}$suffix'] =
            Uint8List.fromList(utf8.encode('${base64Encode(key)}\x00'));
      }
      final original = {
        for (final entry in credentials.entries)
          entry.key: Uint8List.fromList(entry.value),
      };
      final next = await open();
      expect(next.data.str('favorite'), 'latest');
      next.dispose();
      expect(
        await privateKey((await pointer()).str('namespace')).readAsBytes(),
        key,
      );
      expect(credentials, original);
      expect(unprotectCalls, 0);
    },
  );

  test(
    'temporary DPAPI failure retries the file and can migrate in the same startup',
    () async {
      await seedLegacy();
      var calls = 0;
      final transient = WindowsLegacyStateKey(
        root,
        unprotect: (_) async {
          if (calls++ == 0) throw PlatformException(code: 'windows_state_key');
          return Uint8List.fromList(utf8.encode(jsonEncode(legacyValues)));
        },
        readCredential: (_) async => null,
      );
      final next = await LegacyStateFixture.open(
        directory,
        localKey: LocalStateKey(
          directory,
          storage,
          nativeAndroid: false,
          windowsFiles: true,
          windowsLegacy: transient,
        ),
      );
      expect(next.data.str('favorite'), 'latest');
      next.dispose();
      expect(calls, 2);
      expect(
        (await pointer()).str('backend'),
        LocalStateKey.windowsPrivateBackend,
      );
    },
  );

  test('malformed legacy JSON preserves its encrypted source', () async {
    await legacyFile().writeAsBytes([5, 6, 7]);
    final malformed = WindowsLegacyStateKey(
      root,
      unprotect: (_) async => Uint8List.fromList(utf8.encode('incomplete')),
      readCredential: (_) async => null,
    );
    await expectLater(
      malformed.read(LocalStateKey.name),
      throwsA(isA<PlatformException>()),
    );
    expect(await legacyFile().readAsBytes(), [5, 6, 7]);
  });

  test('diagnostics never include legacy key values', () async {
    await seedLegacy();
    broken = true;
    final log = DiagnosticLog.open(null);
    DiagnosticLog.active = log;
    try {
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      final output = jsonEncode(log.exportFiles());
      expect(output, contains('state_key.storage_failed'));
      expect(output, isNot(contains(legacyValues[LocalStateKey.name]!)));
      expect(output, isNot(contains('engine-fixture')));
    } finally {
      DiagnosticLog.active = null;
      log.dispose();
    }
  });
}
