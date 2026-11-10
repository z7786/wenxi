import 'dart:convert';
import '../domain/rapid_transfer.dart';
import 'http.dart';

// Only dedicated whole-content headers qualify. An arbitrary ETag can identify
// a multipart upload, a preview, or an encrypted object instead of the file.
String? md5FromHeaders(HttpResult response) {
  for (final key in ['content-md5', 'x-bs-meta-md5', 'x-bce-content-md5']) {
    final raw = response.header(key).trim();
    final hex = contentMd5(raw);
    if (hex != null) return hex;
    try {
      final bytes = base64Decode(raw);
      if (bytes.length == 16) {
        return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      }
    } on FormatException {
      /* Not a content digest. */
    }
  }
  return null;
}

Future<String?> probeTransferMd5(
  JsonHttp http,
  String url,
  Map<String, String> headers,
  int size,
) async {
  String? urlDigest(Uri uri) {
    for (final key in [
      'md5',
      'content-md5',
      'content_md5',
      'x-bce-content-md5',
    ]) {
      final digest = contentMd5(uri.queryParameters[key]);
      if (digest != null) return digest;
    }
    return null;
  }

  for (var redirects = 0; redirects <= 4; redirects++) {
    RequestScope.checkpoint();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        !(uri.host == 'baidu.com' ||
            uri.host.endsWith('.baidu.com') ||
            uri.host == 'baidupcs.com' ||
            uri.host.endsWith('.baidupcs.com'))) {
      return null;
    }
    final head = await http.readRequest(
      'HEAD',
      url,
      headers: headers,
      followRedirects: false,
    );
    if ([301, 302, 303, 307, 308].contains(head.status)) {
      final location = head.header('location');
      if (location.isEmpty) return null;
      url = uri.resolve(location).toString();
      continue;
    }
    if (head.successful && head.header('content-length') == '$size') {
      final hash = md5FromHeaders(head) ?? urlDigest(uri);
      if (hash != null) return hash;
    }
    // peek is streamed and bounded even if the CDN ignores the Range header.
    final range = await http.peek(
      url,
      headers,
      maxBytes: 256 * 1024,
      followRedirects: false,
    );
    final total = RegExp(
      r'^bytes 0-\d+/(\d+)$',
    ).firstMatch(range.header('content-range'))?.group(1);
    if (range.status == 206 && total == '$size' ||
        range.status == 200 && range.header('content-length') == '$size') {
      return md5FromHeaders(range) ?? urlDigest(uri);
    }
    return null;
  }
  return null;
}
