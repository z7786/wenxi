import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../core/json.dart';
import '../domain/links.dart';
import '../domain/models.dart';
import '../domain/xunlei_kouling.dart';
import '../domain/c139_passcode.dart';
import 'http.dart';

class CloudCommandKeys {
  const CloudCommandKeys({
    this.quark = const String.fromEnvironment('ASTERLINK_QUARK_COMMAND_KEY'),
    this.uc = const String.fromEnvironment('ASTERLINK_UC_COMMAND_KEY'),
  });
  final String quark, uc;
}

/// Resolves only the explicitly selected provider. Account authentication and
/// downloading remain the responsibility of the normal share connector.
class CloudCommandResolver {
  CloudCommandResolver(
    this.http, {
    this.keys = const CloudCommandKeys(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final JsonHttp http;
  final CloudCommandKeys keys;
  final DateTime Function() clock;
  static const platforms = [
    CloudPlatform.quark,
    CloudPlatform.xunlei,
    CloudPlatform.uc,
    CloudPlatform.c139,
  ];
  static const maximumLength = 2000;

  Future<ParsedLink> resolve(CloudPlatform platform, String text) async {
    require(platforms.contains(platform), '请选择支持口令的网盘');
    require(text.trim().isNotEmpty, '请先粘贴${platform.shortName}口令');
    require(text.length <= maximumLength, '口令内容过长，请只复制本次分享文案');
    RequestScope.checkpoint();
    if (platform == CloudPlatform.c139) {
      final code = C139Passcode.parse(text);
      require(code != null, '未识别到移动云盘口令，请完整复制分享文案');
      return code!.toLink(text);
    }
    if (platform == CloudPlatform.xunlei) return _resolveXunlei(text);
    final body = buildRequest(platform, text, clock().millisecondsSinceEpoch);
    final response = await http.postJsonRead(
      'https://utoken2.${platform == CloudPlatform.quark ? 'quark' : 'uc'}.cn/utoken/v2/parse',
      body,
      {'Accept': 'application/json'},
    );
    RequestScope.checkpoint();
    require(
      response.successful,
      '${platform.shortName}口令服务暂不可用（HTTP ${response.status}），请稍后重试',
    );
    return decodeResponse(platform, response.json);
  }

  Future<ParsedLink> _resolveXunlei(String text) async {
    // Older commands need surrounding quotation marks removed. Keep the raw
    // text as a fallback when punctuation is part of a newer command format.
    final candidates = {
      XunleiKouling.normalize(text),
      text.trim(),
    }.where((value) => value.isNotEmpty).toList();
    for (var index = 0; index < candidates.length; index++) {
      final response = await http
          .get(XunleiKouling.jumpUrl(candidates[index]), {
            'User-Agent': XunleiKouling.userAgent,
            'Accept': '*/*',
            'Origin': XunleiKouling.origin,
            'Referer': XunleiKouling.referer,
          });
      RequestScope.checkpoint();
      try {
        final url = XunleiKouling.shareUrlFromResponse(
          response.status,
          response.json,
        )!;
        return LinkParser.parse(url).single;
      } on AppException {
        if (!response.successful || index == candidates.length - 1) rethrow;
      }
    }
    throw const AppException('该迅雷口令没有对应的网盘分享');
  }

  Json buildRequest(CloudPlatform platform, String clipboard, int timestamp) {
    require(
      platform == CloudPlatform.quark || platform == CloudPlatform.uc,
      '不支持此网盘口令',
    );
    require(
      clipboard.trim().isNotEmpty && clipboard.length <= maximumLength,
      '请粘贴有效口令',
    );
    final quark = platform == CloudPlatform.quark;
    final key = utf8.encode(quark ? keys.quark : keys.uc);
    require(
      key.length == (quark ? 88 : 24),
      '当前安装包未配置${platform.shortName}口令解析，请使用分享链接',
    );
    final app = quark ? 'QUARK' : 'UC';
    // Clipboard bytes are preserved. No Unicode normalization, trimming,
    // JSON escaping, or Base64 decoding of the UTF-8 signing material.
    // Both services accept the full clipboard with empty extraction hints.
    // Let the selected service recognize evolving formats before validation.
    final input = '$app$clipboard$timestamp';
    final signature = Hmac(sha1, key).convert(utf8.encode(input)).toString();
    return {
      'app': app,
      'clipboard': clipboard,
      'identifier': '',
      'shareSecret': '',
      'timestamp': '$timestamp',
      'sign': '${quark ? '2ee1' : '03e9'}$signature',
      'kps': '',
    };
  }

  static ParsedLink decodeResponse(CloudPlatform platform, Json response) {
    require(
      platform == CloudPlatform.quark || platform == CloudPlatform.uc,
      '不支持此网盘口令',
    );
    require(
      response.boolean('success') && response.str('code') == 'OK',
      '${platform.shortName}口令解析失败，口令可能已失效，请重新复制或使用分享链接',
    );
    final data = response.obj('data');
    for (final target in [data.str('androidUrl'), data.str('iosUrl')]) {
      try {
        final uri = Uri.parse(target);
        final quark = platform == CloudPlatform.quark;
        // Some short commands return a web share rather than an app deep link.
        if (uri.scheme == 'https' &&
            uri.host == (quark ? 'pan.quark.cn' : 'drive.uc.cn') &&
            uri.userInfo.isEmpty) {
          final links = LinkParser.parse(target);
          if (links.length == 1 &&
              links.single.platform == platform &&
              links.single.isCloudShare) {
            return links.single;
          }
        }
        // Uri.queryParameters already decodes percent escapes once.
        final query = uri.queryParameters;
        final payload = asJson(
          jsonDecode(query[quark ? 'qk_params' : 'clouddrive_params'] ?? ''),
        );
        final share = quark
            ? payload.obj('params').obj('query')
            : payload.obj('additionProps');
        final id = share.str('pwd_id');
        final code = share['passcode'] ?? '';
        if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
            code is! String ||
            code.length > 128) {
          continue;
        }
        final url = 'https://${quark ? 'pan.quark.cn' : 'drive.uc.cn'}/s/$id';
        return ParsedLink(
          source: code.isEmpty ? url : '$url\n提取码：$code',
          url: url,
          kind: LinkKind.cloudShare,
          platform: platform,
          shareId: id,
          passcode: code.isEmpty ? null : code,
        );
      } on FormatException {
        continue;
      }
    }
    throw AppException('${platform.shortName}口令响应中没有有效分享，请改用分享链接');
  }
}
