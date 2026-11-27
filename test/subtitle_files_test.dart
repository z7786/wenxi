import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/playback/subtitle_files.dart';
import 'player_support.dart';

const _caption = '1\r\n00:00:01,000 --> 00:00:08,000\r\n中文字幕\r\n';

List<int> _utf16(String text, {required bool little, bool bom = true}) => [
  if (bom)
    if (little) ...[0xff, 0xfe] else ...[0xfe, 0xff],
  for (final unit in text.codeUnits)
    if (little) ...[unit & 255, unit >> 8] else ...[unit >> 8, unit & 255],
];

void main() {
  late Directory root, directory;
  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'asterlink-player-subtitle-encoding-',
    );
    directory = Directory('${root.path}/private');
  });
  tearDown(() => removePlayerFixture(root));

  for (final entry in <String, List<int>>{
    'UTF-8': utf8.encode(_caption),
    'UTF-8 BOM': [0xef, 0xbb, 0xbf, ...utf8.encode(_caption)],
    'GBK': [
      ...ascii.encode('1\r\n00:00:01,000 --> 00:00:08,000\r\n'),
      0xd6,
      0xd0,
      0xce,
      0xc4,
      0xd7,
      0xd6,
      0xc4,
      0xbb,
      13,
      10,
    ],
    'UTF-16 LE': _utf16(_caption, little: true),
    'UTF-16 BE': _utf16(_caption, little: false),
    'UTF-16 LE without BOM': _utf16(_caption, little: true, bom: false),
    'UTF-16 BE without BOM': _utf16(_caption, little: false, bom: false),
  }.entries) {
    test(
      '${entry.key} staging keeps Chinese text and cue timing in UTF-8',
      () async {
        final file = await SubtitleFiles(directory).stage(
          '原字幕.srt',
          // Split code units across chunks, as a file picker or HTTP stream can.
          Stream.fromIterable([
            for (var i = 0; i < entry.value.length; i += 3)
              entry.value.sublist(i, (i + 3).clamp(0, entry.value.length)),
          ]),
        );
        expect(await file.readAsString(), _caption);
        expect(await file.readAsBytes(), utf8.encode(_caption));
      },
    );
  }

  test('UTF-16 preserves supplementary characters and ASS styles', () async {
    const text =
        '[Script Info]\rScriptType: v4.00+\r[Events]\r'
        r'Dialogue: 0,0:00:01.00,0:00:08.00,Default,,0,0,0,,{\an8}字幕 😀\N第二行'
        '\r';
    final file = await SubtitleFiles(
      directory,
    ).stage('styled.ass', Stream.value(_utf16(text, little: true)));
    expect(await file.readAsString(), text);
  });

  for (final entry in <String, List<int>>{
    'HTML error page': utf8.encode('<!doctype html><html>expired</html>'),
    'JSON error': utf8.encode('{"error":"expired"}'),
    'not a subtitle': utf8.encode('ordinary text'),
    'incomplete UTF-8 BOM file': [
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode(_caption),
      0xc4,
    ],
    'incomplete UTF-16': [0xff, 0xfe, 0x31],
    'invalid UTF-16 surrogate': _utf16('$_caption\ud800', little: true),
    'invalid GBK': [
      ...ascii.encode('1\n00:00:01,000 --> 00:00:08,000\n'),
      0x81,
    ],
  }.entries) {
    test('${entry.key} is rejected before creating a private file', () async {
      await expectLater(
        SubtitleFiles(
          directory,
        ).stage('caption.srt', Stream.value(entry.value)),
        throwsA(isA<AppException>()),
      );
      expect(await directory.exists(), isFalse);
    });
  }

  test('The 8 MB limit also applies after expanding GBK to UTF-8', () async {
    final header = ascii.encode('1\n00:00:01,000 --> 00:00:08,000\n');
    final characters = SubtitleFiles.maximumBytes ~/ 3 + 1;
    final bytes = Uint8List(header.length + characters * 2)
      ..setRange(0, header.length, header);
    for (var i = header.length; i < bytes.length; i += 2) {
      bytes[i] = 0xd6;
      bytes[i + 1] = 0xd0;
    }
    await expectLater(
      SubtitleFiles(directory).stage('large.srt', Stream.value(bytes)),
      throwsA(
        isA<AppException>().having(
          (e) => e.message,
          'message',
          contains('8 MB'),
        ),
      ),
    );
    expect(await directory.exists(), isFalse);
  });

  test(
    'Cancellation during a streamed subtitle read writes no late file',
    () async {
      final scope = RequestScope(), chunks = StreamController<List<int>>();
      addTearDown(chunks.close);
      final pending = scope.run(
        () => SubtitleFiles(directory).stage('caption.srt', chunks.stream),
      );
      final expectation = expectLater(pending, throwsA(isA<AppException>()));
      chunks.add(utf8.encode(_caption));
      scope.cancel();
      await chunks.close();
      await expectation;
      expect(await directory.exists(), isFalse);
    },
  );
}
