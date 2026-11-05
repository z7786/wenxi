import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import '../core/crypto_box.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../diagnostics/app_log.dart';
import 'state_key.dart';

Json _decryptSnapshot((Uint8List, Uint8List) args) =>
    asJson(jsonDecode(utf8.decode(CryptoBox.open(args.$1, args.$2))));

Uint8List encodePlainState(Json data) {
  final serialized = jsonEncode(data);
  return _packPlainState(serialized);
}

Uint8List _packPlainState(String serialized) {
  final checksum = sha256.convert(utf8.encode(serialized)).toString();
  return Uint8List.fromList(
    utf8.encode(
      '{"format":"asterlink-state-v2","sha256":"$checksum","data":$serialized}',
    ),
  );
}

Json decodePlainState(Uint8List bytes) {
  final raw = jsonDecode(utf8.decode(bytes));
  require(raw is Map, '本地数据格式错误');
  final envelope = asJson(raw);
  require(
    envelope.str('format') == 'asterlink-state-v2' && envelope['data'] is Map,
    '本地数据格式错误',
  );
  final data = envelope.obj('data');
  require(
    sha256.convert(utf8.encode(jsonEncode(data))).toString() ==
        envelope.str('sha256'),
    '本地数据文件已损坏',
  );
  require(data.integer('schema', 1) == 1, '本地数据来自更新版本，请更新应用');
  return data;
}

Object? _copyStateValue(Object? value) => switch (value) {
  Map() => <String, dynamic>{
    for (final entry in value.entries)
      entry.key.toString(): _copyStateValue(entry.value),
  },
  List() => [for (final item in value) _copyStateValue(item)],
  _ => value,
};

typedef _EncodedChange = ({
  bool changed,
  Uint8List? bytes,
  int serializeMs,
  int packMs,
});

_EncodedChange _encodeChange((bool, Json, Json, bool) args) {
  final timer = Stopwatch()..start();
  final changed =
      args.$4 || !const DeepCollectionEquality().equals(args.$2, args.$3);
  final serialized = changed && args.$1 ? jsonEncode(args.$3) : '';
  final serializeMs = timer.elapsedMilliseconds;
  timer.reset();
  final bytes = changed && args.$1 ? _packPlainState(serialized) : null;
  return (
    changed: changed,
    bytes: bytes,
    serializeMs: serializeMs,
    packMs: timer.elapsedMilliseconds,
  );
}

enum StateRecoveryCause {
  missingKey,
  invalidKey,
  unreadableData,
  secureStorageUnavailable,
}

class StateRecoveryRequired extends AppException {
  const StateRecoveryRequired(this.directory, this.cause)
    : super(
        cause == StateRecoveryCause.secureStorageUnavailable
            ? '本地密钥读取失败，可能是设备存储兼容或密钥访问异常。原文件已保留，请重试；仍无法进入时，可使用下方的恢复方式。'
            : '本地账号和设置暂时无法读取，原文件已保留。可以尝试下方的恢复方式。',
      );
  final Directory directory;
  final StateRecoveryCause cause;
}

/// New snapshots are plain JSON with a checksum and atomic backup rotation.
/// Legacy encrypted snapshots are read only during the first migration.
class StateStore extends ChangeNotifier {
  static const keyName = LocalStateKey.name;
  static const secureStorage = FlutterSecureStorage(
    aOptions: LocalStateKey.options,
  );
  StateStore._(this.file, this._data);
  final File? file;
  Json _data;
  final _gate = AsyncGate();
  final _notificationZone = Zone.current;
  Json get data => _data;

  static Future<StateStore> open(
    Directory directory, {
    Uint8List? testKey,
    FlutterSecureStorage storage = secureStorage,
    LocalStateKey? localKey,
  }) async {
    await directory.create(recursive: true);
    final file = File(
      '${directory.path}${Platform.pathSeparator}state-v2.json',
    );
    var foundPlain = false;
    for (final candidate in [
      file,
      File('${file.path}.tmp'),
      File('${file.path}.bak'),
    ]) {
      if (!await candidate.exists()) continue;
      foundPlain = true;
      Json decoded;
      try {
        decoded = await compute(
          decodePlainState,
          await candidate.readAsBytes(),
        );
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      } on AppException catch (error) {
        if (error.message == '本地数据来自更新版本，请更新应用') rethrow;
        continue;
      }
      if (candidate.path != file.path) {
        final repair = File('${file.path}.recovery');
        await repair.writeAsBytes(await candidate.readAsBytes(), flush: true);
        if (await file.exists()) {
          await file.rename(
            '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        await repair.rename(file.path);
      }
      return StateStore._(file, decoded);
    }
    // A corrupt current-format file must not revive stale pre-upgrade accounts.
    if (foundPlain) {
      throw StateRecoveryRequired(directory, StateRecoveryCause.unreadableData);
    }
    final legacy = File(
      '${directory.path}${Platform.pathSeparator}state-v1.enc',
    );
    if (!await legacy.exists() &&
        !await File('${legacy.path}.bak').exists() &&
        !await File('${legacy.path}.tmp').exists()) {
      for (final name in LocalStateKey.sidecars) {
        if (await File(
          '${directory.path}${Platform.pathSeparator}$name',
        ).exists()) {
          throw StateRecoveryRequired(
            directory,
            StateRecoveryCause.unreadableData,
          );
        }
      }
      return StateStore._(file, {});
    }
    final legacySnapshot = await readLegacySnapshot(
      directory,
      testKey: testKey,
      storage: storage,
      localKey: localKey,
    );
    final data = legacySnapshot.data;
    final bytes = await compute(encodePlainState, data);
    // Keep the original snapshots and keys until the new file is durable and
    // readable. A stopped migration can retry without resetting user data.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await compute(decodePlainState, await temporary.readAsBytes());
    await temporary.rename(file.path);
    DiagnosticLog.event(
      'state.plaintext_migrated',
      fields: {'snapshotBytes': bytes.length},
    );
    return StateStore._(file, data);
  }

  /// Exposed to compatibility fixtures that model an older app's snapshots.
  @visibleForTesting
  static Future<({Json data, Uint8List key})> readLegacySnapshot(
    Directory directory, {
    Uint8List? testKey,
    FlutterSecureStorage storage = secureStorage,
    LocalStateKey? localKey,
  }) async {
    await directory.create(recursive: true);
    final file = File('${directory.path}${Platform.pathSeparator}state-v1.enc');
    final backup = File('${file.path}.bak');
    final pending = File('${file.path}.tmp');
    localKey = testKey == null
        ? (localKey ?? LocalStateKey(directory, storage))
        : null;
    final saved = await localKey?.read(
      readLegacyWithoutPointer:
          await file.exists() ||
          await backup.exists() ||
          await pending.exists() ||
          await localKey.canUnlock(),
    );
    final keys = testKey != null ? [testKey] : saved!.keys;
    List<StateKeyFallback>? fallbackKeys;
    Future<List<StateKeyFallback>> fallbacks() async =>
        fallbackKeys ??= await localKey?.readFallbacks() ?? [];
    StateKeyFallback? usedFallback;
    if (keys.isEmpty) {
      final cause = saved!.unavailable
          ? StateRecoveryCause.secureStorageUnavailable
          : saved.invalid
          ? StateRecoveryCause.invalidKey
          : StateRecoveryCause.missingKey;
      final hasFallback = (await fallbacks()).isNotEmpty;
      if (!hasFallback &&
          (saved.unavailable ||
              saved.invalid ||
              await file.exists() ||
              await backup.exists() ||
              await pending.exists() ||
              await localKey!.canUnlock())) {
        throw StateRecoveryRequired(directory, cause);
      }
      if (!hasFallback) {
        final generated = CryptoBox.random(32);
        if (localKey!.nativeAndroid) {
          await localKey.saveFresh(generated);
        } else {
          await localKey.save(generated);
        }
        keys.add(generated);
      }
    }
    Uint8List? key = keys.firstOrNull;
    Json data = {};
    final candidates = [file, backup, pending];
    final fallbackSnapshot = await file.exists()
        ? file.path
        : await pending.exists()
        ? pending.path
        : backup.path;
    var found = false;
    var recovered = false;
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      final newestSnapshot = candidate.path == fallbackSnapshot;
      found = true;
      final bytes = await candidate.readAsBytes();
      Json? decoded;
      // Try every key against the newest snapshot before considering older data.
      for (final candidateKey in keys) {
        if (saved?.requiresLatestSnapshot == true && !newestSnapshot) continue;
        try {
          decoded = await compute(_decryptSnapshot, (candidateKey, bytes));
          key = candidateKey;
          break;
        } on AppException {
          continue;
        } on FormatException {
          continue;
        }
      }
      // Fallback keys must authenticate the newest available snapshot. Never
      // let a stale fallback key silently replace it with an older .bak file.
      if (decoded == null && newestSnapshot) {
        for (final fallback in await fallbacks()) {
          try {
            decoded = await compute(_decryptSnapshot, (fallback.key, bytes));
            key = fallback.key;
            usedFallback = fallback;
            break;
          } on AppException {
            continue;
          } on FormatException {
            continue;
          }
        }
      }
      if (decoded == null) continue;
      data = decoded;
      require(data.integer('schema', 1) == 1, '本地数据来自更新版本，请更新应用');
      // Repair the primary before accepting edits. A corrupt primary must never
      // replace the sole authenticated backup during the next commit.
      if (candidate.path != file.path) {
        final repair = File('${file.path}.recovery');
        await repair.writeAsBytes(await candidate.readAsBytes(), flush: true);
        if (await file.exists()) {
          await file.rename(
            '${file.path}.corrupt-${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        await repair.rename(file.path);
      }
      recovered = true;
      break;
    }
    if (found && !recovered) {
      throw StateRecoveryRequired(directory, StateRecoveryCause.unreadableData);
    }
    if (key == null) {
      throw StateRecoveryRequired(directory, StateRecoveryCause.unreadableData);
    }
    if (!found && localKey != null && await localKey.canUnlock()) {
      throw StateRecoveryRequired(directory, StateRecoveryCause.unreadableData);
    }
    if (saved?.needsMigration == true ||
        recovered &&
            (usedFallback != null || saved?.needsRepair(key) == true)) {
      try {
        if (usedFallback != null) {
          await localKey!.useFallback(usedFallback);
        } else {
          await localKey!.save(key);
        }
      } on PlatformException {
        // Authenticated data is usable even while a secure write is unavailable.
      } on AppException {
        // Keep the usable record; explicit password recovery can rebind storage.
      } on FileSystemException {
        // A failed pointer repair must not prevent using authenticated data.
      }
    }
    return (data: data, key: key);
  }

  factory StateStore.memory([Json? data]) =>
      StateStore._(null, asJson(jsonDecode(jsonEncode(data ?? {}))));

  Future<T> change<T>(T Function(Json draft) edit, {String? recoveryPassword}) {
    final timer = Stopwatch()..start();
    return _gate.run(() async {
      final queueMs = timer.elapsedMilliseconds;
      // Copy containers without re-parsing every URL and torrent string on the
      // UI isolate. Failed edits still cannot mutate the committed snapshot.
      final draft = _copyStateValue(_data) as Json;
      final result = edit(draft);
      draft['schema'] = 1;
      final args = (file != null, _data, draft, recoveryPassword != null);
      final encoded = file == null
          ? _encodeChange(args)
          : await compute(_encodeChange, args, debugLabel: 'state.commit');
      // Startup reconciliation and idle shutdown often leave the state unchanged.
      // No-op edits do not rewrite an unchanged snapshot.
      if (!encoded.changed) return result;
      if (file != null) {
        final protectedImport = recoveryPassword != null;
        final originals = <String, Uint8List?>{};
        if (protectedImport) {
          // Preserve the previous files until a backup import passes readback.
          for (final path in [
            file!.path,
            '${file!.path}.bak',
            '${file!.path}.tmp',
          ]) {
            final original = File(path);
            originals[path] = await original.exists()
                ? await original.readAsBytes()
                : null;
          }
        }
        try {
          final temporary = File('${file!.path}.tmp');
          final backup = File('${file!.path}.bak');
          await temporary.writeAsBytes(encoded.bytes!, flush: true);
          // Keep the previous complete snapshot until the next successful commit.
          if (await file!.exists()) {
            if (await backup.exists()) await backup.delete();
            await file!.rename(backup.path);
          }
          await temporary.rename(file!.path);
          if (protectedImport) {
            final reopened = await compute(
              decodePlainState,
              await file!.readAsBytes(),
            );
            require(jsonEncode(reopened) == jsonEncode(draft), '导入后的数据保存校验失败');
          }
        } catch (error, stack) {
          if (protectedImport) {
            try {
              for (final entry in originals.entries) {
                final target = File(entry.key);
                if (entry.value != null) {
                  final rollback = File('${target.path}.rollback');
                  await rollback.writeAsBytes(entry.value!, flush: true);
                  await rollback.rename(target.path);
                } else if (await target.exists()) {
                  await target.delete();
                }
              }
            } catch (_) {
              throw const AppException('导入未完成，请勿清除数据；重新打开应用后检查恢复提示');
            }
          }
          Error.throwWithStackTrace(error, stack);
        }
      }
      _data = draft;
      _notificationZone.run(notifyListeners);
      if (file != null && timer.elapsedMilliseconds >= 500) {
        DiagnosticLog.event(
          'state.commit_slow',
          fields: {
            'queueMs': queueMs,
            'serializeMs': encoded.serializeMs,
            'packMs': encoded.packMs,
            'elapsedMs': timer.elapsedMilliseconds,
            'snapshotBytes': encoded.bytes!.length,
          },
        );
      }
      return result;
    });
  }

  Future<void> put(String key, Object? value) => change((draft) {
    draft[key] = value;
  });
  Future<void> flush() => _gate.run(() async {});

  /// Kept for callers of older backup APIs; current snapshots need no key.
  Future<void> protectRecovery(String password) => flush();

  /// Password recovery must authenticate the current data, never silently pick
  /// an older backup encrypted with a different key.
  static Future<void> validateRecoveryKey(
    Directory directory,
    Uint8List key,
  ) async {
    for (final suffix in ['', '.tmp', '.bak']) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}state-v1.enc$suffix',
      );
      if (!await file.exists()) continue;
      final data = await compute(_decryptSnapshot, (
        key,
        await file.readAsBytes(),
      ));
      require(data.integer('schema', 1) == 1, '本地数据来自更新版本，请更新应用');
      return;
    }
    throw const AppException('本地数据文件不存在，请使用备份文件恢复');
  }
}

abstract class CredentialStore {
  Credential? credential(CloudPlatform platform);
  String? secret(String key);
  Future<void> putCredential(CloudPlatform platform, Credential credential);
  Future<bool> replaceCredential(
    CloudPlatform platform,
    Credential? expected,
    Credential replacement, {
    bool Function()? canCommit,
  });
  Future<bool> putSecretForCredential(
    CloudPlatform platform,
    Credential expected,
    String key,
    String value,
  );
  Future<void> removeCredential(CloudPlatform platform);
  Future<void> putSecret(String key, String value);
  Future<void> removeSecret(String key);
}

class Vault implements CredentialStore {
  Vault(this.store);
  final StateStore store;
  final _accountScope = Object();

  String? activeAccountId(CloudPlatform platform) =>
      activeIdIn(store.data, platform);

  static String? activeIdIn(Json data, CloudPlatform platform) {
    final saved = data.obj('activeCloudAccounts').str(platform.key);
    if (saved.isNotEmpty) return saved;
    return data.obj('credentials')[platform.key] == null
        ? null
        : 'legacy-${platform.key}';
  }

  String? accountId(CloudPlatform platform) {
    final scope = Zone.current[_accountScope] as Map<CloudPlatform, String?>?;
    return scope?.containsKey(platform) == true
        ? scope![platform]
        : activeAccountId(platform);
  }

  T withAccount<T>(CloudPlatform platform, String? id, T Function() action) =>
      runZoned(
        action,
        zoneValues: {
          _accountScope: {
            ...?Zone.current[_accountScope] as Map<CloudPlatform, String?>?,
            platform: id,
          },
        },
      );

  static Credential? credentialIn(
    Json data,
    CloudPlatform platform,
    String? id,
  ) {
    if (id == null) return null;
    final value = id == activeIdIn(data, platform)
        ? data.obj('credentials')[platform.key]
        : data.obj('cloudAccounts').obj(platform.key).obj(id)['credential'];
    return value == null ? null : Credential.fromJson(asJson(value));
  }

  Credential? credentialFor(CloudPlatform platform, String? id) =>
      credentialIn(store.data, platform, id);

  static String customAccountName(Json record, Credential credential) {
    final name = record.str('name').trim();
    if (record.containsKey('nameIsCustom')) {
      return record.boolean('nameIsCustom') ? name : '';
    }
    // Older backups saved the displayed nickname in the custom-name field.
    return name == credential.field('nickname').trim() ||
            name == credential.label.trim()
        ? ''
        : name;
  }

  List<CloudAccountProfile> profiles(CloudPlatform platform) {
    final values = store.data.obj('cloudAccounts').obj(platform.key);
    final active = activeAccountId(platform);
    final ids = {...values.keys, ?active};
    return [
      for (final id in ids)
        if (credentialFor(platform, id) case final credential?)
          CloudAccountProfile(
            id,
            platform,
            customAccountName(
              values.obj(id),
              credential,
            ).ifEmpty(credential.field('nickname')).ifEmpty(credential.label),
            active: id == active,
            customName: customAccountName(values.obj(id), credential),
            nickname: credential.field('nickname'),
          ),
    ];
  }

  String? accountForRevision(CloudPlatform platform, int revision) {
    final matches = profiles(platform)
        .where((a) => credentialFor(platform, a.id)?.updatedAt == revision)
        .toList();
    return matches.length == 1 ? matches.single.id : null;
  }

  static bool accountSecret(CloudPlatform platform, String key) =>
      switch (platform) {
        CloudPlatform.pan123 => key.startsWith('pan123.'),
        CloudPlatform.xunlei => key.startsWith('xunlei.'),
        _ => false,
      };

  static void migrateDraft(Json draft) {
    final all = draft.obj('cloudAccounts'),
        active = draft.obj('activeCloudAccounts');
    for (final platform in CloudPlatform.values) {
      final savedRecords = all.obj(platform.key);
      for (final entry in savedRecords.entries.toList()) {
        final record = asJson(entry.value);
        if (record.containsKey('nameIsCustom') ||
            record['credential'] == null) {
          continue;
        }
        final name = customAccountName(
          record,
          Credential.fromJson(record.obj('credential')),
        );
        savedRecords[entry.key] = {
          ...record,
          'name': name,
          'nameIsCustom': name.isNotEmpty,
        };
      }
      if (savedRecords.isNotEmpty) all[platform.key] = savedRecords;
      final credential = draft.obj('credentials')[platform.key];
      if (credential == null) continue;
      final id = activeIdIn(draft, platform)!;
      final records = all.obj(platform.key), previous = records.obj(id);
      final name = customAccountName(
        previous,
        Credential.fromJson(asJson(credential)),
      );
      records[id] = {
        ...previous,
        if (!previous.containsKey('nameIsCustom')) ...{
          'name': name,
          'nameIsCustom': name.isNotEmpty,
        },
        'credential': credential,
        'secrets': {
          for (final e in draft.obj('secrets').entries)
            if (accountSecret(platform, e.key)) e.key: e.value,
        },
      };
      all[platform.key] = records;
      active[platform.key] = id;
    }
    draft['cloudAccounts'] = all;
    draft['activeCloudAccounts'] = active;
  }

  Future<void> initializeAccounts() {
    final saved = store.data;
    final accounts = saved.obj('cloudAccounts');
    final active = saved.obj('activeCloudAccounts');
    final draft = <String, dynamic>{
      'cloudAccounts': accounts,
      'activeCloudAccounts': active,
      'credentials': saved.obj('credentials'),
      'secrets': saved.obj('secrets'),
    };
    migrateDraft(draft);
    const equality = DeepCollectionEquality();
    // Inspect only account data. A settled migration must not clone, serialize
    // and enqueue the entire download/search history on every launch.
    if ((saved['cloudAccounts'] == null || saved['cloudAccounts'] is Map) &&
        (saved['activeCloudAccounts'] == null ||
            saved['activeCloudAccounts'] is Map) &&
        equality.equals(accounts, draft['cloudAccounts']) &&
        equality.equals(active, draft['activeCloudAccounts'])) {
      return Future.value();
    }
    return store.change(migrateDraft);
  }

  static void activateDraft(Json draft, CloudPlatform platform, String? id) {
    final record = id == null
        ? <String, dynamic>{}
        : draft.obj('cloudAccounts').obj(platform.key).obj(id);
    final credentials = draft.obj('credentials')..remove(platform.key);
    if (record['credential'] != null) {
      credentials[platform.key] = record['credential'];
    }
    draft['credentials'] = credentials;
    final active = draft.obj('activeCloudAccounts')..remove(platform.key);
    if (id != null) active[platform.key] = id;
    draft['activeCloudAccounts'] = active;
    final secrets = draft.obj('secrets')
      ..removeWhere((key, _) => accountSecret(platform, key));
    draft['secrets'] = {...secrets, ...record.obj('secrets')};
  }

  static void _writeRecord(
    Json draft,
    CloudPlatform platform,
    String id,
    Json record,
  ) {
    draft['cloudAccounts'] = {
      ...draft.obj('cloudAccounts'),
      platform.key: {
        ...draft.obj('cloudAccounts').obj(platform.key),
        id: record,
      },
    };
    if (activeIdIn(draft, platform) == id) activateDraft(draft, platform, id);
  }

  Future<String> createAccount(CloudPlatform platform) => store.change((draft) {
    migrateDraft(draft);
    final id = newId();
    _writeRecord(draft, platform, id, {
      'name': '',
      'nameIsCustom': false,
      'secrets': <String, dynamic>{},
    });
    return id;
  });

  Future<void> activate(
    CloudPlatform platform,
    String id, {
    bool Function()? canCommit,
  }) => store.change((draft) {
    require(canCommit?.call() ?? true, '登录已取消或账号发生变化');
    migrateDraft(draft);
    require(credentialIn(draft, platform, id) != null, '该账号已移除，请重新添加');
    activateDraft(draft, platform, id);
  });

  Future<void> renameAccount(CloudPlatform platform, String id, String name) =>
      store.change((draft) {
        migrateDraft(draft);
        final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
        require(record.isNotEmpty, '该账号已移除');
        _writeRecord(draft, platform, id, {
          ...record,
          'name': name.trim(),
          'nameIsCustom': name.trim().isNotEmpty,
        });
      });

  Future<bool> updateAccountNickname(
    CloudPlatform platform,
    String id,
    int revision,
    String nickname,
  ) async {
    final name = nickname.trim();
    final current = credentialFor(platform, id);
    if (current == null || current.updatedAt != revision || name.isEmpty) {
      return false;
    }
    if (current.field('nickname') == name) return true;
    return store.change((draft) {
      migrateDraft(draft);
      final credential = credentialIn(draft, platform, id);
      if (credential == null || credential.updatedAt != revision) return false;
      final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
      _writeRecord(draft, platform, id, {
        ...record,
        'credential': credential.withFields({
          'nickname': name,
        }, preserveRevision: true).toJson(),
      });
      return true;
    });
  }

  Future<void> removeAccount(
    CloudPlatform platform,
    String id, {
    bool onlyIfEmpty = false,
  }) => store.change((draft) {
    migrateDraft(draft);
    if (onlyIfEmpty && credentialIn(draft, platform, id) != null) return;
    final records = draft.obj('cloudAccounts').obj(platform.key)..remove(id);
    draft['cloudAccounts'] = {
      ...draft.obj('cloudAccounts'),
      platform.key: records,
    };
    if (activeIdIn(draft, platform) == id) {
      activateDraft(
        draft,
        platform,
        records.entries
            .where((e) => asJson(e.value)['credential'] != null)
            .firstOrNull
            ?.key,
      );
    }
    draft['cloudFavorites'] = draft
        .list('cloudFavorites')
        .where(
          (f) => f.str('platform') != platform.key || f.str('accountId') != id,
        )
        .toList();
  });

  @override
  Credential? credential(CloudPlatform platform) =>
      credentialFor(platform, accountId(platform));

  @override
  String? secret(String key) {
    final platform = CloudPlatform.values
        .where((p) => accountSecret(p, key))
        .firstOrNull;
    if (platform == null) return store.data.obj('secrets')[key]?.toString();
    final id = accountId(platform);
    if (id == activeAccountId(platform)) {
      return store.data.obj('secrets')[key]?.toString();
    }
    return store.data
        .obj('cloudAccounts')
        .obj(platform.key)
        .obj(id ?? '')
        .obj('secrets')[key]
        ?.toString();
  }

  @override
  Future<void> putCredential(
    CloudPlatform platform,
    Credential credential,
  ) async {
    final owner = accountId(platform);
    await store.change((draft) {
      migrateDraft(draft);
      final id = owner ?? newId();
      final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
      require(owner == null || record.isNotEmpty, '该账号已移除');
      _writeRecord(draft, platform, id, {
        ...record,
        'credential': credential.toJson(),
      });
      if (owner == null) activateDraft(draft, platform, id);
    });
  }

  @override
  Future<bool> replaceCredential(
    CloudPlatform platform,
    Credential? expected,
    Credential replacement, {
    bool Function()? canCommit,
  }) {
    final owner = accountId(platform);
    return store.change((draft) {
      if (canCommit != null && !canCommit()) return false;
      migrateDraft(draft);
      final current = credentialIn(draft, platform, owner);
      if (expected == null ? current != null : !expected.sameAs(current)) {
        return false;
      }
      final id = owner ?? newId();
      final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
      if (owner != null && record.isEmpty) return false;
      final secrets = record.obj('secrets');
      if (platform == CloudPlatform.pan123) {
        secrets.remove('pan123.access_token');
      }
      _writeRecord(draft, platform, id, {
        ...record,
        'credential': replacement.toJson(),
        'secrets': secrets,
      });
      if (owner == null) activateDraft(draft, platform, id);
      return true;
    });
  }

  static String _loginUserId(Credential value) => value.field('userId').trim();
  static String _loginUsername(Credential value) {
    final name = value.field('loginUsername').ifEmpty(value.field('username'));
    return (name.isNotEmpty
            ? name
            : value.field('authType') == 'password'
            ? value.primary
            : '')
        .trim()
        .toLowerCase();
  }

  static bool sameLoginOwner(Credential left, Credential right) {
    final a = _loginUserId(left), b = _loginUserId(right);
    if (a.isNotEmpty && b.isNotEmpty) return a == b;
    final username = _loginUsername(left);
    return username.isNotEmpty && username == _loginUsername(right);
  }

  /// Commits an explicit login without overwriting a different remembered account.
  Future<String?> commitLogin(
    CloudPlatform platform,
    String pendingId,
    Credential? expected,
    Credential replacement, {
    required bool Function() canCommit,
  }) => store.change((draft) {
    if (!canCommit()) return null;
    migrateDraft(draft);
    final current = credentialIn(draft, platform, pendingId);
    if (expected == null ? current != null : !expected.sameAs(current)) {
      return null;
    }
    final records = draft.obj('cloudAccounts').obj(platform.key);
    if (!records.containsKey(pendingId)) return null;
    final match = records.entries.where((entry) {
      final record = asJson(entry.value);
      return record['credential'] != null &&
          sameLoginOwner(
            Credential.fromJson(record.obj('credential')),
            replacement,
          );
    }).firstOrNull;
    final different =
        current != null &&
        (_loginUserId(current).isNotEmpty &&
                _loginUserId(replacement).isNotEmpty &&
                _loginUserId(current) != _loginUserId(replacement) ||
            (_loginUserId(current).isEmpty ||
                    _loginUserId(replacement).isEmpty) &&
                _loginUsername(current).isNotEmpty &&
                _loginUsername(replacement).isNotEmpty &&
                _loginUsername(current) != _loginUsername(replacement));
    final id = match?.key ?? (different ? newId() : pendingId);
    final record = records.obj(id);
    final old = record['credential'] == null
        ? null
        : Credential.fromJson(record.obj('credential'));
    final remembered = <String, String>{};
    if (old != null && sameLoginOwner(old, replacement)) {
      for (final key in ['loginUsername', 'loginPassword']) {
        if (replacement.field(key).isEmpty && old.field(key).isNotEmpty) {
          remembered[key] = old.field(key);
        }
      }
    }
    final secrets = record.obj('secrets');
    if (platform == CloudPlatform.pan123) secrets.remove('pan123.access_token');
    _writeRecord(draft, platform, id, {
      'name': '',
      'nameIsCustom': false,
      ...record,
      'credential':
          (remembered.isEmpty
                  ? replacement
                  : replacement.withFields(remembered, preserveRevision: true))
              .toJson(),
      'secrets': secrets,
    });
    if (id != pendingId && current == null) {
      final updated = draft.obj('cloudAccounts').obj(platform.key)
        ..remove(pendingId);
      draft['cloudAccounts'] = {
        ...draft.obj('cloudAccounts'),
        platform.key: updated,
      };
    }
    return id;
  });

  @override
  Future<bool> putSecretForCredential(
    CloudPlatform platform,
    Credential expected,
    String key,
    String value,
  ) {
    final owner = accountId(platform);
    return store.change((draft) {
      migrateDraft(draft);
      final current = credentialIn(draft, platform, owner);
      if (owner == null || !expected.sameAs(current)) {
        return false;
      }
      _putSecretDraft(draft, platform, owner, key, value);
      return true;
    });
  }

  @override
  Future<void> removeCredential(CloudPlatform platform) async {
    final id = accountId(platform);
    if (id != null) await removeAccount(platform, id);
  }

  static void _putSecretDraft(
    Json draft,
    CloudPlatform? platform,
    String? id,
    String key,
    String? value,
  ) {
    if (platform == null || id == null) {
      final secrets = draft.obj('secrets')..remove(key);
      if (value != null) secrets[key] = value;
      draft['secrets'] = secrets;
      return;
    }
    final record = draft.obj('cloudAccounts').obj(platform.key).obj(id);
    require(record.isNotEmpty, '该账号已移除');
    final secrets = record.obj('secrets')..remove(key);
    if (value != null) secrets[key] = value;
    _writeRecord(draft, platform, id, {...record, 'secrets': secrets});
  }

  Future<void> _secretChange(String key, String? value) {
    final platform = CloudPlatform.values
        .where((p) => accountSecret(p, key))
        .firstOrNull;
    final id = platform == null ? null : accountId(platform);
    return store.change((draft) {
      migrateDraft(draft);
      _putSecretDraft(draft, platform, id, key, value);
    });
  }

  @override
  Future<void> putSecret(String key, String value) => _secretChange(key, value);
  @override
  Future<void> removeSecret(String key) => _secretChange(key, null);
}

class CloudAccountProfile {
  const CloudAccountProfile(
    this.id,
    this.platform,
    this.name, {
    required this.active,
    this.customName = '',
    this.nickname = '',
  });
  final String id, name, customName, nickname;
  final CloudPlatform platform;
  final bool active;
}
