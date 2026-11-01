import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

class WindowsStorageVolume {
  const WindowsStorageVolume(this.id, {required this.supportsHardLinks});
  final String id;
  final bool supportsHardLinks;
}

/// Hard links keep the resumable payload until the completed task is durable,
/// without allocating a second full file on its volume.
class WindowsStorage {
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _volumePath = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('GetVolumePathNameW');
  static final _volumeName = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('GetVolumeNameForVolumeMountPointW');
  static final _volumeInformation = _kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Utf16>,
          Uint32,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Utf16>,
          int,
        )
      >('GetVolumeInformationW');
  static final _hardLink = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>)
      >('CreateHardLinkW');
  static final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

  static WindowsStorageVolume? volume(String path) {
    if (!Platform.isWindows) return null;
    const capacity = 32768;
    final input = path.toNativeUtf16();
    final mount = calloc<Uint16>(capacity).cast<Utf16>();
    final name = calloc<Uint16>(capacity).cast<Utf16>();
    final flags = calloc<Uint32>();
    try {
      if (_volumePath(input, mount, capacity) == 0) return null;
      final hasIdentity = _volumeName(mount, name, capacity) != 0;
      final hasFlags =
          _volumeInformation(
            mount,
            nullptr,
            0,
            nullptr,
            nullptr,
            flags,
            nullptr,
            0,
          ) !=
          0;
      return WindowsStorageVolume(
        (hasIdentity ? name : mount).toDartString().toLowerCase(),
        supportsHardLinks: hasFlags && (flags.value & 0x00400000) != 0,
      );
    } finally {
      calloc.free(flags);
      calloc.free(name);
      calloc.free(mount);
      calloc.free(input);
    }
  }

  static void createHardLink(String source, String target) {
    final existing = source.toNativeUtf16();
    final output = target.toNativeUtf16();
    try {
      if (_hardLink(output, existing, nullptr) == 0) {
        final code = _lastError();
        throw FileSystemException(
          '无法发布下载文件，缓存已保留，请检查目录权限后重试',
          target,
          OSError('CreateHardLinkW failed', code),
        );
      }
    } finally {
      calloc.free(output);
      calloc.free(existing);
    }
  }
}
