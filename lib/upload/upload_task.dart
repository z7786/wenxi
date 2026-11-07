import '../core/json.dart';
import '../domain/models.dart';
import '../domain/uploads.dart';
import 'upload_folder.dart';

enum UploadStatus {
  pending,
  running,
  completed,
  failed,
  cancelled,
  interrupted,
}

class UploadTask {
  UploadTask({
    required this.id,
    required this.session,
    required this.parent,
    required this.folderName,
    required this.accountName,
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedAt,
    required this.createdAt,
    this.mimeType = 'application/octet-stream',
    this.status = UploadStatus.pending,
    this.phase = UploadPhase.preparing,
    this.sent = 0,
    this.error = '',
    this.fileId = '',
    this.folder,
  }) {
    require(
      folder == null ||
          folder!.size == size &&
              folder!.name == name &&
              folder!.location == path,
      '已保存的上传文件夹信息不一致，请重新选择',
    );
  }

  final String id, parent, folderName, accountName, path, name, mimeType;
  BrowseSession session;
  final int size, modifiedAt, createdAt;
  UploadStatus status;
  UploadPhase phase;
  int sent, speed = 0;
  String error, fileId;
  final UploadFolder? folder;
  bool get isFolder => folder != null;
  bool get active =>
      status == UploadStatus.pending || status == UploadStatus.running;
  bool get canRetry => !active && status != UploadStatus.completed;
  String get stage => switch (status) {
    UploadStatus.pending => '等待上传',
    UploadStatus.completed => '上传完成',
    UploadStatus.failed => '上传失败',
    UploadStatus.cancelled => '已取消',
    UploadStatus.interrupted => '已中断',
    UploadStatus.running => switch (phase) {
      UploadPhase.preparing => isFolder ? '正在准备文件夹' : '正在校验文件',
      UploadPhase.uploading => '正在上传',
      UploadPhase.finishing => '等待网盘确认',
    },
  };

  // Only account/space references are stored; fresh provider sessions are opened
  // when a saved task is retried. No upload tokens or cookies belong in a task.
  Json toJson() => {
    'id': id,
    'session': BrowseSession(
      platform: session.platform,
      mode: BrowseMode.personal,
      title: session.title,
      rootId: session.rootId,
      metadata: {
        ...session.spaceMetadata,
        'accountId': session.accountId ?? '',
      },
    ).toJson(),
    'parent': parent,
    'folderName': folderName,
    'accountName': accountName,
    'path': path,
    'name': name,
    'size': size,
    'modifiedAt': modifiedAt,
    'createdAt': createdAt,
    'mimeType': mimeType,
    'status': status.name,
    'phase': phase.name,
    'sent': sent,
    'error': error,
    'fileId': fileId,
    if (folder != null) 'folder': folder!.toJson(),
  };

  factory UploadTask.fromJson(Json value) => UploadTask(
    id: value.str('id'),
    session: BrowseSession.fromJson(value.obj('session')),
    parent: value.str('parent'),
    folderName: value.str('folderName'),
    accountName: value.str('accountName'),
    path: value.str('path'),
    name: value.str('name'),
    size: value.integer('size'),
    modifiedAt: value.integer('modifiedAt'),
    createdAt: value.integer('createdAt'),
    mimeType: value.str('mimeType', 'application/octet-stream'),
    status: UploadStatus.values.firstWhere(
      (s) => s.name == value.str('status'),
      orElse: () => UploadStatus.interrupted,
    ),
    phase: UploadPhase.values.firstWhere(
      (s) => s.name == value.str('phase'),
      orElse: () => UploadPhase.preparing,
    ),
    sent: value.integer('sent'),
    error: value.str('error'),
    fileId: value.str('fileId'),
    folder: value['folder'] == null
        ? null
        : UploadFolder.fromJson(value.obj('folder')),
  );
}
