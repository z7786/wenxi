import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../core/json.dart';

/// Read the host executable without relying on the launch working directory.
/// Some embedded Dart runtimes omit the resolved-executable metadata.
String applicationExecutablePath() => resolveExecutablePath();

String resolveExecutablePath({
  String? platform,
  String? Function()? resolved,
  String? Function()? nativeWindows,
  String? Function()? invocation,
}) {
  final system = platform ?? Platform.operatingSystem;
  final paths = system == 'windows' ? p.windows : p.posix;
  String? read(String? Function() getter) {
    try {
      final value = getter();
      if (value == null ||
          value.isEmpty ||
          value.contains('\u0000') ||
          !paths.isAbsolute(value) ||
          paths.isRootRelative(value)) {
        return null;
      }
      final normalized = paths.normalize(value);
      if (paths.dirname(normalized) == normalized) return null;
      return normalized;
    } catch (_) {
      return null;
    }
  }

  final dart = read(resolved ?? () => Platform.resolvedExecutable);
  if (dart != null) return dart;
  if (system == 'windows') {
    final native = read(nativeWindows ?? windowsProcessExecutablePath);
    if (native != null) return native;
  }
  final original = read(invocation ?? () => Platform.executable);
  if (original != null) return original;
  throw const AppException('无法读取程序安装路径，请重新打开软件或重新安装；现有数据已保留');
}

String? windowsProcessExecutablePath() {
  if (!Platform.isWindows) return null;
  // A Unicode Windows path can contain up to 32,767 characters.
  const capacity = 32768;
  final buffer = calloc<Uint16>(capacity).cast<Utf16>();
  try {
    final length = _WindowsModulePath.read(nullptr, buffer, capacity);
    if (length == 0 || length >= capacity) return null;
    return buffer.toDartString(length: length);
  } finally {
    calloc.free(buffer);
  }
}

class _WindowsModulePath {
  static final read = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Void>, Pointer<Utf16>, int)
      >('GetModuleFileNameW');
}
