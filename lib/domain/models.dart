import 'dart:math';
import '../core/json.dart';
import 'download_network_policy.dart';
import 'uploads.dart';

String newId() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

enum CloudPlatform {
  pan115('Pan115', '115网盘', '115', '115', [
    '115.com',
    '115cdn.com',
    '115sha1.com',
  ]),
  baidu('Baidu', '百度网盘', '百度', 'baidu', ['pan.baidu.com', 'baidu.com']),
  quark('Quark', '夸克网盘', '夸克', 'quark', ['quark.cn']),
  uc('Uc', 'UC网盘', 'UC', 'uc', ['uc.cn']),
  xunlei('Xunlei', '迅雷网盘', '迅雷', 'xunlei', ['xunlei.com']),
  pan123('Pan123', '123网盘', '123', '123', ['123pan.com', '123pan.cn']),
  guangya('Guangya', '光鸭云盘', '光鸭', 'guangya', ['guangyapan.com']),
  aliyun('Aliyun', '阿里云盘', '阿里', 'ali', ['aliyundrive.com', 'alipan.com']),
  c139('C139', '中国移动云盘', '139', 'yidong', ['yun.139.com', 'caiyun.139.com']),
  tianyi('Tianyi', '天翼云盘', '天翼', 'tianyi', ['189.cn']),
  ilanzou('ILanzou', '蓝奏云优享版', '蓝奏优享', 'lanzous', ['ilanzou.com']),
  weiyun('Weiyun', '腾讯微云', '微云', 'weiyun', ['weiyun.com']),
  wopan('Wopan', '中国联通云盘', '联通', 'wopan', [
    'pan.wo.cn',
    'panservice.mail.wo.cn',
  ]),
  lanzou('Lanzou', '蓝奏云', '蓝奏', 'lanzous', [
    'lanzou.com',
    'lanzous.com',
    'lanzoux.com',
  ]),
  ctfile('Ctfile', '城通网盘', '城通', 'ctfile', [
    'ctfile.com',
    'ctfile.cn',
    '400gb.com',
    '545c.com',
    'pipipan.com',
  ]),
  feijipan('Feijipan', '小飞机网盘', '小飞机', 'feijipan', ['feijipan.com']),
  pikpak('PikPak', 'PikPak网盘', 'PikPak', 'pikpak', ['mypikpak.com']),
  github('GitHub', 'GitHub', 'GitHub', 'github', [
    'github.com',
    'raw.githubusercontent.com',
    'codeload.github.com',
  ]);

  const CloudPlatform(
    this.key,
    this.label,
    this.shortName,
    this.icon,
    this.hosts,
  );
  final String key, label, shortName, icon;
  final List<String> hosts;
  bool get requiresAccount => true;
  bool get canCreateFolder => true;
  bool get supportsFamilyCloud =>
      this == tianyi || this == c139 || this == wopan;
  bool get supportsPersonalSpaces => this == aliyun || this == ctfile;
  bool get supportsShareParsing => this != ilanzou && this != weiyun;
  bool get shareRequiresAccount => !{
    baidu,
    lanzou,
    guangya,
    aliyun,
    wopan,
    quark,
    uc,
    ctfile,
    feijipan,
    pikpak,
    github,
  }.contains(this);
  bool get supportsSharing =>
      this != ilanzou && this != weiyun && this != wopan && this != github;
  String get shareUnavailableMessage => '$label暂不支持分享解析，请在网盘页登录后浏览个人文件';
  bool get exactFileSize =>
      this != ilanzou && this != lanzou && this != feijipan;
  // MoePal's share classifier accepts these domain families, not a fixed list
  // of aliases. Use the same rule for pasted links and share-page redirects.
  static const subdomainHostPattern = r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*';
  static const lanzouHostPattern =
      subdomainHostPattern +
      r'(?:lanzou[a-z0-9-]*|lan[zs]o[ux])\.(?:com|net|org|cn)';
  static const pan123HostPattern = subdomainHostPattern + r'123\d+\.(?:com|cn)';
  static final _lanzouHost = RegExp('^$lanzouHostPattern\$');
  static final _pan123Host = RegExp('^$pan123HostPattern\$');
  static CloudPlatform? fromKey(String? value) {
    for (final p in values) {
      if (p.key == value || p.name == value) return p;
    }
    return null;
  }

  static CloudPlatform? fromHost(String host) {
    final normalized = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    if (_lanzouHost.hasMatch(normalized)) return lanzou;
    if (_pan123Host.hasMatch(normalized)) return pan123;
    for (final p in values) {
      if (p.hosts.any((h) => normalized == h || normalized.endsWith('.$h'))) {
        return p;
      }
    }
    return null;
  }
}

// Recognition is separate from the list of working account connectors.
enum UnsupportedCloudPlatform {
  aliyun('阿里云盘', '阿里', ['aliyundrive.com', 'alipan.com']),
  guangya('光鸭网盘', '光鸭', ['guangyapan.com']),
  weiyun('腾讯微云', '微云', ['weiyun.com']);

  const UnsupportedCloudPlatform(this.label, this.shortName, this.hosts);
  final String label, shortName;
  final List<String> hosts;

  static UnsupportedCloudPlatform? fromHost(String host) {
    final normalized = host.toLowerCase();
    for (final platform in values) {
      if (platform.hosts.any(
        (domain) => normalized == domain || normalized.endsWith('.$domain'),
      )) {
        return platform;
      }
    }
    return null;
  }
}

enum LinkKind { cloudShare, direct, magnet, torrent, unsupportedCloud, ed2k }

class ParsedLink {
  ParsedLink({
    String? id,
    required this.source,
    required this.url,
    required this.kind,
    this.platform,
    this.unsupportedPlatform,
    this.shareId,
    this.passcode,
  }) : id = id ?? newId();
  final String id, source, url;
  final LinkKind kind;
  final CloudPlatform? platform;
  final UnsupportedCloudPlatform? unsupportedPlatform;
  final String? shareId, passcode;
  bool get isCloudShare =>
      kind == LinkKind.cloudShare ||
      kind == LinkKind.unsupportedCloud && shareId != null;
  String? get cloudLabel => platform?.label ?? unsupportedPlatform?.label;
  String get textForCopy {
    final code = passcode;
    if (!isCloudShare || code == null || code.isEmpty) return url;
    final keys = {
      'pwd',
      'pass',
      'passcode',
      'password',
      'accesscode',
      if (platform == CloudPlatform.pikpak) 'pass_code',
      if (platform == CloudPlatform.ctfile) 'p',
      if (platform == CloudPlatform.ctfile ||
          platform == CloudPlatform.feijipan)
        'code',
    };
    // A manually corrected code must replace an embedded old code. Keep every
    // unrelated query byte intact, especially share IDs and nested URLs.
    String replaceCodes(String query) => query
        .split('&')
        .map((field) {
          final separator = field.indexOf('=');
          if (separator < 0) return field;
          final key = field.substring(0, separator);
          try {
            if (!keys.contains(Uri.decodeQueryComponent(key).toLowerCase())) {
              return field;
            }
          } on FormatException {
            return field;
          }
          try {
            if (Uri.decodeQueryComponent(field.substring(separator + 1)) ==
                code) {
              return field;
            }
          } on FormatException {
            // Replace malformed old escaping with the successfully used code.
          }
          return '$key=${Uri.encodeQueryComponent(code)}';
        })
        .join('&');

    final hash = url.indexOf('#');
    var address = hash < 0 ? url : url.substring(0, hash);
    final query = address.indexOf('?');
    if (query >= 0) {
      address =
          '${address.substring(0, query + 1)}${replaceCodes(address.substring(query + 1))}';
    }
    if (hash >= 0) {
      var fragment = url.substring(hash + 1);
      final query = fragment.indexOf('?');
      if (query >= 0) {
        fragment =
            '${fragment.substring(0, query + 1)}${replaceCodes(fragment.substring(query + 1))}';
      } else if (RegExp(r'^[A-Za-z0-9]{1,12}$').hasMatch(fragment)) {
        fragment = Uri.encodeQueryComponent(code);
      } else {
        fragment = replaceCodes(fragment);
      }
      address = '$address#$fragment';
    }
    return '$address 提取码：$code';
  }

  ParsedLink withPasscode(String value) => ParsedLink(
    id: id,
    source: source,
    url: url,
    kind: kind,
    platform: platform,
    unsupportedPlatform: unsupportedPlatform,
    shareId: shareId,
    passcode: value.trim().isEmpty ? null : value.trim(),
  );
  Json toJson() => {
    'id': id,
    'source': source,
    'normalizedUrl': url,
    'kind': kind.name,
    'platform': platform?.key,
    if (unsupportedPlatform != null)
      'unsupportedPlatform': unsupportedPlatform!.name,
    'shareId': shareId,
    'passcode': passcode,
  };
  factory ParsedLink.fromJson(Json j) {
    final upgraded = j.str('kind').toLowerCase() == 'unsupportedcloud'
        ? CloudPlatform.fromKey(j.str('unsupportedPlatform'))
        : null;
    return ParsedLink(
      id: j.str('id').isEmpty ? null : j.str('id'),
      source: j.str('source'),
      url: j.str('normalizedUrl', j.str('url')),
      kind: upgraded != null && j.str('shareId').isNotEmpty
          ? LinkKind.cloudShare
          : LinkKind.values.firstWhere(
              (k) => k.name.toLowerCase() == j.str('kind').toLowerCase(),
              orElse: () => LinkKind.direct,
            ),
      platform: CloudPlatform.fromKey(j.str('platform')) ?? upgraded,
      unsupportedPlatform: upgraded != null
          ? null
          : UnsupportedCloudPlatform.values
                .where(
                  (platform) => platform.name == j.str('unsupportedPlatform'),
                )
                .firstOrNull,
      shareId: j['shareId']?.toString(),
      passcode: j['passcode']?.toString(),
    );
  }
}

class Credential {
  Credential(this.label, Map<String, String> fields, {int? updatedAt})
    : fields = Map.unmodifiable(fields),
      updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;
  final String label;
  final Map<String, String> fields;
  final int updatedAt;
  String get primary => field('primary').trim();
  String get secondary => field('secondary').trim();
  String field(String key) => fields[key] ?? '';
  Credential withFields(
    Map<String, String> values, {
    bool preserveRevision = false,
  }) => Credential(label, {
    ...fields,
    ...values,
  }, updatedAt: preserveRevision ? updatedAt : null);
  Json toJson() => {'label': label, 'fields': fields, 'updatedAt': updatedAt};
  factory Credential.fromJson(Json j) => Credential(
    j.str('label'),
    strings(j['fields']),
    updatedAt: j.integer('updatedAt'),
  );
  bool sameAs(Credential? other) =>
      other != null &&
      label == other.label &&
      updatedAt == other.updatedAt &&
      fields.length == other.fields.length &&
      fields.entries.every((e) => other.fields[e.key] == e.value);
}

class CloudAccount {
  const CloudAccount(this.nickname, {this.used = 0, this.total = 0});
  final String nickname;
  final int used, total;
}

class CloudSpace {
  const CloudSpace(this.id, this.name);
  final String id, name;
}

class CloudFile {
  const CloudFile({
    required this.id,
    required this.name,
    this.size = 0,
    this.isDirectory = false,
    this.parentId = '',
    this.token = '',
    this.modifiedAt = '',
    this.hashType,
    this.hashValue,
    this.thumbnailUrl = '',
  });
  final String id, name, parentId, token, modifiedAt;
  final int size;
  final bool isDirectory;
  final String? hashType, hashValue;
  // Preview URLs are temporary and must be refreshed from the file listing.
  // They deliberately do not participate in persisted downloads or history.
  final String thumbnailUrl;
  Json toJson() => {
    'id': id,
    'name': name,
    'size': size,
    'isDirectory': isDirectory,
    'parentId': parentId,
    'token': token,
    'modifiedAt': modifiedAt,
    'hashType': hashType,
    'hashValue': hashValue,
  };
  factory CloudFile.fromJson(Json j) => CloudFile(
    id: j.str('id'),
    name: j.str('name'),
    size: j.integer('size'),
    isDirectory: j.boolean('isDirectory'),
    parentId: j.str('parentId'),
    token: j.str('token'),
    modifiedAt: j.str('modifiedAt'),
    hashType: j['hashType']?.toString(),
    hashValue: j['hashValue']?.toString(),
  );
}

enum BrowseMode { share, personal }

class BrowseSession {
  const BrowseSession({
    required this.platform,
    required this.mode,
    required this.title,
    required this.rootId,
    this.metadata = const {},
    this.sourceLink,
  });
  final CloudPlatform platform;
  final BrowseMode mode;
  final String title, rootId;
  final Map<String, String> metadata;
  final ParsedLink? sourceLink;
  String meta(String key) => metadata[key] ?? '';
  String? get accountId => metadata['accountId'];
  BrowseSession withAccount(String? id) => BrowseSession(
    platform: platform,
    mode: mode,
    title: title,
    rootId: rootId,
    metadata: {...metadata, 'accountId': id ?? ''},
    sourceLink: sourceLink,
  );
  String get familyId => meta('familyId');
  String get personalSpaceId =>
      mode == BrowseMode.personal ? meta('driveId') : '';
  bool get isFamily => mode == BrowseMode.personal && familyId.isNotEmpty;
  bool get canManageFiles => platform == CloudPlatform.github
      ? mode == BrowseMode.personal && meta('githubAuthenticated') == 'true'
      : mode == BrowseMode.personal && !isFamily;
  Map<String, String> get spaceMetadata => {
    if (isFamily) 'familyId': familyId,
    if (isFamily) 'familyName': meta('familyName'),
    if (personalSpaceId.isNotEmpty) 'driveId': personalSpaceId,
    if (personalSpaceId.isNotEmpty) 'driveName': meta('driveName'),
  };
  BrowseSession withLink(ParsedLink link) => BrowseSession(
    platform: platform,
    mode: mode,
    title: title,
    rootId: rootId,
    metadata: metadata,
    sourceLink: link,
  );
  Json toJson() => {
    'platform': platform.key,
    'mode': mode.name,
    'title': title,
    'rootId': rootId,
    'metadata': metadata,
    'sourceLink': sourceLink?.toJson(),
  };
  factory BrowseSession.fromJson(Json j) => BrowseSession(
    platform:
        CloudPlatform.fromKey(j.str('platform')) ??
        (throw const AppException('未知网盘来源')),
    mode: j.str('mode').toLowerCase() == 'share'
        ? BrowseMode.share
        : BrowseMode.personal,
    title: j.str('title'),
    rootId: j.str('rootId'),
    metadata: strings(j['metadata']),
    sourceLink: j['sourceLink'] == null
        ? null
        : ParsedLink.fromJson(j.obj('sourceLink')),
  );
}

class ShareOptions {
  const ShareOptions(this.title, {this.expiryDays, this.passcode});
  final String title;
  final int? expiryDays;
  final String? passcode;
}

class ShareCreation {
  const ShareCreation(this.url, this.passcode, this.title);
  final String url, passcode, title;
  String get text => '$title\n$url${passcode.isEmpty ? '' : '\n提取码：$passcode'}';
}

class DownloadCleanup {
  const DownloadCleanup({
    required this.url,
    this.method = 'POST',
    this.body,
    this.action,
    this.headers = const {},
  });
  final String url, method;
  final String? body;
  final Json? action;
  final Map<String, String> headers;
  Json toJson() => {
    'url': url,
    'method': method,
    'body': body,
    if (action != null) 'action': action,
    'headers': headers,
  };
  factory DownloadCleanup.fromJson(Json j) => DownloadCleanup(
    url: j.str('url'),
    method: j.str('method', 'POST'),
    body: j['body']?.toString(),
    action: j['action'] == null ? null : j.obj('action'),
    headers: strings(j['headers']),
  );
}

class DownloadSpec {
  const DownloadSpec({
    required this.url,
    required this.fileName,
    this.relativePath = '',
    this.headers = const {},
    this.expectedSize = 0,
    this.checksumType,
    this.checksumValue,
    this.cleanup,
    this.source,
    this.profile,
    this.torrent,
    this.appUpdateKey,
    this.guestDownload = false,
    this.networkPolicy,
    this.maxPlaybackConnections,
  });
  final String url, fileName, relativePath;
  final Map<String, String> headers;
  final int expectedSize;
  final String? checksumType, checksumValue, profile;
  final DownloadCleanup? cleanup;
  final Json? source, torrent;
  final String? appUpdateKey;
  final bool guestDownload;
  final DownloadNetworkPolicy? networkPolicy;

  /// A positive upstream limit; null leaves playback concurrency unrestricted.
  final int? maxPlaybackConnections;
  bool get isTorrent => torrent != null;
  bool get isEd2k => url.toLowerCase().startsWith('ed2k://');
  bool get needsPreparation => !isTorrent && url.isEmpty && source != null;
  CloudPlatform? get platform => CloudPlatform.fromKey(
    source?.str('platform') ?? asJson(source?['session']).str('platform'),
  );
  DownloadSpec copyWith({
    String? url,
    String? relativePath,
    Json? source,
    String? fileName,
    DownloadCleanup? cleanup,
    String? appUpdateKey,
    bool? guestDownload,
    String? profile,
  }) => DownloadSpec(
    url: url ?? this.url,
    fileName: fileName ?? this.fileName,
    relativePath: relativePath ?? this.relativePath,
    headers: headers,
    expectedSize: expectedSize,
    checksumType: checksumType,
    checksumValue: checksumValue,
    cleanup: cleanup ?? this.cleanup,
    source: source ?? this.source,
    profile: profile ?? this.profile,
    torrent: torrent,
    appUpdateKey: appUpdateKey ?? this.appUpdateKey,
    guestDownload: guestDownload ?? this.guestDownload,
    networkPolicy: networkPolicy,
    maxPlaybackConnections: maxPlaybackConnections,
  );
  Json toJson() => {
    'url': url,
    'fileName': fileName,
    'relativePath': relativePath,
    'headers': headers,
    'expectedSize': expectedSize,
    'checksumType': checksumType,
    'checksumValue': checksumValue,
    'cleanup': cleanup?.toJson(),
    'source': source,
    'profile': profile,
    'torrent': torrent,
    if (appUpdateKey != null) 'appUpdateKey': appUpdateKey,
    if (guestDownload) 'guestDownload': true,
    if (networkPolicy != null) 'networkPolicy': networkPolicy!.toJson(),
    if (maxPlaybackConnections != null)
      'maxPlaybackConnections': maxPlaybackConnections,
  };
  factory DownloadSpec.fromJson(Json j) => DownloadSpec(
    url: j.str('url'),
    fileName: j.str('fileName'),
    relativePath: j.str('relativePath'),
    headers: strings(j['headers']),
    expectedSize: j.integer('expectedSize'),
    checksumType: j['checksumType']?.toString(),
    checksumValue: j['checksumValue']?.toString(),
    cleanup: j['cleanup'] == null
        ? null
        : DownloadCleanup.fromJson(j.obj('cleanup')),
    source: j['source'] == null ? null : j.obj('source'),
    profile: j['profile']?.toString(),
    torrent: j['torrent'] == null ? null : j.obj('torrent'),
    appUpdateKey: j['appUpdateKey'] as String?,
    guestDownload: j.boolean('guestDownload', false),
    networkPolicy: j['networkPolicy'] == null
        ? null
        : DownloadNetworkPolicy.fromJson(j.obj('networkPolicy')),
    maxPlaybackConnections: j.integer('maxPlaybackConnections') > 0
        ? j.integer('maxPlaybackConnections')
        : null,
  );
}

abstract class CloudConnector {
  CloudPlatform get platform;
  bool canUploadTo(BrowseSession session, String parent) =>
      session.canManageFiles;
  bool canCreateFolderIn(BrowseSession session, String parent) =>
      session.canManageFiles && platform.canCreateFolder;
  bool canRenameFile(BrowseSession session, CloudFile file) =>
      session.canManageFiles;
  bool canDeleteFile(BrowseSession session, CloudFile file) =>
      session.canManageFiles;
  bool canMoveFile(BrowseSession session, CloudFile file) =>
      session.canManageFiles;
  bool canDownloadFile(BrowseSession session, CloudFile file) => true;
  Future<CloudAccount> account(Credential credential);
  Future<BrowseSession> openShare(ParsedLink link, Credential? credential);
  Future<BrowseSession> openPersonal(Credential credential);
  Future<List<CloudSpace>> personalSpaces(Credential credential) async => [];
  Future<BrowseSession> openPersonalSpace(
    CloudSpace space,
    Credential credential,
  ) async => throw const AppException('该网盘暂不支持切换存储空间');
  String destinationId(BrowseSession session, String parentId) => parentId;
  Future<List<CloudSpace>> familySpaces(Credential credential) async => [];
  Future<BrowseSession> openFamily(
    CloudSpace space,
    Credential credential,
  ) async => throw const AppException('该网盘暂不支持家庭云');
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  );
  Future<DownloadSpec> download(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  );

  /// Playback may need a different authorization route from queued downloads.
  Future<DownloadSpec> playback(
    BrowseSession session,
    CloudFile file,
    Credential? credential,
  ) => download(session, file, credential);
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async => throw const AppException('该网盘暂不支持新建文件夹');
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async => throw const AppException('该网盘暂不支持上传文件');
  Future<void> rename(BrowseSession s, CloudFile f, String name, Credential c);
  Future<void> move(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  );
  Future<void> delete(BrowseSession s, List<CloudFile> files, Credential c);
  Future<ShareCreation> createShare(
    BrowseSession s,
    List<CloudFile> files,
    ShareOptions options,
    Credential c,
  );
  Future<void> saveShare(
    BrowseSession s,
    List<CloudFile> files,
    String target,
    Credential c,
  );
}
