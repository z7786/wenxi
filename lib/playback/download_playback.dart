import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/playback_store.dart';
import '../domain/downloads.dart';
import '../domain/file_types.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import '../download/download_playback_cache.dart';
import '../download/download_manager.dart';
import 'media_backend.dart';
import 'delegating_backend.dart';
import 'playback_backend_factory.dart';
import 'playback_controller.dart';
import 'playback_sources.dart';
import 'playback_screen_info.dart';

PlaybackController downloadPlayback(
  AppServices services,
  DownloadTask initial, {
  PlaybackBackend Function(PlaybackEntry, bool)? backendFactory,
  String? initialHistoryKey,
}) {
  final current = services.downloads.task(initial.id);
  require(current != null, '下载任务已删除，请重新添加下载');
  if (current!.status == DownloadStatus.completed) {
    return downloadedPlayback(
      services,
      current,
      services.downloads.tasks,
      initialHistoryKey: initialHistoryKey,
      backendFactory: backendFactory,
    );
  }
  require(services.downloads.canStream(current), '此文件暂不支持边下边播');
  final entries = [
    PlaybackEntry(
      id: current.id,
      key: initialHistoryKey ?? playbackKey(['download-stream', current.id]),
      name: current.spec.fileName,
      video: fileKind(current.spec.fileName) == FileKind.video,
      source: PlaybackSource.download(current.id, size: current.total),
    ),
  ];
  final leases = <DownloadSpec, ({DownloadPlaybackCache cache, int count})>{};

  Future<DownloadSpec> prepare(
    PlaybackEntry entry,
    RequestScope scope, {
    bool refresh = false,
  }) => scope.run(() async {
    final cache = await services.downloads.acquirePlayback(
      entry.id,
      refresh: refresh,
    );
    if (scope.token.isCancelled) {
      await cache.release();
      throw const AppException('已取消播放');
    }
    leases[cache.source] = (cache: cache, count: 1);
    return cache.source;
  });

  return PlaybackController(
    entries: entries,
    initialIndex: 0,
    history: PlaybackStore(services.store),
    prepare: prepare,
    refresh: (entry, scope) => prepare(entry, scope, refresh: true),
    retain: (source) {
      final lease = leases[source];
      if (lease != null) {
        leases[source] = (cache: lease.cache, count: lease.count + 1);
      }
    },
    release: (source) async {
      final lease = leases[source];
      if (lease == null) return;
      if (lease.count > 1) {
        leases[source] = (cache: lease.cache, count: lease.count - 1);
      } else {
        leases.remove(source);
        await lease.cache.release();
      }
    },
    backendFactory:
        backendFactory ??
        (entry, hardware) => DownloadMediaBackend(
          services.downloads,
          entry.id,
          video: entry.video,
          hardwareAcceleration: hardware,
          downloadCache: (source, start, end, identity) async {
            final lease = leases[source];
            require(lease != null, '播放已结束');
            return lease!.cache.readAvailable(start, end, identity);
          },
          downloadSnapshot: (source) async => leases[source]?.cache.snapshot(),
        ),
  );
}

class DownloadMediaBackend extends DelegatingPlaybackBackend {
  DownloadMediaBackend(
    this.downloads,
    this.downloadId, {
    required bool video,
    bool hardwareAcceleration = true,
    PlaybackCacheReader? downloadCache,
    PlaybackCacheSnapshot? downloadSnapshot,
  }) : super(
         createPlaybackBackend(
           video: video,
           hardwareAcceleration: hardwareAcceleration,
           downloadCache: downloadCache,
           downloadSnapshot: downloadSnapshot,
         ),
       ) {
    downloads.addListener(_downloadChanged);
  }
  final DownloadManager downloads;
  final String downloadId;
  bool _watching = true;
  void _downloadChanged() {
    if (_watching) notifyListeners();
  }

  @override
  String get streamingDescription {
    final task = downloads.task(downloadId);
    if (task == null) return '下载任务已移除';
    if (task.status == DownloadStatus.completed) return '边下边播 · 文件已下载完成';
    final progress = task.total > 0
        ? ' ${(task.progress * 100).toStringAsFixed(1)}%'
        : '';
    return '边下边播 · ${task.status.label}$progress';
  }

  @override
  PlaybackScreenInfo get screenInfo => delegate.screenInfo.withNetworkSpeed(
    downloads.task(downloadId)?.speed.toDouble(),
  );

  @override
  Future<void> close() {
    if (_watching) {
      _watching = false;
      downloads.removeListener(_downloadChanged);
    }
    return super.close();
  }
}
