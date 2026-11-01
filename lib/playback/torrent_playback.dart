import 'dart:async';
import '../app_services.dart';
import '../core/json.dart';
import '../data/playback_store.dart';
import '../domain/downloads.dart';
import '../domain/file_types.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import '../domain/torrent.dart';
import '../platform/native_engine.dart';
import 'media_backend.dart';
import 'playback_controller.dart';

typedef TorrentBackendFactory =
    PlaybackBackend Function(PlaybackEntry entry, bool hardware);

PlaybackController torrentPlayback(
  AppServices services,
  TorrentInfo info,
  TorrentFile initial, {
  TorrentBackendFactory? backendFactory,
  String? initialHistoryKey,
}) => _playback(
  services,
  info.hash,
  info.data,
  [
    for (final file in info.files)
      if (file.playable && fileKind(file.name) == fileKind(initial.name)) file,
  ],
  initial.index,
  backendFactory,
  initialHistoryKey,
);

PlaybackController torrentDownloadPlayback(
  AppServices services,
  DownloadTask initial, {
  TorrentBackendFactory? backendFactory,
}) {
  final hash = initial.spec.torrent!.str('hash');
  final metadata = services.store.data.obj('torrents').obj(hash);
  final files =
      <int, TorrentFile>{
          for (final task in services.downloads.tasks)
            if (task.spec.torrent?.str('hash') == hash &&
                fileKind(task.spec.fileName) == fileKind(initial.spec.fileName))
              task.spec.torrent!.integer('index'): TorrentFile(
                task.spec.torrent!.integer('index'),
                task.spec.torrent!.str('path').ifEmpty(task.spec.fileName),
                task.total,
              ),
        }.values.where((file) => file.playable).toList()
        ..sort((a, b) => a.index.compareTo(b.index));
  return _playback(
    services,
    hash,
    metadata.str('data'),
    files,
    initial.spec.torrent!.integer('index'),
    backendFactory,
    null,
  );
}

PlaybackController _playback(
  AppServices services,
  String hash,
  String data,
  List<TorrentFile> files,
  int initialIndex,
  TorrentBackendFactory? backendFactory,
  String? initialHistoryKey,
) {
  require(data.startsWith(torrentDataPrefix), '种子信息已丢失，请重新解析 BT 链接');
  final entries = [
    for (final file in files)
      PlaybackEntry(
        id: '${file.index}',
        key: file.index == initialIndex && initialHistoryKey != null
            ? initialHistoryKey
            : playbackKey(['torrent', hash, file.index, file.size]),
        name: file.name,
        video: fileKind(file.name) == FileKind.video,
        torrent: true,
        source: PlaybackSource.torrent(
          hash,
          file,
          torrentData: data,
          torrentFiles: files,
        ),
      ),
  ];
  // The decoder may be rebuilt once. Keep the same verified torrent lease
  // throughout that fallback, just as cloud playback retains its transfer.
  final leases = <String, int>{};
  final releaseQueue = <String, void Function()>{};
  return PlaybackController(
    entries: entries,
    initialIndex: entries.indexWhere((entry) => entry.id == '$initialIndex'),
    history: PlaybackStore(services.store),
    prepare: (entry, scope) async {
      final id = newId();
      try {
        releaseQueue[id] = await services.downloads.prioritizeTorrentPlayback();
        require(!scope.token.isCancelled, '播放已取消');
        final file = files.firstWhere((file) => '${file.index}' == entry.id);
        final result = await services.engine.torrentCall('torrentStreamStart', {
          'id': id,
          'torrentData': data,
          'torrentIndex': file.index,
          'speedLimit': services.settings.speedLimit,
          'btUploadLimit': services.settings.btUploadLimit,
        });
        require(!scope.token.isCancelled, '播放已取消');
        final uri = Uri.tryParse(result.str('url'));
        require(
          uri != null &&
              uri.scheme == 'http' &&
              uri.host == '127.0.0.1' &&
              uri.port > 0 &&
              result.integer('size') == file.size,
          'BT 播放地址无效',
        );
        leases[id] = 1;
        return DownloadSpec(
          url: uri.toString(),
          fileName: file.name,
          expectedSize: file.size,
          torrent: {'hash': hash, 'index': file.index, 'streamId': id},
        );
      } catch (_) {
        try {
          await services.engine.torrentCall('torrentStreamStop', {'id': id});
        } finally {
          releaseQueue.remove(id)?.call();
        }
        rethrow;
      }
    },
    retain: (source) {
      final id = source.torrent!.str('streamId');
      leases[id] = (leases[id] ?? 0) + 1;
    },
    release: (source) async {
      final id = source.torrent!.str('streamId');
      final count = leases[id];
      if (count == null) return;
      if (count > 1) {
        leases[id] = count - 1;
      } else {
        leases.remove(id);
        try {
          await services.engine.torrentCall('torrentStreamStop', {'id': id});
        } finally {
          releaseQueue.remove(id)?.call();
        }
      }
    },
    backendFactory:
        backendFactory ??
        (entry, hardware) => TorrentMediaBackend(
          services.engine,
          video: entry.video,
          hardwareAcceleration: hardware,
        ),
  );
}

class TorrentMediaBackend extends MediaKitBackend {
  TorrentMediaBackend(
    this.engine, {
    required super.video,
    super.hardwareAcceleration,
    super.player,
  });
  final GopeedEngine engine;
  Json _torrentStats = {};

  @override
  Map<String, Object?> get diagnosticFields => {
    ...super.diagnosticFields,
    'torrent': _torrentStats,
  };
  Timer? _timer;
  String _id = '', _description = 'BT · 正在连接做种者…';
  bool _closed = false, _polling = false;
  Future<void>? _closingTorrent;
  @override
  String get streamingDescription => _description;

  Future<void> _poll() async {
    if (_closed || _polling || _id.isEmpty) return;
    _polling = true;
    try {
      final stats = await engine.torrentCall('torrentStreamStatus', {
        'id': _id,
      });
      if (_closed) return;
      _torrentStats = stats;
      final peers = stats.integer('activePeers'),
          seeders = stats.integer('seeders');
      final speed = stats.integer('speed');
      final rate = speed >= 1024 * 1024
          ? '${(speed / 1024 / 1024).toStringAsFixed(1)} MiB/s'
          : '${(speed / 1024).round()} KiB/s';
      _description =
          stats.integer('total') > 0 &&
              stats.integer('downloaded') >= stats.integer('total')
          ? 'BT · 当前文件已缓冲完成'
          : peers == 0 && speed == 0
          ? 'BT · 正在寻找可用节点…'
          : 'BT · $peers 个连接 · $seeders 个做种者 · $rate';
      notifyListeners();
    } catch (_) {
      if (!_closed) {
        _description = 'BT · 等待连接恢复…';
        notifyListeners();
      }
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> open(DownloadSpec source, Duration start) async {
    _id = source.torrent!.str('streamId');
    _timer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_poll()),
    );
    unawaited(_poll());
    await super.open(source, start);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_closed) return;
    if (_id.isNotEmpty) {
      await engine.torrentCall('torrentStreamInterrupt', {'id': _id});
    }
    if (!_closed) await super.seek(position);
  }

  @override
  Future<void> close() => _closingTorrent ??= _closeTorrent();
  Future<void> _closeTorrent() async {
    _closed = true;
    _timer?.cancel();
    try {
      if (_id.isNotEmpty) {
        await engine.torrentCall('torrentStreamInterrupt', {'id': _id});
      }
    } catch (_) {
      // Player disposal remains necessary after a native transport failure.
    }
    await super.close();
  }
}
