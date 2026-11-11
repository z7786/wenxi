import 'dart:async';
import 'dart:math' as math;
import '../diagnostics/app_log.dart';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/json.dart';
import '../core/operation_progress.dart';
import '../data/http.dart';
import '../data/remote_control_service.dart';
import '../domain/models.dart';
import '../domain/file_types.dart';
import '../download/mobile_data_download_guard.dart';
import 'operation_progress_view.dart';
import 'app_theme.dart';
import 'desktop_mouse_back.dart';
export '../domain/file_types.dart';
export '../download/mobile_data_download_guard.dart'
    show DownloadConfirmationCancelled;
export 'app_theme.dart' show themeAccent, themeCompanion, themeOnAccent;
export 'app_background.dart' show backgroundSurface, BackgroundReadable;

Color secondary(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;
Color fill(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerLow;
Color border(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant;

String formatBytes(num bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble(), unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 2)} ${units[unit]}';
}

String formatDate(int stamp) {
  if (stamp <= 0) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(stamp);
  String two(int n) => '$n'.padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}

String errorText(Object error) => error is AppException
    ? error.message
    : error is FileSystemException
    ? '文件读写失败，请检查目录权限和可用空间'
    : '操作失败，请稍后重试';
void message(BuildContext context, String text, {VoidCallback? onTap}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final theme = Theme.of(context);
  final screenWidth = MediaQuery.sizeOf(context).width;
  // Use one inset for phone and desktop so a custom-width snackbar does not
  // silently fall back to Flutter's lower default margin on large screens.
  final horizontalMargin = math.max(16.0, (screenWidth - 520) / 2);
  final accent = theme.colorScheme.primary;
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: theme.colorScheme.surface,
      elevation: 4,
      margin: EdgeInsets.fromLTRB(horizontalMargin, 0, horizontalMargin, 28),
      padding: EdgeInsets.zero,
      duration: Duration(seconds: onTap == null ? 4 : 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: border(context), width: .7),
      ),
      clipBehavior: Clip.antiAlias,
      content: Semantics(
        button: onTap != null,
        hint: onTap == null ? null : '打开下载管理',
        child: InkWell(
          onTap: onTap == null
              ? null
              : () {
                  messenger.removeCurrentSnackBar();
                  onTap();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  onTap == null
                      ? CupertinoIcons.info_circle
                      : CupertinoIcons.checkmark_circle_fill,
                  size: 22,
                  color: accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (onTap != null) ...[
                  const SizedBox(width: 8),
                  Icon(CupertinoIcons.chevron_right, size: 17, color: accent),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

bool allowCloudAction(
  BuildContext context,
  RemoteControlService control,
  CloudPlatform platform,
) {
  if (control.cloudEnabled(platform)) return true;
  message(context, control.config.cloud(platform).reason(platform));
  return false;
}

Future<T?> busy<T>(
  BuildContext context,
  Future<T> Function() action, {
  String label = '正在处理…',
}) async {
  final navigator = Navigator.of(context, rootNavigator: true),
      scope = RequestScope(),
      progress = OperationProgress();
  var cancelled = false;
  final operationClock = Stopwatch()..start();
  DiagnosticLog.event('ui.operation_start', fields: {'operation': label});
  late final DialogRoute<void> route;
  route = DialogRoute(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        constraints: const BoxConstraints(maxWidth: 400),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 360,
            maxHeight: MediaQuery.sizeOf(context).height * .55,
          ),
          child: SizedBox(
            width: 352,
            child: SingleChildScrollView(
              child: OperationProgressView(progress: progress, label: label),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              progress.close(cancelled: true);
              scope.cancel();
              navigator.removeRoute(route);
            },
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );
  unawaited(route.completed.then((_) => progress.dispose()));
  unawaited(navigator.push(route));
  try {
    final value = await scope.run(() => progress.run(action));
    return cancelled ? null : value;
  } on DownloadConfirmationCancelled {
    cancelled = true;
    progress.close(cancelled: true);
    return null;
  } catch (e, stack) {
    if (!cancelled) {
      DiagnosticLog.error(
        'ui.operation_failed',
        e,
        stack,
        fields: {'operation': label},
      );
    }
    if (!cancelled && context.mounted) message(context, errorText(e));
    return null;
  } finally {
    progress.close();
    DiagnosticLog.event(
      'ui.operation_end',
      fields: {
        'operation': label,
        'cancelled': cancelled,
        'elapsedMs': operationClock.elapsedMilliseconds,
      },
    );
    if (route.isActive) navigator.removeRoute(route);
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = '确定',
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive
                ? TextButton.styleFrom(foregroundColor: Colors.red)
                : null,
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
  String? hint,
  bool secret = false,
  bool numeric = false,
  int lines = 1,
  bool barrierDismissible = true,
}) => showDialog<String>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (_) => _TextDialog(title, initial, hint, secret, numeric, lines),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog(
    this.title,
    this.initial,
    this.hint,
    this.secret,
    this.numeric,
    this.lines,
  );
  final String title, initial;
  final String? hint;
  final bool secret, numeric;
  final int lines;
  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: controller,
        autofocus: true,
        obscureText: widget.secret,
        maxLines: widget.lines,
        minLines: widget.lines,
        keyboardType: widget.numeric ? TextInputType.number : null,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => Navigator.pop(context, controller.text),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('确定'),
      ),
    ],
  );
}

class PlatformMark extends StatelessWidget {
  const PlatformMark({super.key, this.platform, this.icon, this.size = 40});
  final CloudPlatform? platform;
  final String? icon;
  final double size;
  @override
  Widget build(BuildContext context) {
    final name = icon ?? platform?.icon;
    if (name == null) {
      return Icon(CupertinoIcons.link, size: size, color: themeAccent(context));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .2),
      child: Image.asset(
        'assets/icons/$name.${name == '123' ? 'webp' : 'png'}',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );
  }
}

class FileGlyph extends StatelessWidget {
  const FileGlyph(
    this.name, {
    super.key,
    this.directory = false,
    this.size = 32,
  });
  final String name;
  final bool directory;
  final double size;
  @override
  Widget build(BuildContext context) {
    final kind = fileKind(name, directory: directory);
    final (icon, color) = switch (kind) {
      FileKind.folder => (CupertinoIcons.folder_fill, const Color(0xffffbe3d)),
      FileKind.android => (Icons.android, const Color(0xff3ddc84)),
      FileKind.image => (CupertinoIcons.photo, const Color(0xffaf52de)),
      FileKind.video => (CupertinoIcons.play_rectangle, themeAccent(context)),
      FileKind.audio => (CupertinoIcons.music_note_2, const Color(0xfff06c96)),
      FileKind.archive => (CupertinoIcons.archivebox, const Color(0xffc29756)),
      FileKind.pdf => (CupertinoIcons.doc_richtext, const Color(0xffff5a55)),
      _ => (CupertinoIcons.doc_text, const Color(0xff8e8e93)),
    };
    return Icon(icon, color: color, size: size);
  }
}

class EmptyPanel extends StatelessWidget {
  const EmptyPanel(
    this.title,
    this.detail, {
    super.key,
    this.icon = CupertinoIcons.tray,
    this.action,
  });
  final String title, detail;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 46,
            color: secondary(context).withValues(alpha: .55),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: secondary(context)),
          ),
          if (action != null)
            Padding(padding: const EdgeInsets.only(top: 18), child: action!),
        ],
      ),
    ),
  );
}

class PageFrame extends StatelessWidget {
  const PageFrame({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });
  final String title;
  final Widget child;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => DesktopMouseBack(
    child: Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: child,
          ),
        ),
      ),
    ),
  );
}
