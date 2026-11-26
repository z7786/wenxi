import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../core/json.dart';
import '../data/http.dart';
import '../lan/lan_files.dart';
import '../lan/lan_models.dart' show lanByteRange;
import 'document_format.dart';

/// A loopback-only, per-viewer file reader. Uses the existing SAF reader on
/// Android; no temporary file, cloud credentials or public HTTP endpoint.
class DocumentServer {
  DocumentServer._(this.files, this.file, this.name, this.format, this.bundle);
  final LanFiles files;
  final LanLocalFile file;
  final String name;
  final DocumentFormat format;
  final AssetBundle bundle;
  final _scope = RequestScope();
  final _assets = <String, Future<ByteData>>{};
  late final HttpServer _server;
  late final Uri uri;
  late final String _prefix;
  bool _closed = false;

  static const maximumOfficeBytes = 32 * 1024 * 1024;
  static const maximumPdfBytes = 256 * 1024 * 1024;

  static Future<DocumentServer> open({
    required String path,
    required String name,
    LanFiles? files,
    AssetBundle? bundle,
  }) async {
    final format = documentFormat(name);
    require(
      format != null &&
          format != DocumentFormat.external &&
          format != DocumentFormat.text,
      '此文档请使用其他应用打开',
    );
    final reader = files ?? LanFiles();
    final selection = await reader.scan([path]);
    require(selection.files.length == 1, '请选择单个文档');
    final file = selection.files.single;
    require(file.size > 0, '文档为空');
    require(
      file.size <=
          (format == DocumentFormat.pdf ? maximumPdfBytes : maximumOfficeBytes),
      '文档较大，请使用其他应用打开',
    );
    final result = DocumentServer._(
      reader,
      file,
      name,
      format!,
      bundle ?? rootBundle,
    );
    HttpServer? bound;
    try {
      if (format == DocumentFormat.pdf) {
        final header = BytesBuilder(copy: false);
        await for (final chunk in reader.read(file, 0, min(file.size, 1024))) {
          RequestScope.checkpoint();
          header.add(chunk);
        }
        require(
          latin1.decode(header.takeBytes()).contains('%PDF-'),
          '文件内容不是有效 PDF',
        );
      } else {
        // Read only the compressed package here. Validation runs off the UI
        // isolate and never expands archive entries or executes document code.
        final data = BytesBuilder(copy: false);
        await for (final chunk in reader.read(file)) {
          RequestScope.checkpoint();
          data.add(chunk);
        }
        final bytes = data.takeBytes();
        await Isolate.run(() => validateOfficePackage(bytes, format));
      }
      RequestScope.checkpoint();
      final token = List.generate(24, (_) => Random.secure().nextInt(256));
      result._prefix = '/${base64UrlEncode(token).replaceAll('=', '')}/';
      bound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      RequestScope.checkpoint();
      result._server = bound;
      result.uri = Uri.parse(
        'http://127.0.0.1:${result._server.port}${result._prefix}index.html',
      );
      result._server.listen((request) {
        unawaited(result._scope.run(() => result._serve(request)));
      });
      return result;
    } catch (_) {
      result._scope.cancel();
      await bound?.close(force: true);
      rethrow;
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    try {
      if (_closed ||
          !const {'GET', 'HEAD'}.contains(request.method) ||
          request.headers.value(HttpHeaders.hostHeader) != uri.authority ||
          !request.uri.path.startsWith(_prefix)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final origin = request.headers.value('origin');
      final referer = request.headers.value(HttpHeaders.refererHeader);
      if (origin != null && origin != uri.origin ||
          referer != null && !referer.startsWith('${uri.origin}$_prefix')) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final resource = request.uri.path.substring(_prefix.length);
      response.headers
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Referrer-Policy', 'no-referrer')
        ..set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self' blob:; "
              "connect-src 'self'; img-src data: blob:; font-src 'self' data: blob:; "
              "style-src 'self' 'unsafe-inline'; media-src 'none'; "
              "frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'",
        );
      if (resource == 'info.json') {
        response.headers.contentType = ContentType.json;
        if (request.method == 'GET') {
          response.write(
            jsonEncode({
              'name': name,
              'format': format.name,
              'size': file.size,
            }),
          );
        }
      } else if (resource == 'document') {
        await _serveFile(request);
      } else {
        final asset = await _asset(resource);
        if (asset == null) {
          response.statusCode = HttpStatus.notFound;
          return;
        }
        response.headers.contentType = switch (resource.split('.').last) {
          'html' => ContentType.html,
          'js' || 'mjs' => ContentType('text', 'javascript', charset: 'utf-8'),
          'css' => ContentType('text', 'css', charset: 'utf-8'),
          'wasm' => ContentType('application', 'wasm'),
          _ => ContentType.binary,
        };
        response.contentLength = asset.lengthInBytes;
        if (request.method == 'GET') {
          response.add(
            asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
          );
        }
      }
    } catch (_) {
      // Renderer failure or a disconnected page must not escape into the
      // application zone or interfere with active downloads.
      try {
        response.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    } finally {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<ByteData?> _asset(String resource) async {
    if (resource.isEmpty ||
        resource.contains('..') ||
        resource.contains('\\') ||
        resource.startsWith('/') ||
        !RegExp(r'^[a-zA-Z0-9_./-]+$').hasMatch(resource)) {
      return null;
    }
    try {
      return await _assets.putIfAbsent(
        resource,
        () => bundle.load('assets/documents/$resource'),
      );
    } catch (_) {
      _assets.remove(resource);
      return null;
    }
  }

  Future<void> _serveFile(HttpRequest request) async {
    final response = request.response;
    (int, int)? range;
    try {
      range = lanByteRange(
        request.headers.value(HttpHeaders.rangeHeader),
        file.size,
      );
    } on HttpException {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */${file.size}',
      );
      return;
    }
    final (start, end) = range ?? (0, file.size);
    await files.check(file);
    response.headers
      ..contentType = format == DocumentFormat.pdf
          ? ContentType('application', 'pdf')
          : ContentType.binary
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.contentLength = end - start;
    if (range != null) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${end - 1}/${file.size}',
      );
    }
    if (request.method == 'GET') {
      await response.addStream(
        files.read(file, start, end).map((chunk) {
          RequestScope.checkpoint();
          return chunk;
        }),
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _scope.cancel();
    await _server.close(force: true);
    _assets.clear();
  }
}

/// Bounded central-directory inspection shared by DOCX/XLSX/PPTX. Legacy XLS
/// is handled by SheetJS; encrypted packages are offered to external apps.
void validateOfficePackage(Uint8List bytes, DocumentFormat format) {
  const ole = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
  if (bytes.length >= ole.length &&
      List.generate(
        ole.length,
        (i) => bytes[i] == ole[i],
      ).every((value) => value)) {
    require(format == DocumentFormat.spreadsheet, '加密文档或旧版格式请使用其他应用打开');
    return;
  }
  require(bytes.length >= 22, '文档内容不完整');
  final data = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= max(0, bytes.length - 65557); i--) {
    if (data.getUint32(i, Endian.little) == 0x06054b50 &&
        i + 22 + data.getUint16(i + 20, Endian.little) == bytes.length) {
      eocd = i;
      break;
    }
  }
  require(eocd >= 0, '文件内容不是有效文档');
  final count = data.getUint16(eocd + 10, Endian.little);
  final length = data.getUint32(eocd + 12, Endian.little);
  final start = data.getUint32(eocd + 16, Endian.little);
  require(
    data.getUint16(eocd + 4, Endian.little) == 0 &&
        data.getUint16(eocd + 6, Endian.little) == 0 &&
        count > 0 &&
        count <= 10000 &&
        data.getUint16(eocd + 8, Endian.little) == count &&
        start + length <= eocd,
    '文档结构过大或不受支持，请使用其他应用打开',
  );
  var at = start, expanded = 0;
  final names = <String>{};
  for (var i = 0; i < count; i++) {
    require(
      at + 46 <= start + length &&
          data.getUint32(at, Endian.little) == 0x02014b50,
      '文档目录损坏',
    );
    final size = data.getUint32(at + 24, Endian.little);
    expanded += size;
    require(
      expanded <= 96 * 1024 * 1024 && size <= 32 * 1024 * 1024,
      '文档展开后过大，请使用其他应用打开',
    );
    require(data.getUint16(at + 8, Endian.little) & 1 == 0, '加密文档请使用其他应用打开');
    final nameLength = data.getUint16(at + 28, Endian.little);
    final next =
        at +
        46 +
        nameLength +
        data.getUint16(at + 30, Endian.little) +
        data.getUint16(at + 32, Endian.little);
    require(next <= start + length, '文档目录不完整');
    final name = utf8.decode(
      bytes.sublist(at + 46, at + 46 + nameLength),
      allowMalformed: true,
    );
    require(
      !name.startsWith('/') &&
          !name.contains('\\') &&
          !name.split('/').contains('..') &&
          names.add(name),
      '文档包含不受支持的条目',
    );
    at = next;
  }
  require(at == start + length, '文档目录不完整');
  require(switch (format) {
    DocumentFormat.word => names.contains('word/document.xml'),
    DocumentFormat.presentation => names.contains('ppt/presentation.xml'),
    DocumentFormat.spreadsheet =>
      names.contains('xl/workbook.xml') ||
          names.contains('xl/workbook.bin') ||
          names.contains('content.xml'),
    _ => false,
  }, '文件内容与文档类型不一致');
}
