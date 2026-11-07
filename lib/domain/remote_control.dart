import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import 'models.dart';

part 'remote_control_parser.dart';

const remoteUpdatePlatforms = ['android', 'windows', 'ios', 'macos'];

/// Remote configuration only controls the features declared in this schema.
/// Announcements support Markdown; links are opened only by user action.
class RemoteControlConfig {
  const RemoteControlConfig({
    this.revision = 0,
    this.announcement,
    this.clouds = const {},
    this.updates = const {},
    this.helpUrl,
    this.aboutDescription = '',
    this.parserHubUrl,
  });

  static const defaults = RemoteControlConfig();
  static const maxBytes = 256 * 1024;
  final int revision;
  final RemoteAnnouncement? announcement;
  final Map<CloudPlatform, CloudControl> clouds;
  final Map<String, RemoteUpdate> updates;
  final Uri? helpUrl;
  final String aboutDescription;
  final Uri? parserHubUrl;
  static const defaultAboutDescription =
      '网盘文件管理与 Gopeed 下载器\nAndroid · iOS · Windows · macOS';
  String get aboutText =>
      aboutDescription.isEmpty ? defaultAboutDescription : aboutDescription;

  CloudControl cloud(CloudPlatform platform) =>
      clouds[platform] ?? const CloudControl();

  factory RemoteControlConfig.decode(String text) =>
      RemoteControlDocument.decode(text).validated;

  factory RemoteControlConfig.fromJson(Object? value) =>
      RemoteControlDocument.parse(value).validated;

  Json toJson() => {
    'schema': 1,
    'revision': revision,
    if (announcement case final notice?)
      'announcement': {
        'enabled': true,
        if (notice.id.isNotEmpty) 'id': notice.id,
        'title': notice.title,
        'content': notice.content,
        if (notice.buttonUrl != null) ...{
          'buttonText': notice.buttonText,
          'buttonUrl': notice.buttonUrl.toString(),
        },
      },
    'clouds': {
      for (final p in CloudPlatform.values)
        p.name: {
          'enabled': cloud(p).enabled,
          'message': cloud(p).message,
          if (cloud(p).expiresAt != null)
            'expiresAt': cloud(p).expiresAt!.toUtc().toIso8601String(),
        },
    },
    'updates': {
      for (final platform in remoteUpdatePlatforms)
        if (updates[platform] case final update?)
          platform: {
            'enabled': true,
            'force': update.force,
            'version': update.version,
            'build': update.build,
            'downloadUrl': update.downloadUrl.toString(),
            if (update.inAppDownloadUrl != null)
              'inAppDownloadUrl': update.inAppDownloadUrl.toString(),
            if (update.inAppPasscode.isNotEmpty)
              'inAppPasscode': update.inAppPasscode,
            'notes': update.notes,
            if (update.expiresAt != null)
              'expiresAt': update.expiresAt!.toUtc().toIso8601String(),
          },
    },
    if (helpUrl != null) 'help': {'enabled': true, 'url': helpUrl.toString()},
    if (aboutDescription.isNotEmpty) 'about': {'description': aboutDescription},
    if (parserHubUrl != null) 'parserHub': {'url': parserHubUrl.toString()},
  };
}

class CloudControl {
  const CloudControl({this.enabled = true, this.message = '', this.expiresAt});
  final bool enabled;
  final String message;
  final DateTime? expiresAt;
  String reason(CloudPlatform platform) =>
      message.isNotEmpty ? message : '${platform.label}暂时停用，请稍后再试';
}

class RemoteAnnouncement {
  const RemoteAnnouncement(
    this.id,
    this.title,
    this.content, {
    this.buttonText = '',
    this.buttonUrl,
  });
  final String id, title, content;
  final String buttonText;
  final Uri? buttonUrl;

  // Local reminder state follows the displayed content, not a publisher-managed
  // ID. Keep the optional ID only for older configurations and clients.
  String get contentKey => sha256
      .convert(
        utf8.encode(
          jsonEncode([title, content, buttonText, buttonUrl?.toString()]),
        ),
      )
      .toString();
}

class RemoteUpdate {
  const RemoteUpdate(
    this.version,
    this.build,
    this.downloadUrl,
    this.notes, {
    this.force = false,
    this.expiresAt,
    this.releaseKey,
    this.inAppDownloadUrl,
    this.inAppPasscode = '',
  });
  final String version, notes;
  final int build;
  final Uri downloadUrl;
  final Uri? inAppDownloadUrl;
  final String inAppPasscode;
  Uri get appDownloadUrl => inAppDownloadUrl ?? downloadUrl;
  final bool force;
  final DateTime? expiresAt;
  // GitHub may provide a version without an Android/Windows build number.
  // Keep its reminder identity separate instead of inventing a build number.
  final String? releaseKey;
  String get key => releaseKey ?? 'build:$build';
}

Uri httpsUri(String value) {
  final uri = Uri.tryParse(value);
  if (value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    throw const FormatException('链接必须是有效的 HTTPS 地址');
  }
  return uri;
}

/// Only announcement buttons may use WeChat's mini-program protocol. Update,
/// service and image addresses retain their HTTPS-only validation.
Uri announcementButtonUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri?.scheme == 'https') return httpsUri(value);
  Never invalid() => throw const FormatException('公告按钮需要有效的 HTTPS 地址或微信小程序链接');
  if (value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) ||
      uri == null ||
      uri.scheme != 'weixin' ||
      uri.host != 'dl' ||
      uri.path != '/business/' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasFragment) {
    invalid();
  }
  final params = uri.queryParametersAll;
  if (params.values.any(
    (values) =>
        values.length != 1 ||
        RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(values.single),
  )) {
    invalid();
  }
  String parameter(String name) => params[name]?.single ?? '';
  bool only(Set<String> keys) => params.keys.every(keys.contains);
  bool queryText(String text, int limit) =>
      text.length <= limit &&
      RegExp(r"^[A-Za-z0-9!#$&'()*+,/:;=?@\-._~%`]*$").hasMatch(text);
  if (params.containsKey('t')) {
    if (!only({'t', 'cq'}) ||
        parameter('t').isEmpty ||
        !queryText(parameter('cq'), 256)) {
      invalid();
    }
  } else {
    // Plain schemes also require the publisher to enable this capability in
    // WeChat's mini-program console; an arbitrary original ID is not a link.
    if (!only({'appid', 'path', 'query', 'env_version'}) ||
        !RegExp(r'^wx[0-9a-fA-F]{16}$').hasMatch(parameter('appid')) ||
        !RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(parameter('path')) ||
        !queryText(parameter('query'), 512) ||
        (parameter('env_version').isNotEmpty &&
            !{
              'release',
              'trial',
              'develop',
            }.contains(parameter('env_version')))) {
      invalid();
    }
  }
  return uri;
}

bool isWeChatMiniProgramLink(Uri uri) =>
    uri.scheme == 'weixin' ||
    (uri.scheme == 'https' &&
        {'wxaurl.cn', 'wxmpurl.cn'}.contains(uri.host.toLowerCase()));

/// Service roots may include a deployment subdirectory. Public configuration
/// carries only the address; API credentials and rule verification stay local.
Uri parserHubUri(String value) {
  final uri = Uri.tryParse(value);
  if (value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'[\s\x00-\x1f\x7f\\]').hasMatch(value) ||
      uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    throw const FormatException('解析后台地址必须是有效的 HTTP/HTTPS 根地址，不能包含账号、查询参数或片段');
  }
  return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
}

Map<String, dynamic> _object(Object? value, String field) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$field 必须是 JSON 对象');
  }
  return value;
}

bool _boolean(Map<String, dynamic> object, String key, {bool fallback = true}) {
  if (!object.containsKey(key)) return fallback;
  final value = object[key];
  if (value is! bool) throw FormatException('$key 必须是 true 或 false');
  return value;
}

String _string(Map<String, dynamic> object, String key, {required int max}) {
  if (!object.containsKey(key)) return '';
  final value = object[key];
  if (value is! String || value.length > max) {
    throw FormatException('$key 必须为不超过 $max 字的文本');
  }
  return value.trim();
}

int _integer(Map<String, dynamic> object, String key, {bool required = false}) {
  if (!object.containsKey(key) && !required) return 0;
  final value = object[key];
  if (value is! int || value < 0 || value > 2147483647) {
    throw FormatException('$key 必须为 0–2147483647 之间的整数');
  }
  return value;
}
