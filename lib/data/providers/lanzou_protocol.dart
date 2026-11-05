import 'dart:math';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;
import '../../core/json.dart';

/// Ported from LanzouAPI 1.3.110 (MIT, MHanL); see assets/licenses.
/// Folder fields also follow LanZouCloud-API (MIT, zaxtyson).
/// Only reads page data. Scripts, ads and external resources are never run.
class LanzouPage {
  LanzouPage(String source) : document = html.parse(source) {
    script = _withoutComments(
      document.querySelectorAll('script').map((e) => e.text).join('\n'),
    );
    for (final match in RegExp(
      r'''\b([A-Za-z_$][\w$]*)\s*=\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")''',
    ).allMatches(script)) {
      final value = _literal(match[2]!);
      if (value != null && value.isNotEmpty) variables[match[1]!] = value;
    }
    for (final match in RegExp(
      r'\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=\s*(\d+)\s*(?:;|,|$)',
    ).allMatches(script)) {
      variables.putIfAbsent(match[1]!, () => match[2]!);
    }
  }

  final Document document;
  late final String script;
  final variables = <String, String>{};

  Map<String, String> get accountParameters {
    final fields = _properties(script);
    final uid =
        RegExp(r'''uid=([^'"&;\s]+)''').firstMatch(script)?.group(1) ??
        fields['uid'] ??
        variables['uid'] ??
        '';
    final vei = fields['vei'] ?? variables['vei'] ?? '';
    require(
      RegExp(r'^\d{1,20}$').hasMatch(uid) &&
          RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(vei),
      '蓝奏登录尚未完成，请在网页登录后进入文件列表',
    );
    return {'uid': uid, 'vei': vei};
  }

  bool get passwordRequired =>
      RegExp(r'\bfunction\s+down_p\s*\(').hasMatch(script) ||
      document.querySelector('input[type="password"]') != null;

  bool get unavailable => RegExp(
    r'文件(?:夹)?取消分享了|文件(?:夹)?不存在|文件(?:夹)?已取消分享|来晚了.*取消',
  ).hasMatch(document.body?.text ?? '');

  bool get folderPasswordRequired =>
      document.querySelector('#pwdload, #passwddiv, input[type="password"]') !=
      null;

  bool get isFolder => RegExp(
    r'''(?:\burl|['"]url['"])\s*:\s*['"](?:\./|/)?filemoreajax\.php(?:\?[^'"]*)?['"]''',
  ).hasMatch(script);

  String get folderName {
    final title = RegExp(
      r'''\bdocument\.title\s*=\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*)''',
    ).firstMatch(script)?.group(1);
    for (final value in [
      title == null ? null : _literal(title) ?? variables[title],
      document.querySelector('.user-title')?.text,
      name,
    ]) {
      final text = (value ?? '').trim();
      if (text.isNotEmpty && text.length <= 1024 && text != '蓝奏云') return text;
    }
    return '蓝奏云文件夹';
  }

  /// Only current templates explicitly stop when their 50-item page is short.
  /// Unknown templates still require the API's terminal response.
  int? get folderPageSize {
    for (final match in RegExp(
      r'\b(?:var|let|const)\s+([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$]*\.text\s*;',
    ).allMatches(script)) {
      final rows = RegExp.escape(match[1]!);
      if (RegExp(
        '\\bif\\s*\\(\\s*$rows\\.length\\s*<\\s*50\\s*\\)\\s*\\{\\s*'
        r'''document\.getElementById\(\s*['"]filemore['"]\s*\)\.style\.display\s*=\s*['"]none['"]''',
      ).hasMatch(script.substring(match.end))) {
        return 50;
      }
    }
    return null;
  }

  /// The public folder page supplies these fields to filemoreajax.php.
  /// Resolve its data object instead of guessing which variable is a timestamp.
  Map<String, String> folderParameters({String? passcode}) {
    require(
      !folderPasswordRequired || passcode?.isNotEmpty == true,
      '此蓝奏分享需要提取码，请填写后重新解析',
    );
    require(isFolder, '蓝奏文件夹页面格式已变化，请稍后重试');
    final fields =
        RegExp(r'''(?:\bdata|['"]data['"])\s*:\s*\{([^{}]*)\}''', dotAll: true)
            .allMatches(script)
            .map((match) => _properties(match[1]!))
            .where(
              (fields) => [
                'lx',
                'fid',
                't',
                'k',
              ].every((key) => fields[key]?.isNotEmpty == true),
            )
            .lastOrNull;
    require(
      fields != null &&
          RegExp(r'^\d{1,2}$').hasMatch(fields['lx']!) &&
          RegExp(r'^\d{1,20}$').hasMatch(fields['fid']!) &&
          fields['t']!.length <= 128 &&
          fields['k']!.length <= 4096 &&
          !RegExp(r'[\x00-\x1f]').hasMatch('${fields['t']}${fields['k']}'),
      '蓝奏文件夹缺少列表参数，请稍后重试',
    );
    return {
      for (final key in ['lx', 'fid', 't', 'k']) key: fields![key]!,
      'pwd': passcode ?? '',
    };
  }

  /// VIP folder pages can expose nested folders separately from the AJAX list.
  List<({String url, String name})> get subfolders => [
    for (final anchor in document.querySelectorAll('.mbxfolder a[href]'))
      (
        url: anchor.attributes['href']!.trim(),
        name: _folderLabel(anchor.querySelector('.filename') ?? anchor).trim(),
      ),
  ];

  static String _folderLabel(Node node) {
    if (node is Element && node.classes.contains('filesize')) return '';
    if (node is Text) return node.data;
    return node.nodes.map(_folderLabel).join();
  }

  static int sizeFromLabel(String label) {
    final match = RegExp(
      r'^\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)(?:i?B)?\s*$',
      caseSensitive: false,
    ).firstMatch(label);
    if (match == null) return 0;
    final value = double.tryParse(match[1]!) ?? 0;
    if (!value.isFinite) return 0;
    final power = ['', 'K', 'M', 'G', 'T'].indexOf(match[2]!.toUpperCase());
    return (value * pow(1024, max(0, power))).clamp(0, 1 << 53).round();
  }

  String get name {
    for (final value in [
      document.querySelector('.n_box_3fn')?.text,
      document
          .querySelectorAll('div[style]')
          .where(
            (e) => RegExp(
              r'font-size\s*:\s*30px',
            ).hasMatch(e.attributes['style']!),
          )
          .firstOrNull
          ?.text,
      variables['filename'],
      document.querySelector('div.b > span')?.text,
      document
          .querySelector('title')
          ?.text
          .replaceFirst(
            RegExp(r'\s*[-—|]\s*蓝奏(?:云|网盘).*$', caseSensitive: false),
            '',
          ),
    ]) {
      final text = (value ?? '').trim();
      if (text.isNotEmpty && text.length <= 1024 && text != '蓝奏云') return text;
    }
    return '';
  }

  /// Page sizes are rounded and used for display, never integrity checks.
  int get displaySize {
    final text =
        '${document.querySelector('.n_filesize')?.text ?? ''} '
        '${document.querySelector('meta[name="description"]')?.attributes['content'] ?? ''} '
        '${document.body?.text ?? ''}';
    final match = RegExp(
      r'(?:文件大小|大小)\s*[:：]\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)(?:i?B)?\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return 0;
    final value = double.tryParse(match[1]!) ?? 0;
    final power = ['', 'K', 'M', 'G', 'T'].indexOf(match[2]!.toUpperCase());
    return (value * pow(1024, max(0, power))).round().clamp(0, 1 << 53);
  }

  String get iframe =>
      document
          .querySelectorAll('iframe[src]')
          .map((e) => e.attributes['src']!.trim())
          .where((value) => value.isNotEmpty)
          .firstOrNull ??
      '';

  String get ajaxUrl {
    // New iframe templates assign the endpoint through an alias inside a
    // domain-selection branch. Resolve only plain variable assignments; never
    // evaluate page scripts or pick unrelated URL literals from the page.
    final aliases = <String, List<String>>{};
    for (final match in RegExp(
      r'\b([A-Za-z_$][\w$]*)\s*=\s*([A-Za-z_$][\w$]*)\s*;',
    ).allMatches(script)) {
      aliases.putIfAbsent(match[1]!, () => []).add(match[2]!);
    }
    String resolve(String name, Set<String> seen) {
      if (seen.length >= 32 || !seen.add(name)) return '';
      final literal = variables[name];
      if (literal != null) return literal;
      for (final target in (aliases[name] ?? <String>[]).reversed) {
        final value = resolve(target, {...seen});
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    for (final match in RegExp(
      r'''(?:\burl|['"]url['"])\s*:\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*)''',
    ).allMatches(script)) {
      final value = _literal(match[1]!) ?? resolve(match[1]!, {});
      final uri = Uri.tryParse(value);
      if (uri != null &&
          RegExp(r'(?:^|/)ajax(?:m|file)\.php$').hasMatch(uri.path) &&
          RegExp(r'^\d+$').hasMatch(uri.queryParameters['file'] ?? '')) {
        return value;
      }
    }
    return '';
  }

  /// Some download nodes show a plain "verify and download" button whose
  /// documented page request is down_r(2). Read only that fixed form; a real
  /// image/interactive challenge is not solved or executed here.
  Map<String, String>? get downloadConfirmation {
    if (!RegExp(r'\bfunction\s+down_r\s*\(\s*el\s*\)').hasMatch(script) ||
        !RegExp(
          r'''\burl\s*:\s*['"](?:\./)?ajax\.php['"]''',
        ).hasMatch(script)) {
      return null;
    }
    for (final match in RegExp(
      r'\bdata\s*:\s*\{([^{}]*)\}',
      dotAll: true,
    ).allMatches(script)) {
      final fields = _properties(match[1]!);
      final file = fields['file'] ?? '', sign = fields['sign'] ?? '';
      if (file.isNotEmpty &&
          file.length <= 8192 &&
          sign.isNotEmpty &&
          sign.length <= 4096) {
        return {'file': file, 'el': '2', 'sign': sign};
      }
    }
    return null;
  }

  Map<String, String> parameters({String? passcode}) {
    // Anchor on real data objects after removing comments: current templates
    // also contain a commented-out data/sign decoy before the actual request.
    final objects = RegExp(r'\bdata\s*:\s*\{([^{}]*)\}', dotAll: true)
        .allMatches(script)
        .map((match) => _properties(match[1]!))
        .where((fields) => fields['action'] == 'downprocess')
        .toList();
    final fields =
        objects
            .where((fields) => (fields['sign'] ?? '').isNotEmpty)
            .lastOrNull ??
        <String, String>{};
    final sign = fields['sign'] ?? variables['wp_sign'] ?? '';
    require(sign.isNotEmpty && ajaxUrl.isNotEmpty, '蓝奏分享页面格式已变化，请稍后重试');
    if (passwordRequired) {
      require(passcode?.isNotEmpty == true, '此蓝奏分享需要提取码，请填写后重新解析');
      return {'action': 'downprocess', 'sign': sign, 'p': passcode!, 'kd': '1'};
    }
    final ajaxData = variables['ajaxdata'] ?? fields['signs'] ?? '';
    final key = fields['websignkey'] ?? ajaxData;
    require(key.isNotEmpty, '蓝奏分享页面缺少下载参数，请稍后重试');
    return {
      'action': 'downprocess',
      'sign': sign,
      if (ajaxData.isNotEmpty) 'signs': ajaxData,
      'websignkey': key,
      'websign': fields['websign'] ?? '',
      'kd': '1',
      'ves': '1',
    };
  }

  Map<String, String> _properties(String source) {
    final result = <String, String>{};
    for (final match in RegExp(
      r'''(?:['"]([A-Za-z_$][\w$]*)['"]|([A-Za-z_$][\w$]*))\s*:\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\d+)''',
    ).allMatches(source)) {
      final value = match[3]!;
      final resolved =
          _literal(value) ??
          variables[value] ??
          (RegExp(r'^\d+$').hasMatch(value) ? value : null);
      if (resolved != null) result[match[1] ?? match[2]!] = resolved;
    }
    return result;
  }

  static String? _literal(String token) {
    if (token.length < 2 || !["'", '"'].contains(token[0])) return null;
    // Recognize string escapes without evaluating expressions or JS.
    return token.substring(1, token.length - 1).replaceAllMapped(
      RegExp(r'\\(?:u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)'),
      (match) {
        final escape = match[0]!.substring(1);
        if (escape.startsWith('u') && escape.length == 5 ||
            escape.startsWith('x') && escape.length == 3) {
          return String.fromCharCode(int.parse(escape.substring(1), radix: 16));
        }
        return switch (escape) {
          'n' => '\n',
          'r' => '\r',
          't' => '\t',
          _ => escape,
        };
      },
    );
  }

  static String _withoutComments(String source) {
    final result = StringBuffer();
    String? quote;
    for (var i = 0; i < source.length; i++) {
      final char = source[i], next = i + 1 < source.length ? source[i + 1] : '';
      if (quote != null) {
        result.write(char);
        if (char == '\\' && next.isNotEmpty) {
          result.write(next);
          i++;
        } else if (char == quote) {
          quote = null;
        }
      } else if (char == "'" || char == '"' || char == '`') {
        quote = char;
        result.write(char);
      } else if (char == '/' && next == '/') {
        while (i < source.length && source[i] != '\n') {
          i++;
        }
        result.write('\n');
      } else if (char == '/' && next == '*') {
        final end = source.indexOf('*/', i + 2);
        i = end < 0 ? source.length : end + 1;
        result.write(' ');
      } else {
        result.write(char);
      }
    }
    return result.toString();
  }
}

/// Fixed public acw_sc__v2 transform used by LanzouAPI; no JS execution.
String? lanzouChallengeCookie(String source) {
  final arg = RegExp(
    r'''\bvar\s+arg1\s*=\s*['"]([0-9a-f]{40})['"]''',
    caseSensitive: false,
  ).firstMatch(source)?.group(1);
  if (arg == null) return null;
  const positions = [
    15,
    35,
    29,
    24,
    33,
    16,
    1,
    38,
    10,
    9,
    19,
    31,
    40,
    27,
    22,
    23,
    25,
    13,
    6,
    11,
    39,
    18,
    20,
    8,
    14,
    21,
    32,
    26,
    2,
    30,
    7,
    4,
    17,
    5,
    3,
    28,
    34,
    37,
    12,
    36,
  ];
  const mask = '3000176000856006061501533003690027800375';
  final shuffled = positions.map((i) => arg[i - 1]).join();
  return [
    for (var i = 0; i < mask.length; i += 2)
      (int.parse(shuffled.substring(i, i + 2), radix: 16) ^
              int.parse(mask.substring(i, i + 2), radix: 16))
          .toRadixString(16)
          .padLeft(2, '0'),
  ].join();
}
