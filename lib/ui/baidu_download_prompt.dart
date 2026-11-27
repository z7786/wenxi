import 'dart:async';
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
  final settings = services.settings;
  if (platform != CloudPlatform.baidu ||
      session != null && BaiduShareRoute.usesPublicParser(session) ||
      settings.hideBaiduDownloadNotice && settings.baiduDownloadNoticeRead) {
    return true;
  }
  // Older opt-outs predate the size warning. Show the updated text once, then
  // keep that preference after the new notice has been read.
  final firstReading = !settings.baiduDownloadNoticeRead;
  var read = !firstReading;
  // null cancels; false downloads once; true downloads and remembers the choice.
  final hide = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _BaiduDownloadNotice(
      waitForReading: firstReading,
      onRead: () => read = true,
    ),
  );
  if (!context.mounted) return false;
  if ((firstReading && read) || hide == true) {
    try {
      await services.updateSettings({
        if (read) 'baiduDownloadNoticeRead': true,
        if (hide == true) 'hideBaiduDownloadNotice': true,
      });
    } catch (error) {
      if (context.mounted) message(context, errorText(error));
    }
  }
  return hide != null && context.mounted;
}

class _BaiduDownloadNotice extends StatefulWidget {
  const _BaiduDownloadNotice({
    required this.waitForReading,
    required this.onRead,
  });

  final bool waitForReading;
  final VoidCallback onRead;

  @override
  State<_BaiduDownloadNotice> createState() => _BaiduDownloadNoticeState();
}

class _BaiduDownloadNoticeState extends State<_BaiduDownloadNotice> {
  late int remaining;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    remaining = widget.waitForReading ? 10 : 0;
    if (remaining > 0) {
      timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        setState(() => remaining--);
        if (remaining == 0) {
          timer.cancel();
          widget.onRead();
        }
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = remaining == 0;
    return PopScope(
      canPop: ready,
      child: AlertDialog(
        key: const ValueKey('baidu-download-notice'),
        scrollable: true,
        title: const Text('百度网盘下载提示'),
        content: const Text(
          '百度网盘风控严重，下载存在一定风险可能导致账号被限制，请自行权衡，另外尽量不要一次性下载太多文件易导致下载失败。'
          '\n\n因不可抗力因素，视频以外，下载 300MB 以上的普通文件会限速。大文件恢复下载时间待定',
          style: TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: ready ? () => Navigator.pop(context) : null,
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: ready ? () => Navigator.pop(context, true) : null,
            child: const Text('不再显示'),
          ),
          FilledButton(
            onPressed: ready ? () => Navigator.pop(context, false) : null,
            child: Text(ready ? '继续下载' : '继续下载（$remaining秒）'),
          ),
        ],
      ),
    );
  }
}
