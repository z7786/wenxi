import '../core/json.dart';
import 'download_activity.dart';

/// Both queues publish through the same gate. Recompute after earlier native
/// updates finish so an idle download cannot stop an active upload service.
class TransferActivity {
  TransferActivity({
    required this.downloads,
    required this.uploads,
    required this.publish,
    this.lan,
    this.rapid,
  });
  final DownloadActivity Function() downloads, uploads;
  final DownloadActivity Function()? lan;
  final DownloadActivity Function()? rapid;
  final Future<void> Function(Json) publish;
  final _gate = AsyncGate();
  Future<void> sync() => _gate.run(() async {
    final down = downloads(),
        up = uploads(),
        local = lan?.call() ?? const DownloadActivity.idle(),
        matching = rapid?.call() ?? const DownloadActivity.idle();
    final both = down.active > 0 && up.active > 0;
    await publish({
      'active': down.active + up.active + local.active + matching.active,
      'uploads': up.active,
      if (matching.active > 0) 'rapid': matching.active,
      if (local.active > 0) 'lan': local.active,
      'progress': both || local.active > 0 || matching.active > 0
          ? -1
          : up.active > 0
          ? up.progress
          : down.progress,
      'text': [
        if (down.active > 0) '下载 ${down.active} · ${down.text}',
        if (up.active > 0) '上传 ${up.active} · ${up.text}',
        if (local.active > 0) local.text,
        if (matching.active > 0) matching.text,
      ].join('；'),
    });
  });
}
