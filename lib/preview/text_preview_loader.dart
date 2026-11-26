import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../domain/models.dart';
import '../download/transfer_http.dart';
import '../lan/lan_files.dart';
import 'text_document.dart';

class TextPreviewLoader {
  static Future<TextDocument> remote(
    TransferHttp http,
    DownloadSpec source, {
    Duration streamTimeout = const Duration(seconds: 15),
  }) async {
    final cancel = CancelToken(), parent = RequestScope.current;
    if (parent?.isCancelled == true) cancel.cancel();
    parent?.whenCancel.then((_) {
      if (!cancel.isCancelled) cancel.cancel();
    });
    final Uint8List bytes;
    try {
      final response = await http.stream(source.url, {
        ...http.headers(source.headers),
        'Range': 'bytes=0-${TextDocument.maxBytes}',
      }, cancel: cancel);
      final status = response.statusCode ?? 0;
      if (status == 416 &&
          response.headers.value('content-range') == 'bytes */0') {
        bytes = Uint8List(0);
      } else {
        if (status != 200 && status != 206) {
          throw DownloadHttpException.response(response);
        }
        int? total;
        if (status == 206) {
          final range = RegExp(
            r'^bytes 0-(\d+)/(\d+)$',
          ).firstMatch(response.headers.value('content-range') ?? '');
          require(range != null, '服务器返回的文本范围无效');
          total = int.parse(range![2]!);
          require(
            int.parse(range[1]!) == (total - 1).clamp(0, TextDocument.maxBytes),
            '服务器返回的文本范围不完整',
          );
        } else {
          total = int.tryParse(response.headers.value('content-length') ?? '');
        }
        final data = BytesBuilder(copy: false);
        await for (final chunk in response.data!.stream.timeout(
          streamTimeout,
        )) {
          RequestScope.checkpoint();
          final take = (TextDocument.maxBytes + 1 - data.length).clamp(
            0,
            chunk.length,
          );
          data.add(Uint8List.sublistView(chunk, 0, take));
          if (data.length > TextDocument.maxBytes) break;
        }
        require(
          total == null ||
              data.length == total ||
              data.length > TextDocument.maxBytes,
          '文本内容读取不完整，请重试',
        );
        bytes = data.takeBytes();
      }
    } finally {
      cancel.cancel();
    }
    return _decode(bytes, source.fileName);
  }

  static Future<TextDocument> local(
    String path,
    String name, {
    LanFiles? files,
  }) async {
    final reader = files ?? LanFiles();
    final selected = (await reader.scan([path])).files.single;
    final data = BytesBuilder(copy: false);
    await for (final chunk in reader.read(
      selected,
      0,
      selected.size.clamp(0, TextDocument.maxBytes + 1),
    )) {
      RequestScope.checkpoint();
      data.add(chunk);
    }
    return _decode(data.takeBytes(), name);
  }

  static Future<TextDocument> _decode(Uint8List data, String name) async {
    RequestScope.checkpoint();
    final partial = data.length > TextDocument.maxBytes;
    final bytes = partial
        ? Uint8List.sublistView(data, 0, TextDocument.maxBytes)
        : data;
    final result = await compute(decodeTextDocument, (bytes, name, partial));
    RequestScope.checkpoint();
    return result;
  }
}
