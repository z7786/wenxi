import '../core/json.dart';

/// File identity is its eMule hash and size. Keep source/hash extensions for
/// the native protocol; HTTP normalization must never touch an ED2K link.
class Ed2kLink {
  const Ed2kLink._(this.url, this.name, this.size, this.hash);
  final String url, name, hash;
  final int size;
  static const maxSize = 256 * 1024 * 1024 * 1024;

  static Ed2kLink parse(String text) {
    final input = text.trim();
    require(input.length <= 64 * 1024, 'ED2K 链接过长');
    require(input.toLowerCase().startsWith('ed2k://'), '请输入 ED2K 文件链接');
    var body = input.substring(7);
    if (body.toLowerCase().startsWith('%7c')) {
      body = body.replaceAll(RegExp('%7c', caseSensitive: false), '|');
    }
    final fields = body.split('|');
    require(
      fields.length >= 6 &&
          fields.first.isEmpty &&
          fields[1].toLowerCase() == 'file' &&
          fields.last == '/' &&
          fields.skip(5).contains('/'),
      'ED2K 文件链接格式错误',
    );
    String name;
    try {
      name = Uri.decodeComponent(fields[2]);
    } catch (_) {
      throw const AppException('ED2K 文件名编码无效');
    }
    require(
      name.isNotEmpty && !RegExp(r'[\x00-\x1f\x7f]').hasMatch(name),
      'ED2K 文件名无效',
    );
    final size = int.tryParse(fields[3]);
    require(
      RegExp(r'^\d+$').hasMatch(fields[3]) &&
          size != null &&
          size > 0 &&
          size <= maxSize,
      'ED2K 文件大小无效（最大 256 GiB）',
    );
    final hash = fields[4].toLowerCase();
    require(RegExp(r'^[a-f0-9]{32}$').hasMatch(hash), 'ED2K 文件校验值无效');
    require(
      fields
          .skip(5)
          .every((field) => !RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(field)),
      'ED2K 扩展字段无效',
    );
    final normalized = [
      '',
      'file',
      Uri.encodeComponent(name),
      '$size',
      hash,
      ...fields.skip(5),
    ].join('|');
    return Ed2kLink._('ed2k://$normalized', name, size!, hash);
  }
}
