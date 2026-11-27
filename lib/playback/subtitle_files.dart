import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:enough_convert/gbk.dart';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../data/http.dart';
import '../domain/models.dart';

Endian? _utf16Order(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xff && bytes[1] == 0xfe) return Endian.little;
    if (bytes[0] == 0xfe && bytes[1] == 0xff) return Endian.big;
  }
  // BOM-less UTF-16 timestamps/headers contain repeated ASCII/NUL pairs.
  // Check both byte positions so ordinary UTF-8 and GBK stay untouched.
  final length = bytes.length.clamp(0, 128);
  var evenZeroes = 0, oddZeroes = 0;
  for (var i = 0; i + 1 < length; i += 2) {
    if (bytes[i] == 0 && bytes[i + 1] > 0 && bytes[i + 1] < 128) {
      evenZeroes++;
    }
    if (bytes[i + 1] == 0 && bytes[i] > 0 && bytes[i] < 128) {
      oddZeroes++;
    }
  }
  if (oddZeroes >= 8 && oddZeroes >= length / 4 && evenZeroes == 0) {
    return Endian.little;
  }
  if (evenZeroes >= 8 && evenZeroes >= length / 4 && oddZeroes == 0) {
    return Endian.big;
  }
  return null;
}

Uint8List _utf8Subtitle(Uint8List bytes) {
  require(bytes.isNotEmpty, '字幕文件为空');
  String text;
  final order = _utf16Order(bytes);
  if (order != null) {
    require(bytes.length.isEven, '字幕编码不完整，请重新下载或选择其他字幕');
    final offset =
        bytes[0] == 0xff && bytes[1] == 0xfe ||
            bytes[0] == 0xfe && bytes[1] == 0xff
        ? 2
        : 0;
    final data = ByteData.sublistView(bytes);
    final units = Uint16List((bytes.length - offset) ~/ 2);
    var highSurrogate = false;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i] = data.getUint16(offset + i * 2, order);
      final low = unit >= 0xdc00 && unit <= 0xdfff;
      require(highSurrogate == low, '字幕编码不完整，请重新下载或选择其他字幕');
      highSurrogate = unit >= 0xd800 && unit <= 0xdbff;
    }
    require(!highSurrogate, '字幕编码不完整，请重新下载或选择其他字幕');
    text = String.fromCharCodes(units);
  } else {
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      // A declared UTF-8 file must not silently become GBK when truncated.
      require(
        bytes.length < 3 ||
            bytes[0] != 0xef ||
            bytes[1] != 0xbb ||
            bytes[2] != 0xbf,
        '字幕编码不完整，请重新下载或选择其他字幕',
      );
      try {
        text = gbk.decode(bytes);
      } on FormatException {
        throw const AppException('无法识别字幕编码，请选择其他字幕');
      }
    }
  }
  text = text.replaceFirst(RegExp(r'^\uFEFF'), '');
  require(
    !RegExp(r'[\x00-\x08\x0b\x0e-\x1f\x7f]').hasMatch(text) &&
        !RegExp(
          r'^\s*<(?:!doctype|html|head|body)\b',
          caseSensitive: false,
        ).hasMatch(text) &&
        (RegExp(r'\d{1,2}:\d{2}(?:[.,]\d{1,3})?\s*-->').hasMatch(text) ||
            RegExp(
              r'(?:^|[\r\n])\s*Dialogue\s*:',
              caseSensitive: false,
            ).hasMatch(text)),
    '文件内容不是有效字幕，请重新下载或选择其他字幕',
  );
  final normalized = utf8.encode(text);
  require(normalized.length <= SubtitleFiles.maximumBytes, '字幕文件不能超过 8 MB');
  return normalized;
}

class SubtitleFiles {
  SubtitleFiles(this.directory);
  final Directory directory;
  static const maximumBytes = 8 * 1024 * 1024;
  static const extensions = ['srt', 'vtt', 'ass', 'ssa'];
  Future<File> stage(String name, Stream<List<int>> stream) async {
    RequestScope.checkpoint();
    final extension = p.extension(name).toLowerCase().replaceFirst('.', '');
    require(extensions.contains(extension), '请选择 SRT、VTT、ASS 或 SSA 字幕');
    final data = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      RequestScope.checkpoint();
      require(data.length + chunk.length <= maximumBytes, '字幕文件不能超过 8 MB');
      data.add(chunk);
    }
    RequestScope.checkpoint();
    final bytes = data.takeBytes();
    // All subtitle sources use the same conversion, off the video/UI isolate.
    final normalized = await Isolate.run(() => _utf8Subtitle(bytes));
    RequestScope.checkpoint();
    await directory.create(recursive: true);
    RequestScope.checkpoint();
    final file = File(p.join(directory.path, '${newId()}.$extension'));
    try {
      await file.writeAsBytes(normalized, flush: true);
      RequestScope.checkpoint();
      return file;
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }
}
