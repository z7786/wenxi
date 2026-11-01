import 'package:flutter/material.dart';
import '../app_services.dart';
import '../domain/models.dart';
import '../domain/baidu_share_route.dart';
import 'common.dart';

/// Confirm at the user's download action, before collecting or preparing files.
/// Playback and background retries must not ask for this confirmation.
Future<bool> confirmBaiduDownload(
  BuildContext context,
  AppServices services,
  CloudPlatform? platform, {
  BrowseSession? session,
}) async {
  if (!context.mounted) return false;
  if (platform != CloudPlatform.baidu ||
      session != null && BaiduShareRoute.usesPublicParser(session) ||
      services.settings.hideBaiduDownloadNotice) {
    return true;
  }
  // null cancels; false downloads once; true downloads and remembers the choice.
  final hide = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      key: const ValueKey('baidu-download-notice'),
      scrollable: true,
      title: const Text('百度网盘下载提示'),
      content: const Text(
        '百度网盘风控严重，下载存在一定风险可能导致账号被限制，请自行权衡，另外尽量不要一次性下载太多文件易导致下载失败。\n\n'
        '下载单个文件大于 1 GB 时会限速。',
        style: TextStyle(fontSize: 14, height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('不再显示'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('继续下载'),
        ),
      ],
    ),
  );
  if (hide == null || !context.mounted) return false;
  if (hide) {
    try {
      await services.updateSettings({'hideBaiduDownloadNotice': true});
    } catch (error) {
      if (context.mounted) message(context, errorText(error));
    }
  }
  return context.mounted;
}
