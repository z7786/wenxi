import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/platform/native_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late List<Json> opens;
  late String? returnedKey;
  late bool failOpen;
  final nativeKey = base64Encode(List.filled(32, 31));
  final unusedOldKey = base64Encode(List.filled(32, 17));
  const password = 'fixture-password';
  const storage = FlutterSecureStorage();

  LocalStateKey keys() => LocalStateKey(root, storage, nativeAndroid: true);
  Future<StateStore> openStore() => StateStore.open(root, localKey: keys());
  GopeedEngine engine(StateStore store) => GopeedEngine(
    AndroidGopeedTransport(),
    store,
    Vault(store),
    Directory('${root.path}/gopeed'),
    Directory('${root.path}/cache'),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('engine-key-recovery-');
    opens = [];
    returnedKey = nativeKey;
    failOpen = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, (call) async {
          // No state-key or legacy secure-storage method may reach Android.
          expect(call.method, 'gopeed');
          final envelope = asJson(call.arguments);
          final args = asJson(jsonDecode(envelope.str('args')));
          if (envelope.str('method') == 'open') {
            opens.add(args);
            if (failOpen) {
              throw PlatformException(
                code: 'operation',
                message: 'fixture failure',
              );
            }
            return returnedKey == null
                ? 'null'
                : jsonEncode({'key': returnedKey});
          }
          return 'null';
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeChannel, null);
    await root.delete(recursive: true);
  });

  test(
    'legacy native key survives plain-state restart without system keys',
    () async {
      final store = await openStore();
      final generation = List.filled(32, 'a').join();
      await store.put('engineStorageGeneration', generation);
      await Vault(store).putSecret('flutter.gopeed.key', unusedOldKey);
      await BackupRepository(store).exportTo(password, (_) async => true);
      final first = engine(store);
      await first.begin({'id': 'fixture-task'});
      expect(opens.single.str('key'), unusedOldKey);
      expect(opens.single.str('storageGeneration'), generation);
      expect(Vault(store).secret('flutter.gopeed.key'), nativeKey);
      await first.transport.dispose();
      store.dispose();

      expect(
        await keys().localFile(LocalStateKey.locationName).exists(),
        isFalse,
      );
      final recovered = await openStore();
      expect(Vault(recovered).secret('flutter.gopeed.key'), nativeKey);
      final restarted = engine(recovered);
      await restarted.begin({'id': 'fixture-task'});
      expect(opens.last.str('key'), nativeKey);
      expect(opens.last.str('storageGeneration'), generation);
      await restarted.transport.dispose();
      recovered.dispose();
    },
  );

  test(
    'older native open responses retain the current device engine key',
    () async {
      returnedKey = null;
      final store = await openStore();
      await Vault(store).putSecret('flutter.gopeed.key', unusedOldKey);
      final current = engine(store);
      await current.begin({'id': 'fixture-task'});
      expect(Vault(store).secret('flutter.gopeed.key'), unusedOldKey);
      expect(opens.single.str('storageGeneration'), isEmpty);
      await current.transport.dispose();
      store.dispose();
    },
  );

  test(
    'invalid returned key cannot replace the persisted engine key',
    () async {
      returnedKey = 'invalid!fixture';
      final store = await openStore();
      await Vault(store).putSecret('flutter.gopeed.key', unusedOldKey);
      final current = engine(store);
      await expectLater(
        current.begin({'id': 'fixture-task'}),
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '下载组件密钥格式错误'),
        ),
      );
      expect(Vault(store).secret('flutter.gopeed.key'), unusedOldKey);
      await current.transport.dispose();
      store.dispose();
    },
  );

  test('failed native open preserves the previous engine key', () async {
    failOpen = true;
    final store = await openStore();
    await Vault(store).putSecret('flutter.gopeed.key', unusedOldKey);
    final current = engine(store);
    await expectLater(
      current.begin({'id': 'fixture-task'}),
      throwsA(isA<AppException>()),
    );
    expect(Vault(store).secret('flutter.gopeed.key'), unusedOldKey);
    await current.transport.dispose();
    store.dispose();
  });
}
