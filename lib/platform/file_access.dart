import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'android_download_file.dart';
import 'native_engine.dart';
import 'windows_storage.dart';

String safeFileName(String raw) {
  var name = raw
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') name = 'download.bin';
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  if (name.length > 180) {
    final ext = p.extension(name);
    name = '${name.substring(0, 160)}${ext.length < 20 ? ext : ''}';
  }
  return name;
}

String safeRelativePath(String raw) => raw
    .replaceAll('\\', '/')
    .split('/')
    .where((s) => s.trim().isNotEmpty && s.trim() != '.' && s.trim() != '..')
    .map(safeFileName)
    .join(p.separator);

abstract class FileAccess {
  bool get directDownloads => false;
  Future<Json?> inspectDownloadTarget(String id) async => null;
  Future<DirectDownloadTarget> openDownloadTarget({
    required String id,
    required String name,
    required String relativePath,
    String? destination,
  }) async => throw const AppException('此平台不支持直接下载');
  Future<String> finishDownloadTarget(
    String id,
    DirectDownloadTarget target,
    String name,
  ) async => throw const AppException('此平台不支持直接下载');
  Future<void> releaseDownloadTarget(
    String id,
    DirectDownloadTarget target,
  ) async {}
  Future<void> discardDownloadTarget(String id) async {}
  Future<void> forgetDownloadTarget(String id) async {}
  // Android targets use openDownloadTarget. This cache root is only used for
  // legacy Android payloads and for desktop downloads beside the destination.
  Future<String?> downloadCacheRoot(String? destination) async => null;
  Future<StoragePlan> storagePlan(String cache, String? destination) async =>
      StoragePlan(StorageVolume('cache', cache), StorageVolume('cache', cache));
  Future<FileAvailability> inspect(String? path);
  Future<String?> chooseDirectory();
  Future<int> freeBytes(String path);
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int copied, int total)? onProgress,
  });
  Future<void> cancelExport(String id);
  Future<void> delete(String? path);
}

/// Only the target key/URI are durable. The path and lease belong to this process.
class DirectDownloadTarget {
  const DirectDownloadTarget({
    required this.uri,
    required this.path,
    required this.key,
    required this.lease,
    File? file,
  }) : _file = file;
  final String uri, path, key, lease;
  final File? _file;
  File get file => _file ?? File(path);
  Json get engineArguments => {'outputPath': path, 'outputKey': key};
}

class StorageVolume {
  const StorageVolume(this.id, this.path);
  final String id, path;
}

class StoragePlan {
  const StoragePlan(
    this.cache,
    this.target, {
    this.directOutput = false,
    this.copyOnSave = true,
  });
  final StorageVolume cache, target;
  final bool directOutput, copyOnSave;
  StoragePlan forDirectOutput() =>
      StoragePlan(cache, target, directOutput: true, copyOnSave: false);
  Map<String, int> requirements(int total, int downloaded, {int overhead = 0}) {
    if (directOutput) {
      final result = {target.id: (total - downloaded).clamp(0, total)};
      if (overhead > 0) result[cache.id] = (result[cache.id] ?? 0) + overhead;
      return result;
    }
    final result = {cache.id: (total - downloaded).clamp(0, total) + overhead};
    if (copyOnSave) result[target.id] = (result[target.id] ?? 0) + total;
    return result;
  }
}

enum FileAvailability { unknown, present, missing, inaccessible }

extension FileAvailabilityLabel on FileAvailability {
  String get label => switch (this) {
    FileAvailability.unknown => '正在检查文件',
    FileAvailability.present => '已完成',
    FileAvailability.missing => '文件不存在',
    FileAvailability.inaccessible => '无法访问文件',
  };
}

class PlatformFileAccess implements FileAccess {
  PlatformFileAccess(this.transport, this.defaultDirectory, {bool? android})
    : _android = android ?? Platform.isAndroid;
  final bool _android;
  final NativeTransport transport;
  final Directory defaultDirectory;
  @override
  bool get directDownloads => _android;
  Future<T?> _targetCall<T>(String method, Json arguments) async {
    try {
      return await nativeChannel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法访问下载目标，请检查目录权限');
    }
  }

  @override
  Future<Json?> inspectDownloadTarget(String id) async {
    if (!_android) return null;
    final value = await _targetCall<Object?>('inspectDownloadTarget', {
      'id': id,
    });
    return value == null ? null : asJson(value);
  }

  @override
  Future<DirectDownloadTarget> openDownloadTarget({
    required String id,
    required String name,
    required String relativePath,
    String? destination,
  }) async {
    require(_android, '此平台不支持直接下载');
    final value = asJson(
      await _targetCall<Object?>('openDownloadTarget', {
        'id': id,
        'name': safeFileName(name),
        'relativePath': safeRelativePath(relativePath),
        'destination': destination,
      }),
    );
    require(
      Uri.tryParse(value.str('uri'))?.scheme == 'content' &&
          RegExp(r'^/proc/self/fd/[0-9]+$').hasMatch(value.str('path')) &&
          value.str('lease').isNotEmpty &&
          value.str('key').isNotEmpty,
      '下载目标响应无效',
    );
    return DirectDownloadTarget(
      uri: value.str('uri'),
      path: value.str('path'),
      key: value.str('key'),
      lease: value.str('lease'),
      file: AndroidDownloadFile(
        path: value.str('path'),
        id: id,
        lease: value.str('lease'),
        channel: nativeChannel,
      ),
    );
  }

  @override
  Future<String> finishDownloadTarget(
    String id,
    DirectDownloadTarget target,
    String name,
  ) async {
    final uri = await _targetCall<String>('finishDownloadTarget', {
      'id': id,
      'lease': target.lease,
      'name': safeFileName(name),
    });
    require(uri == target.uri, '下载目标身份发生变化，文件已保留');
    return uri!;
  }

  @override
  Future<void> releaseDownloadTarget(
    String id,
    DirectDownloadTarget target,
  ) async {
    await _targetCall<void>('releaseDownloadTarget', {
      'id': id,
      'lease': target.lease,
    });
  }

  @override
  Future<void> discardDownloadTarget(String id) async {
    if (_android) await _targetCall<void>('discardDownloadTarget', {'id': id});
  }

  @override
  Future<void> forgetDownloadTarget(String id) async {
    if (_android) await _targetCall<void>('forgetDownloadTarget', {'id': id});
  }

  final _exportCallbacks = <String, (int, void Function(int, int))>{};
  int _exportGeneration = 0;
  void exportProgress(Json value) {
    final callback = _exportCallbacks[value.str('id')];
    if (callback != null && callback.$1 == value.integer('token')) {
      callback.$2(value.integer('copied'), value.integer('total'));
    }
  }

  @override
  Future<String?> downloadCacheRoot(String? destination) async {
    if (_android) return null;
    final target = destination ?? defaultDirectory.path;
    require(p.isAbsolute(target), '请选择有效的下载目录');
    return p.normalize(p.join(target, GopeedEngine.destinationCacheName));
  }

  @override
  Future<StoragePlan> storagePlan(String cache, String? destination) async {
    if (_android) {
      final value = asJson(
        await nativeChannel.invokeMethod<Object?>('storagePlan', {
          'cache': cache,
          'destination': destination,
        }),
      );
      StorageVolume volume(String key) => StorageVolume(
        value.obj(key).str('volume'),
        value.obj(key).str('path'),
      );
      return StoragePlan(volume('cache'), volume('target'));
    }
    Future<(StorageVolume, bool)> volume(String path) async {
      var directory = Directory(path).absolute;
      while (!await directory.exists() &&
          p.dirname(directory.path) != directory.path) {
        directory = directory.parent;
      }
      final resolved = await directory.resolveSymbolicLinks();
      final windows = WindowsStorage.volume(resolved);
      return (
        StorageVolume(
          windows?.id ?? p.rootPrefix(resolved).toLowerCase(),
          resolved,
        ),
        windows?.supportsHardLinks ?? false,
      );
    }

    final cacheVolume = await volume(cache);
    final targetVolume = await volume(destination ?? defaultDirectory.path);
    return StoragePlan(
      cacheVolume.$1,
      targetVolume.$1,
      copyOnSave:
          cacheVolume.$1.id != targetVolume.$1.id ||
          !cacheVolume.$2 ||
          !targetVolume.$2,
    );
  }

  @override
  Future<FileAvailability> inspect(String? path) async {
    if (path == null || path.isEmpty) return FileAvailability.missing;
    if (_android) {
      try {
        return switch (await nativeChannel.invokeMethod<String>(
          'fileAvailability',
          {'path': path},
        )) {
          'present' => FileAvailability.present,
          'missing' => FileAvailability.missing,
          _ => FileAvailability.inaccessible,
        };
      } catch (_) {
        return FileAvailability.inaccessible;
      }
    }
    RandomAccessFile? handle;
    try {
      final uri = Uri.tryParse(path);
      final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(path);
      if (!p.isAbsolute(file.path)) return FileAvailability.inaccessible;
      handle = await file.open();
      await handle.length();
      return FileAvailability.present;
    } on FileSystemException catch (error) {
      return {2, 3}.contains(error.osError?.errorCode)
          ? FileAvailability.missing
          : FileAvailability.inaccessible;
    } catch (_) {
      return FileAvailability.inaccessible;
    } finally {
      await handle?.close();
    }
  }

  @override
  Future<String?> chooseDirectory() async => Platform.isAndroid
      ? nativeChannel.invokeMethod<String>('chooseDirectory')
      : getDirectoryPath(confirmButtonText: '选择下载目录');
  @override
  Future<int> freeBytes(String path) async {
    if (_android) {
      return await nativeChannel.invokeMethod<int>('freeSpace', {
            'path': path,
          }) ??
          -1;
    }
    return asJson(
      await transport.call('freeSpace', {'path': path}),
    ).integer('bytes');
  }

  @override
  Future<void> cancelExport(String id) async {
    if (Platform.isAndroid) {
      await nativeChannel.invokeMethod<void>('cancelExport', {'id': id});
    }
  }

  @override
  Future<String> save({
    required String id,
    required File source,
    required String name,
    required String relativePath,
    String? destination,
    required void Function() checkpoint,
    void Function(int copied, int total)? onProgress,
  }) async {
    checkpoint();
    if (_android) {
      final token = ++_exportGeneration;
      if (onProgress != null) _exportCallbacks[id] = (token, onProgress);
      try {
        return (await nativeChannel.invokeMethod<String>('saveFile', {
          'id': id,
          'source': source.path,
          'name': safeFileName(name),
          'relativePath': safeRelativePath(relativePath),
          'destination': destination,
          'token': token,
        }))!;
      } on PlatformException catch (e) {
        throw AppException(e.message ?? '无法保存文件');
      } finally {
        if (_exportCallbacks[id]?.$1 == token) _exportCallbacks.remove(id);
      }
    }
    final root = Directory(destination ?? defaultDirectory.path);
    await root.create(recursive: true);
    final rootPath = await root.resolveSymbolicLinks();
    final targetDirectory = Directory(
      p.join(rootPath, safeRelativePath(relativePath)),
    );
    await targetDirectory.create(recursive: true);
    final resolved = await targetDirectory.resolveSymbolicLinks();
    require(
      p.equals(rootPath, resolved) || p.isWithin(rootPath, resolved),
      '下载路径超出所选目录',
    );
    final safe = safeFileName(name),
        base = p.basenameWithoutExtension(safe),
        ext = p.extension(safe);
    final plan = await storagePlan(source.parent.path, resolved);
    if (!plan.copyOnSave) {
      final total = await source.length();
      for (var i = 0; i < 10000; i++) {
        checkpoint();
        final file = File(p.join(resolved, i == 0 ? safe : '$base ($i)$ext'));
        try {
          WindowsStorage.createHardLink(source.path, file.path);
        } on FileSystemException {
          if (!await file.exists()) rethrow;
          continue;
        }
        try {
          checkpoint();
          onProgress?.call(total, total);
          return file.path;
        } catch (_) {
          await file.delete();
          rethrow;
        }
      }
      throw const AppException('同名文件过多，请更换下载目录');
    }
    File? target;
    for (var i = 0; i < 10000; i++) {
      checkpoint();
      final file = File(p.join(resolved, i == 0 ? safe : '$base ($i)$ext'));
      try {
        await file.create(exclusive: true);
        target = file;
        break;
      } on FileSystemException {
        if (!await file.exists()) rethrow;
      }
    }
    require(target != null, '同名文件过多，请更换下载目录');
    RandomAccessFile? output;
    final total = await source.length();
    var copied = 0;
    try {
      output = await target!.open(mode: FileMode.write);
      await for (final bytes in source.openRead()) {
        checkpoint();
        await output.writeFrom(bytes);
        copied += bytes.length;
        onProgress?.call(copied, total);
      }
      checkpoint();
      await output.flush();
      await output.close();
      output = null;
      return target.path;
    } catch (_) {
      await output?.close();
      if (await target!.exists()) await target.delete();
      rethrow;
    }
  }

  @override
  Future<void> delete(String? path) async {
    if (path == null || path.isEmpty) return;
    if (_android) {
      try {
        await nativeChannel.invokeMethod<void>('deleteFile', {'path': path});
      } on PlatformException catch (e) {
        throw AppException(e.message ?? '文件未能删除，请检查目录权限后重试');
      }
    } else {
      final uri = Uri.tryParse(path);
      final file = uri?.scheme == 'file' ? File.fromUri(uri!) : File(path);
      require(p.isAbsolute(file.path), '已保存文件路径无效');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (await inspect(path) == FileAvailability.missing) return;
        throw const AppException('无法访问文件，请检查目录权限后重试');
      }
      require(type == FileSystemEntityType.file, '文件位置发生变化，已保留下载记录');
      try {
        await file.delete();
      } on FileSystemException {
        if (await inspect(path) == FileAvailability.missing) return;
        throw const AppException('文件正在使用或目录不可写，已保留下载记录');
      }
    }
  }
}
