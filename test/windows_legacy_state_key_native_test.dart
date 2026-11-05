import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asterlink/platform/windows_legacy_state_key.dart';

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> data;
}

// Creates disposable fixtures under the current test user's DPAPI context.
// It never uses the app's actual key files or Credential Manager records.
Uint8List _protect(Uint8List plain) {
  final protect = DynamicLibrary.open('crypt32.dll')
      .lookupFunction<
        Int32 Function(
          Pointer<_Blob>,
          Pointer<Utf16>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_Blob>,
        ),
        int Function(
          Pointer<_Blob>,
          Pointer<Utf16>,
          Pointer<_Blob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_Blob>,
        )
      >('CryptProtectData');
  final localFree = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  final input = calloc<_Blob>(), output = calloc<_Blob>();
  final bytes = calloc<Uint8>(plain.length);
  try {
    bytes.asTypedList(plain.length).setAll(0, plain);
    input.ref
      ..length = plain.length
      ..data = bytes;
    expect(
      protect(input, nullptr, nullptr, nullptr, nullptr, 1, output),
      isNonZero,
    );
    return Uint8List.fromList(output.ref.data.asTypedList(output.ref.length));
  } finally {
    if (output.ref.data != nullptr) localFree(output.ref.data.cast());
    bytes.asTypedList(plain.length).fillRange(0, plain.length, 0);
    calloc.free(bytes);
    calloc.free(input);
    calloc.free(output);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real Windows DPAPI decrypts old JSON and preserves the source file',
    () async {
      final directory = await Directory.systemTemp.createTemp('legacy-dpapi-');
      try {
        const name = 'fixture-key', value = 'fixture-state-key';
        final plain = Uint8List.fromList(
          utf8.encode(jsonEncode({name: value})),
        );
        final encrypted = _protect(plain);
        final source = File(
          '${directory.path}/${WindowsLegacyStateKey.encryptedFileName}',
        );
        await source.writeAsBytes(encrypted, flush: true);
        final reader = WindowsLegacyStateKey(directory);
        expect(await reader.read(name), value);
        expect(await source.readAsBytes(), encrypted);
        expect(await unprotectWindowsState(encrypted), plain);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'real Windows DPAPI failure preserves the encrypted source and reports recovery',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'legacy-dpapi-bad-',
      );
      try {
        final source = File(
          '${directory.path}/${WindowsLegacyStateKey.encryptedFileName}',
        );
        await source.writeAsBytes([1, 2, 3, 4]);
        final reader = WindowsLegacyStateKey(directory);
        for (var i = 0; i < 2; i++) {
          await expectLater(
            reader.read('fixture-${directory.path.hashCode}'),
            throwsA(
              isA<PlatformException>().having(
                (e) => e.code,
                'code',
                'windows_state_key',
              ),
            ),
          );
        }
        expect(await source.readAsBytes(), [1, 2, 3, 4]);
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'real Windows credential read never creates a missing record',
    () async {
      final target =
          'asterlink-disposable-missing-${DateTime.now().microsecondsSinceEpoch}';
      expect(await readWindowsStateCredential(target), isNull);
      expect(await readWindowsStateCredential(target), isNull);
    },
    skip: !Platform.isWindows,
  );
}
