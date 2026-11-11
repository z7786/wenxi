import '../core/json.dart';

enum UploadPhase { preparing, uploading, finishing }

class UploadProgress {
  const UploadProgress(this.phase, this.sent, this.total);
  final UploadPhase phase;
  final int sent, total;
  double? get fraction => total > 0 ? (sent / total).clamp(0, 1) : null;
}

typedef UploadProgressCallback = void Function(UploadProgress progress);

/// A reopenable range source. Large files remain streamed from the picker.
class UploadFile {
  UploadFile({
    required this.name,
    required this.size,
    required this.read,
    this.mimeType = 'application/octet-stream',
    DateTime? modifiedAt,
    this.validate,
    this.verifiedHashes = const {},
  }) : modifiedAt = modifiedAt ?? DateTime.now() {
    require(size >= 0, '无法读取本地文件大小');
    require(
      name.trim().isNotEmpty &&
          name != '.' &&
          name != '..' &&
          !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name),
      '文件名称无效',
    );
  }
  final String name, mimeType;
  final int size;
  final DateTime modifiedAt;
  final Stream<List<int>> Function(int start, int end) read;
  final Future<void> Function()? validate;

  /// Whole-file hashes computed from the verified relay payload.
  final Map<String, String> verifiedHashes;

  Stream<List<int>> openRead([int start = 0, int? end]) async* {
    final stop = end ?? size;
    require(start >= 0 && stop >= start && stop <= size, '文件读取范围无效');
    await validate?.call();
    var count = 0;
    await for (final chunk in read(start, stop)) {
      count += chunk.length;
      require(count <= stop - start, '本地文件内容已变化，请重新选择');
      yield chunk;
    }
    require(count == stop - start, '本地文件读取不完整，请重新选择');
    await validate?.call();
  }

  UploadFile guarded(void Function() checkpoint) => UploadFile(
    name: name,
    size: size,
    mimeType: mimeType,
    modifiedAt: modifiedAt,
    verifiedHashes: verifiedHashes,
    validate: () async {
      checkpoint();
      await validate?.call();
      checkpoint();
    },
    read: (start, end) async* {
      checkpoint();
      await for (final chunk in openRead(start, end)) {
        checkpoint();
        yield chunk;
      }
      checkpoint();
    },
  );
}
