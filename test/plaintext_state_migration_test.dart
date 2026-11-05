import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/startup_recovery.dart';
import 'package:asterlink/domain/models.dart';
import 'legacy_state_fixture.dart';

class _UnavailableStorage extends FlutterSecureStorage {
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
    throw PlatformException(code: 'fixture-unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  File file(String name) => File('${directory.path}/$name');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('plain-migration-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('new installation and repeated reopen require no key storage', () async {
    final storage = _UnavailableStorage();
    final store = await StateStore.open(directory, storage: storage);
    await Vault(store).putCredential(
      CloudPlatform.quark,
      Credential('fixture', {'primary': 'cookie=fixture'}),
    );
    await store.put('tasks', [
      {
        'id': 'task',
        'done': 4096,
        'ranges': [
          [0, 4096],
        ],
      },
    ]);
    final saved = jsonEncode(store.data);
    store.dispose();
    for (var i = 0; i < 3; i++) {
      final next = await StateStore.open(directory, storage: storage);
      expect(jsonEncode(next.data), saved);
      next.dispose();
    }
    expect(storage.calls, 0);
    expect(await file('state-key-location.json').exists(), isFalse);
    expect(
      await file('state-v2.json').readAsString(),
      contains('cookie=fixture'),
    );
  });

  test(
    'legacy encrypted snapshot migrates without changing accounts or checkpoints',
    () async {
      final key = CryptoBox.random(32);
      final data = <String, dynamic>{
        'schema': 1,
        'credentials': {
          'Baidu': Credential('old', {
            'primary': 'BDUSS=fixture',
          }, updatedAt: 10).toJson(),
        },
        'settings': {'theme': 'Dark'},
        'engineStorageGeneration': 'a' * 32,
        'secrets': {'flutter.gopeed.key': base64Encode(List.filled(32, 7))},
        'tasks': [
          {
            'id': 'task',
            'done': 7654321,
            'ranges': [
              [0, 4096],
              [8192, 16384],
            ],
          },
        ],
      };
      final original = CryptoBox.seal(key, utf8.encode(jsonEncode(data)));
      await file('state-v1.enc').writeAsBytes(original, flush: true);
      final store = await StateStore.open(directory, testKey: key);
      expect(store.data, data);
      expect(await file('state-v1.enc').readAsBytes(), original);
      expect(decodePlainState(await file('state-v2.json').readAsBytes()), data);
      await store.put('after', true);
      store.dispose();
      final unavailable = _UnavailableStorage();
      final reopened = await StateStore.open(directory, storage: unavailable);
      expect(reopened.data.list('tasks').single['done'], 7654321);
      expect(
        reopened.data.obj('secrets').str('flutter.gopeed.key'),
        data.obj('secrets').str('flutter.gopeed.key'),
      );
      expect(unavailable.calls, 0);
      reopened.dispose();
    },
  );

  test(
    'wrong legacy key never creates a new snapshot or resets existing data',
    () async {
      final old = CryptoBox.seal(
        CryptoBox.random(32),
        utf8.encode('{"schema":1,"keep":true}'),
      );
      await file('state-v1.enc').writeAsBytes(old);
      await expectLater(
        StateStore.open(directory, testKey: CryptoBox.random(32)),
        throwsA(isA<StateRecoveryRequired>()),
      );
      expect(await file('state-v1.enc').readAsBytes(), old);
      expect(await file('state-v2.json').exists(), isFalse);
      expect(await file('state-v2.json.tmp').exists(), isFalse);
    },
  );

  test('interrupted migration uses validated pending plain snapshot', () async {
    await file('state-v1.enc').writeAsString('unreadable old state');
    await file(
      'state-v2.json.tmp',
    ).writeAsBytes(encodePlainState({'schema': 1, 'keep': 'latest'}));
    final store = await StateStore.open(
      directory,
      storage: _UnavailableStorage(),
    );
    expect(store.data['keep'], 'latest');
    expect(await file('state-v2.json').exists(), isTrue);
    expect(await file('state-v1.enc').readAsString(), 'unreadable old state');
    store.dispose();
  });

  test(
    'checksum backup recovers damage and all corrupt v2 never revives stale v1',
    () async {
      final store = await StateStore.open(directory);
      await store.put('keep', 'previous');
      await store.put('keep', 'latest');
      store.dispose();
      await file('state-v2.json').writeAsString('broken');
      final recovered = await StateStore.open(directory);
      expect(recovered.data['keep'], 'previous');
      recovered.dispose();
      await file('state-v1.enc').writeAsBytes(
        CryptoBox.seal(Uint8List(32), utf8.encode('{"schema":1,"stale":true}')),
      );
      for (final suffix in ['', '.bak', '.tmp']) {
        await file('state-v2.json$suffix').writeAsString('broken');
      }
      await expectLater(
        StateStore.open(directory, testKey: Uint8List(32)),
        throwsA(isA<StateRecoveryRequired>()),
      );
    },
  );

  test(
    'future v2 schema refuses older backup and recovery replacement',
    () async {
      await file(
        'state-v2.json',
      ).writeAsBytes(encodePlainState({'schema': 2, 'keep': true}));
      await file(
        'state-v2.json.bak',
      ).writeAsBytes(encodePlainState({'schema': 1}));
      await expectLater(
        StateStore.open(directory),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        StartupRecovery(
          StateRecoveryRequired(directory, StateRecoveryCause.unreadableData),
        ).reinitialize(),
        throwsA(isA<AppException>()),
      );
      expect(await file('state-recovery').exists(), isFalse);
    },
  );

  test(
    'plain backup has no password and modified payload is rejected atomically',
    () async {
      final store = StateStore.memory();
      await Vault(store).putCredential(
        CloudPlatform.baidu,
        Credential('backup', {'primary': 'BDUSS=fixture'}),
      );
      final bytes = await BackupRepository(store).create('');
      expect(isPlainBackup(bytes), isTrue);
      expect(utf8.decode(bytes), contains('BDUSS=fixture'));
      final target = await StateStore.open(directory);
      expect(await BackupRepository(target).restore(bytes, ''), 1);
      expect(
        Vault(target).credential(CloudPlatform.baidu)?.primary,
        'BDUSS=fixture',
      );
      final original = jsonEncode(target.data);
      final tampered = asJson(jsonDecode(utf8.decode(bytes)));
      tampered['data'] = {
        ...tampered.obj('data'),
        'settings': {'theme': 'Light'},
      };
      await expectLater(
        BackupRepository(
          target,
        ).restore(Uint8List.fromList(utf8.encode(jsonEncode(tampered))), ''),
        throwsA(isA<AppException>()),
      );
      expect(jsonEncode(target.data), original);
      target.dispose();
      store.dispose();
    },
  );

  test(
    'old password backup and locked key capsule still restore into plain state',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final keys = LocalStateKey(
        directory,
        const FlutterSecureStorage(),
        nativeAndroid: true,
      );
      final old = await LegacyStateFixture.open(directory, localKey: keys);
      await Vault(old).putCredential(
        CloudPlatform.uc,
        Credential('old', {'primary': 'cookie=legacy'}),
      );
      await old.put('tasks', [
        {'id': 'checkpoint', 'done': 777},
      ]);
      await old.protectRecovery('fixture-password');
      final pointer = asJson(
        jsonDecode(await file(LocalStateKey.locationName).readAsString()),
      );
      for (final name in ['primary.bin', 'copy.bin']) {
        await file(
          '${LocalStateKey.privateDirectoryName}/${pointer.str('namespace')}/$name',
        ).delete();
      }
      old.dispose();
      final recovery = StartupRecovery(
        StateRecoveryRequired(directory, StateRecoveryCause.missingKey),
        localKey: keys,
      );
      await expectLater(
        recovery.unlock('wrong-password'),
        throwsA(isA<AppException>()),
      );
      await recovery.unlock('fixture-password');
      final next = await StateStore.open(
        directory,
        storage: _UnavailableStorage(),
      );
      expect(
        Vault(next).credential(CloudPlatform.uc)?.primary,
        'cookie=legacy',
      );
      expect(next.data.list('tasks').single.integer('done'), 777);
      expect(await file('state-v2.json').exists(), isTrue);
      next.dispose();
    },
  );
}
