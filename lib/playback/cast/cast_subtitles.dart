import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import '../../core/json.dart';
import '../playback_state.dart';
import '../subtitle_files.dart';

/// A bounded snapshot, independent of the local decoder's temporary files.
/// Renderers get plain UTF-8 SRT instead of a private file URI or account URL.
class CastSubtitle {
  CastSubtitle._(Uint8List bytes, this.cues)
    : bytes = bytes.asUnmodifiableView();
  final Uint8List bytes;
  final int cues;

  static Future<CastSubtitle> load(
    SubtitleTrack track, {
    double delay = 0,
  }) async {
    final Uint8List bytes;
    if (track.data) {
      require(track.id.length <= SubtitleFiles.maximumBytes, '字幕文件过大');
      bytes = Uint8List.fromList(utf8.encode(track.id));
    } else {
      final uri = Uri.tryParse(track.id);
      require(track.uri && uri?.scheme == 'file', '此外挂字幕暂不能发送到电视，请选择本地字幕文件');
      final file = File.fromUri(uri!);
      require(await file.length() <= SubtitleFiles.maximumBytes, '字幕文件过大');
      final content = BytesBuilder(copy: false);
      await for (final chunk in file.openRead().timeout(
        const Duration(seconds: 5),
      )) {
        require(
          content.length + chunk.length <= SubtitleFiles.maximumBytes,
          '字幕文件过大',
        );
        content.add(chunk);
      }
      bytes = content.takeBytes();
    }
    require(
      bytes.isNotEmpty && bytes.length <= SubtitleFiles.maximumBytes,
      '字幕文件为空或过大',
    );
    // Conversion must not make scrolling or the local playback surface stall.
    return Isolate.run(() => CastSubtitle.fromBytes(bytes, delay: delay));
  }

  factory CastSubtitle.fromBytes(List<int> bytes, {double delay = 0}) {
    require(
      bytes.isNotEmpty && bytes.length <= SubtitleFiles.maximumBytes,
      '字幕文件为空或过大',
    );
    return CastSubtitle.fromText(_decode(bytes), delay: delay);
  }

  factory CastSubtitle.fromText(String text, {double delay = 0}) {
    require(text.length <= SubtitleFiles.maximumBytes, '字幕文件过大');
    final normalized = text
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final offset = delay.isFinite ? (delay.clamp(-10, 10) * 1000).round() : 0;
    final cues =
        RegExp(
          r'^\s*\[Events\]\s*$',
          multiLine: true,
          caseSensitive: false,
        ).hasMatch(normalized)
        ? _ass(normalized)
        : _timed(normalized);
    final output = StringBuffer('\uFEFF');
    var count = 0;
    for (final cue in cues) {
      final start = (cue.start + offset).clamp(0, 35999999999);
      final end = (cue.end + offset).clamp(0, 35999999999);
      if (end <= start || cue.text.trim().isEmpty) continue;
      require(++count <= 100000, '字幕条目过多');
      output.write(
        '$count\n${_time(start)} --> ${_time(end)}\n${cue.text}\n\n',
      );
      require(output.length <= SubtitleFiles.maximumBytes, '字幕文件过大');
    }
    require(count > 0, '此字幕格式无法转换为电视字幕，请选择 SRT、VTT 或 ASS 字幕');
    final bytes = Uint8List.fromList(utf8.encode(output.toString()));
    require(bytes.length <= SubtitleFiles.maximumBytes, '字幕文件过大');
    return CastSubtitle._(bytes, count);
  }

  static String _decode(List<int> bytes) {
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      require(bytes.length.isEven, '字幕编码无法识别');
      final little = bytes[0] == 0xff;
      return String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const AppException('字幕编码无法识别，请使用 UTF-8 或 UTF-16 字幕');
    }
  }

  static int? _milliseconds(String value) {
    final match = RegExp(
      r'^(?:(\d{1,4}):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final hours = int.parse(match[1] ?? '0');
    final minutes = int.parse(match[2]!);
    final seconds = int.parse(match[3]!);
    if (minutes > 59 || seconds > 59) return null;
    final fraction = int.parse((match[4] ?? '').padRight(3, '0'));
    return ((hours * 60 + minutes) * 60 + seconds) * 1000 + fraction;
  }

  static String _time(int value) =>
      '${(value ~/ 3600000).toString().padLeft(2, '0')}:'
      '${(value ~/ 60000 % 60).toString().padLeft(2, '0')}:'
      '${(value ~/ 1000 % 60).toString().padLeft(2, '0')},'
      '${(value % 1000).toString().padLeft(3, '0')}';

  static Iterable<_Cue> _timed(String text) sync* {
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      // WebVTT notes/style blocks are not subtitle text, even if they contain
      // a timing example. Cue identifiers and settings do not enter the SRT.
      if (line == 'STYLE' || line == 'REGION' || line.startsWith('NOTE')) {
        while (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty) {
          i++;
        }
        continue;
      }
      final match = RegExp(r'^(\S+)\s+-->\s+(\S+)').firstMatch(line);
      if (match == null) continue;
      final start = _milliseconds(match[1]!);
      final end = _milliseconds(match[2]!);
      final content = <String>[];
      while (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty) {
        content.add(lines[++i]);
      }
      if (start == null || end == null || end <= start) continue;
      final caption = content
          .join('\n')
          .replaceAll(RegExp(r'<(?:v|c)(?:[ .][^>]*)?>|</(?:v|c)>'), '')
          .replaceAll(RegExp(r'<\d{2}:\d{2}(?::\d{2})?\.\d{3}>'), '');
      yield _Cue(start, end, caption);
    }
  }

  static Iterable<_Cue> _ass(String text) sync* {
    var events = false;
    var format = <String>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        events = line.toLowerCase() == '[events]';
        continue;
      }
      if (!events) continue;
      if (line.toLowerCase().startsWith('format:')) {
        format = line
            .substring(7)
            .split(',')
            .map((s) => s.trim().toLowerCase())
            .toList();
        continue;
      }
      if (!line.toLowerCase().startsWith('dialogue:') || format.isEmpty) {
        continue;
      }
      final startIndex = format.indexOf('start');
      final endIndex = format.indexOf('end');
      final textIndex = format.indexOf('text');
      if (startIndex < 0 || endIndex < 0 || textIndex != format.length - 1) {
        continue;
      }
      final value = line.substring(9).trimLeft();
      final fields = <String>[];
      var at = 0;
      for (var n = 0; n < format.length - 1; n++) {
        final comma = value.indexOf(',', at);
        if (comma < 0) break;
        fields.add(value.substring(at, comma));
        at = comma + 1;
      }
      if (fields.length != format.length - 1) continue;
      fields.add(value.substring(at));
      final start = _milliseconds(fields[startIndex]);
      final end = _milliseconds(fields[endIndex]);
      if (start == null || end == null || end <= start) continue;
      yield _Cue(start, end, _assText(fields[textIndex]));
    }
  }

  static String _assText(String value) {
    var drawing = false, at = 0;
    final output = StringBuffer();
    for (final tag in RegExp(r'\{[^}]*\}').allMatches(value)) {
      if (!drawing) output.write(value.substring(at, tag.start));
      for (final p in RegExp(r'\\p(\d+)').allMatches(tag[0]!)) {
        drawing = int.tryParse(p[1]!) != 0;
      }
      at = tag.end;
    }
    if (!drawing) output.write(value.substring(at));
    return output
        .toString()
        .replaceAll(r'\N', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\h', ' ')
        .trim();
  }
}

class _Cue {
  const _Cue(this.start, this.end, this.text);
  final int start, end;
  final String text;
}
