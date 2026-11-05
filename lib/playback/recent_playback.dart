import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/playback_store.dart';
import '../diagnostics/app_log.dart';
import '../domain/downloads.dart';
import '../domain/file_types.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import '../domain/torrent.dart';
import '../platform/file_access.dart';
import 'media_backend.dart';
import 'playback_backend_factory.dart';
import 'playback_controller.dart';
import 'playback_sources.dart';
import 'torrent_playback.dart';
import 'download_playback.dart';

typedef RecentBackendFactory = PlaybackBackend Function(PlaybackEntry, bool);

Future<PlaybackController> restoreRecentPlayback(
  AppServices services,
  PlaybackRecord record, {
  RecentBackendFactory? backendFactory,
}) async {
  try {
    return await _restoreRecentPlayback(
      services,
      record,
      backendFactory: backendFactory,
    );
  } catch (error, stack) {
    if (RequestScope.current?.isCancelled != true) {
      DiagnosticLog.error(
        'player.restore_failed',
        error,
        stack,
        fields: {
          'playback': DiagnosticLog.reference(record.key),
          'stage': 'restore',
          'sourceKind': record.source?.kind.name ?? 'legacy',
          'platform': record.source?.cloud?.session.platform.key,
        },
      );
    }
    rethrow;
  }
}

Future<PlaybackController> _restoreRecentPlayback(
  AppServices services,
  PlaybackRecord record, {
  RecentBackendFactory? backendFactory,
}) async {
  final source = record.source;
  require(source != null, '这条旧记录没有保存播放来源，请从原文件列表打开一次');
  RequestScope.checkpoint();
  switch (source!.kind) {
    case PlaybackSourceKind.download:
      final task = services.downloads.task(source.downloadId);
      require(task != null, '下载任务已删除，请重新添加下载');
      return downloadPlayback(
        services,
        task!,
        backendFactory: backendFactory,
        initialHistoryKey: record.key,
      );
    case PlaybackSourceKind.cloud:
      final restored = await services.cloud.restoreOrigin(source.cloud!);
      RequestScope.checkpoint();
      return cloudPlayback(
        services,
        restored.session,
        restored.file,
        restored.siblings,
        initialHistoryKey: record.key,
        backendFactory: backendFactory,
      );
    case PlaybackSourceKind.local:
      await _checkFile(services, source.path);
      RequestScope.checkpoint();
      final kind = fileKind(record.name);
      final entries = <String, PlaybackEntry>{
        for (final task in services.downloads.tasks)
          if (task.status == DownloadStatus.completed &&
              task.savedPath?.isNotEmpty == true &&
              fileKind(task.spec.fileName) == kind)
            task.savedPath!: PlaybackEntry(
              id: task.savedPath!,
              key: playbackKey([
                'download',
                task.id,
                task.savedPath,
                task.total,
              ]),
              name: task.spec.fileName,
              video: kind == FileKind.video,
              source: PlaybackSource.local(
                path: task.savedPath!,
                downloadId: task.id,
                size: task.total,
              ),
            ),
        source.path: PlaybackEntry(
          id: source.path,
          key: record.key,
          name: record.name,
          video: kind == FileKind.video,
          source: source,
        ),
      }.values.toList();
      return PlaybackController(
        entries: entries,
        initialIndex: entries.indexWhere((entry) => entry.id == source.path),
        history: PlaybackStore(services.store),
        prepare: (entry, scope) => scope.run(() async {
          await _checkFile(services, entry.source!.path);
          RequestScope.checkpoint();
          return DownloadSpec(url: entry.source!.path, fileName: entry.name);
        }),
        retain: (_) {},
        release: (_) async {},
        backendFactory:
            backendFactory ??
            (entry, hardware) => createPlaybackBackend(
              video: entry.video,
              hardwareAcceleration: hardware,
            ),
      );
    case PlaybackSourceKind.torrent:
      final cache = services.store.data.obj('playbackTorrents');
      final data = source.torrentData.isNotEmpty
          ? <String, dynamic>{
              'hash': source.torrentHash,
              'data': source.torrentData,
              'files': [
                for (final file in source.torrentFiles)
                  {'index': file.index, 'path': file.path, 'size': file.size},
              ],
            }
          : cache.obj(source.torrentHash).isNotEmpty
          ? cache.obj(source.torrentHash)
          : services.store.data.obj('torrents').obj(source.torrentHash);
      final raw = data.str('data');
      require(
        raw.startsWith(torrentDataPrefix) &&
            raw.length <= maxTorrentBytes * 4 ~/ 3 + 100,
        '这条记录的种子信息已失效，请重新解析原磁力链接或种子',
      );
      final files = data.list('files').map(TorrentFile.fromJson).toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      final selected = files
          .where((file) => file.index == source.torrentIndex)
          .firstOrNull;
      require(
        data.str('hash') == source.torrentHash &&
            selected != null &&
            selected.path == source.path &&
            selected.size == source.size &&
            selected.playable,
        '种子中的视频信息已变化，请重新选择文件',
      );
      RequestScope.checkpoint();
      return torrentPlayback(
        services,
        TorrentInfo(source.torrentHash, record.name, raw, files),
        selected!,
        backendFactory: backendFactory,
        initialHistoryKey: record.key,
      );
  }
}

Future<void> _checkFile(AppServices services, String path) async {
  final availability = await services.files.inspect(path);
  require(
    availability == FileAvailability.present,
    availability == FileAvailability.missing
        ? '本地文件不存在或已被移动，可移除这条播放记录'
        : '无法访问本地文件，请检查文件或目录权限',
  );
}
