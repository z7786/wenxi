import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int size;
  external Pointer<Uint8> bytes;
}

final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;
}

final class _Credential extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int type;
  external Pointer<Utf16> target;
  external Pointer<Utf16> comment;
  external _FileTime written;
  @Uint32()
  external int size;
  external Pointer<Uint8> bytes;
  @Uint32()
  external int persist;
  @Uint32()
  external int attributeCount;
  external Pointer<Void> attributes;
  external Pointer<Utf16> alias;
  external Pointer<Utf16> username;
}

PlatformException _failure(String stage, [int? code]) => PlatformException(
  code: 'windows_state_key',
  message: '旧版本地密钥暂时无法读取，原文件已保留',
  details: {'stage': stage, 'code': ?code},
);

/// Reads the old stores without invoking the plugin's destructive migration.
/// These stores are never written, renamed, deleted or added to diagnostics.
class WindowsLegacyStateKey {
  WindowsLegacyStateKey(
    this.directory, {
    Future<Uint8List> Function(Uint8List)? unprotect,
    Future<Uint8List?> Function(String)? readCredential,
  }) : _unprotect = unprotect ?? unprotectWindowsState,
       _readCredential = readCredential ?? readWindowsStateCredential;

  final Directory directory;
  final Future<Uint8List> Function(Uint8List) _unprotect;
  final Future<Uint8List?> Function(String) _readCredential;
  static const encryptedFileName = 'flutter_secure_storage.dat';
  static const credentialPrefix = 'asterlink_VGhpcyBpcyB0aGUgcHJlZml4IGZv_';
  Future<Map<String, String>>? _map;

  Future<Map<String, String>> _load() async {
    final file = File(p.join(directory.path, encryptedFileName));
    if (!await file.exists()) return {};
    if (await file.length() > 1024 * 1024) throw _failure('file_size');
    final encrypted = await file.readAsBytes();
    Uint8List? plain;
    try {
      plain = await _unprotect(encrypted);
      final data = jsonDecode(utf8.decode(plain));
      if (data is! Map) throw _failure('json');
      return {
        for (final entry in data.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } on FormatException {
      throw _failure('json');
    } finally {
      plain?.fillRange(0, plain.length, 0);
      encrypted.fillRange(0, encrypted.length, 0);
    }
  }

  Future<String?> read(String name) async {
    PlatformException? failure;
    try {
      final value = (await (_map ??= _load()))[name];
      if (value != null) return value;
    } on PlatformException catch (error) {
      _map = null;
      failure = error;
    } on FileSystemException {
      _map = null;
      failure = _failure('file_read');
    }
    // Releases before the JSON store kept AES-GCM records in separate files.
    final target = '$credentialPrefix$name';
    final file = File(p.join(directory.path, '$target.secure'));
    try {
      if (await file.exists()) {
        if (await file.length() > 4096) throw _failure('record_size');
        final key = await _readCredential('key_$credentialPrefix');
        if (key == null) throw _failure('credential_missing');
        try {
          return _decodeRecord(await file.readAsBytes(), key);
        } finally {
          key.fillRange(0, key.length, 0);
        }
      }
      final value = await _readCredential(target);
      if (value != null) {
        try {
          return utf8.decode(value.takeWhile((byte) => byte != 0).toList());
        } finally {
          value.fillRange(0, value.length, 0);
        }
      }
    } on PlatformException catch (error) {
      failure ??= error;
    } on FormatException {
      failure ??= _failure('record_format');
    } on FileSystemException {
      failure ??= _failure('record_read');
    }
    if (failure != null) throw failure;
    return null;
  }

  static String _decodeRecord(Uint8List packed, Uint8List key) {
    if (key.length != 16 || packed.length < 29) throw _failure('record_format');
    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        false,
        AEADParameters(
          KeyParameter(key),
          128,
          Uint8List.sublistView(packed, 0, 12),
          Uint8List(0),
        ),
      );
    Uint8List? plain;
    try {
      // The old file order is nonce, authentication tag, ciphertext.
      plain = cipher.process(
        Uint8List.fromList([...packed.sublist(28), ...packed.sublist(12, 28)]),
      );
      return utf8.decode(plain.takeWhile((byte) => byte != 0).toList());
    } on InvalidCipherTextException {
      throw _failure('record_authentication');
    } finally {
      plain?.fillRange(0, plain.length, 0);
      packed.fillRange(0, packed.length, 0);
    }
  }
}

Future<Uint8List> unprotectWindowsState(Uint8List encrypted) async {
  if (!Platform.isWindows) throw _failure('platform');
  if (encrypted.isEmpty || encrypted.length > 1024 * 1024) {
    throw _failure('file_size');
  }
  return Isolate.run(() {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
      'GetLastError',
    );
    final localFree = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    final input = calloc<_DataBlob>(), output = calloc<_DataBlob>();
    final bytes = calloc<Uint8>(encrypted.length);
    try {
      bytes.asTypedList(encrypted.length).setAll(0, encrypted);
      input.ref
        ..size = encrypted.length
        ..bytes = bytes;
      final unprotect = DynamicLibrary.open('crypt32.dll')
          .lookupFunction<
            Int32 Function(
              Pointer<_DataBlob>,
              Pointer<Pointer<Utf16>>,
              Pointer<_DataBlob>,
              Pointer<Void>,
              Pointer<Void>,
              Uint32,
              Pointer<_DataBlob>,
            ),
            int Function(
              Pointer<_DataBlob>,
              Pointer<Pointer<Utf16>>,
              Pointer<_DataBlob>,
              Pointer<Void>,
              Pointer<Void>,
              int,
              Pointer<_DataBlob>,
            )
          >('CryptUnprotectData');
      if (unprotect(input, nullptr, nullptr, nullptr, nullptr, 1, output) ==
          0) {
        throw _failure('unprotect', lastError());
      }
      if (output.ref.bytes == nullptr || output.ref.size > 1024 * 1024) {
        throw _failure('unprotect_size');
      }
      return Uint8List.fromList(output.ref.bytes.asTypedList(output.ref.size));
    } finally {
      if (output.ref.bytes != nullptr) {
        if (output.ref.size <= 1024 * 1024) {
          output.ref.bytes
              .asTypedList(output.ref.size)
              .fillRange(0, output.ref.size, 0);
        }
        localFree(output.ref.bytes.cast());
      }
      bytes.asTypedList(encrypted.length).fillRange(0, encrypted.length, 0);
      calloc.free(bytes);
      calloc.free(input);
      calloc.free(output);
    }
  });
}

Future<Uint8List?> readWindowsStateCredential(String target) async {
  if (!Platform.isWindows) throw _failure('platform');
  return Isolate.run(() {
    final lastError = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<Uint32 Function(), int Function()>('GetLastError');
    final name = target.toNativeUtf16(),
        output = calloc<Pointer<_Credential>>();
    final library = DynamicLibrary.open('advapi32.dll');
    try {
      final read = library
          .lookupFunction<
            Int32 Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Pointer<_Credential>>,
            ),
            int Function(
              Pointer<Utf16>,
              int,
              int,
              Pointer<Pointer<_Credential>>,
            )
          >('CredReadW');
      if (read(name, 1, 0, output) == 0) {
        final code = lastError();
        if (code == 1168) return null;
        throw _failure('credential_read', code);
      }
      final record = output.value.ref;
      if (record.bytes == nullptr || record.size > 4096) {
        throw _failure('credential_size');
      }
      return Uint8List.fromList(record.bytes.asTypedList(record.size));
    } finally {
      if (output.value != nullptr) {
        library.lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('CredFree')(output.value.cast());
      }
      calloc.free(name);
      calloc.free(output);
    }
  });
}
