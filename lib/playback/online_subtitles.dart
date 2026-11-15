import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:enough_convert/gbk.dart';
import 'package:path/path.dart' as p;
import '../core/html_entities.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../download/transfer_http.dart';
import 'subtitle_files.dart';

/// Only a filename or the user's search words leave the device.
String onlineSubtitleQuery(String name) {
  final value = name.trim(), uri = Uri.tryParse(name.trim());
  if (uri != null && {'http', 'https'}.contains(uri.scheme)) {
    return uri.pathSegments.lastOrNull ?? '';
  }
  return value.replaceAll('\\', '/').split('/').last.trim();
}

String _displayText(String value) => unescapeDisplayName(
  value.replaceAllMapped(
    RegExp(r'\\u([0-9a-fA-F]{4})'),
    (match) => String.fromCharCode(int.parse(match[1]!, radix: 16)),
  ),
).replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();

Uint8List _utf8Subtitle(Uint8List bytes) {
  require(bytes.isNotEmpty, '字幕文件为空');
  String text;
  if (bytes.length >= 2 &&
      (bytes[0] == 0xff && bytes[1] == 0xfe ||
          bytes[0] == 0xfe && bytes[1] == 0xff)) {
    require(bytes.length.isEven, '字幕编码不完整，请选择其他字幕');
    final little = bytes[0] == 0xff;
    text = String.fromCharCodes([
      for (var i = 2; i < bytes.length; i += 2)
        little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  } else {
    try {
      text = utf8.decode(bytes);
    } on FormatException {
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
        ).hasMatch(text),
    '下载内容不是有效字幕，请重新搜索',
  );
  require(
    RegExp(r'\d{1,2}:\d{2}(?:[.,]\d{1,3})?\s*-->').hasMatch(text) ||
        RegExp(
          r'^\s*Dialogue\s*:',
          multiLine: true,
          caseSensitive: false,
        ).hasMatch(text),
    '下载内容不是有效字幕，请重新搜索',
  );
  final utf8Bytes = utf8.encode(text);
  require(utf8Bytes.length <= SubtitleFiles.maximumBytes, '字幕文件不能超过 8 MB');
  return utf8Bytes;
}

Future<Uint8List> _normalizeSubtitle(Uint8List bytes) =>
    Isolate.run(() => _utf8Subtitle(bytes));

class OnlineSubtitle {
  const OnlineSubtitle({
    required this.url,
    required this.name,
    required this.title,
    required this.format,
    this.languages = const [],
    this.duration,
  });
  final String url, name, title, format;
  final List<String> languages;
  final Duration? duration;

  static OnlineSubtitle? fromJson(Json json) {
    final uri = Uri.tryParse(json.str('url'));
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final original = onlineSubtitleQuery(
      _displayText(json.str('name')).ifEmpty(p.basename(uri.path)),
    );
    final format = json
        .str('ext', p.extension(original))
        .toLowerCase()
        .replaceFirst(RegExp(r'^\.'), '')
        .trim();
    if (!SubtitleFiles.extensions.contains(format)) return null;
    final name = '${p.withoutExtension(original).ifEmpty('在线字幕')}.$format';
    final languages = json['languages'];
    final milliseconds = json.integer('duration');
    return OnlineSubtitle(
      url: uri.removeFragment().toString(),
      name: name,
      title: _displayText(json.str('simple_name')).ifEmpty(name),
      format: format,
      languages: List.unmodifiable(
        languages is List
            ? languages
                  .whereType<String>()
                  .map((s) => _displayText(s).replaceAll('&', ' / '))
                  .where((s) => s.isNotEmpty)
                  .toSet()
            : <String>[],
      ),
      duration: milliseconds > 0 ? Duration(milliseconds: milliseconds) : null,
    );
  }
}

abstract interface class OnlineSubtitleService {
  Future<List<OnlineSubtitle>> search(String name, RequestScope scope);
  Future<File> download(
    OnlineSubtitle subtitle,
    Directory directory,
    RequestScope scope,
  );
  void close();
}

/// A dedicated transport never inherits a video source's cookies or headers.
class XunleiOnlineSubtitleService implements OnlineSubtitleService {
  XunleiOnlineSubtitleService({TransferHttp? http})
    : _http = http ?? TransferHttp(),
      _ownsHttp = http == null;
  static const endpoint = 'https://api-shoulei-ssl.xunlei.com/oracle/subtitle';
  static const maximumSearchBytes = 2 * 1024 * 1024;
  final TransferHttp _http;
  final bool _ownsHttp;
  final _scopes = <RequestScope>{};
  bool _closed = false;

  Future<T> _request<T>(RequestScope scope, Future<T> Function() action) async {
    require(!_closed, '在线字幕已关闭');
    _scopes.add(scope);
    try {
      return await scope.run(() async {
        RequestScope.checkpoint();
        return await action();
      });
    } finally {
      _scopes.remove(scope);
    }
  }

  @override
  Future<List<OnlineSubtitle>> search(String name, RequestScope scope) =>
      _request(scope, () async {
        final keyword = onlineSubtitleQuery(name);
        require(keyword.isNotEmpty, '请输入视频名称');
        require(keyword.length <= 512, '视频名称不能超过 512 个字符');
        final url = Uri.parse(
          endpoint,
        ).replace(queryParameters: {'name': keyword});
        final bytes = await _http.limited(url.toString(), const {
          'Accept': 'application/json',
        }, maximumSearchBytes);
        RequestScope.checkpoint();
        Object? decoded;
        try {
          decoded = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          throw const AppException('在线字幕服务响应异常，请重试');
        }
        require(decoded is Map, '在线字幕服务响应异常，请重试');
        final json = asJson(decoded);
        require(json.integer('code', -1) == 0, '在线字幕服务暂不可用，请稍后重试');
        require(json['data'] == null || json['data'] is List, '在线字幕服务响应异常，请重试');
        final results = <OnlineSubtitle>[], seen = <String>{};
        for (final item in objects(json['data'])) {
          final subtitle = OnlineSubtitle.fromJson(item);
          if (subtitle != null && seen.add(subtitle.url)) results.add(subtitle);
        }
        return List.unmodifiable(results);
      });

  @override
  Future<File> download(
    OnlineSubtitle subtitle,
    Directory directory,
    RequestScope scope,
  ) => _request(scope, () async {
    require(
      OnlineSubtitle.fromJson({
            'url': subtitle.url,
            'name': subtitle.name,
            'ext': subtitle.format,
          }) !=
          null,
      '字幕下载地址或格式无效，请重新搜索',
    );
    final cancel = CancelToken();
    final relay = scope.token.whenCancel.asStream().listen((_) {
      if (!cancel.isCancelled) cancel.cancel();
    });
    File? pending;
    try {
      final response = await _http.stream(
        subtitle.url,
        _http.headers(const {}),
        cancel: cancel,
      );
      if (response.statusCode != 200) {
        throw DownloadHttpException.response(response);
      }
      require(response.data != null, '字幕下载失败，请重试');
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      require(
        length == null || length <= SubtitleFiles.maximumBytes,
        '字幕文件不能超过 8 MB',
      );
      final type = response.headers.value('content-type')?.toLowerCase() ?? '';
      require(
        !type.contains('text/html') && !type.contains('application/json'),
        '字幕下载地址已失效，请重新搜索',
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        RequestScope.checkpoint();
        require(
          bytes.length + chunk.length <= SubtitleFiles.maximumBytes,
          '字幕文件不能超过 8 MB',
        );
        bytes.add(chunk);
      }
      RequestScope.checkpoint();
      final data = bytes.takeBytes();
      // Conversion stays off the platform thread used to deliver video frames.
      final normalized = await _normalizeSubtitle(data);
      RequestScope.checkpoint();
      pending = await SubtitleFiles(
        directory,
      ).stage(subtitle.name, Stream.value(normalized));
      RequestScope.checkpoint();
      final file = pending;
      pending = null;
      return file;
    } finally {
      cancel.cancel();
      await relay.cancel();
      if (pending != null && await pending.exists()) await pending.delete();
    }
  });

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final scope in _scopes.toList()) {
      scope.cancel();
    }
    if (_ownsHttp) _http.dio.close(force: true);
  }
}
