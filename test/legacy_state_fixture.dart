import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_key.dart';
import 'package:asterlink/data/state_store.dart';

/// Test-only writer for the v1 app format. Production writes only v2 plain data.
/// Old key tests exercise the legacy reader; migration tests use StateStore.open.
class LegacyStateFixture extends ChangeNotifier implements StateStore {
  LegacyStateFixture._(this.file, this.key, this.localKey, Json data)
    : memory = StateStore.memory(data);
  @override
  final File file;
  final Uint8List key;
  final LocalStateKey? localKey;
  final StateStore memory;
  final gate = AsyncGate();
  @override
  Json get data => memory.data;

  static Future<StateStore> open(
    Directory directory, {
    Uint8List? testKey,
    FlutterSecureStorage storage = StateStore.secureStorage,
    LocalStateKey? localKey,
  }) async {
    if (await File('${directory.path}/state-v2.json').exists() ||
        await File('${directory.path}/state-v2.json.tmp').exists() ||
        await File('${directory.path}/state-v2.json.bak').exists()) {
      return StateStore.open(directory, storage: storage, localKey: localKey);
    }
    localKey ??= testKey == null ? LocalStateKey(directory, storage) : null;
    final legacy = await StateStore.readLegacySnapshot(
      directory,
      testKey: testKey,
      storage: storage,
      localKey: localKey,
    );
    return LegacyStateFixture._(
      File('${directory.path}/state-v1.enc'),
      legacy.key,
      localKey,
      legacy.data,
    );
  }

  @override
  Future<T> change<T>(T Function(Json) edit, {String? recoveryPassword}) =>
      gate.run(() async {
        final draft = asJson(jsonDecode(jsonEncode(data)));
        final result = edit(draft);
        draft['schema'] = 1;
        if (jsonEncode(data) == jsonEncode(draft) && recoveryPassword == null) {
          return result;
        }
        final protected = recoveryPassword != null && localKey != null;
        final originals = <String, Uint8List?>{};
        if (protected) {
          for (final path in [
            file.path,
            '${file.path}.bak',
            '${file.path}.tmp',
            for (final name in LocalStateKey.sidecars)
              localKey!.localFile(name).path,
          ]) {
            final source = File(path);
            originals[path] = await source.exists()
                ? await source.readAsBytes()
                : null;
          }
        }
        try {
          Uint8List? capsule;
          if (protected) {
            capsule = await localKey!.prepareRecovery(key, recoveryPassword);
            await localKey!.saveForImport(key);
          }
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsBytes(
            CryptoBox.seal(key, utf8.encode(jsonEncode(draft))),
            flush: true,
          );
          if (await file.exists()) {
            final backup = File('${file.path}.bak');
            if (await backup.exists()) await backup.delete();
            await file.rename(backup.path);
          }
          await temporary.rename(file.path);
          if (protected) await localKey!.installRecovery(capsule!);
        } catch (_) {
          if (protected) {
            for (final entry in originals.entries) {
              final target = File(entry.key);
              if (entry.value != null) {
                final rollback = File('${entry.key}.rollback');
                await rollback.writeAsBytes(entry.value!, flush: true);
                await rollback.rename(entry.key);
              } else if (await target.exists()) {
                await target.delete();
              }
            }
          }
          rethrow;
        }
        await memory.change((value) {
          value.clear();
          value.addAll(draft);
        });
        notifyListeners();
        return result;
      });
  @override
  Future<void> put(String name, Object? value) => change((draft) {
    draft[name] = value;
  });
  @override
  Future<void> flush() => gate.run(() async {});
  @override
  Future<void> protectRecovery(String password) async {
    if (!await file.exists()) {
      await file.writeAsBytes(
        CryptoBox.seal(key, utf8.encode(jsonEncode(data))),
        flush: true,
      );
    }
    final local = localKey;
    if (local != null) {
      final sealed = await local.prepareRecovery(key, password);
      await local.installRecovery(sealed);
    }
  }

  @override
  void dispose() {
    memory.dispose();
    super.dispose();
  }
}

/// Old exported files/password capsules are fixtures, never new app behavior.
class LegacyBackupFixture extends BackupRepository {
  LegacyBackupFixture(super.store);
  @override
  Future<Uint8List> create(
    String password, {
    bool includeBackgroundImages = false,
  }) async {
    final plain = await super.create(
      '',
      includeBackgroundImages: includeBackgroundImages,
    );
    return encryptBackup((decryptBackup((plain, '')), password));
  }

  @override
  Future<bool> exportTo(
    String password,
    Future<bool> Function(Uint8List) save, {
    bool includeBackgroundImages = false,
  }) async {
    final bytes = await create(
      password,
      includeBackgroundImages: includeBackgroundImages,
    );
    RequestScope.checkpoint();
    if (!await save(bytes)) return false;
    try {
      await store.protectRecovery(password);
    } catch (_) {
      throw const AppException('备份文件已导出，但本地恢复保护保存失败');
    }
    return true;
  }
}
