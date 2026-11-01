import '../core/json.dart';
import 'models.dart';
import 'github.dart';
import 'aliyun_share.dart';
import 'link_obfuscation.dart';
import 'ed2k.dart';

class LinkParser {
  static const _tail = r'''[^\s<>"'，。；！、【】《》「」“”‘’\u3000\u200b]+''';
  static final _urls = RegExp('https?://$_tail', caseSensitive: false);
  static final _knownHosts = {
    ...CloudPlatform.values.expand((p) => p.hosts),
    ...UnsupportedCloudPlatform.values.expand((p) => p.hosts),
  }.map(RegExp.escape).join('|');
  static final _bare = RegExp(
    '(?<![A-Za-z0-9./_@%删-])(?:${CloudPlatform.subdomainHostPattern}(?:$_knownHosts)|${CloudPlatform.lanzouHostPattern}|${CloudPlatform.pan123HostPattern})/$_tail',
    caseSensitive: false,
  );
  static final _magnets = RegExp(
    r'magnet:\?xt=urn:btih:[A-Za-z0-9]+[^\s<>\u3000]*',
    caseSensitive: false,
  );
  static final _ed2k = RegExp(
    r'ed2k://\|file\|[^|\r\n]+\|[0-9]+\|[a-f0-9]{32}\|(?:[^|\s]*\|)*/(?:\|sources,[^|\s]+\|/)?|ed2k://%7cfile%7c[^\s<>]+',
    caseSensitive: false,
  );
  static final _code = RegExp(
    r'(?:提取码|访问码|密码|口令|(?<![A-Za-z0-9_])pwd)\s*(?:为|是)?\s*[:：=]?\s*[【\[(（]?\s*([A-Za-z0-9]{1,12})',
    caseSensitive: false,
  );
  // A whole path segment such as /密码1234 can itself be a custom share name.
  static final _lanzouCodeLabel = RegExp(
    r'(?<!/)(?:提取码|访问码|密码|口令)\s*(?:为|是)?\s*[:：=]?\s*[【\[(（]?\s*[A-Za-z0-9]{1,12}',
  );
  static const _codeKeys = ['pwd', 'pass', 'passcode', 'password'];
  static final _rawCode = RegExp(
    r'[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]{4})',
    caseSensitive: false,
  );
  static final _rawLanzouCode = RegExp(
    r'[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]{1,12})',
    caseSensitive: false,
  );
  static final _codeWhitespace = RegExp(r'[\s\u3000\u00a0]+');
  static final _legacyCode = RegExp(r'^[A-Za-z0-9]{1,12}$');
  static final _punctuation = RegExp('[。，,；;！!)）\\]】}》"\'\u3000]+\$');

  static String normalize(String input) {
    var value = LinkObfuscation.cleanUrl(input.trim());
    require(value.isNotEmpty, '请输入链接');
    require(!RegExp(r'[\x00-\x20\x7f]').hasMatch(value), '链接包含空格或控制字符');
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://').hasMatch(value)) {
      value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    require(
      uri != null &&
          (uri.scheme.toLowerCase() == 'http' ||
              uri.scheme.toLowerCase() == 'https'),
      '仅支持 HTTP 或 HTTPS 链接',
    );
    require(uri!.host.isNotEmpty, '链接缺少域名');
    require(uri.userInfo.isEmpty, '链接中不能包含用户名或密码');
    require(!RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(value), '链接转义格式错误');
    // Change only scheme/host. Keep signed paths, escapes and query order byte-for-byte.
    final prefix = RegExp(r'^([^:]+)://([^/?#]+)').firstMatch(value)!;
    return '${prefix[1]!.toLowerCase()}://${prefix[2]!.toLowerCase()}${value.substring(prefix.end)}';
  }

  static List<ParsedLink> parse(String text) =>
      _parse(LinkObfuscation.cleanText(text), text);

  static List<ParsedLink> _parse(String text, String sourceText) {
    final matches = [
      ..._urls.allMatches(text),
      ..._bare.allMatches(text),
      ..._magnets.allMatches(text),
      ..._ed2k.allMatches(text),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final candidates = <_LinkCandidate>[];
    var end = -1;
    for (final match in matches) {
      if (match.start < end) continue;
      end = match.end;
      var raw = match[0]!.replaceFirst(_punctuation, '');
      if (raw.toLowerCase().startsWith('ed2k://')) {
        try {
          final file = Ed2kLink.parse(raw);
          candidates.add(
            _LinkCandidate(
              match.start,
              match.end,
              ParsedLink(source: raw, url: file.url, kind: LinkKind.ed2k),
            ),
          );
        } on AppException {
          continue;
        }
        continue;
      }
      if (raw.toLowerCase().startsWith('magnet:')) {
        candidates.add(
          _LinkCandidate(
            match.start,
            match.start + raw.length,
            ParsedLink(source: raw, url: raw, kind: LinkKind.magnet),
          ),
        );
        continue;
      }
      try {
        var url = normalize(raw);
        var uri = Uri.parse(url);
        final platform = CloudPlatform.fromHost(uri.host);
        if ((platform == CloudPlatform.github ||
                platform == CloudPlatform.ctfile ||
                platform == CloudPlatform.aliyun ||
                platform == CloudPlatform.feijipan) &&
            raw.contains('](')) {
          raw = raw.substring(0, raw.indexOf(']('));
          url = normalize(raw);
          uri = Uri.parse(url);
        }
        if (platform == CloudPlatform.feijipan && raw.endsWith('`')) {
          raw = raw.replaceFirst(RegExp(r'`+$'), '');
          url = normalize(raw);
          uri = Uri.parse(url);
        }
        final unsupported = platform == null
            ? UnsupportedCloudPlatform.fromHost(uri.host)
            : null;
        // Most share IDs are ASCII; Lanzou also accepts custom Unicode paths.
        // Separate adjacent code labels without cutting those custom names.
        if (platform != CloudPlatform.github &&
            (platform != null || unsupported != null)) {
          final prose = (platform == CloudPlatform.lanzou
              ? _lanzouCodeLabel.allMatches(text, match.start).firstOrNull
              : RegExp(r'[\u3400-\u9fff]').firstMatch(raw));
          final proseStart = prose == null
              ? null
              : prose.start -
                    (platform == CloudPlatform.lanzou ? match.start : 0);
          if (proseStart != null && proseStart < raw.length) {
            raw = raw.substring(0, proseStart).replaceFirst(_punctuation, '');
            if (platform == CloudPlatform.ctfile ||
                platform == CloudPlatform.feijipan ||
                platform == CloudPlatform.aliyun ||
                platform == CloudPlatform.tianyi) {
              raw = raw.replaceFirst(RegExp(r'[(（]+$'), '');
            }
            url = normalize(raw);
            uri = Uri.parse(url);
          }
        }
        final id = platform != null
            ? shareId(platform, url)
            : unsupported != null
            ? _unsupportedShareId(unsupported, uri)
            : null;
        candidates.add(
          _LinkCandidate(
            match.start,
            match.start + raw.length,
            ParsedLink(
              source: raw,
              url: url,
              kind: unsupported != null
                  ? LinkKind.unsupportedCloud
                  : id != null
                  ? LinkKind.cloudShare
                  : uri.path.toLowerCase().endsWith('.torrent')
                  ? LinkKind.torrent
                  : LinkKind.direct,
              platform: platform,
              unsupportedPlatform: unsupported,
              shareId: id,
              passcode: id == null ? null : _embeddedCode(url, uri),
            ),
          ),
        );
      } on AppException {
        continue;
      } on FormatException {
        continue;
      }
    }
    // Keep the former convenience of accepting one scheme-less direct URL.
    if (candidates.isEmpty &&
        RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}(?::\d+)?(?:/[^\s]*)?$',
        ).hasMatch(text.trim())) {
      return _parse('https://${text.trim()}', sourceText);
    }
    final codes = _code
        .allMatches(text)
        .where(
          (code) => !candidates.any(
            (candidate) =>
                code.start >= candidate.start && code.start < candidate.end,
          ),
        )
        .toList();
    final leadingCodes =
        codes.isNotEmpty &&
        candidates.isNotEmpty &&
        codes.first.start < candidates.first.start;
    for (final code in codes) {
      final before = candidates.where((c) => c.end <= code.start).lastOrNull;
      final after = candidates.where((c) => c.start >= code.end).firstOrNull;
      _LinkCandidate? owner;
      if (before == null) {
        owner = after;
      } else if (after == null) {
        owner = before;
      } else {
        final left = text.substring(before.end, code.start);
        final right = text.substring(code.end, after.start);
        final blank = RegExp(r'\r?\n[ \t]*\r?\n');
        if (!left.contains('\n')) {
          owner = before;
        } else if (!right.contains('\n')) {
          owner = after;
        } else if (blank.hasMatch(left) && !blank.hasMatch(right)) {
          owner = after;
        } else if (blank.hasMatch(right) && !blank.hasMatch(left)) {
          owner = before;
        } else {
          owner = leadingCodes ? after : before;
        }
      }
      if (owner != null &&
          owner.link.platform != CloudPlatform.github &&
          owner.link.isCloudShare &&
          !owner.hasEmbeddedCode) {
        final value = code[1]!;
        if (_isCode(value) &&
            (owner.link.platform == CloudPlatform.lanzou ||
                owner.link.platform == CloudPlatform.ctfile ||
                (owner.link.platform == CloudPlatform.pikpak &&
                    value.length >= 4 &&
                    value.length <= 10) ||
                value.length == 4)) {
          // MoePal keeps the last valid label. Embedded URL codes still win.
          owner.link = owner.link.withPasscode(value);
        }
      }
    }
    // Deduplicate after assigning codes: a repeated URL may carry the code
    // only in its second occurrence. Never apply a global code to many shares.
    final result = <String, ParsedLink>{};
    for (final candidate in candidates) {
      final link = candidate.link;
      final known = result[link.url];
      if (known == null || known.passcode == null && link.passcode != null) {
        result[link.url] = link;
      }
    }
    return result.values
        .map(
          (link) => ParsedLink(
            id: link.id,
            source: result.length == 1
                ? sourceText
                : '${link.url}${link.passcode == null ? '' : '\n提取码：${link.passcode}'}',
            url: link.url,
            kind: link.kind,
            platform: link.platform,
            unsupportedPlatform: link.unsupportedPlatform,
            shareId: link.shareId,
            passcode: link.passcode,
          ),
        )
        .toList();
  }

  static String? _embeddedCode(String url, Uri uri) {
    final platform = CloudPlatform.fromHost(uri.host);
    if (platform == CloudPlatform.github) return null;
    if (platform == CloudPlatform.ctfile) {
      return _ctfileCode(uri);
    }
    if (platform == CloudPlatform.feijipan) {
      return _feijipanCode(uri);
    }
    if (platform == CloudPlatform.pikpak) {
      for (final part in _parts(uri)) {
        final params = _parameters(part.query);
        for (final key in ['pass_code', ..._codeKeys]) {
          final value = params[key] ?? '';
          if (RegExp(r'^[A-Za-z0-9]{4,10}$').hasMatch(value) &&
              _isCode(value)) {
            return value;
          }
        }
      }
      return null;
    }
    final lanzou = platform == CloudPlatform.lanzou;
    // VLa: decoded query -> hash-route query -> raw URL -> text labels.
    // See docs/LINK-RECOGNITION.md for addresses and compatibility extensions.
    final queryCode = _mapCode(_parameters(uri.query), lanzou);
    if (queryCode != null) return queryCode;
    final fragment = uri.fragment.trim();
    final question = fragment.indexOf('?');
    if (question >= 0 && question + 1 < fragment.length) {
      final fragmentCode = _mapCode(
        _parameters(fragment.substring(question + 1)),
        lanzou,
      );
      if (fragmentCode != null) return fragmentCode;
    }
    final raw = (lanzou ? _rawLanzouCode : _rawCode).firstMatch(url)?[1];
    if (raw != null && _isCode(raw)) return raw;

    // Preserve existing #pwd=..., #abcd and provider-specific parameters.
    if (question < 0) {
      final fragmentCode = _mapCode(_parameters(fragment), lanzou);
      if (fragmentCode != null) return fragmentCode;
    }
    for (final part in _parts(uri)) {
      for (final entry in _parameters(part.query).entries) {
        if (!(platform == CloudPlatform.wopan && entry.key == 'sharecode') &&
            entry.key != 'accesscode' &&
            (entry.key != 'code' || platform == CloudPlatform.tianyi)) {
          continue;
        }
        if (_legacyCode.hasMatch(entry.value) && _isCode(entry.value)) {
          return entry.value;
        }
      }
    }
    return _legacyCode.hasMatch(fragment) && _isCode(fragment)
        ? fragment
        : null;
  }

  static bool _isCode(String value) =>
      value.isNotEmpty && !{'http', 'https'}.contains(value.toLowerCase());

  static String? _ctfileCode(Uri uri) {
    for (final part in _parts(uri)) {
      final parameters = _parameters(part.query);
      for (final key in ['p', ..._codeKeys, 'accesscode', 'code']) {
        final value = parameters[key]?.trim();
        if (value != null && _legacyCode.hasMatch(value) && _isCode(value)) {
          return value;
        }
      }
    }
    final fragment = uri.fragment.trim();
    return _legacyCode.hasMatch(fragment) && _isCode(fragment)
        ? fragment
        : null;
  }

  static String? _ctfileShareId(Uri uri) {
    // Match only actual share routes, never redirect queries or nested help paths.
    for (final part in _parts(uri).reversed) {
      final match = RegExp(
        r'^/(f|file|d|dir|s)/([A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*)/?$',
      ).firstMatch(part.path);
      if (match != null) return '${match[1]}/${match[2]}';
    }
    return null;
  }

  static String? _feijipanShareId(Uri uri) {
    final route = RegExp(r'^/s/([A-Za-z0-9]{4,64})/?$');
    final direct = route.firstMatch(uri.path)?[1];
    if (direct != null) return direct;
    // Hash routes belong at the site root, never inside a help/login path.
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    if (!uri.fragment.startsWith('/')) return null;
    final fragment = Uri.tryParse(uri.fragment);
    return fragment == null || fragment.hasAuthority
        ? null
        : route.firstMatch(fragment.path)?[1];
  }

  static String? _feijipanCode(Uri uri) {
    final valid = RegExp(r'^[A-Za-z0-9]{4}$');
    bool accepted(String value) => valid.hasMatch(value) && _isCode(value);
    // The official copy action uses `code`; preserve its priority over aliases.
    for (final part in _parts(uri)) {
      final parameters = _parameters(part.query);
      for (final key in ['code', ..._codeKeys, 'accesscode']) {
        final value = parameters[key]?.trim();
        if (value != null && accepted(value)) return value;
      }
    }
    final fragment = uri.fragment.trim();
    return accepted(fragment) ? fragment : null;
  }

  static Map<String, String> _parameters(String query) {
    try {
      return {
        for (final entry in Uri.splitQueryString(query).entries)
          entry.key.toLowerCase(): entry.value,
      };
    } on FormatException {
      return const {};
    }
  }

  static String? _mapCode(Map<String, String> parameters, bool lanzou) {
    String? value;
    for (final key in _codeKeys) {
      value = parameters[key];
      if (value != null) break;
    }
    if (value == null) return null;
    value = value.trim().replaceAll(_codeWhitespace, '');
    final limit = lanzou ? 12 : 4;
    if (value.length > limit) value = value.substring(0, limit);
    return _isCode(value) && (lanzou || value.length == 4) ? value : null;
  }

  // Match IDs in the actual path/hash route, never in a nested redirect URL.
  static List<Uri> _parts(Uri uri) {
    final fragment = uri.fragment;
    final route = Uri.tryParse(
      fragment.startsWith('/') || fragment.startsWith('?')
          ? fragment
          : '?$fragment',
    );
    return [uri, if (route != null && !route.hasAuthority) route];
  }

  static String? _pathId(List<Uri> parts, String pattern) {
    final expression = RegExp('$pattern(?=/|\$)');
    for (final part in parts) {
      final value = expression.firstMatch(part.path)?[1];
      if (value != null) return value;
    }
    return null;
  }

  static String? _queryId(List<Uri> parts, String key) {
    for (final part in parts) {
      for (final field in part.query.split('&')) {
        final split = field.indexOf('=');
        if (split < 0 || field.substring(0, split) != key) continue;
        try {
          final value = Uri.decodeQueryComponent(field.substring(split + 1));
          if (RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) return value;
        } on FormatException {
          continue;
        }
      }
    }
    return null;
  }

  static String? shareId(CloudPlatform platform, String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        CloudPlatform.fromHost(uri.host) != platform) {
      return null;
    }
    final parts = _parts(uri);
    return switch (platform) {
      CloudPlatform.github =>
        GitHubLink.parse(uri) == null ? null : '${uri.host}${uri.path}',
      CloudPlatform.pikpak => _pathId(parts, r'^/s/([A-Za-z0-9_-]+)'),
      CloudPlatform.feijipan => _feijipanShareId(uri),
      CloudPlatform.ctfile => _ctfileShareId(uri),
      CloudPlatform.baidu =>
        _queryId(parts, 'surl') ??
            _pathId(parts, r'/s/[A-Za-z0-9_-]([A-Za-z0-9_-]+)'),
      CloudPlatform.quark ||
      CloudPlatform.uc => _pathId(parts, r'/s/([A-Za-z0-9]+)'),
      CloudPlatform.pan115 => _pathId(parts, r'/s/([A-Za-z0-9]+)'),
      CloudPlatform.xunlei => _pathId(parts, r'/s/([A-Za-z0-9_-]+)'),
      CloudPlatform.guangya => _pathId(parts, r'/s/([A-Za-z0-9_-]+)'),
      CloudPlatform.aliyun => AliyunShareLink.parse(uri)?.id,
      CloudPlatform.ilanzou => _pathId(parts, r'/s/([A-Za-z0-9_-]+)'),
      CloudPlatform.weiyun =>
        uri.host == 'share.weiyun.com'
            ? _pathId(parts, r'/(?:s/)?([A-Za-z0-9_-]+)')
            : null,
      CloudPlatform.wopan =>
        _queryId(parts, 'surl') ??
            _queryId(parts, 'shareId') ??
            _pathId(parts, r'/s/([A-Za-z0-9_-]+)'),
      CloudPlatform.c139 => _mobileShareId(url),
      CloudPlatform.lanzou =>
        uri.pathSegments
            .where((segment) => segment.trim().isNotEmpty)
            .lastOrNull,
      CloudPlatform.tianyi =>
        (uri.path == '/web/share' ? _queryId([uri], 'code') : null) ??
            _pathId(parts, r'/t/([A-Za-z0-9]+)') ??
            _queryId(parts, 'code'),
      CloudPlatform.pan123 =>
        _pathId(parts, r'/(?:s|123pan)/([A-Za-z0-9_-]+)') ??
            _queryId(parts, 'sk'),
    };
  }

  static const _mobilePages = {
    'shareweb',
    'share',
    'login',
    'register',
    'account',
    'index',
    'download',
    'passport',
    'help',
    'w',
    'm',
    'i',
  };

  static String? _mobileShareId(String url) {
    var cleaned = url.replaceAll(
      RegExp(r'\s+|%(?:20|0a|0d)', caseSensitive: false),
      '',
    );
    final comment = cleaned.indexOf('/*');
    if (comment >= 0) cleaned = cleaned.substring(0, comment);
    cleaned = cleaned.replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(cleaned);
    if (uri == null) return null;
    final parts = _parts(uri);
    final webId = _pathId(parts, r'/w/i/([A-Za-z0-9_-]+)');
    if (webId != null) return webId;
    for (final part in parts) {
      if (!part.path.endsWith('/m/i')) continue;
      final mobileId = RegExp(
        r'^([A-Za-z0-9]+)(?:&|$)',
      ).firstMatch(part.query)?[1];
      if (mobileId != null) return mobileId;
    }
    final queryId = _queryId(parts, 'linkID');
    if (queryId != null) return queryId;
    final shortId = _pathId(parts, r'/w/([A-Za-z0-9]+)');
    if (shortId != null && !_mobilePages.contains(shortId.toLowerCase())) {
      return shortId;
    }
    for (final part in parts.reversed) {
      final last = RegExp(r'/([A-Za-z0-9]+)$').firstMatch(part.path)?[1];
      if (last != null && !_mobilePages.contains(last.toLowerCase())) {
        return last;
      }
    }
    // MoePal also searches for an 8+ character token. Keep the fallback in
    // path/query values so a host, page name or password cannot become an ID.
    for (final part in parts) {
      final values = [
        ...part.path.split('/'),
        for (final entry in _parameters(part.query).entries)
          if (!_codeKeys.contains(entry.key) &&
              !{'code', 'accesscode'}.contains(entry.key))
            entry.value,
      ];
      for (final value in values) {
        if (RegExp(r'^[A-Za-z0-9]{8,}$').hasMatch(value) &&
            !_mobilePages.contains(value.toLowerCase())) {
          return value;
        }
      }
    }
    return null;
  }

  static String? _unsupportedShareId(
    UnsupportedCloudPlatform platform,
    Uri uri,
  ) => switch (platform) {
    UnsupportedCloudPlatform.aliyun => _pathId(
      _parts(uri),
      r'/s/([A-Za-z0-9]+)',
    ),
    UnsupportedCloudPlatform.guangya => _pathId(_parts(uri), r'/s/([^/?#]+)'),
    UnsupportedCloudPlatform.weiyun => RegExp(
      r'^/(?:s/)?([A-Za-z0-9_-]+)/?$',
    ).firstMatch(uri.path)?[1],
  };
}

class _LinkCandidate {
  _LinkCandidate(this.start, this.end, this.link)
    : hasEmbeddedCode = link.passcode != null;
  final int start, end;
  final bool hasEmbeddedCode;
  ParsedLink link;
}
