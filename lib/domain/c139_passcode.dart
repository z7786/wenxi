import 'models.dart';

class C139Passcode {
  const C139Passcode(this.code, {this.password});
  final String code;
  final String? password;
  int get codeType => RegExp(r'^[\u4e00-\u9fa5]{9}$').hasMatch(code) ? 2 : 1;
  static C139Passcode? parse(String text) {
    if (text.length > 2000) return null;
    final match = RegExp(r'[\s\S]*/\*(.*?):/[\s\S]*').firstMatch(text);
    final code = match?[1];
    if (code == null ||
        code.isEmpty ||
        code.length > 128 ||
        RegExp(r'[\x00-\x1f]').hasMatch(code)) {
      return null;
    }
    final remaining = text.replaceAll('/*$code:/', '');
    final explicit = RegExp(
      r'(?:提取码|访问码|密码)\s*[:：=]?\s*([a-zA-Z0-9]{4,8})',
    ).firstMatch(remaining)?[1];
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
