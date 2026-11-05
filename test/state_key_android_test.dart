import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'legacy_state_fixture.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/startup_recovery.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/models.dart';

class _LegacyStorage extends FlutterSecureStorage {
  bool broken = false;
  String failure = 'InvalidKeyException';
  int reads = 0, writes = 0;
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
    reads++;
    if (broken) {
      throw PlatformException(code: 'Exception', message: failure);
    }
    return super.read(key: key, aOptions: aOptions);
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
    writes++;
    if (broken) {
      throw PlatformException(code: 'Exception', message: failure);
    }
    await super.write(key: key, value: value, aOptions: aOptions);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const password = 'fixture-password';
  late Directory directory;
  late _LegacyStorage legacy;
  late Uint8List backup;
  // Existing native records survive new Dart facades, just as on an upgrade.
  // All newly written keys must live on disk without using either OS backend.
  late Map<String, Map<bool, Uint8List>> records;
  late Set<String> blocked;
  late bool nativeBroken;
  late int nativeCalls;
  LocalStateKey keys() => LocalStateKey(directory, legacy, nativeAndroid: true);
  Future<StateStore> open() =>
      LegacyStateFixture.open(directory, localKey: keys());
  File file(String name) => File('${directory.path}/$name');
  File keyFile(String namespace, {bool copy = false}) => file(
    '${LocalStateKey.privateDirectoryName}/$namespace/'
    '${copy ? 'copy.bin' : 'primary.bin'}',
  );
  Future<Json> location() async =>
      asJson(jsonDecode(await file(LocalStateKey.locationName).readAsString()));
  StartupRecovery recovery() => StartupRecovery(
    StateRecoveryRequired(
      directory,
      StateRecoveryCause.secureStorageUnavailable,
    ),
    storage: legacy,
    localKey: keys(),
  );
  Future<Uint8List> seedLegacy({bool namespaced = false}) async {
    final localKey = LocalStateKey(directory, legacy, nativeAndroid: false);
    final old = await LegacyStateFixture.open(directory, localKey: localKey);
    try {
      await old.put('favorite', 'old');
      await old.put('favorite', 'latest');
    } finally {
      old.dispose();
    }
    final key = (await localKey.read()).keys.single;
    if (namespaced) await localKey.saveFresh(key);
    return key;
  }

  Future<({String namespace, Uint8List key})> seedNative({
    Uint8List? key,
    Json? data,
    Json? fallback,
  }) async {
    key ??= CryptoBox.random(32);
    final namespace =
        'state_${CryptoBox.random(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    records[namespace] = {
      false: Uint8List.fromList(key),
      true: Uint8List.fromList(key),
    };
    await file(LocalStateKey.locationName).writeAsString(
      jsonEncode({
        'namespace': namespace,
        'backend': LocalStateKey.nativeBackend,
        'fallback': ?fallback,
      }),
      flush: true,
    );
    await file('state-v1.enc').writeAsBytes(
      CryptoBox.seal(key, utf8.encode(jsonEncode({'schema': 1, ...?data}))),
      flush: true,
    );
    return (namespace: namespace, key: key);
  }

  Future<void> losePrivateRecords() async {
    final namespace = (await location()).str('namespace');
    await keyFile(namespace).delete();
    await keyFile(namespace, copy: true).delete();
  }

  setUpAll(() async {
    final source = StateStore.memory({
      'settings': {'theme': 'Dark'},
    });
    try {
      await Vault(source).putCredential(
        CloudPlatform.baidu,
        Credential('备份账号', {'primary': 'BDUSS=fixture-only'}),
      );
      backup = await LegacyBackupFixture(source).create(password);
    } finally {
      source.dispose();
    }
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('state-android-');
    legacy = _LegacyStorage();
    FlutterSecureStorage.setMockInitialValues({});
    records = {};
    blocked = {};
    nativeBroken = false;
    nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalStateKey.channel, (call) async {
          nativeCalls++;
          expect(call.method, 'readStateKey');
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final namespace = args['namespace'] as String;
          if (nativeBroken || blocked.contains(namespace)) {
            throw PlatformException(
              code: 'state_key_storage',
              details: 'UnrecoverableKeyException',
            );
          }
          return records[namespace]?[args['copy'] == true];
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalStateKey.channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'storage diagnostics retain category without logging secret payload',
    () async {
      final log = DiagnosticLog.open(null);
      DiagnosticLog.active = log;
      try {
        legacy.broken = true;
        legacy.failure = 'InvalidKeyException: sensitive-fixture-key-value';
        final saved = await keys().read();
        expect(saved.unavailable, isTrue);
        final events = jsonEncode(
          log.entries().map((entry) => entry.data).toList(),
        );
        expect(events, contains('InvalidKeyException'));
        expect(events, isNot(contains('sensitive-fixture-key-value')));
      } finally {
        DiagnosticLog.active = null;
        log.close();
      }
    },
  );

  test(
    'fresh Android install and repeated restarts never access broken Keystore',
    () async {
      legacy.broken = true;
      nativeBroken = true;
      final first = await open();
      await Vault(first).putCredential(
        CloudPlatform.quark,
        Credential('首次登录', {'primary': 'cookie=fixture-only'}),
      );
      await first.put('favorite', 'kept');
      first.dispose();
      final pointer = await location();
      expect(pointer.str('backend'), LocalStateKey.privateBackend);
      expect(
        await keyFile(pointer.str('namespace')).readAsBytes(),
        await keyFile(pointer.str('namespace'), copy: true).readAsBytes(),
      );
      for (var i = 0; i < 4; i++) {
        final next = await open();
        expect(next.data['favorite'], 'kept');
        expect(
          Vault(next).credential(CloudPlatform.quark)?.primary,
          'cookie=fixture-only',
        );
        await next.put('restart', i);
        next.dispose();
      }
      expect(await location(), pointer);
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
      expect(legacy.writes, 0);
      expect(
        utf8.decode(
          await file('state-v1.enc').readAsBytes(),
          allowMalformed: true,
        ),
        isNot(contains('cookie=fixture-only')),
      );
    },
  );

  test('first private write failure cannot orphan encrypted state', () async {
    legacy.broken = true;
    nativeBroken = true;
    final blocker = file(LocalStateKey.privateDirectoryName);
    await blocker.writeAsString('occupied');
    await expectLater(open(), throwsA(isA<FileSystemException>()));
    expect(await file(LocalStateKey.locationName).exists(), isFalse);
    expect(await file('state-v1.enc').exists(), isFalse);
    await blocker.delete();
    final next = await open();
    await next.put('favorite', 'retry');
    next.dispose();
    final restarted = await open();
    expect(restarted.data['favorite'], 'retry');
    restarted.dispose();
    expect(nativeCalls, 0);
    expect(legacy.reads, 0);
    expect(legacy.writes, 0);
  });

  test(
    'pointer publication failure leaves both durable private copies',
    () async {
      final blocker = Directory(file('${LocalStateKey.locationName}.tmp').path);
      await blocker.create();
      await expectLater(open(), throwsA(isA<FileSystemException>()));
      expect(await file(LocalStateKey.locationName).exists(), isFalse);
      expect(await file('state-v1.enc').exists(), isFalse);
      final namespaces = await Directory(
        file(LocalStateKey.privateDirectoryName).path,
      ).list().toList();
      expect(namespaces, hasLength(1));
      final primary = File('${namespaces.single.path}/primary.bin');
      final copy = File('${namespaces.single.path}/copy.bin');
      expect(await primary.length(), 32);
      expect(await primary.readAsBytes(), await copy.readAsBytes());
      await blocker.delete();
      final next = await open();
      await next.put('retry', true);
      next.dispose();
      final reopened = await open();
      expect(reopened.data['retry'], true);
      reopened.dispose();
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
    },
  );

  test(
    'missing private records cannot initialize even without a snapshot',
    () async {
      final first = await open();
      first.dispose();
      final pointer = await file(LocalStateKey.locationName).readAsBytes();
      await losePrivateRecords();
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
      expect(await file('state-v1.enc').exists(), isFalse);
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
    },
  );

  test('missing private records preserve existing encrypted state', () async {
    final first = await open();
    await first.put('favorite', 'kept');
    first.dispose();
    final pointer = await file(LocalStateKey.locationName).readAsBytes();
    final encrypted = await file('state-v1.enc').readAsBytes();
    await losePrivateRecords();
    await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
    expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
    expect(await file('state-v1.enc').readAsBytes(), encrypted);
    expect(nativeCalls, 0);
    expect(legacy.reads, 0);
  });

  for (final damage in ['missing', 'truncated', 'wrong-key']) {
    test('private primary $damage repairs from authenticated copy', () async {
      final first = await open();
      await first.put('favorite', 'latest');
      first.dispose();
      final previous = (await location()).str('namespace');
      final originalKey = await keyFile(previous, copy: true).readAsBytes();
      final encrypted = await file('state-v1.enc').readAsBytes();
      if (damage == 'missing') {
        await keyFile(previous).delete();
      } else {
        await keyFile(previous).writeAsBytes(
          damage == 'truncated' ? [1, 2, 3] : CryptoBox.random(32),
          flush: true,
        );
      }
      legacy.broken = true;
      nativeBroken = true;
      final repaired = await open();
      expect(repaired.data['favorite'], 'latest');
      repaired.dispose();
      final active = (await location()).str('namespace');
      expect(active, isNot(previous));
      expect(await keyFile(active).readAsBytes(), originalKey);
      expect(await keyFile(active, copy: true).readAsBytes(), originalKey);
      expect(await keyFile(previous, copy: true).readAsBytes(), originalKey);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      final next = await open();
      expect(next.data['favorite'], 'latest');
      next.dispose();
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
    });
  }

  test(
    'private repair retains a file fallback without probing OS storage',
    () async {
      final first = await open();
      await first.put('favorite', 'latest');
      first.dispose();
      final previous = (await location()).str('namespace');
      await keyFile(previous).delete();
      final repaired = await open();
      repaired.dispose();
      expect((await location()).obj('fallback').str('namespace'), previous);
      await losePrivateRecords();
      legacy.broken = true;
      nativeBroken = true;
      final fallback = await open();
      expect(fallback.data['favorite'], 'latest');
      fallback.dispose();
      expect((await location()).str('backend'), LocalStateKey.privateBackend);
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
    },
  );

  test('private mode ignores an obsolete Keystore fallback', () async {
    final first = await open();
    await first.put('favorite', 'latest');
    first.dispose();
    await file(LocalStateKey.locationName).writeAsString(
      jsonEncode({
        ...await location(),
        'fallback': {'namespace': null},
      }),
      flush: true,
    );
    await losePrivateRecords();
    legacy.broken = true;
    nativeBroken = true;
    await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
    expect(nativeCalls, 0);
    expect(legacy.reads, 0);
  });

  for (final namespaced in [false, true]) {
    test(
      'healthy legacy storage migrates once (namespace=$namespaced)',
      () async {
        final key = await seedLegacy(namespaced: namespaced);
        final encrypted = await file('state-v1.enc').readAsBytes();
        final oldValue = await legacy.read(key: StateStore.keyName);
        nativeBroken = true;
        final migrated = await open();
        expect(migrated.data['favorite'], 'latest');
        migrated.dispose();
        final pointer = await location();
        expect(pointer.str('backend'), LocalStateKey.privateBackend);
        expect(await keyFile(pointer.str('namespace')).readAsBytes(), key);
        expect(await legacy.read(key: StateStore.keyName), oldValue);
        expect(await file('state-v1.enc').readAsBytes(), encrypted);
        legacy.broken = true;
        final reads = legacy.reads, writes = legacy.writes;
        for (var i = 0; i < 3; i++) {
          final next = await open();
          expect(next.data['favorite'], 'latest');
          next.dispose();
        }
        expect(await location(), pointer);
        expect(legacy.reads, reads);
        expect(legacy.writes, writes);
        expect(nativeCalls, 0);
      },
    );
  }

  test(
    'healthy native key migrates unchanged before Keystore can fail',
    () async {
      final old = await seedNative(data: {'favorite': 'latest'});
      final encrypted = await file('state-v1.enc').readAsBytes();
      final first = await open();
      expect(first.data['favorite'], 'latest');
      first.dispose();
      final pointer = await location();
      expect(pointer.str('backend'), LocalStateKey.privateBackend);
      expect(await keyFile(pointer.str('namespace')).readAsBytes(), old.key);
      expect(records[old.namespace]![false], old.key);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      nativeBroken = true;
      legacy.broken = true;
      final calls = nativeCalls;
      for (var i = 0; i < 3; i++) {
        final next = await open();
        expect(next.data['favorite'], 'latest');
        next.dispose();
      }
      expect(nativeCalls, calls);
      expect(legacy.reads, 0);
      expect(legacy.writes, 0);
    },
  );

  test(
    'failed migration preserves native pointer and data until retry',
    () async {
      await seedNative(data: {'favorite': 'latest'});
      final pointer = await file(LocalStateKey.locationName).readAsBytes();
      final encrypted = await file('state-v1.enc').readAsBytes();
      final blocker = Directory(file('${LocalStateKey.locationName}.tmp').path);
      await blocker.create();
      final readable = await open();
      expect(readable.data['favorite'], 'latest');
      readable.dispose();
      expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      await blocker.delete();
      final retry = await open();
      expect(retry.data['favorite'], 'latest');
      retry.dispose();
      expect((await location()).str('backend'), LocalStateKey.privateBackend);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
    },
  );

  test(
    'wrong legacy keys cannot migrate or overwrite encrypted data',
    () async {
      await seedLegacy();
      final encrypted = await file('state-v1.enc').readAsBytes();
      final wrongKey = base64Encode(CryptoBox.random(32));
      FlutterSecureStorage.setMockInitialValues({
        StateStore.keyName: wrongKey,
        '${StateStore.keyName}.copy': wrongKey,
      });
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file(LocalStateKey.locationName).exists(), isFalse);
      expect(
        await Directory(file(LocalStateKey.privateDirectoryName).path).exists(),
        isFalse,
      );
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      expect(nativeCalls, 0);
    },
  );

  test(
    'broken legacy storage with existing data cannot become an empty install',
    () async {
      await seedLegacy();
      final encrypted = await file('state-v1.enc').readAsBytes();
      legacy.broken = true;
      nativeBroken = true;
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file(LocalStateKey.locationName).exists(), isFalse);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
    },
  );

  for (final namespaced in [false, true]) {
    for (final wrongKey in [false, true]) {
      test('native failure migrates authenticated legacy fallback '
          '(namespace=$namespaced, wrongKey=$wrongKey)', () async {
        final key = await seedLegacy(namespaced: namespaced);
        final fallback = namespaced ? await location() : {'namespace': null};
        final native = await seedNative(
          key: key,
          data: {'favorite': 'latest'},
          fallback: fallback,
        );
        final encrypted = await file('state-v1.enc').readAsBytes();
        if (wrongKey) {
          records[native.namespace] = {
            false: CryptoBox.random(32),
            true: CryptoBox.random(32),
          };
        } else {
          blocked.add(native.namespace);
        }
        final migrated = await open();
        expect(migrated.data['favorite'], 'latest');
        migrated.dispose();
        expect((await location()).str('backend'), LocalStateKey.privateBackend);
        expect(await file('state-v1.enc').readAsBytes(), encrypted);
        expect(records.containsKey(native.namespace), isTrue);
        nativeBroken = true;
        legacy.broken = true;
        final calls = nativeCalls, reads = legacy.reads;
        final next = await open();
        expect(next.data['favorite'], 'latest');
        next.dispose();
        expect(nativeCalls, calls);
        expect(legacy.reads, reads);
      });
    }
  }

  test(
    'stale native fallback cannot roll newer data back to an old snapshot',
    () async {
      await seedLegacy();
      final older = await file('state-v1.enc').readAsBytes();
      final native = await seedNative(
        data: {'favorite': 'new-key-data'},
        fallback: {'namespace': null},
      );
      await file('state-v1.enc.bak').writeAsBytes(older, flush: true);
      final current = await file('state-v1.enc').readAsBytes();
      final pointer = await file(LocalStateKey.locationName).readAsBytes();
      blocked.add(native.namespace);
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file('state-v1.enc').readAsBytes(), current);
      expect(await file('state-v1.enc.bak').readAsBytes(), older);
      expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
      // Interrupted commits can have a newer .tmp without the primary.
      await file('state-v1.enc').rename(file('state-v1.enc.tmp').path);
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file('state-v1.enc.tmp').readAsBytes(), current);
      expect(await file('state-v1.enc').exists(), isFalse);
      expect(
        await Directory(file(LocalStateKey.privateDirectoryName).path).exists(),
        isFalse,
      );
    },
  );

  test(
    'different private key never retains or accepts a stale fallback',
    () async {
      final first = await open();
      await first.put('favorite', 'old');
      first.dispose();
      final oldPointer = await location();
      final older = await file('state-v1.enc').readAsBytes();
      final key = CryptoBox.random(32);
      await keys().saveFresh(key);
      expect((await location())['fallback'], isNull);
      final current = CryptoBox.seal(
        key,
        utf8.encode('{"schema":1,"favorite":"latest"}'),
      );
      await file('state-v1.enc').writeAsBytes(current, flush: true);
      await file('state-v1.enc.bak').writeAsBytes(older, flush: true);
      await losePrivateRecords();
      final pointer = {...await location(), 'fallback': oldPointer};
      await file(
        LocalStateKey.locationName,
      ).writeAsString(jsonEncode(pointer), flush: true);
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file('state-v1.enc').readAsBytes(), current);
      expect(await file('state-v1.enc.bak').readAsBytes(), older);
      expect(await location(), pointer);
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
    },
  );

  test('invalid namespace is rejected before any key access', () async {
    await file(LocalStateKey.locationName).writeAsString(
      jsonEncode({
        'namespace': '../outside',
        'backend': LocalStateKey.privateBackend,
      }),
      flush: true,
    );
    await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
    expect(nativeCalls, 0);
    expect(legacy.reads, 0);
    expect(await file('state-v1.enc').exists(), isFalse);
  });

  test(
    'invalid optional fallback cannot break healthy private storage',
    () async {
      final first = await open();
      await first.put('favorite', 'kept');
      first.dispose();
      await file(LocalStateKey.locationName).writeAsString(
        jsonEncode({
          ...await location(),
          'fallback': {'namespace': '../invalid'},
        }),
        flush: true,
      );
      final next = await open();
      expect(next.data['favorite'], 'kept');
      next.dispose();
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
    },
  );

  test(
    'temporary native failure preserves data, retry then migrates',
    () async {
      final native = await seedNative(data: {'favorite': 'kept'});
      final pointer = await file(LocalStateKey.locationName).readAsBytes();
      final encrypted = await file('state-v1.enc').readAsBytes();
      blocked.add(native.namespace);
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
      expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
      blocked.clear();
      final next = await open();
      expect(next.data['favorite'], 'kept');
      next.dispose();
      expect((await location()).str('backend'), LocalStateKey.privateBackend);
    },
  );

  test(
    'missing native records behind a pointer never initialize silently',
    () async {
      await seedNative(data: {'favorite': 'kept'});
      final pointer = await file(LocalStateKey.locationName).readAsBytes();
      final encrypted = await file('state-v1.enc').readAsBytes();
      records.clear();
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
      expect(await file('state-v1.enc').readAsBytes(), encrypted);
    },
  );

  test(
    'native primary damage migrates the key from its authenticated copy',
    () async {
      final native = await seedNative(data: {'favorite': 'latest'});
      records[native.namespace]![false] = CryptoBox.random(32);
      final migrated = await open();
      expect(migrated.data['favorite'], 'latest');
      migrated.dispose();
      expect(
        await keyFile((await location()).str('namespace')).readAsBytes(),
        native.key,
      );
      expect(records[native.namespace]![true], native.key);
    },
  );

  test(
    'export password restores newest native state without working Keystore',
    () async {
      await seedNative(data: {'favorite': 'at-export'});
      // Simulate an unlocked old installation whose compatibility migration could
      // not yet finish. Export must still protect its in-memory, authenticated key.
      final blocker = file(LocalStateKey.privateDirectoryName);
      await blocker.writeAsString('occupied');
      final initial = await open();
      try {
        final pointer = await file(LocalStateKey.locationName).readAsBytes();
        final encrypted = await file('state-v1.enc').readAsBytes();
        await LegacyBackupFixture(
          initial,
        ).exportTo(password, (_) async => true);
        expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
        expect(await file('state-v1.enc').readAsBytes(), encrypted);
        await initial.put('favorite', 'after-export');
      } finally {
        initial.dispose();
      }
      final latest = await file('state-v1.enc').readAsBytes();
      await blocker.delete();
      nativeBroken = true;
      legacy.broken = true;
      await expectLater(open(), throwsA(isA<StateRecoveryRequired>()));
      await recovery().unlock(password);
      final calls = nativeCalls;
      final next = await open();
      expect(next.data['favorite'], 'after-export');
      next.dispose();
      expect((await location()).str('backend'), LocalStateKey.privateBackend);
      expect(await file('state-v1.enc').readAsBytes(), latest);
      expect(nativeCalls, calls);
      expect(legacy.reads, 0);
      expect(legacy.writes, 0);
    },
  );

  test(
    'private import and password recovery survive total Keystore failure',
    () async {
      legacy.broken = true;
      nativeBroken = true;
      final first = await open();
      final pointer = await file(LocalStateKey.locationName).readAsBytes();
      final key = (await keys().read()).keys.single;
      await LegacyBackupFixture(first).restore(backup, password);
      await first.put('after-import', true);
      first.dispose();
      expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
      final latest = await file('state-v1.enc').readAsBytes();
      await losePrivateRecords();
      await expectLater(
        recovery().unlock('wrong-password'),
        throwsA(isA<AppException>()),
      );
      expect(await file(LocalStateKey.locationName).readAsBytes(), pointer);
      await recovery().unlock(password);
      for (var i = 0; i < 3; i++) {
        final next = await open();
        expect(next.data['after-import'], true);
        expect(
          Vault(next).credential(CloudPlatform.baidu)?.primary,
          'BDUSS=fixture-only',
        );
        next.dispose();
      }
      expect((await keys().read()).keys.single, key);
      expect(await file('state-v1.enc').readAsBytes(), latest);
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
      expect(legacy.writes, 0);
    },
  );

  test(
    'backup restore archives locked native data and uses private storage',
    () async {
      await seedNative(data: {'favorite': 'old'});
      final original = await file('state-v1.enc').readAsBytes();
      final pointer = await file(LocalStateKey.locationName).readAsBytes();
      nativeBroken = true;
      legacy.broken = true;
      final result = await recovery().restore(backup, password);
      expect(result.accounts, 1);
      expect(
        await File('${result.archive.path}/state-v1.enc').readAsBytes(),
        original,
      );
      expect(
        await File(
          '${result.archive.path}/${LocalStateKey.locationName}',
        ).readAsBytes(),
        pointer,
      );
      final calls = nativeCalls;
      for (var i = 0; i < 3; i++) {
        final next = await open();
        expect(next.data.obj('settings').str('theme'), 'Dark');
        expect(
          Vault(next).credential(CloudPlatform.baidu)?.primary,
          'BDUSS=fixture-only',
        );
        next.dispose();
      }
      expect(await file('state-v2.json').exists(), isTrue);
      expect(nativeCalls, calls);
      expect(legacy.reads, 0);
      expect(legacy.writes, 0);
    },
  );

  test(
    'reinitialize works with both old OS backends completely unavailable',
    () async {
      await seedLegacy();
      final original = await file('state-v1.enc').readAsBytes();
      nativeBroken = true;
      legacy.broken = true;
      final writes = legacy.writes;
      final result = await recovery().reinitialize();
      expect(
        await File('${result.archive.path}/state-v1.enc').readAsBytes(),
        original,
      );
      final reads = legacy.reads;
      for (var i = 0; i < 3; i++) {
        final next = await open();
        expect(next.data['favorite'], isNull);
        next.dispose();
      }
      expect(await file('state-v2.json').exists(), isTrue);
      expect(nativeCalls, 0);
      expect(legacy.reads, reads);
      expect(legacy.writes, writes);
    },
  );

  test(
    'failed replacement rolls back snapshot, pointer and recovery envelope',
    () async {
      final first = await open();
      await LegacyBackupFixture(first).restore(backup, password);
      first.dispose();
      final originals = {
        for (final name in [
          'state-v1.enc',
          LocalStateKey.locationName,
          LocalStateKey.recoveryName,
        ])
          name: await file(name).readAsBytes(),
      };
      await losePrivateRecords();
      final blocker = Directory(file('state-v2.json.tmp').path);
      await blocker.create();
      await expectLater(
        recovery().reinitialize(),
        throwsA(isA<FileSystemException>()),
      );
      for (final entry in originals.entries) {
        expect(await file(entry.key).readAsBytes(), entry.value);
      }
      await blocker.delete();
      await recovery().unlock(password);
      final next = await open();
      expect(
        Vault(next).credential(CloudPlatform.baidu)?.primary,
        'BDUSS=fixture-only',
      );
      next.dispose();
      expect(nativeCalls, 0);
      expect(legacy.reads, 0);
    },
  );
}
