import 'dart:convert';
import 'remote_control.dart';

class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(this.parts, this.build);
  final List<int> parts;
  final int? build;
  String get core => parts.join('.');

  static ReleaseVersion? parse(String value) {
    if (value.length > 128) return null;
    final match = RegExp(
      r'^v?(\d+)\.(\d+)(?:\.(\d+))?(?:\+([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*))?$',
      caseSensitive: false,
    ).firstMatch(value.trim());
    if (match == null) return null;
    final parts = [for (var i = 1; i <= 3; i++) int.tryParse(match[i] ?? '0')];
    if (parts.any((part) => part == null || part > 2147483647)) return null;
    final metadata = match[4];
    int? build;
    if (metadata != null && RegExp(r'^\d+$').hasMatch(metadata)) {
      build = int.tryParse(metadata);
      if (build == null || build <= 0 || build > 2147483647) return null;
    }
    return ReleaseVersion(parts.cast<int>(), build);
  }

  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < parts.length; i++) {
      final result = parts[i].compareTo(other.parts[i]);
      if (result != 0) return result;
    }
    return 0;
  }
}

class GitHubReleaseParser {
  static bool newerThan(
    RemoteUpdate update,
    String currentVersion,
    int currentBuild,
  ) {
    final release = ReleaseVersion.parse(update.version);
    final current = ReleaseVersion.parse(currentVersion);
    if (release == null || current == null) return false;
    final comparison = release.compareTo(current);
    if (comparison < 0) return false;
    if (update.build > 0) return update.build > currentBuild;
    return comparison > 0;
  }

  static RemoteUpdate? parse(
    String text, {
    required String repository,
    required String platform,
    required String architecture,
  }) {
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic> ||
        json['draft'] is! bool ||
        json['prerelease'] is! bool ||
        json['tag_name'] is! String ||
        json['assets'] is! List) {
      throw const FormatException('GitHub 版本信息格式有误');
    }
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name'] as String;
    final version = ReleaseVersion.parse(tag);
    if (version == null) return null;
    final assets = <({String name, Uri url, int score, int build})>[];
    for (final asset in json['assets'] as List) {
      if (asset is! Map ||
          asset['name'] is! String ||
          asset['browser_download_url'] is! String ||
          (asset['state'] != null && asset['state'] != 'uploaded')) {
        continue;
      }
      final name = asset['name'] as String;
      if (name.isEmpty || name.length > 300) continue;
      final score = _assetScore(name, platform, architecture);
      if (score == null) continue;
      Uri url;
      try {
        url = httpsUri(asset['browser_download_url'] as String);
      } on FormatException {
        continue;
      }
      final parts = url.pathSegments;
      if (url.host != 'github.com' ||
          (url.hasPort && url.port != 443) ||
          url.hasQuery ||
          url.hasFragment ||
          parts.length != 6 ||
          '${parts[0]}/${parts[1]}'.toLowerCase() != repository.toLowerCase() ||
          parts[2] != 'releases' ||
          parts[3] != 'download' ||
          parts[4] != tag ||
          parts[5] != name) {
        continue;
      }
      final namedVersion = RegExp(
        r'(?:^|[-_ ])v?(\d+\.\d+\.\d+(?:\+\d+)?)(?=[-_. ]|$)',
        caseSensitive: false,
      ).firstMatch(name)?[1];
      final named = namedVersion == null
          ? null
          : ReleaseVersion.parse(namedVersion);
      if (namedVersion != null &&
          (named == null ||
              named.compareTo(version) != 0 ||
              (named.build != null &&
                  version.build != null &&
                  named.build != version.build))) {
        continue;
      }
      assets.add((
        name: name,
        url: url,
        score: score,
        build: version.build ?? named?.build ?? 0,
      ));
    }
    if (assets.isEmpty) return null;
    assets.sort((a, b) {
      final rank = b.score.compareTo(a.score);
      if (rank != 0) return rank;
      final build = b.build.compareTo(a.build);
      return build == 0 ? a.name.compareTo(b.name) : build;
    });
    final selected = assets.first;
    final notes = json['body'] is String ? json['body'] as String : '';
    return RemoteUpdate(
      version.core,
      selected.build,
      selected.url,
      notes.length <= 8000 ? notes : notes.substring(0, 8000),
      releaseKey:
          'github:${repository.toLowerCase()}:$platform:$architecture:'
          '${version.core}+${selected.build}',
    );
  }

  static int? _assetScore(String name, String platform, String architecture) {
    final lower = name.toLowerCase();
    final int kind;
    if (platform == 'android') {
      if (!lower.endsWith('.apk')) return null;
      kind = 1;
    } else if (platform == 'windows') {
      if (lower.endsWith('.exe')) {
        kind = 5;
      } else if (lower.endsWith('.msi')) {
        kind = 4;
      } else if (lower.endsWith('.msix') || lower.endsWith('.msixbundle')) {
        kind = 3;
      } else if (lower.endsWith('.zip') &&
          RegExp(
            r'(?:^|[-_. ])(?:windows|win(?:32|64)?)(?:[-_. ]|$)',
          ).hasMatch(lower)) {
        kind = 1;
      } else {
        return null;
      }
    } else if (platform == 'macos') {
      if (RegExp(r'(?:^|[-_. ])test(?:[-_. ]|$)').hasMatch(lower)) {
        return null;
      }
      if (!RegExp(
        r'(?:^|[-_. ])(?:macos|darwin|mac)(?:[-_. ]|$)',
      ).hasMatch(lower)) {
        return null;
      }
      if (lower.endsWith('.dmg')) {
        kind = 5;
      } else if (lower.endsWith('.zip')) {
        kind = 1;
      } else {
        return null;
      }
    } else {
      return null;
    }
    final declared = <String>{
      if (RegExp(
        r'(?<![a-z0-9])(?:arm64(?:[-_]v8a)?|aarch64)(?![a-z0-9])',
      ).hasMatch(lower))
        'arm64',
      if (RegExp(
        r'(?<![a-z0-9])(?:x86[-_]64|x64|amd64|win64)(?![a-z0-9])',
      ).hasMatch(lower))
        'x64',
      if (RegExp(
        r'(?<![a-z0-9])(?:armeabi(?:[-_]v7a)?|armv7a?|arm32|arm)(?![a-z0-9])',
      ).hasMatch(lower))
        'arm',
      if (RegExp(
        r'(?<![a-z0-9])(?:x86(?![-_]64)|ia32|i[3-6]86|win32)(?![a-z0-9])',
      ).hasMatch(lower))
        'x86',
    };
    if (declared.isNotEmpty && !declared.contains(architecture)) return null;
    final architectureRank = declared.contains(architecture)
        ? 3
        : RegExp(r'(?:universal|all[-_]?abi|all[-_]?arch)').hasMatch(lower)
        ? 2
        : 1;
    return architectureRank * 10 + kind;
  }
}
