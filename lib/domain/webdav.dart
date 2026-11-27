import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import 'models.dart';

/// Paths are relative to the configured collection, with encoded segments.
class WebDavLocation {
  WebDavLocation(String url) : base = _base(url);
  final Uri base;

  static Uri _base(String value) {
    final uri = Uri.tryParse(value.trim());
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          !RegExp(r'[\\\x00-\x1f\x7f]').hasMatch(value),
      '请输入完整 WebDAV 目录地址，不含账号、查询参数或片段',
    );
    // Validate before Uri normalizes dot segments in an untrusted path.
    final rawPath = value.trim().replaceFirst(
      RegExp(r'^https?://[^/]*', caseSensitive: false),
      '',
    );
    final segments = _segments(rawPath);
    return uri!.replace(
      path:
          '/${segments.map(Uri.encodeComponent).join('/')}${segments.isEmpty ? '' : '/'}',
    );
  }

  static void checkName(String name) => require(
    name.isNotEmpty &&
        name != '.' &&
        name != '..' &&
        !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(name),
    'WebDAV 文件或文件夹名称无效',
  );

  static List<String> _segments(String path) {
    try {
      final segments = path
          .split('/')
          .where((s) => s.isNotEmpty)
          .map(
            (s) => Uri.decodeComponent(
              s.replaceAllMapped(
                RegExp(r'[^\x00-\x7f]+'),
                (match) => Uri.encodeComponent(match[0]!),
              ),
            ),
          )
          .toList();
      for (final segment in segments) {
        checkName(segment);
      }
      return segments;
    } on FormatException {
      throw const AppException('WebDAV 路径编码无效');
    } on ArgumentError {
      throw const AppException('WebDAV 路径编码无效');
    }
  }

  Uri uri(String id, {bool directory = false}) {
    require(id.startsWith('/') && !id.startsWith('//'), 'WebDAV 路径无效，请重新打开目录');
    require(!id.contains('?') && !id.contains('#'), 'WebDAV 路径无效');
    final segments = _segments(id);
    final path = segments.map(Uri.encodeComponent).join('/');
    return base.resolve('$path${directory && path.isNotEmpty ? '/' : ''}');
  }

  String? id(Uri target) {
    if (!{'http', 'https'}.contains(target.scheme) ||
        target.origin != base.origin ||
        target.userInfo.isNotEmpty ||
        target.hasQuery ||
        target.hasFragment) {
      return null;
    }
    final root = base.pathSegments.where((s) => s.isNotEmpty).toList();
    final path = target.pathSegments.where((s) => s.isNotEmpty).toList();
    if (path.length < root.length ||
        List.generate(root.length, (i) => root[i] == path[i]).contains(false)) {
      return null;
    }
    final relative = path.skip(root.length).toList();
    if (relative.any(
      (s) => s == '.' || s == '..' || RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(s),
    )) {
      return null;
    }
    return '/${relative.map(Uri.encodeComponent).join('/')}';
  }

  String child(String parent, String name) {
    checkName(name);
    final directory = uri(parent, directory: true);
    return id(directory.resolve(Uri.encodeComponent(name)))!;
  }

  static Credential credential({
    required String url,
    required String username,
    required bool rememberPassword,
    String password = '',
  }) {
    final location = WebDavLocation(url);
    final user = username.trim();
    require(
      !RegExp(r'[:\x00-\x1f\x7f]').hasMatch(user),
      'WebDAV 用户名不能包含冒号或控制字符',
    );
    return Credential(user.ifEmpty(location.base.host), {
      'primary': location.base.toString(),
      'url': location.base.toString(),
      'username': user,
      'userId': sha256
          .convert(utf8.encode('${location.base}\n$user'))
          .toString(),
      'authType': 'webdav',
      'sessionId': newId(),
      'rememberPassword': '$rememberPassword',
      if (rememberPassword) 'password': password,
    });
  }
}
