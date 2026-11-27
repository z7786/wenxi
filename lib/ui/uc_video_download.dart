import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/downloads.dart';
import '../domain/uc_video_download.dart';
import '../domain/public_share_route.dart';
import 'common.dart';
import 'download_location_picker.dart';

bool canDownloadUcPlayable(BrowseSession session, CloudFile file) =>
    session.platform == CloudPlatform.uc &&
    !PublicShareRoute.uses(session) &&
    !file.isDirectory &&
    fileKind(file.name) == FileKind.video;

bool canRecoverUcPlayable(DownloadTask task) =>
    task.status == DownloadStatus.failed &&
    task.spec.source != null &&
    task.spec.platform == CloudPlatform.uc &&
    !task.spec.source!.containsKey('ucVideo') &&
    fileKind(asJson(task.spec.source!['file']).str('name')) == FileKind.video;

Future<void> downloadUcPlayable(
  BuildContext context,
  AppServices services, {
  BrowseSession? session,
  CloudFile? file,
  DownloadOrigin? origin,
}) async {
  DownloadSpec? prepared;
  var queued = false;
  try {
    final result = await busy(context, () async {
      if (origin != null) {
        final restored = await services.cloud.restoreOrigin(origin);
        session = restored.session;
        file = restored.file;
      }
      require(session != null && file != null, '视频来源信息不完整，请重新打开文件列表');
      prepared = await services.cloud.prepareUcPlayable(session!, file!);
      return prepared;
    }, label: '正在获取可播放版本…');
    if (result == null || !context.mounted) return;
    final boundSession = DownloadOrigin.fromJson(result.source!).session;
    final quality = UcVideoDownload.fromSpec(result)!;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('下载可播放版本'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                result.fileName,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              Text(
                '画质：${quality.label}\n分辨率：${quality.dimensions}\n大小：${formatBytes(quality.size)}',
                style: const TextStyle(height: 1.8),
              ),
              const SizedBox(height: 12),
              const Text('这是 UC 提供的转码视频，画质可能低于原文件。文件名会标注画质和分辨率。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            key: const Key('uc-playable-confirm'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(CupertinoIcons.arrow_down),
            label: Text('下载${quality.label}版本'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    final location = await chooseDownloadLocation(context, services);
    if (location == null || !context.mounted) return;
    await busy(
      context,
      () => services.cloud.withSession(boundSession, () async {
        require(
          services.cloud.vault.credential(CloudPlatform.uc)?.updatedAt ==
              result.source!['accountRevision'],
          'UC 账号已变化，请重新选择视频',
        );
        await services.downloads.enqueue(result, location: location);
        queued = true;
      }),
      label: '正在添加下载任务…',
    );
    if (queued && context.mounted) {
      message(
        context,
        '已添加${quality.label}视频下载',
        onTap: services.requestDownloadManager,
      );
    }
  } finally {
    if (!queued && prepared != null) {
      await services.cleanups.release(prepared!.cleanup);
      await services.cleanups.ready(prepared!.cleanup);
      unawaited(services.cleanups.drain());
    }
  }
}
