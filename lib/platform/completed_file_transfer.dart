import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'file_access.dart';
import 'windows_storage.dart';

/// Publishes a new name without replacing any existing destination. The caller
/// commits the download record before deleting the old name for a move.
class CompletedFileTransfer {
  static Future<File> publish(
    File source,
    String destination, {
    required bool move,
    required void Function() checkpoint,
    void Function(int copied, int total)? onProgress,
  }) async {
    require(p.isAbsolute(source.path) && p.isAbsolute(destination), '文件路径无效');
    require(
      await FileSystemEntity.type(source.path, followLinks: false) ==
          FileSystemEntityType.file,
      '原文件已不存在或位置发生变化',
    );
    final directory = Directory(destination);
    require(await directory.exists(), '目标目录不存在');
    final resolved = await directory.resolveSymbolicLinks();
    final sourcePath = await source.resolveSymbolicLinks();
    require(!move || !p.equals(p.dirname(sourcePath), resolved), '文件已在目标目录');
    final name = safeFileName(p.basename(source.path));
    final ext = p.extension(name), base = p.basenameWithoutExtension(name);
    final total = await source.length();
    final from = move && Platform.isWindows
        ? WindowsStorage.volume(sourcePath)
        : null;
    final to = from == null ? null : WindowsStorage.volume(resolved);
    final link = from != null && from.supportsHardLinks && from.id == to?.id;
    File? target;
    for (var i = 0; i < 10000; i++) {
      checkpoint();
      final candidate = File(
        p.join(resolved, i == 0 ? name : '$base ($i)$ext'),
      );
      try {
        if (link) {
          WindowsStorage.createHardLink(sourcePath, candidate.path);
        } else {
          await candidate.create(exclusive: true);
        }
        target = candidate;
        break;
      } on FileSystemException {
        if (await FileSystemEntity.type(candidate.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          rethrow;
        }
      }
    }
    require(target != null, '目标目录同名文件过多');
    RandomAccessFile? output;
    try {
      if (!link) {
        output = await target!.open(mode: FileMode.write);
        var copied = 0;
        await for (final bytes in source.openRead()) {
          checkpoint();
          await output.writeFrom(bytes);
          copied += bytes.length;
          onProgress?.call(copied, total);
        }
        require(
          copied == total && await source.length() == total,
          '原文件在复制时发生变化，已保留原文件',
        );
        await output.flush();
        await output.close();
        output = null;
      }
      checkpoint();
      onProgress?.call(total, total);
      return target!;
    } catch (_) {
      await output?.close();
      await target!.delete();
      rethrow;
    }
  }
}
