import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import 'windows_actions.dart';

class WindowsExternalPlayer {
  WindowsExternalPlayer({WindowsCommand? start}) : _start = start ?? _launch;
  final WindowsCommand _start;
  String? executable;

  Future<bool> open(String url) async {
    final path = executable;
    require(path != null && p.isAbsolute(path), '请先选择外部播放器');
    require(p.extension(path!).toLowerCase() == '.exe', '请选择播放器的 exe 程序');
    require(await File(path).exists(), '播放器程序不存在，请重新选择');
    final uri = Uri.tryParse(url);
    final media = uri?.scheme == 'file' ? uri!.toFilePath(windows: true) : url;
    require(media.isNotEmpty, '播放地址为空');
    try {
      await _start(path, [media]);
    } on ProcessException {
      throw const AppException('无法启动所选播放器，请检查程序后重试');
    }
    return true;
  }

  static Future<void> _launch(String executable, List<String> arguments) async {
    await Process.start(
      executable,
      arguments,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }
}
