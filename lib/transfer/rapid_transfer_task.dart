import '../core/json.dart';
import '../domain/models.dart';
import '../domain/baidu_share_route.dart';
import '../domain/public_share_route.dart';

enum RapidTaskStatus {
  pending,
  running,
  completed,
  failed,
  cancelled,
  interrupted,
}

enum RapidEntryStatus {
  pending,
  processing,
  downloading,
  uploading,
  reused,
  uploaded,
  missed,
  noHash,
  duplicate,
  failed,
}

enum CrossTransferMethod { automatic, rapid, relay }

BrowseSession transferSessionReference(BrowseSession s) => BrowseSession(
  platform: s.platform,
  mode: s.mode,
  title: s.title,
  rootId: s.rootId,
  sourceLink: s.sourceLink,
  metadata: {
    ...s.spaceMetadata,
    'accountId': s.accountId ?? '',
    for (final key in [
      BaiduShareRoute.metadataKey,
      PublicShareRoute.metadataKey,
      'parserSiteId',
    ])
      if (s.meta(key).isNotEmpty) key: s.meta(key),
  },
);

class RapidTransferEntry {
  RapidTransferEntry(
    this.file,
    this.path, {
    this.status = RapidEntryStatus.pending,
    this.message = '',
    this.fileId = '',
    this.md5 = '',
    this.submitted = false,
    this.method = CrossTransferMethod.automatic,
    this.transferSize = 0,
    this.downloaded = 0,
    this.sent = 0,
    this.payloadReady = false,
  });
  final CloudFile file;
  final List<String> path;
  RapidEntryStatus status;
  String message, fileId, md5;
  bool submitted, payloadReady;
  CrossTransferMethod method;
  int transferSize, downloaded, sent;
  bool get finished =>
      status != RapidEntryStatus.pending &&
      status != RapidEntryStatus.processing &&
      status != RapidEntryStatus.downloading &&
      status != RapidEntryStatus.uploading;
  bool get succeeded =>
      status == RapidEntryStatus.reused || status == RapidEntryStatus.uploaded;
  int get size => transferSize > 0 ? transferSize : file.size;
  double get progress => finished
      ? 1
      : size <= 0
      ? 0
      : status == RapidEntryStatus.downloading
      ? .5 * (downloaded / size).clamp(0, 1)
      : status == RapidEntryStatus.uploading
      ? .5 + .5 * (sent / size).clamp(0, 1)
      : 0;
  Json toJson() => {
    'file': file.toJson(),
    'path': path,
    'status': status.name,
    'message': message,
    'fileId': fileId,
    'md5': md5,
    'submitted': submitted,
    'method': method.name,
    'transferSize': transferSize,
    'downloaded': downloaded,
    'sent': sent,
    'payloadReady': payloadReady,
  };
  factory RapidTransferEntry.fromJson(Json j) => RapidTransferEntry(
    CloudFile.fromJson(j.obj('file')),
    (j['path'] as List? ?? []).cast<String>(),
    status: RapidEntryStatus.values.firstWhere(
      (s) => s.name == j.str('status'),
      orElse: () => RapidEntryStatus.pending,
    ),
    message: j.str('message'),
    fileId: j.str('fileId'),
    md5: j.str('md5'),
    submitted: j.boolean('submitted'),
    method: CrossTransferMethod.values.firstWhere(
      (m) => m.name == j.str('method'),
      orElse: () => j.str('status') == 'reused'
          ? CrossTransferMethod.rapid
          : CrossTransferMethod.automatic,
    ),
    transferSize: j.integer('transferSize'),
    downloaded: j.integer('downloaded').clamp(0, 1 << 62),
    sent: j.integer('sent').clamp(0, 1 << 62),
    payloadReady: j.boolean('payloadReady'),
  );
}

class RapidTransferTask {
  RapidTransferTask({
    required this.id,
    required this.source,
    required this.target,
    required this.parent,
    required this.folderName,
    required this.selections,
    required this.createdAt,
    this.status = RapidTaskStatus.pending,
    this.scanned = false,
    this.error = '',
    List<RapidTransferEntry>? entries,
    Map<String, String>? directories,
    List<List<String>>? folders,
  }) : entries = entries ?? [],
       directories = directories ?? {},
       folders = folders ?? [];
  final String id, parent, folderName;
  BrowseSession source, target;
  final List<CloudFile> selections;
  final int createdAt;
  RapidTaskStatus status;
  bool scanned;
  int scannedFiles = 0, scannedFolders = 0;
  String error;
  int speed = 0;
  final List<RapidTransferEntry> entries;
  final List<List<String>> folders;
  final Map<String, String> directories;
  bool get active =>
      status == RapidTaskStatus.pending || status == RapidTaskStatus.running;
  int count(RapidEntryStatus status) =>
      entries.where((e) => e.status == status).length;
  int get done => entries.where((e) => e.finished).length;
  int get succeeded => entries.where((e) => e.succeeded).length;
  double? get progress => !scanned || entries.isEmpty
      ? null
      : entries.fold<double>(0, (n, e) => n + e.progress) / entries.length;
  String get methodLabel {
    final rapid = entries.any((e) => e.status == RapidEntryStatus.reused);
    final relay = entries.any((e) => e.method == CrossTransferMethod.relay);
    return rapid && relay
        ? '秒传 + 下载后上传'
        : rapid
        ? '秒传'
        : relay
        ? '下载后上传'
        : '自动判断';
  }

  String get name => selections.length == 1
      ? selections.first.name
      : '${selections.length} 项文件';
  bool get canRetry =>
      !active &&
      (status != RapidTaskStatus.completed ||
          count(RapidEntryStatus.failed) +
                  count(RapidEntryStatus.missed) +
                  count(RapidEntryStatus.noHash) >
              0);
  String get stage => switch (status) {
    RapidTaskStatus.pending => '等待传输',
    RapidTaskStatus.running =>
      !scanned
          ? '正在扫描文件夹'
          : entries.any((e) => e.status == RapidEntryStatus.downloading)
          ? '正在下载'
          : entries.any((e) => e.status == RapidEntryStatus.uploading)
          ? '正在上传'
          : '正在判断秒传',
    RapidTaskStatus.completed => canRetry ? '部分文件待重试' : '传输完成',
    RapidTaskStatus.failed => '传输中断',
    RapidTaskStatus.cancelled => '已取消',
    RapidTaskStatus.interrupted => '等待继续',
  };
  Json toJson() => {
    'id': id,
    'source': transferSessionReference(source).toJson(),
    'target': transferSessionReference(target).toJson(),
    'parent': parent,
    'folderName': folderName,
    'selections': selections.map((f) => f.toJson()).toList(),
    'createdAt': createdAt,
    'status': status.name,
    'scanned': scanned,
    'error': error,
    'entries': entries.map((e) => e.toJson()).toList(),
    'directories': directories,
    'folders': folders,
  };
  factory RapidTransferTask.fromJson(Json j) => RapidTransferTask(
    id: j.str('id'),
    source: BrowseSession.fromJson(j.obj('source')),
    target: BrowseSession.fromJson(j.obj('target')),
    parent: j.str('parent'),
    folderName: j.str('folderName'),
    selections: j.list('selections').map(CloudFile.fromJson).toList(),
    createdAt: j.integer('createdAt'),
    scanned: j.boolean('scanned'),
    error: j.str('error'),
    status: RapidTaskStatus.values.firstWhere(
      (s) => s.name == j.str('status'),
      orElse: () => RapidTaskStatus.interrupted,
    ),
    entries: j.list('entries').map(RapidTransferEntry.fromJson).toList(),
    directories: strings(j['directories']),
    folders: (j['folders'] as List? ?? [])
        .map((p) => (p as List).cast<String>())
        .toList(),
  );
}
