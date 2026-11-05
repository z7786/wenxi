import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import '../core/crypto_box.dart';
import '../core/json.dart';
import '../diagnostics/app_log.dart';
import '../platform/windows_legacy_state_key.dart';

class StateKeyRead {
  StateKeyRead({this.needsMigration = false});
  final keys = <Uint8List>[];
  final bool needsMigration;
  bool unavailable = false, invalid = false;
  bool pointerNeedsRepair = false;
  bool requiresLatestSnapshot = false;
  String? primary, copy;
  bool needsRepair(Uint8List key) =>
      pointerNeedsRepair ||
      primary != base64Encode(key) ||
      copy != base64Encode(key);
}

class _KeyLocation {
  const _KeyLocation(this.namespace, {this.backend = ''});
  final String? namespace;
  final String backend;
  bool get native => backend == LocalStateKey.nativeBackend;
  bool get privateFiles =>
      backend == LocalStateKey.privateBackend ||
      backend == LocalStateKey.windowsPrivateBackend;
  Json toJson() => {
    'namespace': namespace,
    if (backend.isNotEmpty) 'backend': backend,
  };
}

class StateKeyFallback {
  StateKeyFallback._(this.key, this._location);
  final Uint8List key;
  final _KeyLocation _location;
}

/// Android and Windows keep two independent key files in the app data directory.
/// OS stores are read only when migrating authenticated existing data.
class LocalStateKey {
  LocalStateKey(
    this.directory,
    this.storage, {
    bool? nativeAndroid,
    bool? windowsFiles,
    WindowsLegacyStateKey? windowsLegacy,
  }) : nativeAndroid = nativeAndroid ?? Platform.isAndroid,
       windowsFiles =
           windowsFiles ?? (nativeAndroid == null && Platform.isWindows),
       _windowsLegacy = windowsLegacy;
  final Directory directory;
  final FlutterSecureStorage storage;
  final bool nativeAndroid;
  final bool windowsFiles;
  WindowsLegacyStateKey? _windowsLegacy;
  bool _pointerNeedsRepair = false;
  bool _usingBackupPointer = false;
  bool get _fileStorage => nativeAndroid || windowsFiles;
  String get _privateBackend =>
      windowsFiles ? windowsPrivateBackend : privateBackend;
  static const nativeBackend = 'android-keystore-aes-v2';
  static const privateBackend = 'android-private-files-v1';
  static const windowsPrivateBackend = 'windows-private-files-v1';
  static const privateDirectoryName = 'state-keys-private-v1';
  static const name = 'asterlink.flutter.state-key.v1';
  static const locationName = 'state-key-location.json';
  static const recoveryName = 'state-key-recovery.json';
  static const sidecars = [
    locationName,
    '$locationName.tmp',
    '$locationName.bak',
    recoveryName,
    '$recoveryName.tmp',
  ];
  static const options = AndroidOptions(
    resetOnError: false,
    migrateWithBackup: true,
  );
  static const channel = MethodChannel('com.asterlink.app/native');
  static final _namespacePattern = RegExp(r'^state_[a-f0-9]{32}$');

  File localFile(String name) => File(p.join(directory.path, name));

  _KeyLocation _parseLocation(Json location) {
    final value = location['namespace'];
    final backend = location.str('backend');
    require(
      backend.isEmpty ||
          backend == nativeBackend ||
          backend == privateBackend ||
          backend == windowsPrivateBackend,
      '本地密钥存储格式不支持',
    );
    require(
      location.containsKey('namespace') &&
          ((value == null && backend.isEmpty) ||
              (value is String && _namespacePattern.hasMatch(value))),
      '本地密钥位置记录损坏',
    );
    return _KeyLocation(value as String?, backend: backend);
  }

  Future<({_KeyLocation active, _KeyLocation? fallback})> _readPointer(
    File file,
  ) async {
    require(await file.length() <= 1024, '本地密钥位置记录损坏');
    final location = asJson(jsonDecode(await file.readAsString()));
    final active = _parseLocation(location);
    _KeyLocation? fallback;
    if (location['fallback'] is Map) {
      try {
        fallback = _parseLocation(asJson(location['fallback']));
      } on AppException {
        // Optional recovery metadata cannot disable the active store.
      }
    }
    return (active: active, fallback: fallback);
  }

  Future<({_KeyLocation active, _KeyLocation? fallback})> _pointer() async {
    _pointerNeedsRepair = false;
    _usingBackupPointer = false;
    final files = [localFile(locationName), localFile('$locationName.bak')];
    Object? failure;
    for (final file in files) {
      if (!await file.exists()) continue;
      try {
        final pointer = await _readPointer(file);
        _usingBackupPointer = file.path != localFile(locationName).path;
        _pointerNeedsRepair = _usingBackupPointer;
        if (windowsFiles && !_pointerNeedsRepair) {
          final copy = localFile('$locationName.bak');
          try {
            _pointerNeedsRepair =
                !await copy.exists() ||
                await copy.length() > 1024 ||
                !listEquals(await file.readAsBytes(), await copy.readAsBytes());
          } on FileSystemException {
            _pointerNeedsRepair = true;
          }
        }
        return pointer;
      } on AppException catch (error) {
        failure = error;
      } on FormatException catch (error) {
        failure = error;
      } on FileSystemException catch (error) {
        failure = error;
      }
    }
    if (failure == null) {
      return (active: const _KeyLocation(null), fallback: null);
    }
    throw failure;
  }

  AndroidOptions _options(String? namespace) => namespace == null
      ? options
      : AndroidOptions(
          resetOnError: false,
          migrateWithBackup: true,
          storageNamespace: namespace,
        );
  String _name(String? namespace) =>
      namespace == null ? name : '$name.$namespace';

  Future<String?> _read(
    String key,
    String? namespace, {
    bool native = false,
    bool copy = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        if (native) {
          final bytes = await channel.invokeMethod<Uint8List>('readStateKey', {
            'namespace': namespace,
            'copy': copy,
          });
          return bytes == null ? null : base64Encode(bytes);
        }
        if (windowsFiles) {
          // The plugin deletes its JSON key store when DPAPI fails. Bypass it
          // even for upgrades and read all historical formats without writes.
          return await (_windowsLegacy ??= WindowsLegacyStateKey(
            directory.parent,
          )).read(key);
        }
        return await storage.read(key: key, aOptions: _options(namespace));
      } on PlatformException catch (error) {
        if (attempt >= 2) {
          _recordFailure(native ? 'native_read' : 'legacy_read', error);
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    }
  }

  Future<StateKeyRead> read({bool readLegacyWithoutPointer = true}) async {
    final result = StateKeyRead();
    _KeyLocation location;
    try {
      // An empty installation never needs to initialize OS key storage.
      // The caller must check for encrypted snapshots and recovery metadata first.
      if (_fileStorage &&
          !readLegacyWithoutPointer &&
          !await localFile(locationName).exists() &&
          !await localFile('$locationName.bak').exists()) {
        return result;
      }
      location = (await _pointer()).active;
    } on FormatException {
      result.invalid = true;
      return result;
    } on AppException {
      result.invalid = true;
      return result;
    } on FileSystemException {
      result.unavailable = true;
      return result;
    }
    final needsRepair = _pointerNeedsRepair;
    final saved = await _readLocation(location);
    saved.pointerNeedsRepair = needsRepair;
    // A backup pointer may be stale. It must never select an older snapshot
    // encrypted with another key and replace the current data with that copy.
    saved.requiresLatestSnapshot = windowsFiles && _usingBackupPointer;
    return saved;
  }

  Future<StateKeyRead> _readLocation(_KeyLocation location) async {
    final result = StateKeyRead(
      needsMigration: _fileStorage && !location.privateFiles,
    );
    final namespace = location.namespace;
    // A pointer to an existing namespace is not a fresh installation, even if
    // every record disappears. Never replace its key with a random one.
    if (location.native && !nativeAndroid) {
      result.unavailable = true;
      return result;
    }
    for (final copy in [false, true]) {
      try {
        final value = location.privateFiles
            ? await _readPrivate(namespace!, copy)
            : await _read(
                '${_name(namespace)}${copy ? '.copy' : ''}',
                namespace,
                native: location.native,
                copy: copy,
              );
        if (copy) {
          result.copy = value;
        } else {
          result.primary = value;
        }
        if (value == null) continue;
        final key = base64Decode(value);
        if (key.length != 32) {
          result.invalid = true;
        } else if (!result.keys.any((k) => listEquals(k, key))) {
          result.keys.add(key);
        }
      } on PlatformException {
        result.unavailable = true;
      } on FileSystemException {
        result.unavailable = true;
      } on FormatException {
        result.invalid = true;
      }
    }
    if (namespace != null && result.keys.isEmpty) result.invalid = true;
    return result;
  }

  Future<List<StateKeyFallback>> readFallbacks() async {
    try {
      final pointer = await _pointer();
      final locations = [if (pointer.fallback != null) pointer.fallback!];
      if (windowsFiles) {
        try {
          final backup = await _readPointer(localFile('$locationName.bak'));
          // An interrupted migration can publish the file pointer backup while
          // the old primary still points at DPAPI. Read the backup independently.
          for (final location in [backup.active, backup.fallback]) {
            if (location != null && location.privateFiles) {
              locations.add(location);
            }
          }
        } on AppException {
          // A bad backup cannot disable a usable primary or its fallback.
        } on FormatException {
          // All candidates still need authentication against the latest data.
        } on FileSystemException {
          // Keep reading the locations available from the primary pointer.
        }
      }
      final results = <StateKeyFallback>[];
      final seen = <String>{};
      for (final location in locations) {
        // Once migrated, even damaged key files must not access OS storage again.
        if (pointer.active.privateFiles && !location.privateFiles) continue;
        if (!seen.add('${location.backend}/${location.namespace}')) continue;
        final saved = await _readLocation(location);
        results.addAll([
          for (final key in saved.keys) StateKeyFallback._(key, location),
        ]);
      }
      return results;
    } on AppException {
      return [];
    } on FormatException {
      return [];
    } on FileSystemException {
      return [];
    }
  }

  /// Only call after this exact key decrypts the newest local snapshot.
  Future<void> useFallback(StateKeyFallback fallback) async {
    if (_fileStorage || fallback._location.privateFiles) {
      await _savePrivate(fallback.key);
    } else {
      final previous = (await _pointer()).active;
      await _writePointer(fallback._location, previous);
    }
    DiagnosticLog.active?.record('state_key.fallback_restored');
  }

  Future<void> _writePointer(
    _KeyLocation active,
    _KeyLocation? fallback,
  ) async {
    final bytes = utf8.encode(
      jsonEncode({
        ...active.toJson(),
        if (fallback != null) 'fallback': fallback.toJson(),
      }),
    );
    // Publish a second pointer only after both key files have been reopened.
    // An interrupted metadata write can then recover without touching OS keys.
    if (windowsFiles) {
      await writeAtomic(localFile('$locationName.bak'), bytes);
    }
    await writeAtomic(localFile(locationName), bytes);
  }

  Future<_KeyLocation?> _verifiedPrivatePrevious(Uint8List key) async {
    try {
      final pointer = await _pointer();
      // New writes, password recovery and later repairs never probe OS storage.
      for (final location in [pointer.active, pointer.fallback]) {
        if (location == null || !location.privateFiles) continue;
        final saved = await _readLocation(location);
        if (saved.keys.any((candidate) => listEquals(candidate, key))) {
          return location;
        }
      }
    } on AppException {
      // A verified password recovery may replace damaged pointer metadata.
    } on FormatException {
      // Leave damaged metadata to the existing archive/rollback mechanism.
    } on FileSystemException {
      // A verified password can also recover unreadable pointer metadata.
    }
    return null;
  }

  static void _recordFailure(String operation, PlatformException error) {
    // Plugin messages may contain values. Keep only known error categories;
    // native details consist solely of exception class names.
    final description = '${error.code} ${error.message} ${error.details}';
    const categories = [
      'KeyPermanentlyInvalidatedException',
      'UserNotAuthenticatedException',
      'UnrecoverableKeyException',
      'KeyStoreException',
      'InvalidKeyException',
      'InvalidAlgorithmParameterException',
      'BadPaddingException',
      'AEADBadTagException',
      'IllegalBlockSizeException',
      'IOException',
      'FileNotFoundException',
      'IllegalStateException',
      'IllegalArgumentException',
    ];
    DiagnosticLog.active?.record(
      'state_key.storage_failed',
      level: 'warning',
      fields: {
        'operation': operation,
        'categories': categories.where(description.contains).toList(),
      },
    );
  }

  Future<void> _write(Uint8List key, String? namespace) async {
    require(key.length == 32, '本地密钥格式错误');
    final value = base64Encode(key);
    for (final suffix in ['', '.copy']) {
      await storage.write(
        key: '${_name(namespace)}$suffix',
        value: value,
        aOptions: _options(namespace),
      );
    }
    if (Platform.isAndroid) {
      require(
        await channel.invokeMethod<bool>('flushStateKeyStorage', {
              'namespace': namespace,
            }) ==
            true,
        '本地密钥未能保存到设备，请检查可用存储空间后重试',
      );
    }
    for (final suffix in ['', '.copy']) {
      require(
        await _read('${_name(namespace)}$suffix', namespace) == value,
        '本地加密密钥保存失败，请检查系统安全存储后重试',
      );
    }
  }

  Future<void> save(Uint8List key) async {
    final location = (await _pointer()).active;
    if (_fileStorage || location.privateFiles) {
      await _savePrivate(key);
      if (!location.privateFiles) {
        DiagnosticLog.active?.record(
          'state_key.storage_migrated',
          fields: {
            'from': location.backend.isEmpty ? 'legacy' : location.backend,
            'to': _privateBackend,
          },
        );
      }
    } else {
      require(!location.native, '此设备不支持原本的密钥存储');
      await _write(key, location.namespace);
    }
  }

  Future<void> saveForImport(Uint8List key) async {
    if (_fileStorage) {
      final saved = await read();
      if (!saved.needsMigration &&
          !saved.needsRepair(key) &&
          saved.keys.any((candidate) => listEquals(candidate, key))) {
        return;
      }
    }
    await saveFresh(key);
  }

  /// Call only with a key authenticated against local data or a verified backup.
  /// Old storage is left intact; the pointer switches only after durable writes.
  Future<void> saveFresh(Uint8List key) async {
    require(key.length == 32, '本地密钥格式错误');
    if (_fileStorage) {
      await _savePrivate(key);
      return;
    }
    final namespace = _newNamespace();
    await _write(key, namespace);
    await _writePointer(_KeyLocation(namespace), null);
  }

  static String _newNamespace() =>
      'state_${CryptoBox.random(16).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';

  File _privateFile(String namespace, bool copy) => localFile(
    p.join(privateDirectoryName, namespace, copy ? 'copy.bin' : 'primary.bin'),
  );

  Future<String?> _readPrivate(String namespace, bool copy) async {
    final file = _privateFile(namespace, copy);
    if (!await file.exists()) return null;
    if (await file.length() != 32) {
      throw const FormatException('本地密钥文件损坏');
    }
    return base64Encode(await file.readAsBytes());
  }

  Future<void> _savePrivate(Uint8List key) async {
    require(key.length == 32, '本地密钥格式错误');
    final previous = await _verifiedPrivatePrevious(key);
    final namespace = _newNamespace();
    await _privateFile(namespace, false).parent.create(recursive: true);
    for (final copy in [false, true]) {
      await writeAtomic(_privateFile(namespace, copy), key);
    }
    // Reopen both final files before publishing the namespace. A failed write
    // leaves the old pointer, old records and encrypted snapshots untouched.
    for (final copy in [false, true]) {
      require(
        await _readPrivate(namespace, copy) == base64Encode(key),
        '本地加密密钥保存校验失败，请检查可用存储空间后重试',
      );
    }
    await _writePointer(
      _KeyLocation(namespace, backend: _privateBackend),
      previous,
    );
  }

  Future<bool> canUnlock() => localFile(recoveryName).exists();

  Future<Uint8List> prepareRecovery(Uint8List key, String password) =>
      compute(_wrapKey, (key, password));

  Future<Uint8List> unlock(String password) async {
    final file = localFile(recoveryName);
    require(await file.exists(), '此设备尚未建立密码恢复保护，请选择备份文件恢复');
    require(await file.length() <= 8192, '本地密码恢复文件损坏');
    return compute(_unwrapKey, (await file.readAsBytes(), password));
  }

  Future<void> installRecovery(List<int> bytes) =>
      writeAtomic(localFile(recoveryName), bytes);

  static Future<void> writeAtomic(File file, List<int> bytes) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    require(listEquals(bytes, await temporary.readAsBytes()), '本地文件保存校验失败');
    await temporary.rename(file.path);
  }
}

const _purpose = 'wenxi-local-state-key-v1';

Uint8List _wrapKey((Uint8List, String) input) {
  require(input.$2.length >= 6, '备份密码至少需要 6 位');
  final salt = CryptoBox.random(16);
  final wrappingKey = CryptoBox.derive(input.$2, salt, 210000);
  final plain = Uint8List.fromList(
    utf8.encode(
      jsonEncode({'purpose': _purpose, 'key': base64Encode(input.$1)}),
    ),
  );
  try {
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': _purpose,
          'salt': base64Encode(salt),
          'iterations': 210000,
          'data': base64Encode(CryptoBox.seal(wrappingKey, plain)),
        }),
      ),
    );
  } finally {
    wrappingKey.fillRange(0, wrappingKey.length, 0);
    plain.fillRange(0, plain.length, 0);
  }
}

Uint8List _unwrapKey((Uint8List, String) input) {
  Uint8List? wrappingKey, plain;
  try {
    final envelope = asJson(jsonDecode(utf8.decode(input.$1)));
    require(envelope.str('format') == _purpose, '恢复文件格式错误');
    wrappingKey = CryptoBox.derive(
      input.$2,
      base64Decode(envelope.str('salt')),
      envelope.integer('iterations'),
    );
    plain = CryptoBox.open(wrappingKey, base64Decode(envelope.str('data')));
    final payload = asJson(jsonDecode(utf8.decode(plain)));
    require(payload.str('purpose') == _purpose, '恢复文件格式错误');
    final key = base64Decode(payload.str('key'));
    require(key.length == 32, '恢复密钥格式错误');
    return key;
  } on FormatException {
    throw const AppException('备份密码错误或本地恢复文件已损坏');
  } on AppException {
    throw const AppException('备份密码错误或本地恢复文件已损坏');
  } finally {
    wrappingKey?.fillRange(0, wrappingKey.length, 0);
    plain?.fillRange(0, plain.length, 0);
  }
}
