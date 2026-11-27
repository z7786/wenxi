import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/playback/cast/cast_subtitles.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/playback/subtitle_files.dart';

void main() {
  test(
    'SRT keeps Unicode and multiline captions and applies the subtitle delay',
    () {
      final subtitle = CastSubtitle.fromText(
        '\uFEFF1\r\n00:00:00,050 --> 00:00:01,250\r\n中文 & 字幕\r\n第二行\r\n\r\n'
        '2\r\n00:00:03,500 --> 00:00:04,000\r\n字幕二\r\n',
        delay: -.1,
      );
      expect(subtitle.cues, 2);
      final text = utf8.decode(subtitle.bytes);
      expect(subtitle.bytes.take(3), [0xef, 0xbb, 0xbf]);
      expect(text, startsWith('1\n00:00:00,000 --> 00:00:01,150\n'));
      expect(text, contains('中文 & 字幕\n第二行\n\n'));
      expect(text, contains('00:00:03,400 --> 00:00:03,900'));
      expect(text, isNot(contains('\r')));
    },
  );

  test('WebVTT removes cue settings, note/style blocks and voice wrappers', () {
    final subtitle = CastSubtitle.fromText(
      'WEBVTT\n\nNOTE timing example\n00:01.000 --> 00:02.000\nignore\n\n'
      'STYLE\n::cue { color: red; }\n\n'
      'cue-1\n00:02.200 --> 00:04.400 line:90% position:50%\n'
      '<v Speaker><c.green>您好</c></v>\n\n'
      'cue-2\n01:02:03.125 --> 01:02:05.100\n<b>结束</b>\n',
    );
    final text = utf8.decode(subtitle.bytes);
    expect(subtitle.cues, 2);
    expect(text, contains('00:00:02,200 --> 00:00:04,400\n您好'));
    expect(text, contains('01:02:03,125 --> 01:02:05,100\n<b>结束</b>'));
    for (final value in ['cue-1', 'ignore', 'color:', 'line:90%', '<v', '<c']) {
      expect(text, isNot(contains(value)));
    }
  });

  test(
    'ASS parses declared event columns and keeps commas and hard line breaks',
    () {
      final subtitle = CastSubtitle.fromText(r'''
[Script Info]
Title: sample
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,do not display
Dialogue: 0,0:00:01.25,0:00:03.50,Default,,0,0,0,,{\an8}{\b1}你好,世界\N第二行\h文字
Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,{\p1}m 0 0 l 10 10{\p0}正常文字
''');
      final text = utf8.decode(subtitle.bytes);
      expect(subtitle.cues, 2);
      expect(text, contains('00:00:01,250 --> 00:00:03,500\n你好,世界\n第二行 文字'));
      expect(text, contains('正常文字'));
      for (final value in ['{', 'do not display', 'm 0 0']) {
        expect(text, isNot(contains(value)));
      }
    },
  );

  test('SSA marked column and CR-only line endings convert to SRT', () {
    final subtitle = CastSubtitle.fromText(
      '[Events]\rFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r'
      'Dialogue: Marked=0,0:00:02.00,0:00:03.00,Default,,0,0,0,,旧格式\r',
    );
    expect(subtitle.cues, 1);
    expect(
      utf8.decode(subtitle.bytes),
      contains('00:00:02,000 --> 00:00:03,000\n旧格式'),
    );
  });

  test('UTF-16 in either byte order keeps Chinese and non-BMP characters', () {
    const text = '1\n00:00:01,000 --> 00:00:03,000\n中文 😀\n';
    for (final little in [true, false]) {
      final bytes = <int>[
        if (little) ...[0xff, 0xfe] else ...[0xfe, 0xff],
        for (final unit in text.codeUnits)
          if (little) ...[
            unit & 0xff,
            unit >> 8,
          ] else ...[
            unit >> 8,
            unit & 0xff,
          ],
      ];
      final result = CastSubtitle.fromBytes(bytes);
      expect(utf8.decode(result.bytes), contains('中文 😀'));
    }
  });

  test(
    'malformed, oversized, binary and timestamp-invalid captions fail explicitly',
    () {
      for (final bytes in [
        <int>[],
        [0xff, 0xfe, 0x20],
        [0xff, 0xab, 0x20],
      ]) {
        expect(
          () => CastSubtitle.fromBytes(bytes),
          throwsA(isA<AppException>()),
        );
      }
      for (final text in [
        'no timed cues',
        '1\n00:99:00,000 --> 00:00:04,000\nwrong\n',
        '1\n00:00:09,000 --> 00:00:04,000\nreverse\n',
        '1\n00:00:01,000 --> 00:00:04,000\n\n',
        'x' * (SubtitleFiles.maximumBytes + 1),
      ]) {
        expect(() => CastSubtitle.fromText(text), throwsA(isA<AppException>()));
      }
    },
  );

  test(
    'staged file is a snapshot and remote account URLs cannot be advertised',
    () async {
      final root = await Directory.systemTemp.createTemp('cast-subtitle-test-');
      addTearDown(() => root.delete(recursive: true));
      final file = await File(
        '${root.path}/test.srt',
      ).writeAsString('1\n00:00:01,000 --> 00:00:04,000\n本地字幕\n');
      final subtitle = await CastSubtitle.load(
        SubtitleTrack.uri(file.uri.toString()),
      );
      await file.delete();
      expect(utf8.decode(subtitle.bytes), contains('本地字幕'));
      expect(() => subtitle.bytes[0] = 0, throwsUnsupportedError);
      await expectLater(
        CastSubtitle.load(
          SubtitleTrack.uri('https://example.invalid/private?signed=secret'),
        ),
        throwsA(isA<AppException>()),
      );
      final inline = await CastSubtitle.load(
        SubtitleTrack.data('1\n00:00:01,000 --> 00:00:04,000\n内联字幕\n'),
      );
      expect(utf8.decode(inline.bytes), contains('内联字幕'));
    },
  );
}
