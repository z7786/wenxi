import '../core/json.dart';

String? contentMd5(String? value) {
  final hash = value?.trim().toLowerCase() ?? '';
  return RegExp(r'^[0-9a-f]{32}$').hasMatch(hash) ? hash : null;
}

void validateTransferName(String name) {
  require(
    name.trim().isNotEmpty &&
        name != '.' &&
        name != '..' &&
        !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name),
    '文件名称无效',
  );
}

class RapidTransferFile {
  RapidTransferFile({
    required this.name,
    required this.size,
    required String md5,
  }) : md5 = contentMd5(md5) ?? (throw const AppException('文件 MD5 无效')) {
    require(size >= 0, '文件大小无效');
    validateTransferName(name);
  }
  final String name, md5;
  final int size;
}

class RapidTransferResult {
  const RapidTransferResult.missed() : fileId = null;
  const RapidTransferResult.reused(String id) : fileId = id;
  final String? fileId;
  bool get reused => fileId?.isNotEmpty == true;
}

class RapidTransferUnavailable extends AppException {
  const RapidTransferUnavailable(super.message);
}
