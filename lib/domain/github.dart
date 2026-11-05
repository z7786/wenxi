import 'dart:convert';
import '../core/json.dart';

enum GitHubNodeKind {
  account,
  owner,
  repository,
  branches,
  code,
  releases,
  release,
  file,
  asset,
  archive,
}

/// Durable browser coordinates. Credentials and download URLs never enter IDs.
class GitHubLocation {
  const GitHubLocation({
    required this.kind,
    required this.owner,
    this.repo = '',
    this.ref = '',
    this.path = '',
    this.releaseId = '',
    this.assetId = '',
    this.branch = true,
    this.writable = false,
  });

  final GitHubNodeKind kind;
  final String owner, repo, ref, path, releaseId, assetId;
  final bool branch, writable;
  String get repository => '$owner/$repo';
  bool get isCode => kind == GitHubNodeKind.code || kind == GitHubNodeKind.file;
  bool get isCodeItem => isCode && path.isNotEmpty && branch && writable;
  String get id =>
      'gh1:${base64Url.encode(utf8.encode(jsonEncode({'k': kind.name, 'o': owner, if (repo.isNotEmpty) 'r': repo, if (ref.isNotEmpty) 'b': ref, if (path.isNotEmpty) 'p': path, if (releaseId.isNotEmpty) 'l': releaseId, if (assetId.isNotEmpty) 'a': assetId, if (!branch) 'tag': true, if (writable) 'w': true})))}';

  GitHubLocation copy({
    GitHubNodeKind? kind,
    String? ref,
    String? path,
    String? releaseId,
    String? assetId,
    bool? branch,
    bool? writable,
  }) => GitHubLocation(
    kind: kind ?? this.kind,
    owner: owner,
    repo: repo,
    ref: ref ?? this.ref,
    path: path ?? this.path,
    releaseId: releaseId ?? this.releaseId,
    assetId: assetId ?? this.assetId,
    branch: branch ?? this.branch,
    writable: writable ?? this.writable,
  );

  static GitHubLocation? tryParse(String id) {
    if (!id.startsWith('gh1:') || id.length > 20000) return null;
    try {
      final j = asJson(
        jsonDecode(utf8.decode(base64Url.decode(id.substring(4)))),
      );
      final kind = GitHubNodeKind.values
          .where((k) => k.name == j.str('k'))
          .firstOrNull;
      if (kind == null ||
          !validOwner(j.str('o')) ||
          j.str('r').isNotEmpty && !validRepo(j.str('r')) ||
          !validPath(j.str('p')) ||
          !validRef(j.str('b'))) {
        return null;
      }
      for (final key in ['l', 'a']) {
        if (j.str(key).isNotEmpty &&
            !RegExp(r'^[1-9][0-9]*$').hasMatch(j.str(key))) {
          return null;
        }
      }
      return GitHubLocation(
        kind: kind,
        owner: j.str('o'),
        repo: j.str('r'),
        ref: j.str('b'),
        path: j.str('p'),
        releaseId: j.str('l'),
        assetId: j.str('a'),
        branch: !j.boolean('tag'),
        writable: j.boolean('w'),
      );
    } catch (_) {
      return null;
    }
  }

  static GitHubLocation parse(String id) =>
      tryParse(id) ?? (throw const AppException('GitHub 目录信息无效，请重新打开仓库'));

  static bool validOwner(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,99}$').hasMatch(value);
  static bool validRepo(String value) =>
      RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(value) &&
      value != '.' &&
      value != '..';
  static bool validPath(String value) =>
      value.isEmpty ||
      !RegExp(r'[\\\x00-\x1f\x7f]').hasMatch(value) &&
          value.split('/').every((p) => p.isNotEmpty && p != '.' && p != '..');
  static bool validRef(String value) =>
      value.isEmpty ||
      validPath(value) &&
          !RegExp(r'[\s~^:?*\[\\]').hasMatch(value) &&
          !value.contains('..') &&
          !value.contains('@{');

  static void checkName(String name) => require(
    name.trim().isNotEmpty &&
        !name.contains('/') &&
        validPath(name) &&
        name.toLowerCase() != '.git',
    '文件名无效，不能包含路径分隔符或使用 .git',
  );
}

/// Recognize only GitHub browser/file routes, never login, issue or action URLs.
class GitHubLink {
  const GitHubLink(this.owner, this.repo, this.route, this.tail);
  final String owner, repo, route;
  final List<String> tail;
  static bool isRawFile(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      (uri.host == 'raw.githubusercontent.com' ||
          uri.host == 'github.com' &&
              uri.pathSegments.length >= 5 &&
              uri.pathSegments[2] == 'raw') &&
      parse(uri)?.route == 'blob';
  bool get isReleaseAsset =>
      route == 'releases' &&
      (tail.length >= 3 && tail.first == 'download' ||
          tail.length == 3 && tail[0] == 'latest' && tail[1] == 'download');
  static GitHubLink? parse(Uri uri) {
    if (uri.userInfo.isNotEmpty ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.hasPort && !{80, 443}.contains(uri.port)) {
      return null;
    }
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final parts = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty || !GitHubLocation.validOwner(parts.first)) return null;
    const reserved = {
      'login',
      'logout',
      'signup',
      'settings',
      'search',
      'explore',
      'marketplace',
      'features',
      'topics',
      'collections',
      'sponsors',
      'notifications',
      'new',
      'about',
      'pricing',
      'enterprise',
      'security',
      'site',
      'apps',
      'organizations',
    };
    if (reserved.contains(parts.first.toLowerCase())) return null;
    if (host == 'github.com' &&
        parts.first == 'orgs' &&
        (parts.length == 2 ||
            parts.length == 3 && parts.last == 'repositories') &&
        GitHubLocation.validOwner(parts[1])) {
      return GitHubLink(parts[1], '', 'owner', const []);
    }
    if (host == 'github.com' && parts.length == 1) {
      return GitHubLink(parts.first, '', 'owner', const []);
    }
    if (parts.length < 2) return null;
    final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
    if (!GitHubLocation.validRepo(repo)) return null;
    if (host == 'raw.githubusercontent.com') {
      return parts.length >= 4
          ? GitHubLink(parts[0], repo, 'blob', parts.skip(2).toList())
          : null;
    }
    if (host == 'codeload.github.com') {
      return parts.length >= 4 && parts[2] == 'zip'
          ? GitHubLink(parts[0], repo, 'archive', parts.skip(3).toList())
          : null;
    }
    if (host != 'github.com') return null;
    if (parts.length == 2) {
      return GitHubLink(parts[0], repo, 'repository', const []);
    }
    final route = parts[2], tail = parts.skip(3).toList();
    if ({'tree', 'blob', 'raw'}.contains(route) && tail.isNotEmpty) {
      return GitHubLink(
        parts[0],
        repo,
        route == 'tree' ? 'tree' : 'blob',
        tail,
      );
    }
    if (route == 'releases' &&
        (tail.isEmpty ||
            tail.length == 1 && tail.first == 'latest' ||
            tail.length == 3 && tail[0] == 'latest' && tail[1] == 'download' ||
            tail.length >= 2 &&
                {'tag', 'download', 'expanded_assets'}.contains(tail.first))) {
      return GitHubLink(parts[0], repo, route, tail);
    }
    if (route == 'archive' && tail.isNotEmpty && tail.last.endsWith('.zip')) {
      return GitHubLink(parts[0], repo, route, tail);
    }
    return null;
  }
}
