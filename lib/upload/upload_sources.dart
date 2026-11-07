import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../data/http.dart';
import '../platform/native_engine.dart';
import 'upload_folder.dart';

/// Reopens picker sources without making a full copy of the selected folder.
class UploadSources {
  UploadSources({bool? android, bool? ios, MethodChannel? channel})
    : android = android ?? Platform.isAndroid,
      ios = ios ?? Platform.isIOS,
      channel = channel ?? nativeChannel;
  final bool android, ios;
  final MethodChannel channel;

  Future<T?> _call<T>(String method, [Json? args]) async {
    try {
      return await channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw AppException(e.message ?? '无法读取所选文件夹，请重新选择并检查权限');
    }
  }

  Future<String?> pickFolder() => android || ios
      ? _call<String>('chooseUploadDirectory')
      : getDirectoryPath(confirmButtonText: '上传此文件夹');

  Future<UploadFolder> scanFolder(String location) async {
    RequestScope.checkpoint();
    if (android || ios) {
      final raw = asJson(
        await _call<Object?>('uploadScan', {'path': location}),
      );
      RequestScope.checkpoint();
      require(
        raw['files'] is List &&
            (raw['files'] as List).length == raw.list('files').length &&
            raw['directories'] is List,
        '文件夹读取结果不完整，请重新选择',
      );
      return UploadFolder(
        location: raw.str('location').ifEmpty(location),
        name: raw.str('name'),
        files: [
          for (final value in raw.list('files'))
            UploadFolderFile(
              location: value.str('location'),
              relativePath: value.str('relative'),
              size: value.integer('size', -1),
              modifiedAt: value.integer('modifiedAt'),
            ),
        ],
        directories: (raw['directories'] as List? ?? const []).cast<String>(),
        skippedLinks: raw.integer('skippedLinks'),
      );
    }
    final uri = Uri.tryParse(location);
    final path = uri?.scheme == 'file' ? File.fromUri(uri!).path : location;
    require(p.isAbsolute(path), '请选择本地文件夹');
    final root = await Directory(path).resolveSymbolicLinks();
    final files = <UploadFolderFile>[], directories = <String>[''];
    var skippedLinks = 0;
    await for (final child in Directory(
      root,
    ).list(recursive: true, followLinks: false)) {
      RequestScope.checkpoint();
      final relative = uploadRelativePath(
        p.relative(child.path, from: root).split(p.separator).join('/'),
      );
      if (child is Link) {
        skippedLinks++;
        continue;
      }
      if (child is Directory) directories.add(relative);
      if (child is File) {
        final stat = await child.stat();
        require(stat.type == FileSystemEntityType.file, '文件已变化，请重新选择文件夹');
        files.add(
          UploadFolderFile(
            location: child.path,
            relativePath: relative,
            size: stat.size,
            modifiedAt: stat.modified.millisecondsSinceEpoch,
          ),
        );
      }
      require(
        files.length + directories.length <= uploadMaxFolderEntries,
        '一次最多上传 10000 个文件和目录，请分批选择',
      );
    }
    return UploadFolder(
      location: root,
      name: p.basename(root),
      files: files,
      directories: directories,
      skippedLinks: skippedLinks,
    );
  }

  Future<void> validate(UploadFolderFile file) async {
    RequestScope.checkpoint();
    if (android || ios) {
      final stat = asJson(
        await _call<Object?>('uploadStat', {'path': file.location}),
      );
      require(
        stat.integer('size', -1) == file.size &&
            (file.modifiedAt <= 0 ||
                stat.integer('modifiedAt') == file.modifiedAt),
        '本地文件已变化，请重新选择上传',
      );
    } else {
      try {
        require(
          await FileSystemEntity.type(file.location, followLinks: false) ==
              FileSystemEntityType.file,
          '本地文件已移走或变为链接，请重新选择上传',
        );
        final stat = await File(file.location).stat();
        require(
          stat.size == file.size &&
              stat.modified.millisecondsSinceEpoch == file.modifiedAt,
          '本地文件已变化，请重新选择上传',
        );
      } on FileSystemException {
        throw const AppException('本地文件已移走或不可读取，请重新选择上传');
      }
    }
    RequestScope.checkpoint();
  }

  Future<void> validateFolder(UploadFolder folder) async {
    RequestScope.checkpoint();
    if (android || ios) {
      await _call<void>('uploadCheckDirectory', {'path': folder.location});
    } else {
      final directory = Directory(folder.location);
      require(await directory.exists(), '本地文件夹已移走，请重新选择上传');
      require(
        p.equals(folder.location, await directory.resolveSymbolicLinks()),
        '本地文件夹已变为链接，请重新选择上传',
      );
    }
    RequestScope.checkpoint();
  }

  Stream<List<int>> read(UploadFolderFile file, int start, int end) async* {
    require(start >= 0 && end >= start && end <= file.size, '文件读取范围无效');
    if (start == end) return;
    if (!android && !ios) {
      yield* File(file.location).openRead(start, end);
      return;
    }
    String? handle;
    if (android) {
      handle = await _call<String>('uploadOpenRead', {
        'path': file.location,
        'offset': start,
      });
      require(handle?.isNotEmpty == true, '无法读取所选文件');
    }
    var offset = start;
    try {
      while (offset < end) {
        RequestScope.checkpoint();
        final bytes = await _call<Uint8List>('uploadRead', {
          if (android) 'id': handle,
          if (ios) ...{'path': file.location, 'offset': offset},
          'length': (end - offset).clamp(1, 512 * 1024),
        });
        require(
          bytes != null && bytes.isNotEmpty && bytes.length <= end - offset,
          '本地文件读取不完整，请重新选择',
        );
        RequestScope.checkpoint();
        offset += bytes!.length;
        yield bytes;
      }
    } finally {
      if (handle != null) {
        try {
          await _call<void>('uploadCloseRead', {'id': handle});
        } catch (_) {}
      }
    }
  }
}
