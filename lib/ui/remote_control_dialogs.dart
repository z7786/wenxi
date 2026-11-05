import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../data/remote_control_service.dart';
import '../data/app_update_service.dart';
import 'app_update_panel.dart';
import '../diagnostics/app_log.dart';
import '../domain/remote_control.dart';
import 'common.dart';
import 'announcement_markdown.dart';
import 'remote_links.dart';
export 'remote_links.dart';

class _DialogActivity extends ChangeNotifier {
  bool showing = false;
  VoidCallback? interruptForUpdate;
  void finish() {
    showing = false;
    interruptForUpdate = null;
    notifyListeners();
  }
}

// Manual and automatic prompts share one presentation slot for this service.
// Weak keys allow a closed app/test instance to release its dialog state.
final _dialogActivities = Expando<_DialogActivity>();
_DialogActivity _activity(RemoteControlService control) =>
    _dialogActivities[control] ??= _DialogActivity();

// The barrier and navigation policy follow live configuration, including a
// normal update becoming mandatory while its dialog is already on screen.
class _UpdateRoute<T> extends DialogRoute<T> {
  _UpdateRoute({
    required super.context,
    required super.builder,
    required super.themes,
    required this.control,
  });

  final RemoteControlService control;
  bool _closing = false;

  @override
  bool get barrierDismissible => control.requiredUpdate == null;

  @override
  RoutePopDisposition get popDisposition => control.requiredUpdate != null
      ? RoutePopDisposition.doNotPop
      : super.popDisposition;

  @override
  bool didPop(Object? result) {
    // Other pages may finish asynchronously with a differently typed result.
    if (control.requiredUpdate != null) return false;
    return super.didPop(result is T ? result : null);
  }

  @override
  void didChangeNext(Route<dynamic>? nextRoute) {
    super.didChangeNext(nextRoute);
    if (nextRoute != null && control.requiredUpdate != null) _configChanged();
  }

  bool get _needsRemoval =>
      control.availableUpdate == null ||
      (control.requiredUpdate != null && !isCurrent);

  @override
  void install() {
    super.install();
    control.addListener(_configChanged);
  }

  void _configChanged() {
    if (!isActive) return;
    changedInternalState();
    if (!_needsRemoval || _closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closing = false;
      if (isActive && _needsRemoval) {
        // Remove this route specifically, even if another route was pushed.
        navigator?.removeRoute(this);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    control.removeListener(_configChanged);
    super.dispose();
  }
}

Future<T?> _present<T>(
  BuildContext context,
  RemoteControlService control,
  WidgetBuilder builder,
  Future<void> Function(T?) acknowledge, {
  bool isUpdate = false,
}) async {
  final activity = _activity(control);
  if (!context.mounted || activity.showing) return null;
  activity.showing = true;
  var interrupted = false;
  try {
    final navigator = Navigator.of(context, rootNavigator: true);
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    while (true) {
      if (!context.mounted) return null;
      final route = isUpdate
          ? _UpdateRoute<T>(
              context: context,
              control: control,
              builder: builder,
              themes: themes,
            )
          : DialogRoute<T>(context: context, builder: builder, themes: themes);
      if (!isUpdate) {
        activity.interruptForUpdate = () {
          if (!route.isActive) return;
          interrupted = true;
          navigator.removeRoute(route);
        };
      }
      final result = await navigator.push(route);
      if (!interrupted) await acknowledge(result);
      // Wait for the old dialog's exit transition before allowing the next one.
      await route.completed;
      if (!isUpdate ||
          control.requiredUpdate == null ||
          !control.inForeground) {
        return result;
      }
      // An asynchronous login/parse may push a page above the gate. Present the
      // required update above that page while retaining the same dialog slot.
    }
  } finally {
    activity.finish();
  }
}

Widget _dialogTitle(BuildContext context, IconData icon, String title) => Row(
  children: [
    Icon(icon, size: 22, color: themeAccent(context)),
    const SizedBox(width: 10),
    Expanded(
      child: Text(
        title,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
    ),
  ],
);

typedef _AnnouncementChoice = ({
  RemoteAnnouncement? notice,
  bool openLink,
  bool hideForWeek,
});

Future<void> showRemoteAnnouncement(
  BuildContext context,
  RemoteControlService control,
  RemoteAnnouncement notice, {
  RemoteLinkLauncher? launcher,
  AppUpdateService? updater,
}) async {
  if (control.requiredUpdate case final update?) {
    await showRemoteUpdate(
      context,
      control,
      update,
      launcher: launcher,
      updater: updater,
    );
    return;
  }
  RemoteAnnouncement? displayed = notice;
  var hideForWeek = control.isAnnouncementMuted(notice);
  final choice = await _present<_AnnouncementChoice>(
    context,
    control,
    (context) => StatefulBuilder(
      builder: (context, setState) => ListenableBuilder(
        listenable: control,
        builder: (context, _) {
          final current = control.config.announcement;
          if (displayed?.contentKey != current?.contentKey) {
            hideForWeek =
                current != null && control.isAnnouncementMuted(current);
          }
          displayed = current;
          final colors = Theme.of(context).colorScheme;
          return AlertDialog(
            key: const ValueKey('control-announcement-dialog'),
            scrollable: true,
            constraints: const BoxConstraints(minWidth: 320, maxWidth: 520),
            title: _dialogTitle(
              context,
              CupertinoIcons.bell,
              current?.title ?? '软件公告',
            ),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (control.checking)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('正在刷新公告…'),
                  ),
                if (control.errorForSection('announcement') case final error?)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colors.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          CupertinoIcons.info_circle,
                          size: 18,
                          color: colors.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DefaultTextStyle(
                            style: TextStyle(
                              color: colors.onErrorContainer,
                              fontSize: 12,
                              height: 1.5,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(error),
                                if (current != null) ...[
                                  const SizedBox(height: 4),
                                  const Text('当前显示上次成功获取的公告。'),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (current != null)
                  AnnouncementMarkdown(
                    current.content,
                    linkLauncher: launcher,
                    imageWidth: (MediaQuery.sizeOf(context).width - 128).clamp(
                      1.0,
                      472.0,
                    ),
                  )
                else if (control.errorForSection('announcement') == null)
                  const Text('暂无公告'),
              ],
            ),
            actions: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (current != null)
                    CheckboxListTile(
                      key: const ValueKey('control-hide-announcement-week'),
                      value: hideForWeek,
                      onChanged: (value) => setState(() {
                        hideForWeek = value ?? false;
                      }),
                      title: const Text(
                        '7天不再显示',
                        style: TextStyle(fontSize: 13),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                    ),
                  OverflowBar(
                    alignment: MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    overflowSpacing: 8,
                    children: [
                      TextButton(
                        key: const ValueKey('control-read-announcement'),
                        onPressed: () =>
                            Navigator.pop<_AnnouncementChoice>(context, (
                              notice: current,
                              openLink: false,
                              hideForWeek: hideForWeek,
                            )),
                        child: const Text('知道了'),
                      ),
                      if (current?.buttonUrl != null)
                        FilledButton.icon(
                          key: const ValueKey('control-announcement-link'),
                          onPressed: () =>
                              Navigator.pop<_AnnouncementChoice>(context, (
                                notice: current,
                                openLink: true,
                                hideForWeek: hideForWeek,
                              )),
                          icon: const Icon(
                            CupertinoIcons.arrow_up_right_square,
                            size: 16,
                          ),
                          label: Text(current!.buttonText),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ),
    (choice) async {
      final seen = choice?.notice ?? displayed;
      if (seen != null) {
        await control.dismissAnnouncement(
          seen,
          hideForWeek: choice?.hideForWeek ?? hideForWeek,
        );
      }
    },
  );
  final url = choice?.openLink == true ? choice?.notice?.buttonUrl : null;
  if (url != null && context.mounted) {
    await openAnnouncementLink(context, url, launcher: launcher);
  }
}

enum _UpdateAction { later, ignore, download }

typedef _UpdateChoice = ({_UpdateAction action, RemoteUpdate update});

Future<void> showRemoteUpdate(
  BuildContext context,
  RemoteControlService control,
  RemoteUpdate update, {
  RemoteLinkLauncher? launcher,
  AppUpdateService? updater,
}) async {
  if (control.availableUpdate == null) return;
  final choice = await _present<_UpdateChoice>(
    context,
    control,
    (context) =>
        _UpdateDialog(control, update, launcher: launcher, updater: updater),
    (choice) async {
      final dismissed = choice?.update ?? control.availableUpdate;
      if (dismissed == null || dismissed.force) return;
      if (choice?.action == _UpdateAction.ignore) {
        await control.ignoreUpdate(dismissed.build, updateKey: dismissed.key);
      } else {
        await control.dismissUpdate(dismissed.build, updateKey: dismissed.key);
      }
    },
    isUpdate: true,
  );
  if (choice?.action == _UpdateAction.download && context.mounted) {
    await openRemoteLink(
      context,
      choice!.update.downloadUrl,
      launcher: launcher,
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog(this.control, this.update, {this.launcher, this.updater});
  final RemoteControlService control;
  final RemoteUpdate update;
  final RemoteLinkLauncher? launcher;
  final AppUpdateService? updater;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  late RemoteUpdate _lastUpdate = widget.update;
  bool _opening = false;

  void _finish(_UpdateAction action, RemoteUpdate displayed) {
    final current = widget.control.availableUpdate;
    if (current == null || current.force || current.key != displayed.key) {
      return;
    }
    Navigator.pop(context, (action: action, update: current));
  }

  Future<void> _download(RemoteUpdate displayed) async {
    final current = widget.control.availableUpdate;
    if (_opening || current == null || current.key != displayed.key) return;
    if (!current.force) {
      _finish(_UpdateAction.download, current);
      return;
    }
    // Opening the browser does not dismiss a required update.
    setState(() => _opening = true);
    await openRemoteLink(
      context,
      current.downloadUrl,
      launcher: widget.launcher,
    );
    if (mounted) setState(() => _opening = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.control,
    builder: (context, _) {
      final update = widget.control.availableUpdate ?? _lastUpdate;
      final updateError = widget.control.errorForSection(
        'updates.${widget.control.platform}',
      );
      _lastUpdate = update;
      final download = OutlinedButton.icon(
        key: const ValueKey('control-download-update'),
        onPressed: _opening ? null : () => _download(update),
        icon: const Icon(CupertinoIcons.arrow_up_right_square, size: 16),
        label: Text(_opening ? '正在打开…' : '浏览器更新'),
      );
      return PopScope<_UpdateChoice>(
        canPop: !update.force,
        child: AlertDialog(
          key: const ValueKey('control-update-dialog'),
          scrollable: true,
          constraints: const BoxConstraints(minWidth: 320, maxWidth: 520),
          title: _dialogTitle(
            context,
            CupertinoIcons.arrow_down_circle,
            '${update.force ? '请更新至' : '发现新版本'} ${update.version}',
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '当前版本 ${applicationVersion.split('+').first}',
                style: TextStyle(fontSize: 12, color: secondary(context)),
              ),
              if (update.force) ...[
                const SizedBox(height: 14),
                const Text(
                  '此版本需要更新后才能继续使用。',
                  style: TextStyle(fontSize: 14, height: 1.65),
                ),
              ],
              if (update.notes.isNotEmpty) ...[
                const SizedBox(height: 14),
                SelectableText(
                  update.notes,
                  style: const TextStyle(fontSize: 14, height: 1.65),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                '下载页面：${update.downloadUrl.host}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: secondary(context),
                ),
              ),
              if (update.force && updateError != null) ...[
                const SizedBox(height: 10),
                Text(
                  updateError,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.updater case final updater?)
                  AppUpdatePanel(
                    key: ValueKey(updater.keyFor(update)),
                    updater: updater,
                    control: widget.control,
                    update: update,
                    openDownloads: () {
                      if (widget.control.requiredUpdate != null) return;
                      _finish(_UpdateAction.later, update);
                      updater.openDownloads();
                    },
                  ),
                OverflowBar(
                  alignment: MainAxisAlignment.end,
                  overflowAlignment: OverflowBarAlignment.end,
                  spacing: 8,
                  overflowSpacing: 8,
                  children: [
                    if (update.force)
                      TextButton(
                        key: const ValueKey('control-recheck-update'),
                        onPressed: widget.control.checking
                            ? null
                            : () => widget.control.refresh(force: true),
                        child: Text(widget.control.checking ? '正在检查…' : '重新检查'),
                      )
                    else
                      TextButton(
                        key: const ValueKey('control-update-later'),
                        onPressed: () => _finish(_UpdateAction.later, update),
                        child: const Text('暂不更新'),
                      ),
                    download,
                  ],
                ),
                if (!update.force) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.center,
                    child: TextButton(
                      key: const ValueKey('control-ignore-update'),
                      onPressed: () => _finish(_UpdateAction.ignore, update),
                      style: TextButton.styleFrom(
                        foregroundColor: secondary(context),
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(fontSize: 12),
                      ),
                      child: const Text('忽略此版本'),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );
    },
  );
}

Future<void> openLatestAnnouncement(
  BuildContext context,
  RemoteControlService control, {
  RemoteLinkLauncher? launcher,
  AppUpdateService? updater,
}) async {
  final route = ModalRoute.of(context);
  if (control.configured) {
    await control.refresh(force: true);
    if (!context.mounted || route?.isCurrent != true) return;
  }
  if (!context.mounted) return;
  final notice = control.config.announcement;
  if (notice == null) {
    message(context, control.errorForSection('announcement') ?? '暂无公告');
  } else {
    await showRemoteAnnouncement(
      context,
      control,
      notice,
      launcher: launcher,
      updater: updater,
    );
  }
}

Future<void> checkForAppUpdate(
  BuildContext context,
  RemoteControlService control, {
  RemoteLinkLauncher? launcher,
  AppUpdateService? updater,
}) async {
  final route = ModalRoute.of(context);
  final result = await control.refresh(force: true);
  if (!context.mounted || route?.isCurrent != true) return;
  if (result == ControlRefreshResult.unconfigured) {
    message(context, '此版本暂未提供在线更新信息');
    return;
  }
  final error = control.errorForSection('updates.${control.platform}');
  if (error != null) {
    message(context, error);
    return;
  }
  if (result != ControlRefreshResult.success &&
      result != ControlRefreshResult.partial &&
      result != ControlRefreshResult.fallback) {
    return;
  }
  final update = control.availableUpdate;
  if (update != null) {
    await showRemoteUpdate(
      context,
      control,
      update,
      launcher: launcher,
      updater: updater,
    );
  } else {
    message(context, !control.hasUpdateInformation ? '暂时没有可用的更新' : '当前已是最新版本');
  }
}

/// Ordinary prompts wait for the main route; required updates also cover other
/// pages and interrupt an announcement, without marking it as read.
class RemoteControlPrompts extends StatefulWidget {
  const RemoteControlPrompts(
    this.control, {
    super.key,
    this.launcher,
    this.updater,
  });
  final RemoteControlService control;
  final RemoteLinkLauncher? launcher;
  final AppUpdateService? updater;
  @override
  State<RemoteControlPrompts> createState() => _RemoteControlPromptsState();
}

class _RemoteControlPromptsState extends State<RemoteControlPrompts> {
  bool _scheduled = false, _showing = false, _routeCurrent = false;
  @override
  void initState() {
    super.initState();
    widget.control.addListener(_schedule);
    _activity(widget.control).addListener(_schedule);
  }

  @override
  void didUpdateWidget(RemoteControlPrompts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.control != widget.control) {
      oldWidget.control.removeListener(_schedule);
      _activity(oldWidget.control).removeListener(_schedule);
      widget.control.addListener(_schedule);
      _activity(widget.control).addListener(_schedule);
    }
  }

  void _schedule() {
    final control = widget.control;
    final activity = _activity(control);
    final required = control.requiredUpdate != null;
    final canInterrupt = required && activity.interruptForUpdate != null;
    if (!mounted ||
        _scheduled ||
        ((_showing || activity.showing) && !canInterrupt) ||
        (!required && !_routeCurrent) ||
        !control.inForeground ||
        control.checking ||
        (control.unreadAnnouncement == null && control.unreadUpdate == null)) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_showNext());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showNext() async {
    final control = widget.control;
    final activity = _activity(control);
    if (!mounted || !control.inForeground || control.checking) return;
    final required = control.requiredUpdate;
    if (required != null && activity.interruptForUpdate != null) {
      activity.interruptForUpdate!();
      return;
    }
    if (!mounted ||
        _showing ||
        activity.showing ||
        (required == null && ModalRoute.of(context)?.isCurrent != true)) {
      return;
    }
    final notice = control.unreadAnnouncement;
    final update = control.unreadUpdate;
    if (notice == null && update == null) return;
    _showing = true;
    try {
      if (notice != null && required == null) {
        await showRemoteAnnouncement(
          context,
          control,
          notice,
          launcher: widget.launcher,
          updater: widget.updater,
        );
      } else {
        await showRemoteUpdate(
          context,
          control,
          update!,
          launcher: widget.launcher,
          updater: widget.updater,
        );
      }
    } finally {
      _showing = false;
      if (mounted) _schedule();
    }
  }

  @override
  void dispose() {
    widget.control.removeListener(_schedule);
    _activity(widget.control).removeListener(_schedule);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watching the modal route also covers popups removed with removeRoute.
    _routeCurrent = ModalRoute.of(context)?.isCurrent == true;
    _schedule();
    return const SizedBox.shrink();
  }
}
