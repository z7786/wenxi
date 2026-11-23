import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_storage.dart';

/// Resolve storage paths without requiring virtual Windows disks to implement
/// GetFinalPathNameByHandle. Preserve real link resolution wherever supported.
Future<String> resolveStoragePath(FileSystemEntity entity) async {
  try {
    return await entity.resolveSymbolicLinks();
  } on FileSystemException catch (error) {
    // ImDisk can support file I/O but reject this final-path query with
    // ERROR_INVALID_FUNCTION / ERROR_NOT_SUPPORTED. Never mask access errors.
    if (!Platform.isWindows ||
        !const {1, 50}.contains(error.osError?.errorCode)) {
      rethrow;
    }
    final path = p.normalize(p.absolute(entity.path));
    // A fallback must not let a junction or symbolic link escape the selected
    // directory. If any component cannot be inspected, retain the error.
    if (!WindowsStorage.isPlainPath(path)) rethrow;
    return path;
  }
}
