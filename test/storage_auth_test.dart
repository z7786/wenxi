import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/legacy_import.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('AES-GCM rejects modified ciphertext without disclosing plaintext', () {
    final key = CryptoBox.random(32),
        original = CryptoBox.seal(key, utf8.encode('cookie=fixture-private'));
    expect(
      utf8.decode(CryptoBox.open(key, original)),
      'cookie=fixture-private',
    );
    original[20] ^= 1;
    expect(() => CryptoBox.open(key, original), throwsA(isA<AppException>()));
  });
  test(
    'Atomic plain state survives corrupt primary and a later interrupted update',
    () async {
      final directory = await Directory.systemTemp.createTemp('aster-state-');
      addTearDown(() => directory.delete(recursive: true));
      final key = CryptoBox.random(32),
          store = await StateStore.open(directory, testKey: key);
      await store.put('cookie', 'fixture-cookie-secret');
      await store.put('counter', 2);
      final file = File('${directory.path}/state-v2.json');
      expect(
        utf8
            .decode(await file.readAsBytes(), allowMalformed: true)
            .contains('fixture-cookie-secret'),
        isTrue,
      );
      await file.writeAsString('corrupt');
      final recovered = await StateStore.open(directory, testKey: key);
      expect(recovered.data.str('cookie'), 'fixture-cookie-secret');
      await recovered.put('counter', 3);
      await file.writeAsString('another interrupted write');
      final again = await StateStore.open(directory, testKey: key);
      expect(again.data.str('cookie'), 'fixture-cookie-secret');
      expect(again.data['counter'], isNull);
      expect(
        directory.listSync().where((e) => e.path.contains('.corrupt-')).length,
        2,
      );
    },
  );
  test(
    'State changes are serialized and failed edits do not damage following commits',
    () async {
      final store = StateStore.memory({'n': 0});
      await Future.wait(
        List.generate(
          40,
          (_) => store.change((d) => d['n'] = d.integer('n') + 1),
        ),
      );
      expect(store.data.integer('n'), 40);
      await expectLater(
        store.change<void>((_) => throw const AppException('fixture')),
        throwsA(isA<AppException>()),
      );
      await store.put('after', true);
      expect(store.data.boolean('after'), isTrue);
    },
  );

  test(
    'A failed edit of nested download ranges cannot mutate committed state',
    () async {
      final store = StateStore.memory({
        'tasks': [
          {
            'name': 'original',
            'ranges': [
              [0, 1024],
              [2048, 4096],
            ],
          },
        ],
      });
      final original = jsonEncode(store.data);
      await expectLater(
        store.change<void>((draft) {
          final task = (draft['tasks'] as List).single as Map;
          task['name'] = 'changed';
          ((task['ranges'] as List).first as List)[0] = 999;
          throw const AppException('fixture edit failed');
        }),
        throwsA(isA<AppException>()),
      );
      expect(jsonEncode(store.data), original);
      await store.put('after', true);
      expect((store.data.list('tasks').single['ranges'] as List).first, [
        0,
        1024,
      ]);
    },
  );

  test(
    'unchanged state preserves plain files and does not notify observers',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'aster-state-noop-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final key = CryptoBox.random(32);
      final store = await StateStore.open(directory, testKey: key);
      await store.put('settings', {
        'nested': [
          1,
          2,
          {'value': 'kept'},
        ],
      });
      await store.put('counter', 7);
      final file = File('${directory.path}/state-v2.json');
      final backup = File('${file.path}.bak');
      final before = await file.readAsBytes(),
          beforeBackup = await backup.readAsBytes();
      var changes = 0;
      store.addListener(() => changes++);
      final value = await store.change((draft) {
        draft['settings'] = {
          'nested': [
            1,
            2,
            {'value': 'kept'},
          ],
        };
        return draft.integer('counter');
      });
      expect(value, 7);
      expect(changes, 0);
      expect(await file.readAsBytes(), before);
      expect(await backup.readAsBytes(), beforeBackup);
      await store.put('counter', 8);
      expect(changes, 1);
      expect(
        (await StateStore.open(
          directory,
          testKey: key,
        )).data.integer('counter'),
        8,
      );
    },
  );
  test(
    'Unrecognized future state schema is not silently replaced by an older backup',
    () async {
      final dir = await Directory.systemTemp.createTemp('aster-schema-');
      addTearDown(() => dir.delete(recursive: true));
      final key = CryptoBox.random(32), file = File('${dir.path}/state-v1.enc');
      await file.writeAsBytes(CryptoBox.seal(key, utf8.encode('{"schema":2}')));
      await File(
        '${file.path}.bak',
      ).writeAsBytes(CryptoBox.seal(key, utf8.encode('{"schema":1}')));
      await expectLater(
        StateStore.open(dir, testKey: key),
        throwsA(isA<AppException>()),
      );
    },
  );
  test(
    'Cancelled login never replaces a previously working credential',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          ready = Completer<CloudAccount>();
      final old = Credential('old', {'primary': 'BDUSS=old'}, updatedAt: 1);
      await vault.putCredential(CloudPlatform.baidu, old);
      final login = AccountLoginService(vault, (_, _) => ready.future);
      final pending = login.submitWeb(CloudPlatform.baidu, 'BDUSS=new');
      final result = expectLater(pending, throwsA(isA<AppException>()));
      login.invalidate(CloudPlatform.baidu);
      ready.complete(const CloudAccount('new'));
      await result;
      expect(vault.credential(CloudPlatform.baidu)!.sameAs(old), isTrue);
    },
  );
  test('Concurrent logout wins over an in-flight password login', () async {
    final store = StateStore.memory(),
        vault = Vault(store),
        pending = Completer<LoginResult>();
    final login = AccountLoginService(
      vault,
      (_, _) async => const CloudAccount('x'),
    );
    final result = expectLater(
      login.submit(CloudPlatform.pan123, (_) => pending.future),
      throwsA(isA<AppException>()),
    );
    await login.remove(CloudPlatform.pan123);
    pending.complete(
      LoginResult(
        Credential('new', {'primary': 'new', 'secondary': 'pass'}),
        const CloudAccount('new'),
      ),
    );
    await result;
    expect(vault.credential(CloudPlatform.pan123), isNull);
  });
  test(
    'A stale 123 token cannot be committed after account replacement',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      final first = Credential('first', {
        'primary': 'one',
        'secondary': 'pass',
      }, updatedAt: 1);
      await vault.putCredential(CloudPlatform.pan123, first);
      await vault.putCredential(
        CloudPlatform.pan123,
        Credential('second', {
          'primary': 'two',
          'secondary': 'pass',
        }, updatedAt: 2),
      );
      expect(
        await vault.putSecretForCredential(
          CloudPlatform.pan123,
          first,
          'pan123.access_token',
          'old-token',
        ),
        isFalse,
      );
      expect(vault.secret('pan123.access_token'), isNull);
    },
  );
  test(
    'Cookie-only login remains available when the optional nickname endpoint fails',
    () async {
      final store = StateStore.memory(),
          vault = Vault(store),
          login = AccountLoginService(
            Vault(store),
            (_, _) async => throw const AppException('quota unavailable'),
          );
      await login.submitWeb(CloudPlatform.quark, '__pus=a; __puus=b');
      expect(
        vault.credential(CloudPlatform.quark)!.primary,
        '__pus=a; __puus=b',
      );
      await expectLater(
        login.submitWeb(CloudPlatform.pan123, 'candidate-token'),
        throwsA(isA<AppException>()),
      );
      expect(vault.credential(CloudPlatform.pan123), isNull);
    },
  );
  test(
    'Automatic Xunlei access-token renewal preserves the account revision',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      final old = Credential('x', {'primary': 'old'}, updatedAt: 123);
      await vault.putCredential(CloudPlatform.xunlei, old);
      final connector = XunleiConnector(
        FakeHttp(),
        vault,
        XunleiDevices(vault),
      );
      await connector.persist(
        XunleiSession(
          old,
          'new',
          'refresh',
          'device',
          'captcha',
          'client',
          'secret',
          'version',
        ),
      );
      expect(vault.credential(CloudPlatform.xunlei)!.updatedAt, 123);
      expect(vault.credential(CloudPlatform.xunlei)!.primary, 'new');
    },
  );
  test(
    'Original JVM backups decrypt in Dart and cannot retain another 123 account token',
    () async {
      final store = StateStore.memory({
        'secrets': {'pan123.access_token': 'wrong-old-account'},
        'credentials': {
          'Quark': Credential('old', {
            'primary': 'old',
          }, updatedAt: 9999999999999).toJson(),
        },
      });
      final bytes = await File(
        'test/fixtures/legacy-jvm-backup.json',
      ).readAsBytes();
      expect(await BackupRepository(store).restore(bytes, '测试密码123'), 2);
      final vault = Vault(store),
          settings = AppSettings.fromJson(store.data.obj('settings'));
      expect(
        vault.credential(CloudPlatform.quark)!.primary,
        '__pus=fixture; __puus=test-only',
      );
      expect(vault.secret('pan123.access_token'), isNull);
      expect(vault.credential(CloudPlatform.quark)!.updatedAt, 10000000000000);
      expect(settings.theme, 'Dark');
      expect(settings.threads, 32);
      expect(settings.destination, isNull);
      expect(settings.threadOverrides['uc'], 128);
    },
  );
  test(
    'Wrong backup passwords and tampered backups leave all existing state unchanged',
    () async {
      final store = StateStore.memory({
        'settings': {'theme': 'Light'},
        'secrets': {'fixture': 'kept'},
      });
      final before = jsonEncode(store.data),
          bytes = await File(
            'test/fixtures/legacy-jvm-backup.json',
          ).readAsBytes();
      await expectLater(
        BackupRepository(store).restore(bytes, 'wrong-password'),
        throwsA(isA<AppException>()),
      );
      expect(jsonEncode(store.data), before);
      final envelope = asJson(jsonDecode(utf8.decode(bytes))),
          encrypted = base64Decode(envelope.str('data'));
      encrypted[4] ^= 1;
      envelope['data'] = base64Encode(encrypted);
      await expectLater(
        BackupRepository(store).restore(
          Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
          '测试密码123',
        ),
        throwsA(isA<AppException>()),
      );
      expect(jsonEncode(store.data), before);
    },
  );
  test(
    'Backup export excludes native encryption keys, paths and signed task URLs',
    () async {
      final store = StateStore.memory({
        'settings': {'destination': 'D:/private'},
        'secrets': {
          'flutter.gopeed.key': 'DO-NOT-EXPORT',
          'pan123.login_uuid': 'test',
        },
        'tasks': [
          {'url': 'https://example.com/?signed=secret'},
        ],
      });
      final bytes = await BackupRepository(store).create('fixture-password');
      final payload = decryptBackup((bytes, 'fixture-password')),
          text = jsonEncode(payload);
      expect(text.contains('DO-NOT-EXPORT'), isFalse);
      expect(text.contains('signed=secret'), isFalse);
      expect(text.contains('D:/private'), isFalse);
      expect(payload.obj('secrets').str('pan123.login_uuid'), 'test');
    },
  );
  test(
    'Legacy import is atomic, one-time, and preserves exported files and paused checkpoints',
    () async {
      final store = StateStore.memory();
      final snapshot = <String, dynamic>{
        'credentials': {
          'Quark': Credential('quark', {
            'primary': '__pus=a; __puus=b',
          }, updatedAt: 42).toJson(),
        },
        'settings': {'threads': 512},
        'tasks': [
          {
            'id': 'legacy-1',
            'url': 'https://example.com/a',
            'fileName': 'a.zip',
            'status': 'running',
            'totalBytes': 100,
            'downloadedBytes': 25,
            'threadCount': 64,
            'headers': {},
            'remoteEtag': '"version1"',
          },
          {
            'id': 'legacy-2',
            'url': 'https://example.com/b',
            'fileName': 'b.zip',
            'status': 'completed',
            'totalBytes': 200,
            'downloadedBytes': 200,
            'savedUri': 'content://fixture/file',
            'headers': {},
          },
        ],
      };
      expect(await LegacyImporter(store).import(snapshot), 2);
      final tasks = store.data.list('tasks');
      expect(tasks[0].str('status'), 'paused');
      expect(tasks[0].integer('downloaded'), 25);
      expect(tasks[1].str('savedPath'), 'content://fixture/file');
      expect(Vault(store).credential(CloudPlatform.quark)!.updatedAt, 42);
      expect(await LegacyImporter(store).import(snapshot), 0);
      expect(store.data.list('tasks').length, 2);
    },
  );
  test(
    'Malformed legacy records fail before importing any credentials',
    () async {
      final store = StateStore.memory({'existing': true});
      await expectLater(
        LegacyImporter(store).import({
          'tasks': [
            {'id': '../escape'},
          ],
          'credentials': {},
        }),
        throwsA(isA<AppException>()),
      );
      expect(store.data, {'existing': true});
    },
  );
}
