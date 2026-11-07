import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';

bool get isDesktopPlatform => Platform.isWindows || Platform.isMacOS;

String desktopDownloadExecutable(String executable, String platform) {
  require({'windows', 'macos'}.contains(platform), '当前系统不支持桌面下载组件');
  final paths = platform == 'windows' ? p.windows : p.posix;
  return paths.join(
    paths.dirname(executable),
    platform == 'windows' ? 'asterlink_gopeed.exe' : 'asterlink_gopeed',
  );
}
