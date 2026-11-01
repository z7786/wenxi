import '../core/json.dart';
import 'download_retries.dart';
import 'models.dart';

enum DownloadStatus {
  pending('等待中'),
  running('下载中'),
  paused('已暂停'),
  completed('已完成'),
  failed('下载失败'),
  cancelled('已取消');

  const DownloadStatus(this.label);
  final String label;
}

enum DownloadRecoveryAction { none, ucAuthorization }

enum DownloadBatchAction {
  pause('暂停'),
  resume('继续'),
  delete('删除');

  const DownloadBatchAction(this.label);
  final String label;

  bool accepts(DownloadTask task) => switch (this) {
    pause => task.active,
    resume =>
      task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.failed,
    delete => true,
  };
}

class DownloadBatchResult {
  const DownloadBatchResult({
    required this.succeeded,
    required this.skipped,
    required this.failed,
    required this.cancelled,
  });
  final List<String> succeeded, skipped;
  final Map<String, Object> failed;
  final bool cancelled;
}

class RemoteIdentity {
  const RemoteIdentity(this.total, this.etag, this.modified);
  final int total;
  final String? etag, modified;
  String? get strongEtag =>
      etag?.trim().isNotEmpty == true &&
          !etag!.trim().toUpperCase().startsWith('W/')
      ? etag!.trim()
      : null;
  String? get ifRange =>
      strongEtag ??
      (modified?.trim().isNotEmpty == true ? modified!.trim() : null);
  bool canResume(RemoteIdentity next) =>
      total > 0 &&
      total == next.total &&
      (strongEtag != null
          ? strongEtag == next.strongEtag
          : ifRange != null && ifRange == next.ifRange);
  Json toJson() => {'total': total, 'etag': etag, 'modified': modified};
  factory RemoteIdentity.fromJson(Json j) => RemoteIdentity(
    j.integer('total'),
    j['etag'] as String?,
    j['modified'] as String?,
  );
}

class DownloadOrigin {
  const DownloadOrigin(this.session, this.file, this.accountRevision);
  final BrowseSession session;
  final CloudFile file;
  final int? accountRevision;
  Json toJson() => {
    'version': 1,
    'platform': session.platform.key,
    'session': session.toJson(),
    'file': file.toJson(),
    'accountRevision': accountRevision,
  };
  factory DownloadOrigin.fromJson(Json j) {
    require(j.integer('version', 1) == 1, '无法读取此下载的来源');
    final session = j['session'] is Map
        ? j.obj('session')
        : {
            ...j,
            'sourceLink': j['share'] == null
                ? null
                : {
                    ...j.obj('share'),
                    'platform': j['platform'],
                    'kind': 'cloudShare',
                  },
          };
    return DownloadOrigin(
      BrowseSession.fromJson(session),
      CloudFile.fromJson(j.obj('file')),
      j['accountRevision'] == null ? null : j.integer('accountRevision'),
    );
  }
}

class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.spec,
    required this.createdAt,
    this.status = DownloadStatus.pending,
    this.downloaded = 0,
    this.total = 0,
    this.speed = 0,
    this.connections = 64,
    this.retries = defaultDownloadRetries,
    this.speedLimit = 0,
    this.destination,
    this.savedPath,
    this.error = '',
    this.recoveryAction = DownloadRecoveryAction.none,
    this.phase = '',
    this.identity = const RemoteIdentity(0, null, null),
    this.payloadReady = false,
    this.directOutput = false,
    this.hls = const {},
    this.connectionOptions = const {},
  });
  final String id;
  final DownloadSpec spec;
  final int createdAt,
      downloaded,
      total,
      speed,
      connections,
      retries,
      speedLimit;
  final DownloadStatus status;
  final String? destination, savedPath;
  final String error, phase;
  final DownloadRecoveryAction recoveryAction;
  final RemoteIdentity identity;
  final bool payloadReady;
  final bool directOutput;
  final Json hls;
  final Map<String, int> connectionOptions;
  bool get active =>
      status == DownloadStatus.pending || status == DownloadStatus.running;
  bool get terminal =>
      status == DownloadStatus.completed || status == DownloadStatus.cancelled;
  bool get needsUcAuthorization =>
      status == DownloadStatus.failed &&
      spec.platform == CloudPlatform.uc &&
      (recoveryAction == DownloadRecoveryAction.ucAuthorization ||
          // Failed tasks saved before recovery actions were recorded.
          error.contains('TV 播放授权') &&
              (error.contains('UC 返回的内容与所选文件不一致') || error.contains('UC TV')));
  double get progress => total > 0 ? (downloaded / total).clamp(0, 1) : 0;
  Json toJson() => {
    'id': id,
    'spec': spec.toJson(),
    'createdAt': createdAt,
    'status': status.name,
    'downloaded': downloaded,
    'total': total,
    'speed': speed,
    'connections': connections,
    'retries': retries,
    'speedLimit': speedLimit,
    'destination': destination,
    'savedPath': savedPath,
    'error': error,
    if (recoveryAction != DownloadRecoveryAction.none)
      'recoveryAction': recoveryAction.name,
    'phase': phase,
    'identity': identity.toJson(),
    'payloadReady': payloadReady,
    if (directOutput) 'directOutput': true,
    'hls': hls,
    if (connectionOptions.isNotEmpty) 'connectionOptions': connectionOptions,
  };
  factory DownloadTask.fromJson(Json j) => DownloadTask(
    id: j.str('id'),
    spec: DownloadSpec.fromJson(j.obj('spec')),
    createdAt: j.integer('createdAt'),
    status: DownloadStatus.values.firstWhere(
      (v) => v.name == j.str('status'),
      orElse: () => DownloadStatus.paused,
    ),
    downloaded: j.integer('downloaded'),
    total: j.integer('total'),
    speed: j.integer('speed'),
    connections: j.integer('connections', 64).clamp(1, 512),
    retries: j
        .integer('retries', defaultDownloadRetries)
        .clamp(0, maxDownloadRetries),
    speedLimit: j.integer('speedLimit'),
    destination: j['destination'] as String?,
    savedPath: j['savedPath'] as String?,
    error: j.str('error'),
    recoveryAction: DownloadRecoveryAction.values.firstWhere(
      (action) => action.name == j.str('recoveryAction'),
      orElse: () => DownloadRecoveryAction.none,
    ),
    phase: j.str('phase'),
    identity: RemoteIdentity.fromJson(j.obj('identity')),
    payloadReady: j.boolean('payloadReady'),
    directOutput: j.boolean('directOutput'),
    hls: j.obj('hls'),
    connectionOptions: {
      for (final entry in j.obj('connectionOptions').entries)
        entry.key: (int.tryParse('${entry.value}') ?? 64).clamp(1, 512),
    },
  );
  DownloadTask update(Json fields) {
    // Progress arrives several times a second. Keep the unchanged source,
    // headers and checkpoint metadata instead of decoding the whole record.
    if (fields.keys.every(
      const {'downloaded', 'total', 'speed', 'phase'}.contains,
    )) {
      final nextDownloaded = fields.containsKey('downloaded')
          ? fields.integer('downloaded')
          : downloaded;
      final nextTotal = fields.containsKey('total')
          ? fields.integer('total')
          : total;
      final nextSpeed = fields.containsKey('speed')
          ? fields.integer('speed')
          : speed;
      final nextPhase = fields.containsKey('phase')
          ? fields.str('phase')
          : phase;
      if (nextDownloaded == downloaded &&
          nextTotal == total &&
          nextSpeed == speed &&
          nextPhase == phase) {
        return this;
      }
      return DownloadTask(
        id: id,
        spec: spec,
        createdAt: createdAt,
        status: status,
        downloaded: nextDownloaded,
        total: nextTotal,
        speed: nextSpeed,
        connections: connections,
        retries: retries,
        speedLimit: speedLimit,
        destination: destination,
        savedPath: savedPath,
        error: error,
        recoveryAction: recoveryAction,
        phase: nextPhase,
        identity: identity,
        payloadReady: payloadReady,
        directOutput: directOutput,
        hls: hls,
        connectionOptions: connectionOptions,
      );
    }
    return DownloadTask.fromJson({...toJson(), ...fields});
  }
}
