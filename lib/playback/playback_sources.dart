import 'dart:io';
import 'package:path/path.dart' as p;
import '../app_services.dart';
import '../core/json.dart';
import '../diagnostics/app_log.dart';
import '../data/playback_store.dart';
import '../data/http.dart';
import '../data/resource_pool_preview.dart';
import '../domain/downloads.dart';
import '../domain/file_types.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../domain/playback_source.dart';
import '../platform/file_access.dart';
import 'media_backend.dart';
import 'playback_backend_factory.dart';
import 'playback_controller.dart';
import 'subtitle_files.dart';
import 'subtitle_matching.dart';

PlaybackController cloudPlayback(
  AppServices services,
  BrowseSession session,
  CloudFile initial,
  List<CloudFile> candidates, {
  String? initialHistoryKey,
  Map<String, String> parentFolders = const {},
  ResourcePoolPreview? poolPreview,
  PoolPreviewTarget? initialPoolTarget,
  List<String> sourceFolders = const [],
  PlaybackBackend Function(PlaybackEntry, bool)? backendFactory,
}) {
  session = services.cloud.bindSession(session);
  final revision = services.cloud.sessionCredential(session)?.updatedAt;
  final kind = fileKind(initial.name);
  CloudFile withParent(CloudFile file, String? parent) =>
      parent == null || parent == file.parentId
      ? file
      : CloudFile.fromJson({...file.toJson(), 'parentId': parent});
  final files = <String, CloudFile>{
    for (final file in candidates)
      if (!file.isDirectory && fileKind(file.name) == kind) file.id: file,
    initial.id: initial,
  };
  for (final file in List.of(files.values)) {
    files[file.id] = withParent(file, parentFolders[file.id]);
  }
  final entries = [
    for (final file in files.values)
      PlaybackEntry(
        id: file.id,
        key: file.id == initial.id && initialHistoryKey != null
            ? initialHistoryKey
            : cloudPlaybackKey(session, file, revision),
        name: file.name,
        video: kind == FileKind.video,
        platform: session.platform,
        source: PlaybackSource.cloud(DownloadOrigin(session, file, revision)),
      ),
  ];
  final subtitleFiles = {
    for (final file in candidates)
      if (!file.isDirectory &&
          file.size <= SubtitleFiles.maximumBytes &&
          SubtitleFiles.extensions.contains(
            p.extension(file.name).toLowerCase().replaceFirst('.', ''),
          ))
        file.id: withParent(file, parentFolders[file.id]),
  };
  void checkAccount() => require(
    services.cloud.sessionCredential(session)?.updatedAt == revision,
    '账号已变化，请重新打开文件列表',
  );
  String? startedEntry;
  var firstPoolTarget = initialPoolTarget;
  Future<DownloadSpec> source(
    PlaybackEntry entry,
    RequestScope scope, {
    bool refresh = false,
    bool download = false,
  }) => scope.run(() async {
    checkAccount();
    final continuing = startedEntry == entry.id;
    if (!continuing) {
      startedEntry = null;
      services.control.checkCloud(session.platform);
    }
    final origin = DownloadOrigin(session, files[entry.id]!, revision);
    final DownloadSpec result;
    if (poolPreview != null) {
      // The pool exposes one transferred file per share. Keep the original
      // directory in history/episodes and resolve only the selected file.
      var target = entry.id == initial.id && !refresh ? firstPoolTarget : null;
      firstPoolTarget = null;
      target ??= await poolPreview.resolve(
        session,
        files[entry.id]!,
        sourceFolders,
        scope,
        sourceParentId: files[entry.id]!.parentId,
      );
      checkAccount();
      RequestScope.checkpoint();
      result =
          await (download
              ? services.cloud.prepare
              : services.cloud.preparePlayback)(
            target.session,
            withParent(target.file, target.parentId),
          );
    } else if (continuing) {
      result = refresh
          ? await services.cloud.refreshPlayback(origin)
          : await services.cloud.continuePlayback(session, files[entry.id]!);
    } else if (refresh) {
      final restored = await services.cloud.restoreOrigin(origin);
      result = await services.cloud.preparePlayback(
        restored.session,
        restored.file,
      );
    } else {
      result = await services.cloud.preparePlayback(session, files[entry.id]!);
    }
    return result;
  });
  return PlaybackController(
    entries: entries,
    initialIndex: entries.indexWhere((entry) => entry.id == initial.id),
    history: PlaybackStore(services.store),
    checkSource: checkAccount,
    checkDownload: () => services.control.checkCloud(session.platform),
    prepare: source,
    sourceAccepted: (entry) => startedEntry = entry.id,
    checkAhead: () => services.control.checkCloud(session.platform),
    prepareAhead: poolPreview != null
        ? null
        : (entry, scope) => scope.run(() async {
            checkAccount();
            services.control.checkCloud(session.platform);
            return services.cloud.preparePlayback(session, files[entry.id]!);
          }),
    prepareDownload: poolPreview != null
        ? (entry, scope) => source(entry, scope, download: true)
        : {
                CloudPlatform.baidu,
                CloudPlatform.uc,
                CloudPlatform.aliyun,
              }.contains(session.platform) &&
              kind == FileKind.video
        ? (entry, scope) async {
            checkAccount();
            return scope.run(
              () => services.cloud.prepare(session, files[entry.id]!),
            );
          }
        : null,
    refresh: (entry, scope) => source(entry, scope, refresh: true),
    subtitlesFor: (entry) => [
      for (final subtitle in subtitleFiles.values)
        if (subtitle.parentId.isEmpty ||
            files[entry.id]!.parentId.isEmpty ||
            subtitle.parentId == files[entry.id]!.parentId)
          PlaybackSubtitle(subtitle.id, subtitle.name),
    ],
    readSubtitle: (entry, subtitle, scope) => scope.run(() async {
      checkAccount();
      DownloadSpec? source;
      File? staged;
      try {
        source = await services.cloud.prepare(
          session,
          subtitleFiles[subtitle.id]!,
        );
        checkAccount();
        RequestScope.checkpoint();
        final bytes = await services.transfer.limited(
          source.url,
          source.headers,
          SubtitleFiles.maximumBytes,
        );
        RequestScope.checkpoint();
        checkAccount();
        staged = await SubtitleFiles(
          Directory(p.join(services.cacheDirectory.path, 'subtitles')),
        ).stage(subtitle.name, Stream.value(bytes));
        RequestScope.checkpoint();
        checkAccount();
        final result = staged;
        staged = null;
        return result;
      } finally {
        if (staged != null && await staged.exists()) await staged.delete();
        if (source != null) {
          try {
            await services.cleanups.release(source.cleanup);
            await services.cleanups.ready(source.cleanup);
            await services.cleanups.drain();
          } catch (error, stack) {
            DiagnosticLog.error(
              'player.subtitle_cleanup',
              error,
              stack,
              fields: {'platform': session.platform.key},
            );
          }
        }
      }
    }),
    retain: (source) => services.cleanups.retain(source.cleanup),
    release: (source) async {
      await services.cleanups.release(source.cleanup);
      await services.cleanups.ready(source.cleanup);
      await services.cleanups.drain();
    },
    backendFactory:
        backendFactory ??
        (entry, hardware) => createPlaybackBackend(
          video: entry.video,
          hardwareAcceleration: hardware,
        ),
  );
}

PlaybackController downloadedPlayback(
  AppServices services,
  DownloadTask initial,
  List<DownloadTask> candidates, {
  String? initialHistoryKey,
  PlaybackBackend Function(PlaybackEntry, bool)? backendFactory,
}) {
  final kind = fileKind(initial.spec.fileName);
  final tasks = <String, DownloadTask>{
    for (final task in candidates)
      if (task.status == DownloadStatus.completed &&
          task.savedPath != null &&
          fileKind(task.spec.fileName) == kind)
        task.id: task,
    initial.id: initial,
  };
  final entries = [
    for (final task in tasks.values)
      PlaybackEntry(
        id: task.id,
        key: task.id == initial.id && initialHistoryKey != null
            ? initialHistoryKey
            : playbackKey(['download', task.id, task.savedPath, task.total]),
        name: task.spec.fileName,
        video: kind == FileKind.video,
        source: PlaybackSource.local(
          path: task.savedPath ?? '',
          downloadId: task.id,
          size: task.total,
        ),
      ),
  ];
  return PlaybackController(
    entries: entries,
    initialIndex: entries.indexWhere((entry) => entry.id == initial.id),
    history: PlaybackStore(services.store),
    prepare: (entry, _) => downloadedSource(services, tasks[entry.id]!),
    retain: (_) {},
    release: (_) async {},
    backendFactory:
        backendFactory ??
        (entry, hardware) => createPlaybackBackend(
          video: entry.video,
          hardwareAcceleration: hardware,
        ),
  );
}

Future<DownloadSpec> downloadedSource(
  AppServices services,
  DownloadTask task,
) async {
  require(task.savedPath?.isNotEmpty == true, '文件位置已失效');
  final availability = await services.downloads.files.inspect(task.savedPath);
  RequestScope.checkpoint();
  require(
    availability == FileAvailability.present,
    availability == FileAvailability.missing ? '文件不存在或已被移动' : '无法访问文件，请检查目录权限',
  );
  return DownloadSpec(url: task.savedPath!, fileName: task.spec.fileName);
}
