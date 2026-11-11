import 'package:flutter/material.dart';
import 'app_switch.dart';
import '../download/download_overlay.dart';
import 'common.dart';

class TransferOverlayControl extends StatelessWidget {
  const TransferOverlayControl(this.overlay, {super.key, this.compact = false});
  final DownloadOverlay overlay;
  final bool compact;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: overlay,
    builder: (context, _) {
      final on = overlay.visible || overlay.pendingPermission;
      if (compact) {
        return Semantics(
          toggled: on,
          child: Tooltip(
            message: overlay.pendingPermission
                ? '继续设置悬浮窗权限'
                : on
                ? '关闭传输悬浮窗'
                : '打开传输悬浮窗',
            child: TextButton.icon(
              key: const Key('transfer-overlay-toggle'),
              onPressed: () => busy(context, overlay.toggle),
              style: TextButton.styleFrom(
                foregroundColor: on
                    ? themeAccent(context)
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                backgroundColor: on
                    ? themeAccent(context).withValues(alpha: .1)
                    : fill(context),
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                  side: BorderSide(
                    color: on
                        ? themeAccent(context).withValues(alpha: .25)
                        : border(context),
                  ),
                ),
                textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              icon: const Icon(Icons.picture_in_picture_alt_rounded, size: 21),
              label: const Text('悬浮窗'),
            ),
          ),
        );
      }
      return Container(
        key: const Key('download-overlay-option'),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: border(context), width: .5)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 5, 12, 5),
        child: Row(
          children: [
            Icon(
              Icons.picture_in_picture_alt_rounded,
              color: themeAccent(context),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('传输悬浮窗', style: TextStyle(fontSize: 13)),
                  Text(
                    overlay.pendingPermission
                        ? '请允许显示在其他应用上层'
                        : '显示下载、上传进度，可缩放或收起为悬浮球',
                    style: TextStyle(fontSize: 11, color: secondary(context)),
                  ),
                ],
              ),
            ),
            AppSwitch(
              value: on,
              onChanged: (_) => busy(context, overlay.toggle),
            ),
          ],
        ),
      );
    },
  );
}
