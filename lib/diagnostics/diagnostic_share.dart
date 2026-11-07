import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Only temporary copies made by this feature are pruned; exported user files
/// and the original diagnostic records are never touched.
Future<File> prepareDiagnosticShare(
  Directory temporary,
  Uint8List bytes,
  String name, {
  DateTime? now,
}) async {
  final ownedName = RegExp(r'^文析助手-logs-[0-9.-]+\.zip$');
  if (!ownedName.hasMatch(name) || p.basename(name) != name) {
    throw ArgumentError('Invalid diagnostic export name');
  }
  final directory = Directory(p.join(temporary.path, 'diagnostic-shares'));
  await directory.create(recursive: true);
  final files = <(File, DateTime)>[];
  await for (final entry in directory.list(followLinks: false)) {
    if (entry is File && ownedName.hasMatch(p.basename(entry.path))) {
      files.add((entry, await entry.lastModified()));
    }
  }
  files.sort((a, b) => b.$2.compareTo(a.$2));
  final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 1));
  for (var index = 0; index < files.length; index++) {
    if (index >= 2 || files[index].$2.isBefore(cutoff)) {
      try {
        await files[index].$1.delete();
      } on FileSystemException {
        // Cache cleanup must not prevent sharing the current report.
      }
    }
  }
  final file = File(p.join(directory.path, name));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<ShareResultStatus> shareDiagnosticZip(
  Uint8List bytes,
  String name, {
  Rect? origin,
}) async {
  final file = await prepareDiagnosticShare(
    await getTemporaryDirectory(),
    bytes,
    name,
  );
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: 'application/zip')],
      title: '分享文析助手日志',
      subject: '文析助手故障日志',
      sharePositionOrigin: origin,
    ),
  );
  return result.status;
}

Future<void> openDiagnosticExportLocation(String path) async {
  if ((!Platform.isWindows && !Platform.isMacOS) ||
      !await File(path).exists()) {
    throw const FileSystemException('导出的日志文件已不存在');
  }
  if (Platform.isMacOS) {
    await Process.start('/usr/bin/open', [
      '-R',
      path,
    ], mode: ProcessStartMode.detached);
  } else {
    await Process.start('explorer.exe', [
      p.dirname(path),
    ], mode: ProcessStartMode.detached);
  }
}
