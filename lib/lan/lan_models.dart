import 'dart:io';
import 'package:path/path.dart' as p;
import '../core/json.dart';
import '../domain/models.dart';
import '../platform/file_access.dart';

const lanProtocol = 'wenxi-lan-1';
const lanHttpPort = 52381;
const lanDiscoveryPort = 52380;
const lanMaxFiles = 10000;
const lanMaxMessageLength = 32768;

String lanId() => newId().replaceAll('-', '');

bool isLanAddress(String value) {
  final address = InternetAddress.tryParse(value);
  if (address == null || address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 10 ||
      b[0] == 127 ||
      b[0] == 100 && b[1] >= 64 && b[1] <= 127 ||
      b[0] == 192 && b[1] == 168 ||
      b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
      b[0] == 169 && b[1] == 254;
}

Uri lanAddress(String value) {
  final text = value.trim();
  final uri = Uri.tryParse(text.contains('://') ? text : 'http://$text');
  require(
    uri != null &&
        uri.scheme == 'http' &&
        isLanAddress(uri.host) &&
        uri.userInfo.isEmpty &&
        uri.port > 0 &&
        uri.port <= 65535,
    '请输入同一局域网设备的 HTTP 地址，例如 http://192.168.1.8:52381',
  );
  return uri!;
}

String lanRelativePath(String value) {
  final parts = value.split('/');
  require(
    value.isNotEmpty &&
        value.length <= 2048 &&
        parts.length <= 64 &&
        parts.every(
          (part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              safeFileName(part) == part,
        ),
    '分享包含无效文件名或目录',
  );
  return value;
}

class LanPeer {
  const LanPeer({
    required this.id,
    required this.name,
    required this.address,
    required this.port,
    required this.lastSeen,
  });
  final String id, name, address;
  final int port;
  final DateTime lastSeen;
  Uri get base => Uri(scheme: 'http', host: address, port: port);
  factory LanPeer.fromJson(Json data, String address, DateTime now) {
    require(data.str('protocol') == lanProtocol, '对方不是兼容的文析助手设备');
    require(isLanAddress(address), '设备不在局域网内');
    final id = data.str('id'), name = data.str('name');
    final port = data.integer('port');
    require(
      RegExp(r'^[a-f0-9]{32}$').hasMatch(id) &&
          name.isNotEmpty &&
          name.length <= 64 &&
          !RegExp(r'[\x00-\x1f]').hasMatch(name) &&
          port > 0 &&
          port <= 65535,
      '设备信息无效',
    );
    return LanPeer(
      id: id,
      name: name,
      address: address,
      port: port,
      lastSeen: now,
    );
  }
}

class LanFileEntry {
  const LanFileEntry({
    required this.id,
    required this.path,
    required this.size,
    required this.sha256,
  });
  final String id, path, sha256;
  final int size;
  String get name => p.posix.basename(path);
  String get directory =>
      p.posix.dirname(path) == '.' ? '' : p.posix.dirname(path);
  Json toJson() => {'id': id, 'path': path, 'size': size, 'sha256': sha256};
  factory LanFileEntry.fromJson(Json data) {
    final id = data.str('id'), hash = data.str('sha256');
    final size = data.integer('size', -1);
    require(
      RegExp(r'^[a-f0-9]{32}$').hasMatch(id) &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) &&
          size >= 0 &&
          size <= 16 * 1024 * 1024 * 1024 * 1024,
      '分享文件信息无效',
    );
    return LanFileEntry(
      id: id,
      path: lanRelativePath(data.str('path')),
      size: size,
      sha256: hash,
    );
  }
}

class LanManifest {
  const LanManifest({
    required this.token,
    required this.name,
    required this.files,
    this.directories = const [],
    this.expiresAt,
  });
  final String token, name;
  final List<LanFileEntry> files;
  final List<String> directories;
  final DateTime? expiresAt;
  int get size => files.fold(0, (sum, file) => sum + file.size);
  bool get singleFile => files.length == 1 && directories.isEmpty;
  Json toJson() => {
    'protocol': lanProtocol,
    'token': token,
    'name': name,
    'files': files.map((f) => f.toJson()).toList(),
    'directories': directories,
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
  };
  factory LanManifest.fromJson(Json data) {
    final token = data.str('token'), name = data.str('name');
    require(
      data.str('protocol') == lanProtocol &&
          RegExp(r'^[a-f0-9]{32}$').hasMatch(token) &&
          name.isNotEmpty &&
          name.length <= 180 &&
          data['files'] is List &&
          data['directories'] is List,
      '分享信息无效或版本不兼容',
    );
    final rawFiles = data['files'] as List,
        rawDirectories = data['directories'] as List;
    require(
      rawFiles.length <= lanMaxFiles && rawDirectories.length <= lanMaxFiles,
      '分享文件数量过多',
    );
    final files = rawFiles
        .map((f) => LanFileEntry.fromJson(asJson(f)))
        .toList();
    final directories = rawDirectories
        .map((d) => lanRelativePath('$d'))
        .toList();
    final paths = <String>{}, ids = <String>{};
    for (final directory in directories) {
      require(paths.add(directory.toLowerCase()), '分享包含重复目录');
    }
    for (final file in files) {
      require(
        paths.add(file.path.toLowerCase()) && ids.add(file.id),
        '分享包含重复文件',
      );
    }
    final filePaths = files.map((f) => f.path.toLowerCase()).toSet();
    for (final path in paths) {
      var parent = p.posix.dirname(path);
      while (parent != '.') {
        require(!filePaths.contains(parent), '分享文件和目录名称冲突');
        parent = p.posix.dirname(parent);
      }
    }
    require(files.isNotEmpty || directories.isNotEmpty, '分享没有文件');
    return LanManifest(
      token: token,
      name: name,
      files: List.unmodifiable(files),
      directories: List.unmodifiable(directories),
      expiresAt: data['expiresAt'] is num
          ? DateTime.fromMillisecondsSinceEpoch(data.integer('expiresAt'))
          : null,
    );
  }

  List<DownloadSpec> downloads(Uri origin) {
    lanAddress(origin.toString());
    final transferId = lanId();
    return [
      for (final file in files)
        DownloadSpec(
          url: origin
              .replace(
                path: '/v1/files/$token/${file.id}',
                queryParameters: {'transfer': transferId},
                fragment: '',
              )
              .toString(),
          fileName: file.name,
          relativePath: file.directory,
          expectedSize: file.size,
          checksumType: 'sha256',
          checksumValue: file.sha256,
          profile: 'lan',
        ),
    ];
  }
}

class LanShareSummary {
  const LanShareSummary({
    required this.token,
    required this.name,
    required this.fileCount,
    required this.size,
  });
  final String token, name;
  final int fileCount, size;
  factory LanShareSummary.fromJson(Json data) {
    final token = data.str('token'), name = data.str('name');
    final count = data.integer('fileCount'), size = data.integer('size');
    require(
      RegExp(r'^[a-f0-9]{32}$').hasMatch(token) &&
          name.isNotEmpty &&
          name.length <= 180 &&
          count >= 0 &&
          count <= lanMaxFiles &&
          size >= 0,
      '分享列表格式无效',
    );
    return LanShareSummary(
      token: token,
      name: name,
      fileCount: count,
      size: size,
    );
  }
}

class LanInboxItem {
  const LanInboxItem({
    required this.id,
    required this.sender,
    required this.kind,
    required this.value,
    required this.createdAt,
    this.senderId = '',
    this.read = false,
  });
  final String id, sender, kind, value, senderId;
  final int createdAt;
  final bool read;
  Json toJson() => {
    'id': id,
    'sender': sender,
    if (senderId.isNotEmpty) 'senderId': senderId,
    'kind': kind,
    'value': value,
    'createdAt': createdAt,
    'read': read,
  };
  factory LanInboxItem.fromJson(Json data) => LanInboxItem(
    id: data.str('id'),
    sender: data.str('sender'),
    senderId: data.str('senderId'),
    kind: data.str('kind'),
    value: data.str('value'),
    createdAt: data.integer('createdAt'),
    read: data.boolean('read'),
  );
}

/// One HTTP byte range, with an exclusive end to match File.openRead.
(int, int)? lanByteRange(String? header, int size) {
  if (header == null) return null;
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null || size <= 0) throw const HttpException('Invalid Range');
  final left = match[1]!, right = match[2]!;
  if (left.isEmpty) {
    final suffix = int.tryParse(right) ?? 0;
    if (suffix <= 0) throw const HttpException('Invalid Range');
    return ((size - suffix).clamp(0, size), size);
  }
  final start = int.tryParse(left),
      last = right.isEmpty ? size - 1 : int.tryParse(right);
  if (start == null || last == null || start >= size || last < start) {
    throw const HttpException('Invalid Range');
  }
  return (start, (last + 1).clamp(0, size));
}
