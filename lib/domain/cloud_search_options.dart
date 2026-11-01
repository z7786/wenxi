import 'file_types.dart';
import 'models.dart';

enum CloudSearchCategory {
  all('全部'),
  video('视频'),
  document('文档'),
  image('图片'),
  audio('音频'),
  archive('压缩包'),
  folder('文件夹'),
  other('其他');

  const CloudSearchCategory(this.label);
  final String label;

  bool matches(CloudFile file) {
    if (this == all) return true;
    if (file.isDirectory) return this == folder;
    final kind = fileKind(file.name);
    final documentFile =
        kind == FileKind.text ||
        kind == FileKind.pdf ||
        isOfficeDocument(file.name) ||
        file.name.split('.').last.toLowerCase() == 'epub';
    return switch (this) {
      all => true,
      folder => false,
      video => kind == FileKind.video,
      image => kind == FileKind.image,
      audio => kind == FileKind.audio,
      archive => kind == FileKind.archive,
      document => documentFile,
      other =>
        !documentFile &&
            !{
              FileKind.video,
              FileKind.image,
              FileKind.audio,
              FileKind.archive,
            }.contains(kind),
    };
  }
}
