import 'models.dart';

class C139Passcode {
  const C139Passcode(this.code, {this.password});
  final String code;
  final String? password;
  static final _chineseCode = RegExp(r'^[\u4e00-\u9fa5]{9}$');
  static final _symbol = RegExp(r'/\*([^\r\n]*?):/');
  static final _chinese = RegExp(
    r'(?<![\u4e00-\u9fa5])([\u4e00-\u9fa5]{9})(?![\u4e00-\u9fa5])',
  );
  static final _password = RegExp(
    r'(?:提取码|访问码|密码)\s*(?:为|是)?\s*[:：=]?\s*[【\[(（]?\s*([A-Za-z0-9]{4,8})(?![A-Za-z0-9])',
  );
  static final _wrapping = RegExp(
    r'''[\s\u200b\uFEFF"'“”‘’「」『』【】\[\]（）(),，。!！:：;；/]+''',
  );
  static final _otherChineseCommand = RegExp(r'^(?:咐置.*叩苓|[觸触].*就[緒绪])$');
  int get codeType => _chineseCode.hasMatch(code) ? 2 : 1;

  static C139Passcode? parse(String text, {bool allowChineseText = false}) {
    if (text.length > 2000) return null;
    final symbolic = text.contains('/*');
    final candidates = (symbolic ? _symbol : _chinese)
        .allMatches(text)
        .map((match) => match[1]!)
        .toSet();
    if (candidates.length != 1) return null;
    final code = candidates.single;
    if (code.isEmpty ||
        code.length > 128 ||
        RegExp(r'[\x00-\x1f]').hasMatch(code)) {
      return null;
    }
    final remaining = text.replaceAll(symbolic ? '/*$code:/' : code, '');
    // Only the explicitly selected provider accepts a code embedded in generic
    // prose. Automatic detection needs a standalone code or a mobile-cloud label.
    if (!symbolic && !allowChineseText) {
      if (_otherChineseCommand.hasMatch(code) ||
          RegExp(r'夸克|迅雷|UC\s*网盘', caseSensitive: false).hasMatch(text)) {
        return null;
      }
      if (!RegExp(r'移动云盘|和彩云').hasMatch(text) &&
          remaining
              .replaceAll(_password, '')
              .replaceAll(_wrapping, '')
              .isNotEmpty) {
        return null;
      }
    }
    final explicit = _password.firstMatch(remaining)?[1];
    final inferred = RegExp(r'[a-zA-Z0-9]{4,8}').firstMatch(remaining)?[0];
    final password =
        explicit ?? (inferred?.contains('http') == true ? null : inferred);
    return C139Passcode(code, password: password);
  }

  ParsedLink toLink(String source) => ParsedLink(
    source: source,
    url: Uri.https('yun.139.com', '/shareweb/', {'linkCode': code}).toString(),
    kind: LinkKind.cloudShare,
    platform: CloudPlatform.c139,
    shareId: code,
    passcode: password,
  );

  static C139Passcode? fromLink(ParsedLink link) {
    if (link.platform != CloudPlatform.c139) return null;
    final code = Uri.tryParse(link.url)?.queryParameters['linkCode'];
    return code == null || code.isEmpty
        ? null
        : C139Passcode(code, password: link.passcode);
  }
}
