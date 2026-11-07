import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../domain/uploads.dart';

const uploadMaxFolderEntries = 10000;

String uploadRelativePath(String value, {bool allowRoot = false}) {
  if (value.isEmpty && allowRoot) return value;
  final parts = value.split('/');
  require(
    value.isNotEmpty &&
        value.length <= 2048 &&
        parts.length <= 63 &&
        parts.every(
          (part) =>
              part.trim().isNotEmpty &&
              part != '.' &&
              part != '..' &&
              !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(part),
        ),
    '文件夹包含无效的文件名或目录层级过深',
  );
  return value;
}

class UploadFolderFile {
  UploadFolderFile({
    required this.location,
    required String relativePath,
    required this.size,
    required this.modifiedAt,
    this.mimeType = 'application/octet-stream',
    String fileId = '',
  }) : relativePath = uploadRelativePath(relativePath),
       _fileId = fileId {
    require(location.isNotEmpty && size >= 0, '无法读取所选文件');
  }

  final String location, relativePath, mimeType;
  final int size, modifiedAt;
  String _fileId;
  String get fileId => _fileId;
  bool get completed => _fileId.isNotEmpty;
  String get name => p.posix.basename(relativePath);
  String get directory =>
      p.posix.dirname(relativePath) == '.' ? '' : p.posix.dirname(relativePath);

  Json toJson() => {
    'location': location,
    'relativePath': relativePath,
    'size': size,
    'modifiedAt': modifiedAt,
    'mimeType': mimeType,
    if (fileId.isNotEmpty) 'fileId': fileId,
  };

  factory UploadFolderFile.fromJson(Json value) => UploadFolderFile(
    location: value.str('location'),
    relativePath: value.str('relativePath'),
    size: value.integer('size', -1),
    modifiedAt: value.integer('modifiedAt'),
    mimeType: value.str('mimeType', 'application/octet-stream'),
    fileId: value.str('fileId'),
  );
}

/// A durable snapshot of a selected directory. Completed files and remote
/// directory identities survive retries without flattening the local tree.
class UploadFolder {
  UploadFolder({
    required this.location,
    required this.name,
    required List<UploadFolderFile> files,
    List<String> directories = const [],
    Map<String, String> remoteDirectories = const {},
    Map<String, String> remoteDirectoryFiles = const {},
    this.skippedLinks = 0,
  }) : files = List.unmodifiable(files),
       remoteDirectories = Map.of(remoteDirectories),
       remoteDirectoryFiles = Map.of(remoteDirectoryFiles) {
    require(location.isNotEmpty, '文件夹位置无效');
    UploadFile(name: name, size: 0, read: (_, _) => const Stream.empty());
    final paths = <String, String>{'': ''};
    void directory(String path) {
      uploadRelativePath(path, allowRoot: true);
      if (path.isEmpty) return;
      final key = path.toLowerCase();
      require(!paths.containsKey(key) || paths[key] == path, '文件夹包含同名目录');
      paths[key] = path;
      final parent = p.posix.dirname(path);
      if (parent != '.') directory(parent);
    }

    for (final path in directories) {
      directory(path);
    }
    for (final file in files) {
      directory(file.directory);
    }
    final names = paths.keys.toSet();
    for (final file in files) {
      require(names.add(file.relativePath.toLowerCase()), '文件夹包含同名文件或目录');
    }
    require(
      files.length + paths.length <= uploadMaxFolderEntries,
      '一次最多上传 10000 个文件和目录，请分批选择',
    );
    this.directories = List.unmodifiable(
      paths.values.toList()..sort((a, b) {
        final depth = a.split('/').length.compareTo(b.split('/').length);
        return depth != 0 ? depth : a.compareTo(b);
      }),
    );
    size = files.fold(0, (sum, file) => sum + file.size);
    for (final file in files.where((f) => f.completed)) {
      completedFiles++;
      completedBytes += file.size;
    }
    require(
      remoteDirectories.entries.every(
            (e) => paths[e.key.toLowerCase()] == e.key && e.value.isNotEmpty,
          ) &&
          remoteDirectoryFiles.entries.every(
            (e) => remoteDirectories.containsKey(e.key) && e.value.isNotEmpty,
          ),
      '已保存的上传目录信息无效，请重新选择文件夹',
    );
  }

  final String location, name;
  final List<UploadFolderFile> files;
  late final List<String> directories;
  final Map<String, String> remoteDirectories;
  final Map<String, String> remoteDirectoryFiles;
  final int skippedLinks;
  String currentItem = '';
  late final int size;
  int completedBytes = 0, completedFiles = 0;

  void completeFile(UploadFolderFile file, String id) {
    require(!file.completed && id.isNotEmpty, '上传完成信息无效');
    file._fileId = id;
    completedFiles++;
    completedBytes += file.size;
  }

  Json toJson() => {
    'location': location,
    'name': name,
    'files': files.map((f) => f.toJson()).toList(),
    'directories': directories,
    'remoteDirectories': Map.of(remoteDirectories),
    if (remoteDirectoryFiles.isNotEmpty)
      'remoteDirectoryFiles': Map.of(remoteDirectoryFiles),
    if (skippedLinks > 0) 'skippedLinks': skippedLinks,
  };

  factory UploadFolder.fromJson(Json value) {
    final files = value.list('files');
    require(
      value['files'] is List &&
          (value['files'] as List).length == files.length &&
          value['directories'] is List &&
          (value['directories'] as List).every((d) => d is String),
      '已保存的上传文件夹信息不完整，请重新选择',
    );
    return UploadFolder(
      location: value.str('location'),
      name: value.str('name'),
      files: files.map(UploadFolderFile.fromJson).toList(),
      directories: (value['directories'] as List).cast<String>(),
      remoteDirectories: strings(value['remoteDirectories']),
      remoteDirectoryFiles: strings(value['remoteDirectoryFiles']),
      skippedLinks: value.integer('skippedLinks'),
    );
  }
}
