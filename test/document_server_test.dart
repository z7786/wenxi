import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/lan/lan_files.dart';
import 'package:asterlink/preview/document_format.dart';
import 'package:asterlink/preview/document_server.dart';

class _Assets extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('/index.html')) {
      return ByteData.sublistView(
        Uint8List.fromList(utf8.encode('<main>local document</main>')),
      );
    }
    throw StateError('Missing asset');
  }
}

class _LocalIo extends HttpOverrides {}

Uint8List _package(String name, [String value = '<document/>']) {
  final archive = Archive()..add(ArchiveFile.string(name, value));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = _LocalIo());
  tearDown(() => HttpOverrides.global = null);

  test(
    'document format selects common local readers and explicit external fallback',
    () {
      final cases = {
        'notes.txt': DocumentFormat.text,
        'README.md': DocumentFormat.text,
        'guide.PDF': DocumentFormat.pdf,
        'report.docx': DocumentFormat.word,
        'table.xls': DocumentFormat.spreadsheet,
        'table.xlsx': DocumentFormat.spreadsheet,
        'table.ods': DocumentFormat.spreadsheet,
        'slides.pptx': DocumentFormat.presentation,
        'old.doc': DocumentFormat.external,
        'old.ppt': DocumentFormat.external,
        'demo.zip': null,
        'video.mp4': null,
      };
      for (final entry in cases.entries) {
        expect(documentFormat(entry.key), entry.value, reason: entry.key);
      }
    },
  );

  test(
    'valid document packages are checked without expanding file contents',
    () {
      for (final (part, format) in [
        ('word/document.xml', DocumentFormat.word),
        ('xl/workbook.xml', DocumentFormat.spreadsheet),
        ('ppt/presentation.xml', DocumentFormat.presentation),
        ('content.xml', DocumentFormat.spreadsheet),
      ]) {
        validateOfficePackage(_package(part), format);
      }
    },
  );

  test(
    'mismatched, truncated, encrypted and oversized office structures are rejected',
    () {
      expect(
        () => validateOfficePackage(
          _package('word/document.xml'),
          DocumentFormat.presentation,
        ),
        throwsA(isA<AppException>()),
      );
      expect(
        () => validateOfficePackage(
          Uint8List.fromList([1, 2]),
          DocumentFormat.word,
        ),
        throwsA(isA<AppException>()),
      );
      final base = _package('word/document.xml');
      var central = -1;
      final data = ByteData.sublistView(base);
      for (var i = 0; i < base.length - 4; i++) {
        if (data.getUint32(i, Endian.little) == 0x02014b50) {
          central = i;
          break;
        }
      }
      expect(central, greaterThanOrEqualTo(0));
      final large = Uint8List.fromList(base);
      ByteData.sublistView(
        large,
      ).setUint32(central + 24, 128 * 1024 * 1024, Endian.little);
      expect(
        () => validateOfficePackage(large, DocumentFormat.word),
        throwsA(isA<AppException>()),
      );
      final encrypted = Uint8List.fromList(base);
      ByteData.sublistView(encrypted).setUint16(central + 8, 1, Endian.little);
      expect(
        () => validateOfficePackage(encrypted, DocumentFormat.word),
        throwsA(isA<AppException>()),
      );
      expect(
        () => validateOfficePackage(
          _package('../word/document.xml'),
          DocumentFormat.word,
        ),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'local document endpoint supports ranges, ignores remote URLs, and closes',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'asterlink-document-',
      );
      final file = File('${directory.path}/合同.pdf');
      final bytes = utf8.encode('%PDF-1.7\npublic synthetic document\n%%EOF');
      await file.writeAsBytes(bytes);
      final server = await DocumentServer.open(
        path: file.path,
        name: '合同.pdf',
        bundle: _Assets(),
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() async {
        client.close(force: true);
        await server.close();
        await directory.delete(recursive: true);
      });
      expect(server.uri.host, '127.0.0.1');
      Future<(int, HttpHeaders, List<int>)> get(
        Uri uri, {
        String? range,
        String? origin,
        String? referer,
        String method = 'GET',
      }) async {
        final request = await client.openUrl(method, uri);
        if (range != null) request.headers.set('Range', range);
        if (origin != null) request.headers.set('Origin', origin);
        if (referer != null) request.headers.set('Referer', referer);
        final response = await request.close();
        final data = await response.fold<List<int>>([], (a, b) => a..addAll(b));
        return (response.statusCode, response.headers, data);
      }

      final page = await get(server.uri);
      expect(page.$1, 200);
      expect(
        page.$2.value('content-security-policy'),
        contains("connect-src 'self'"),
      );
      expect(
        page.$2.value('content-security-policy'),
        contains("frame-src 'none'"),
      );
      expect(page.$2.value('cache-control'), 'no-store');
      final meta = await get(server.uri.resolve('info.json'));
      expect(jsonDecode(utf8.decode(meta.$3)), {
        'name': '合同.pdf',
        'format': 'pdf',
        'size': bytes.length,
      });
      final partial = await get(
        server.uri.resolve('document'),
        range: 'bytes=5-12',
      );
      expect(partial.$1, 206);
      expect(partial.$2.value('content-range'), 'bytes 5-12/${bytes.length}');
      expect(partial.$3, bytes.sublist(5, 13));
      final head = await get(server.uri.resolve('document'), method: 'HEAD');
      expect(head.$1, 200);
      expect(head.$2.contentLength, bytes.length);
      expect(head.$3, isEmpty);
      expect(
        (await get(server.uri.resolve('document'), range: 'bytes=999-1000')).$1,
        416,
      );
      expect(
        (await get(
          server.uri.resolve('document'),
          origin: 'https://outside.example',
        )).$1,
        403,
      );
      expect((await get(server.uri.replace(path: '/document'))).$1, 404);
      expect((await get(server.uri.resolve('unknown.js'))).$1, 404);
      expect(
        (await get(server.uri, referer: '${server.uri.origin}/outside')).$1,
        403,
      );
      expect((await get(server.uri, method: 'POST')).$1, 404);
      await file.writeAsString('%PDF-1.7\nchanged document');
      expect((await get(server.uri.resolve('document'))).$1, 500);
      await server.close();
      await server.close();
      await expectLater(
        get(server.uri),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    },
  );

  test(
    'Android content URI is read with the existing SAF lease and always closed',
    () async {
      const channel = MethodChannel('test/document-saf');
      final data = Uint8List.fromList(
        utf8.encode('%PDF-1.7\nsmall content URI fixture'),
      );
      var closed = 0;
      final reads = <String, int>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'lanScan':
                return {
                  'name': 'fixture.pdf',
                  'files': [
                    {
                      'location': 'content://documents/one',
                      'relative': '',
                      'size': data.length,
                      'modifiedAt': 0,
                    },
                  ],
                };
              case 'lanStat':
                return {'size': data.length, 'modifiedAt': 0};
              case 'lanOpenRead':
                final id = 'read-${reads.length}';
                reads[id] = call.arguments['offset'];
                return id;
              case 'lanRead':
                final start = reads[call.arguments['id']]!;
                final length = call.arguments['length'] as int;
                reads[call.arguments['id']] = start + length;
                return Uint8List.sublistView(data, start, start + length);
              case 'lanCloseRead':
                closed++;
                return null;
            }
            throw StateError(call.method);
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final server = await DocumentServer.open(
        path: 'content://documents/one',
        name: 'fixture.pdf',
        files: LanFiles(android: true, channel: channel),
        bundle: _Assets(),
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      addTearDown(() async {
        await server.close();
        client.close(force: true);
      });
      final request = await client.getUrl(server.uri.resolve('document'));
      request.headers.set('range', 'bytes=6-10');
      final response = await request.close();
      expect(
        await response.fold<List<int>>([], (a, b) => a..addAll(b)),
        data.sublist(6, 11),
      );
      expect(closed, 2);
    },
  );

  test(
    'viewer rejects empty and incorrect PDF without allocating a web server',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'asterlink-bad-pdf-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/bad.pdf');
      await file.writeAsString('not a PDF');
      await expectLater(
        DocumentServer.open(path: file.path, name: 'bad.pdf'),
        throwsA(isA<AppException>()),
      );
      await file.writeAsBytes([]);
      await expectLater(
        DocumentServer.open(path: file.path, name: 'bad.pdf'),
        throwsA(isA<AppException>()),
      );
    },
  );
}
