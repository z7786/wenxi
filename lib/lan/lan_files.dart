import 'dart:io';
import 'package:crypto/crypto.dart' as crypto;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../data/http.dart';
import '../platform/file_access.dart';
import '../platform/native_engine.dart';
import '../platform/apple_storage.dart';
import 'lan_models.dart';

class LanLocalFile {
  const LanLocalFile({
    required this.location,
    required this.path,
    required this.size,
    required this.modifiedAt,
  });
  final String location, path;
  final int size, modifiedAt;
}

class LanFileSelection {
  const LanFileSelection(this.files, [this.directories = const []]);
  final List<LanLocalFile> files;
  final List<String> directories;
}

class LanFiles {
  LanFiles({bool? android, MethodChannel? channel})
    : android = android ?? Platform.isAndroid,
      channel = channel ?? nativeChannel;
  final bool android;
  final MethodChannel channel;

  Future<List<String>> pickFiles() async {
    if (android) {
      return (await channel.invokeListMethod<String>('lanPickFiles')) ?? [];
    }
    return (await openFiles(
      confirmButtonText: '分享所选文件',
    )).map((f) => f.path).toList();
  }

  Future<LanFileSelection> scan(
    List<String> locations, {
    bool folder = false,
  }) async {
    require(locations.isNotEmpty, '请选择文件');
    final files = <LanLocalFile>[], directories = <String>[];
    final roots = <String>{};
    for (final location in locations) {
      RequestScope.checkpoint();
      final Json raw;
      if (android) {
        raw = asJson(
          await channel.invokeMethod<Object?>('lanScan', {
            'path': location,
            'folder': folder,
          }),
        );
      } else {
        raw = await _scanDesktop(location, folder);
      }
      final original = safeFileName(raw.str('name'));
      var root = original, suffix = 1;
      while (!roots.add(root.toLowerCase())) {
        root =
            '${p.basenameWithoutExtension(original)} (${suffix++})${p.extension(original)}';
      }
      String relative(String value) => value.isEmpty
          ? root
          : '$root/${value.split('/').map(safeFileName).join('/')}';
      for (final entry in raw.list('files')) {
        files.add(
          LanLocalFile(
            location: entry.str('location'),
            path: relative(entry.str('relative')),
            size: entry.integer('size', -1),
            modifiedAt: entry.integer('modifiedAt'),
          ),
        );
      }
      directories.addAll(
        (raw['directories'] as List? ?? []).map((d) => relative('$d')),
      );
      require(
        files.length <= lanMaxFiles && directories.length <= lanMaxFiles,
        '一次最多分享 10000 个文件或目录',
      );
    }
    require(
      files.every((f) => f.location.isNotEmpty && f.size >= 0),
      '无法读取所选文件大小',
    );
    final paths = <String>{};
    for (final value in [...directories, ...files.map((f) => f.path)]) {
      lanRelativePath(value);
      require(paths.add(value.toLowerCase()), '部分文件整理后名称重复，请分开分享');
    }
    return LanFileSelection(files, directories);
  }

  Future<Json> _scanDesktop(String location, bool folder) async {
    final uri = Uri.tryParse(location);
    final path = await resolveAppleDirectory(
      uri?.scheme == 'file' ? File.fromUri(uri!).path : location,
    );
    require(p.isAbsolute(path), '文件位置无效');
    final entity = folder ? Directory(path) : File(path);
    final resolved = await entity.resolveSymbolicLinks();
    final name = p.basename(resolved),
        files = <Json>[],
        directories = <String>[];
    Future<void> add(File file, String relative) async {
      final stat = await file.stat();
      require(stat.type == FileSystemEntityType.file, '文件不可读取');
      files.add({
        'location': file.path,
        'relative': relative,
        'size': stat.size,
        'modifiedAt': stat.modified.millisecondsSinceEpoch,
      });
    }

    if (folder) {
      directories.add('');
      await for (final child in Directory(
        resolved,
      ).list(recursive: true, followLinks: false)) {
        RequestScope.checkpoint();
        final relative = p
            .relative(child.path, from: resolved)
            .split(p.separator)
            .join('/');
        if (child is Directory) directories.add(relative);
        if (child is File) await add(child, relative);
        require(
          files.length <= lanMaxFiles && directories.length <= lanMaxFiles,
          '一次最多分享 10000 个文件或目录',
        );
      }
    } else {
      await add(File(resolved), '');
    }
    return {'name': name, 'files': files, 'directories': directories};
  }

  Stream<List<int>> read(LanLocalFile file, [int start = 0, int? end]) async* {
    final stop = end ?? file.size;
    require(start >= 0 && stop >= start && stop <= file.size, '文件读取范围无效');
    if (!android) {
      yield* File(
        await resolveAppleDirectory(file.location),
      ).openRead(start, stop);
      return;
    }
    final handle = await channel.invokeMethod<String>('lanOpenRead', {
      'path': file.location,
      'offset': start,
    });
    require(handle != null, '无法读取所选文件');
    var remaining = stop - start;
    try {
      while (remaining > 0) {
        RequestScope.checkpoint();
        final chunk = await channel.invokeMethod<Uint8List>('lanRead', {
          'id': handle,
          'length': remaining.clamp(1, 512 * 1024),
        });
        require(
          chunk != null && chunk.isNotEmpty && chunk.length <= remaining,
          '源文件在传输期间发生变化',
        );
        remaining -= chunk!.length;
        yield chunk;
      }
    } finally {
      try {
        await channel.invokeMethod<void>('lanCloseRead', {'id': handle});
      } catch (_) {}
    }
  }

  Future<void> check(LanLocalFile file) async {
    if (android) {
      final stat = asJson(
        await channel.invokeMethod<Object?>('lanStat', {'path': file.location}),
      );
      require(
        stat.integer('size', -1) == file.size &&
            (file.modifiedAt <= 0 ||
                stat.integer('modifiedAt') == file.modifiedAt),
        '源文件已修改，请重新创建分享',
      );
    } else {
      final location = await resolveAppleDirectory(file.location);
      require(
        await FileSystemEntity.type(location, followLinks: false) ==
            FileSystemEntityType.file,
        '源文件已变化，请重新创建分享',
      );
      final stat = await File(location).stat();
      require(
        stat.type == FileSystemEntityType.file &&
            stat.size == file.size &&
            stat.modified.millisecondsSinceEpoch == file.modifiedAt,
        '源文件已修改，请重新创建分享',
      );
    }
  }

  Future<String> digest(LanLocalFile file) async {
    await check(file);
    final result = await crypto.sha256
        .bind(
          read(file).map((bytes) {
            RequestScope.checkpoint();
            return bytes;
          }),
        )
        .first;
    await check(file);
    return result.toString();
  }

  Future<void> createDirectories(
    String destination,
    List<String> directories,
  ) async {
    for (final directory in directories) {
      lanRelativePath(directory);
    }
    if (android) {
      await channel.invokeMethod<void>('lanCreateDirectories', {
        'destination': destination,
        'directories': directories,
      });
      return;
    }
    final root = Directory(await resolveAppleDirectory(destination));
    await root.create(recursive: true);
    final resolvedRoot = await root.resolveSymbolicLinks();
    for (final directory in directories) {
      var current = resolvedRoot;
      for (final part in directory.split('/')) {
        current = p.join(current, part);
        require(
          await FileSystemEntity.type(current, followLinks: false) !=
              FileSystemEntityType.link,
          '保存目录包含符号链接，请换一个目录',
        );
        await Directory(current).create();
        require(
          p.isWithin(
            resolvedRoot,
            await Directory(current).resolveSymbolicLinks(),
          ),
          '文件夹超出所选目录',
        );
      }
    }
  }

  Future<void> network(bool enabled) async {
    if (android) {
      await channel.invokeMethod<void>('lanNetwork', {'enabled': enabled});
    }
  }
}
