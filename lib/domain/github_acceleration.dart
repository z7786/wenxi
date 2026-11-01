import '../core/json.dart';
import 'models.dart';

class GitHubAcceleration {
  const GitHubAcceleration({this.mode = defaultMode, this.customUrl = ''});

  final String mode, customUrl;
  static const defaultMode = 'gh-proxy.com';
  static const presets = {
    'gh-proxy.com': 'https://gh-proxy.com/',
    'ghproxy.net': 'https://ghproxy.net/',
    'ghfast.top': 'https://ghfast.top/',
  };
  static const testUrl =
      'https://raw.githubusercontent.com/octocat/Hello-World/master/README';

  String get label => switch (mode) {
    'custom' => '自定义代理',
    _ => presets.containsKey(mode) ? mode : '直连',
  };
  String get prefix =>
      mode == 'custom' ? (validPrefix(customUrl) ?? '') : presets[mode] ?? '';

  static String normalizePrefix(String input) {
    final text = input.trim();
    require(text.isNotEmpty && text.length <= 2048, '请输入有效的 GitHub 加速地址');
    require(!RegExp(r'[\s\x00-\x20\x7f\\]').hasMatch(text), '加速地址不能包含空格或控制字符');
    final value = text.contains('://') ? text : 'https://$text';
    final uri = Uri.tryParse(value);
    require(
      uri != null &&
          {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          uri.port > 0 &&
          uri.port <= 65535 &&
          uri.userInfo.isEmpty &&
          !uri.hasQuery &&
          !uri.hasFragment &&
          !uri.path.contains('://') &&
          !RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(value),
      '请输入 HTTP 或 HTTPS 地址，不要包含账号、密码、查询参数或待下载链接',
    );
    final normalized = uri!.toString();
    return normalized.endsWith('/') ? normalized : '$normalized/';
  }

  static String? validPrefix(String input) {
    try {
      return normalizePrefix(input);
    } on AppException {
      return null;
    } on FormatException {
      return null;
    }
  }

  // Only anonymous public file URLs go to a third-party download proxy.
  // Signed URLs, API calls and caller-specific headers retain their origin.
  static bool permits(String url, Map<String, String> headers) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        headers.keys.any(
          (key) => !const {
            'user-agent',
            'accept',
            'accept-encoding',
            'accept-language',
            'range',
            'if-range',
            'if-match',
            'if-none-match',
            'if-modified-since',
            'if-unmodified-since',
            'cache-control',
          }.contains(key.toLowerCase()),
        )) {
      return false;
    }
    final segments = uri.pathSegments;
    if (segments.length < 4) return false;
    return switch (uri.host.toLowerCase()) {
      'raw.githubusercontent.com' => true,
      'codeload.github.com' => {
        'zip',
        'tar.gz',
        'legacy.zip',
        'legacy.tar.gz',
      }.contains(segments[2]),
      'github.com' =>
        segments[2] == 'archive' ||
            segments[2] == 'raw' ||
            segments.length >= 6 &&
                segments[2] == 'releases' &&
                (segments[3] == 'download' ||
                    segments[3] == 'latest' && segments[4] == 'download'),
      _ => false,
    };
  }

  String urlFor(String url, [Map<String, String> headers = const {}]) {
    final base = prefix;
    return base.isNotEmpty && permits(url, headers) ? '$base$url' : url;
  }

  DownloadSpec apply(DownloadSpec spec) {
    if (spec.networkPolicy != null || spec.isTorrent || spec.isEd2k) {
      return spec;
    }
    final url = urlFor(spec.url, spec.headers);
    return url == spec.url ? spec : spec.copyWith(url: url);
  }

  Json toJson() => {'mode': mode, 'customUrl': customUrl};

  factory GitHubAcceleration.fromJson(
    Json data, {
    bool migrateLegacyDefault = false,
  }) {
    final custom = validPrefix(data.str('customUrl')) ?? '';
    final savedMode = data.str('mode', defaultMode);
    final mode = migrateLegacyDefault && savedMode == 'direct'
        ? defaultMode
        : savedMode;
    return GitHubAcceleration(
      mode: presets.containsKey(mode) || mode == 'custom' && custom.isNotEmpty
          ? mode
          : 'direct',
      customUrl: custom,
    );
  }
}
