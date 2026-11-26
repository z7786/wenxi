import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';

typedef WindowsCommand =
    Future<void> Function(String executable, List<String> arguments);

final _windowsRootPattern = RegExp(
  r'^[A-Za-z]:\\[^\\\x00-\x1f<>:"|?*/][^\x00-\x1f<>:"|?*/]*$',
);
final _trailingBackslashes = RegExp(r'\\+$');

String windowsSystemRoot([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final raw = (env['SystemRoot'] ?? env['SYSTEMROOT'] ?? '').trim();
  if (_windowsRootPattern.hasMatch(raw)) {
    final normalized = raw.replaceFirst(_trailingBackslashes, '');
    final segments = normalized.split('\\').skip(1);
    if (segments.isNotEmpty &&
        segments.every(
          (s) =>
              s.isNotEmpty &&
              s != '.' &&
              s != '..' &&
              !s.endsWith('.') &&
              !s.endsWith(' '),
        )) {
      return normalized;
    }
  }
  return r'C:\Windows';
}

String windowsSystemExecutable(
  String relativePath, [
  Map<String, String>? environment,
]) => p.windows.join(windowsSystemRoot(environment), relativePath);

class WindowsActions {
  WindowsActions({
    required this.supported,
    WindowsCommand? start,
    WindowsCommand? run,
  }) : _start = start ?? _startDetached,
       _run = run ?? _runChecked;

  final bool supported;
  final WindowsCommand _start, _run;

  Future<void> revealFile(String path) async {
    require(supported, '当前平台不支持打开资源管理器');
    require(p.isAbsolute(path), '无法定位文件，请重新检查下载文件');
    final location = p.normalize(path);
    final type = await FileSystemEntity.type(location);
    require(type != FileSystemEntityType.notFound, '文件不存在或已被移动');
    await _start(windowsSystemExecutable('explorer.exe'), [
      if (type != FileSystemEntityType.directory) '/select,',
      location,
    ]);
  }

  Future<void> shutdown() async {
    require(supported, '当前平台不支持下载完成后关机');
    // Windows implies /f when /t is positive. The cancellable countdown lives
    // in the app, so this request never forces other applications to close.
    await _run(
      windowsSystemExecutable(r'System32\shutdown.exe'),
      const ['/s', '/t', '0'],
    );
  }

  Future<void> hibernate() async {
    require(supported, '当前平台不支持下载完成后休眠');
    // /h requests hibernation without forcing applications to close. Keep the
    // cancellable countdown in the app, just as for shutdown.
    await _run(
      windowsSystemExecutable(r'System32\shutdown.exe'),
      const ['/h'],
    );
  }

  static Future<void> _startDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  static Future<void> _runChecked(
    String executable,
    List<String> arguments,
  ) async {
    final result = await Process.run(executable, arguments);
    require(
      result.exitCode == 0,
      arguments.contains('/h')
          ? '系统未接受休眠请求，请检查是否已启用休眠及当前权限后重试'
          : '系统未接受关机请求，请检查权限后重试',
    );
  }
}
