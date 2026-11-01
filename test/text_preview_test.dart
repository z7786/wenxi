import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:enough_convert/gbk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/domain/file_types.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/preview/text_document.dart';
import 'package:asterlink/preview/text_preview_loader.dart';

TextDocument document(String text, [String name = 'demo.txt']) =>
    decodeTextDocument((Uint8List.fromList(utf8.encode(text)), name, false));

class _Transfer extends TransferHttp {
  _Transfer(
    this.content, {
    this.ignoreRange = false,
    this.hold = false,
    this.wrongRange = false,
  });
  final Uint8List content;
  final bool ignoreRange, hold, wrongRange;
  final ready = Completer<void>();
  CancelToken? token;
  int delivered = 0;
  @override
  Future<Response<ResponseBody>> stream(
    String url,
    Map<String, String> h, {
    CancelToken? cancel,
  }) async {
    token = cancel;
    ready.complete();
    expect(h['Range'], 'bytes=0-${TextDocument.maxBytes}');
    expect(h['Accept-Encoding'], 'identity');
    if (hold) {
      await cancel!.whenCancel;
      throw cancel.cancelError!;
    }
    final length = ignoreRange
        ? content.length
        : content.length.clamp(0, TextDocument.maxBytes + 1);
    final headers = {
      'content-length': ['$length'],
      if (!ignoreRange)
        'content-range': [
          'bytes ${wrongRange ? 1 : 0}-${length - 1}/${content.length}',
        ],
    };
    Stream<Uint8List> chunks() async* {
      for (var first = 0; first < length; first += 65536) {
        final last = (first + 65536).clamp(0, length);
        delivered += last - first;
        yield Uint8List.sublistView(content, first, last);
      }
    }

    return Response(
      requestOptions: RequestOptions(path: url),
      statusCode: ignoreRange ? 200 : 206,
      headers: Headers.fromMap(headers),
      data: ResponseBody(chunks(), ignoreRange ? 200 : 206, headers: headers),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'text and code file names include double extensions without changing video or archive recognition',
    () {
      for (final name in [
        '密码.TXT.ZIP',
        'a.js',
        'a.mjs',
        'a.py',
        'a.py.zip',
        'a.ps1',
        'a.sh',
        'a.dart',
        'a.json',
        'README',
        '.env',
      ]) {
        expect(fileKind(name), FileKind.text, reason: name);
      }
      expect(fileKind('movie.ts'), FileKind.video);
      expect(fileKind('backup.zip'), FileKind.archive);
      expect(fileKind('photo.png.zip'), FileKind.archive);
      expect(fileKind('file.py', directory: true), FileKind.folder);
      for (final name in [
        'guide.docx',
        'table.xlsx',
        'slides.pptx',
        'notes.odt',
      ]) {
        expect(isOfficeDocument(name), true, reason: name);
      }
      expect(isOfficeDocument('archive.docx.zip'), false);
      expect(isOfficeDocument('guide.pdf'), false);
    },
  );
  test(
    'plain text disguised as txt.zip is decoded and real archives or binaries are rejected',
    () {
      expect(document('第一行密码\r\n第二行说明', '密码.txt.zip').text, '第一行密码\n第二行说明');
      for (final bytes in [
        [0x50, 0x4b, 3, 4],
        [0x50, 0x4b, 5, 6],
        [0x1f, 0x8b],
        [0, 1, 2],
      ]) {
        expect(
          () => decodeTextDocument((
            Uint8List.fromList(bytes),
            'a.txt.zip',
            false,
          )),
          throwsA(isA<AppException>()),
        );
      }
    },
  );
  test('UTF-8, UTF-16 and GBK preserve Chinese text and empty files', () {
    const text = '中文密码🙂\nprint(1)';
    expect(document('\uFEFF$text').text, text);
    for (final little in [true, false]) {
      final bytes = <int>[
        if (little) ...[255, 254] else ...[254, 255],
      ];
      for (final value in text.codeUnits) {
        bytes.addAll(
          little ? [value & 255, value >> 8] : [value >> 8, value & 255],
        );
      }
      expect(
        decodeTextDocument((Uint8List.fromList(bytes), 'a.txt', false)).text,
        text,
      );
    }
    final value = decodeTextDocument((
      Uint8List.fromList(gbk.encode('中文密码\n第二行')),
      'a.txt',
      false,
    ));
    expect(value.text, '中文密码\n第二行');
    expect(value.encoding, 'GBK');
    expect(document('').text, isEmpty);
  });
  test(
    'a partial UTF-8 character is removed without changing the encoding',
    () {
      final value = decodeTextDocument((
        Uint8List.fromList([...utf8.encode('中文\n'), 0xe4, 0xb8]),
        'a.txt',
        true,
      ));
      expect(value.text, '中文\n');
      expect(value.encoding, 'UTF-8');
    },
  );
  test('scripts are highlighted without changing their text', () {
    for (final (name, content) in [
      ('demo.js', 'const message = "中文";\n// 注释\nconsole.log(message);'),
      ('demo.py', 'import os\n# 仅显示源码\ndef hello():\n    return "中文"\n'),
      ('demo.sh', '#!/bin/bash\necho "hello"'),
      ('demo.json', '{"message": "中文", "count": 3}'),
    ]) {
      final doc = document(content, name);
      expect(doc.highlighted, true, reason: name);
      expect(
        doc.tokens!.expand((t) => t).any((token) => token.scope.isNotEmpty),
        true,
      );
      expect(
        doc.tokens!
            .map((line) => line.map((token) => token.text).join())
            .join('\n'),
        content,
      );
    }
  });
  test('large files and long lines have explicit bounded previews', () {
    final many = document(List.filled(10010, '0123456789').join('\n'));
    expect(many.lines.length, TextDocument.maxLines);
    expect(many.truncated, true);
    final long = document('a' * 15000, 'demo.py');
    expect(long.text.length, TextDocument.maxLineLength);
    expect(long.truncated, true);
    final largeCode = document(
      List.filled(6000, 'print("hello")').join('\n'),
      'demo.py',
    );
    expect(largeCode.highlighted, false);
    expect(largeCode.truncated, false);
  });
  for (final ignoreRange in [true, false]) {
    test(
      'remote text limits memory and stops reading when range is ignored: $ignoreRange',
      () async {
        final transfer = _Transfer(
          Uint8List.fromList(utf8.encode('中文\n' * 400000)),
          ignoreRange: ignoreRange,
        );
        addTearDown(() => transfer.dio.close(force: true));
        final result = await TextPreviewLoader.remote(
          transfer,
          const DownloadSpec(
            url: 'https://example.com/file',
            fileName: 'a.txt.zip',
          ),
        );
        expect(result.truncated, true);
        expect(result.text, startsWith('中文\n'));
        expect(
          transfer.delivered,
          lessThanOrEqualTo(TextDocument.maxBytes + 65536),
        );
        expect(transfer.token!.isCancelled, true);
      },
    );
  }
  test(
    'a mismatched range is rejected and closing cancels an active load',
    () async {
      final broken = _Transfer(Uint8List.fromList([97, 98]), wrongRange: true);
      addTearDown(() => broken.dio.close(force: true));
      const spec = DownloadSpec(
        url: 'https://example.com/file',
        fileName: 'a.txt',
      );
      await expectLater(
        TextPreviewLoader.remote(broken, spec),
        throwsA(isA<AppException>()),
      );
      final held = _Transfer(Uint8List.fromList([97]), hold: true);
      addTearDown(() => held.dio.close(force: true));
      final scope = RequestScope();
      final load = scope.run(() => TextPreviewLoader.remote(held, spec));
      final cancelled = expectLater(load, throwsA(anything));
      await held.ready.future;
      scope.cancel();
      await cancelled;
      expect(held.token!.isCancelled, true);
    },
  );
  test('local Windows files use the same decoder', () async {
    final dir = await Directory.systemTemp.createTemp('wenxi-text-');
    addTearDown(() => dir.delete(recursive: true));
    final file = await File(
      '${dir.path}/sample.py',
    ).writeAsString('print("本地预览")');
    final result = await TextPreviewLoader.local(file.path, 'sample.py');
    expect(result.text, 'print("本地预览")');
    expect(result.highlighted, true);
  });
  test(
    'Android document URIs use the existing bounded native reader and release it',
    () async {
      const channel = MethodChannel('text-preview-fixture');
      final bytes = Uint8List.fromList(utf8.encode('const a = "安卓";'));
      var closed = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'lanScan':
                return {
                  'name': 'a.js',
                  'files': [
                    {
                      'location': 'content://docs/a',
                      'relative': '',
                      'size': bytes.length,
                      'modifiedAt': 0,
                    },
                  ],
                };
              case 'lanOpenRead':
                return 'reader';
              case 'lanRead':
                expect(call.arguments['length'], bytes.length);
                return bytes;
              case 'lanCloseRead':
                closed = true;
                return null;
            }
            throw StateError(call.method);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final result = await TextPreviewLoader.local(
        'content://docs/a',
        'a.js',
        files: LanFiles(android: true, channel: channel),
      );
      expect(result.text, 'const a = "安卓";');
      expect(closed, true);
    },
  );
}
