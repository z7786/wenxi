import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'windows_actions.dart';

Future<void> revealDesktopFile(String path, WindowsActions windows) async {
  if (!Platform.isMacOS) return windows.revealFile(path);
  require(
    p.isAbsolute(path) &&
        await FileSystemEntity.type(path) != FileSystemEntityType.notFound,
    '文件不存在或已被移动',
  );
  final result = await Process.run('/usr/bin/open', ['-R', path]);
  require(result.exitCode == 0, '无法在访达中显示文件');
}
