import 'dart:convert';

/// Diagnostics never need account secrets, user filenames, or complete URLs.
/// Apply this at collection time and again when packaging native reports.
class LogRedactor {
  static const hidden = '[已隐藏]';
  static final _secretKey = RegExp(
    r'cookie|authorization|password|passwd|passcode|token|secret|credential|capability|parserstate|x-parser-job-key|extract|提取码|访问码|密码|口令|skey|signature|sign$|headers|body|filename|savedpath|destination|sharetext|bduss|__puus|__pus|^pwd$|access_?code|access_?pass|login_user|sessionkey|^primary$|^secondary$|^epd$|^username$|^passport$|^mobile$|^paramid$|^lt$|^reqid$|validate|^cp$|^pb$',
    caseSensitive: false,
  );
  static final _url = RegExp(
    r'''\b(?:https?|wss?|content|file|magnet|data)[:][^\s<>"']+''',
    caseSensitive: false,
  );
  static final _header = RegExp(
    r'''(?:set-cookie|cookie|authorization|proxy-authorization)\s*[=:]\s*[^\r\n]+''',
    caseSensitive: false,
  );
  static final _pair = RegExp(
    r'''((?:[\w.-]*(?:token|secret|password|passwd|passcode|credential|capability|parserstate|x-parser-job-key|skey|signature|cookie|access_?pass)[\w.-]*|BDUSS|STOKEN|__puus|__pus|pwd|access_?code|LOGIN_USER|sessionKey|primary|secondary|epd|username|passport|mobile|paramid|lt|reqid|validate|validateCode|smsValidateCode|cp|pb|提取码|访问码|密码|口令)["']?\s*[=:：]\s*)(?:"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|[^\s,;&}\]\r\n]+)''',
    caseSensitive: false,
  );

  static String text(Object? value, {int limit = 12000}) {
    var input = '$value';
    // Bound work before running expressions; do not copy arbitrarily large
    // plugin errors or server responses into memory or onto disk.
    final inputLimit = limit > 48000 ? 64000 : 48000;
    if (input.length > inputLimit) input = input.substring(0, inputLimit);
    input = input
        .replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '')
        .replaceAll(_header, '凭据: $hidden')
        .replaceAll(_url, '[链接已隐藏]')
        .replaceAll(RegExp(r'\{(?:NRP|RSA)\}[A-Za-z0-9+/=]+'), hidden)
        .replaceAllMapped(_pair, (match) => '${match[1]}$hidden')
        .replaceAllMapped(
          RegExp(r'((?:提取码|访问码|密码|口令)\s+)[A-Za-z0-9_-]+'),
          (match) => '${match[1]}$hidden',
        )
        .replaceAll(
          RegExp(
            r'\b(?:Bearer|Basic)\s+[A-Za-z0-9+/=_-]+',
            caseSensitive: false,
          ),
          hidden,
        )
        .replaceAll(RegExp(r'''\b[A-Za-z]:[\\/][^\r\n"'<>]*'''), '[本地路径已隐藏]')
        .replaceAll(RegExp(r'''\\\\[^\r\n"'<> ]+\\[^\r\n"'<>]*'''), '[本地路径已隐藏]')
        .replaceAll(
          RegExp(
            r'''/(?:storage|sdcard|data|home|Users|tmp|mnt|private|var|Volumes)/[^\r\n"'<>]*''',
          ),
          '[本地路径已隐藏]',
        )
        .replaceAll(
          RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'),
          '[邮箱已隐藏]',
        )
        .replaceAll(RegExp(r'\b1[3-9]\d{9}\b'), '[手机号已隐藏]')
        .replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b'), '[IP 已隐藏]');
    return input.length <= limit ? input : '${input.substring(0, limit)}…[已截断]';
  }

  static Object? value(Object? value, {int depth = 0, int stringLimit = 4096}) {
    if (depth > 5) return '[层级已截断]';
    if (value == null || value is bool) return value;
    if (value is num) return value.isFinite ? value : '$value';
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries.take(64))
          text(entry.key, limit: 80): _secretKey.hasMatch('${entry.key}')
              ? hidden
              : LogRedactor.value(
                  entry.value,
                  depth: depth + 1,
                  stringLimit: switch ('${entry.key}') {
                    'stack' => 12000,
                    'trace' => 64000,
                    _ => 4096,
                  },
                ),
      };
    }
    if (value is Iterable) {
      return value
          .take(100)
          .map((item) => LogRedactor.value(item, depth: depth + 1))
          .toList();
    }
    return text(value, limit: stringLimit);
  }

  static String json(Object? data) => jsonEncode(value(data));
}
