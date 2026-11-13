import 'dart:async';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../domain/downloads.dart';
import '../domain/models.dart' show CloudPlatform;
import '../download/completed_files.dart';
import '../platform/file_access.dart';
import '../platform/completed_file_actions.dart';
import '../platform/desktop_actions.dart';
import '../platform/desktop_platform.dart';
import '../playback/playback_sources.dart';
import '../playback/torrent_playback.dart';
import '../playback/download_playback.dart';
import 'announcements_page.dart';
import 'common.dart';
import 'app_context_menu.dart';
import 'app_popup_menu.dart';
import 'download_progress.dart';
import 'transfer_widgets.dart';
import 'player_page.dart';
import 'download_protection_page.dart';
import 'download_concurrency_dialog.dart';
import 'download_completion_option.dart';
import 'uc_tv_authorization_page.dart';
import 'uc_video_download.dart';
import 'text_preview.dart';

enum _DownloadHelpAction { announcements, resources }

class DownloadsPage extends StatefulWidget {
  const DownloadsPage(
    this.services, {
    super.key,
    this.active = true,
    this.onPlay,
    this.fileActions,
    this.onSelectionChanged,
  });
  final AppServices services;
  final bool active;
  final Future<void> Function(DownloadTask)? onPlay;
  final CompletedFileActions? fileActions;
  final ValueChanged<bool>? onSelectionChanged;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage>
    with WidgetsBindingObserver {
  late final files = CompletedFiles(widget.services.downloads);
  Timer? _refreshTimer;
  bool _foreground = true;
  bool _selecting = false, _batching = false;
  bool _selectionNotificationPending = false;
  bool _detailsOpen = false;
  bool _externalFileActionPending = false;
  late final _fileActions = widget.fileActions ?? CompletedFileActions();
  String? _authorizingDownload;
  String? _selectionNotice;
  final _selected = <String>{};
  int filter = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.services.downloads.addListener(_downloadsChanged);
    files.addListener(_pruneSelection);
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkFiles(),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _checkFiles(force: true),
    );
  }

  void _downloadsChanged() {
    _pruneSelection();
    _checkFiles();
  }

  void _pruneSelection() {
    if (!mounted || !_selecting) return;
    final visible = widget.services.downloads.tasks
        .where((task) => accepts(task, filter))
        .map((task) => task.id)
        .toSet();
    if (_selected.every(visible.contains) && visible.isNotEmpty) return;
    setState(() {
      _selected.removeWhere((id) => !visible.contains(id));
      if (visible.isEmpty) _setSelecting(false);
    });
  }

  void _setSelecting(bool value) {
    if (_selecting == value) return;
    _selecting = value;
    if (_selectionNotificationPending || widget.onSelectionChanged == null) {
      return;
    }
    // A tab change can reset selection in didUpdateWidget. Notify after this
    // frame so the parent can update its footer without rebuilding mid-layout.
    _selectionNotificationPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectionNotificationPending = false;
      if (mounted) widget.onSelectionChanged?.call(_selecting);
    });
  }

  void _toggleSelection(String id) {
    if (_batching) return;
    if (!_selecting) ScaffoldMessenger.of(context).removeCurrentSnackBar();
    setState(() {
      _setSelecting(true);
      _selectionNotice = null;
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  void _exitSelection() {
    if (_batching) return;
    setState(() {
      _setSelecting(false);
      _selected.clear();
      _selectionNotice = null;
    });
  }

  void _checkFiles({bool force = false}) {
    if (mounted &&
        widget.active &&
        _foreground &&
        (ModalRoute.of(context)?.isCurrent != false || _detailsOpen)) {
      unawaited(files.refresh(force: force));
    }
  }

  @override
  void didUpdateWidget(DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active && oldWidget.active) {
      _selected.clear();
      _setSelecting(false);
    }
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _checkFiles(force: true),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _foreground = state == AppLifecycleState.resumed);
    if (_foreground) _checkFiles(force: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.services.downloads.removeListener(_downloadsChanged);
    _refreshTimer?.cancel();
    files.removeListener(_pruneSelection);
    files.dispose();
    super.dispose();
  }

  bool accepts(DownloadTask task, int value) => switch (value) {
    1 => task.active,
    2 => task.status == DownloadStatus.completed,
    3 => task.status == DownloadStatus.failed,
    4 =>
      task.status == DownloadStatus.completed &&
          {
            FileAvailability.missing,
            FileAvailability.inaccessible,
          }.contains(files.state(task)),
    _ => true,
  };
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.services.downloads,
      widget.services.store,
      widget.services.downloadShutdown,
      files,
    ]),
    builder: (context, _) {
      final manager = widget.services.downloads, all = manager.tasks;
      final concurrent = widget.services.settings.concurrent;
      final concurrencyOptions = {1, 2, 3, 5, 8, 16, 32, concurrent}.toList()
        ..sort();
      final groups = List.generate(6, (_) => <DownloadTask>[]);
      for (final task in all) {
        if (!accepts(task, filter)) continue;
        final rank = switch (task.status) {
          DownloadStatus.running => 0,
          DownloadStatus.pending => 1,
          DownloadStatus.paused => 2,
          DownloadStatus.failed => 3,
          DownloadStatus.completed => 4,
          _ => 5,
        };
        groups[rank].add(task);
      }
      // Manager snapshots already have descending creation times. Grouping
      // preserves that order within each status without sorting on every tick.
      final tasks = [for (final group in groups) ...group];
      final taskIndices = {
        for (var i = 0; i < tasks.length; i++) ValueKey(tasks[i].id): i,
      };
      return PopScope(
        canPop: !widget.active || !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && widget.active && _selecting) _exitSelection();
        },
        child: Column(
          key: const Key('downloads-task-layout'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TransferFilterBar(
              entries: [
                for (var i = 0; i < 5; i++)
                  (
                    ['全部', '进行中', '已完成', '失败', '文件异常'][i],
                    all.where((t) => accepts(t, i)).length,
                  ),
              ],
              selected: filter,
              keyPrefix: 'download-filter',
              accent: themeAccent(context),
              onSelected: _batching
                  ? null
                  : (value) => setState(() {
                      if (filter == value) return;
                      filter = value;
                      _selected.clear();
                      _setSelecting(false);
                    }),
            ),
            if (_selecting)
              _selectionBar(tasks)
            else
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: border(context), width: .5),
                    bottom: BorderSide(color: border(context), width: .5),
                  ),
                ),
                padding: const EdgeInsets.only(left: 16),
                child: Row(
                  children: [
                    Expanded(
                      flex: 4,
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 4,
                        children: [
                          Text(
                            '同时下载数：',
                            style: TextStyle(
                              fontSize: 12,
                              color: secondary(context),
                            ),
                          ),
                          DropdownButton<int>(
                            key: const Key('download-concurrency'),
                            value: concurrent,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            padding: const EdgeInsets.symmetric(vertical: 7),
                            iconSize: 16,
                            iconEnabledColor: themeAccent(context),
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  fontSize: 13,
                                  color: themeAccent(context),
                                ),
                            items: [
                              for (final i in concurrencyOptions)
                                DropdownMenuItem(value: i, child: Text('$i')),
                              const DropdownMenuItem(
                                value: 0,
                                child: Text('自定义…'),
                              ),
                            ],
                            selectedItemBuilder: (context) => List.generate(
                              concurrencyOptions.length + 1,
                              (_) => Text('$concurrent'),
                            ),
                            onChanged: (value) {
                              if (value == 0) {
                                editDownloadConcurrency(
                                  context,
                                  widget.services,
                                );
                              } else if (value != null) {
                                busy(
                                  context,
                                  () => widget.services.updateSettings({
                                    'concurrent': value,
                                  }),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      key: const Key('download-failure-help'),
                      onPressed: _showDownloadHelp,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(fontSize: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('无法下载？'),
                    ),
                    if (widget.services.platformFeatures &&
                        (Platform.isAndroid ||
                            Platform.isIOS ||
                            Platform.isWindows ||
                            Platform.isMacOS))
                      IconButton(
                        tooltip: '后台下载保护',
                        icon: Icon(
                          CupertinoIcons.shield_lefthalf_fill,
                          size: 19,
                          color: themeAccent(context),
                        ),
                        onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const DownloadProtectionPage(),
                          ),
                        ),
                      ),
                    if (manager.activeCount > 0)
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.only(right: 16),
                          child: Text(
                            '${formatBytes(all.where((t) => t.active).fold<int>(0, (n, t) => n + t.speed))}/s',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: themeAccent(context),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (widget.services.downloadShutdown.supported)
              DownloadCompletionOption(widget.services.downloadShutdown),
            Expanded(
              child: tasks.isEmpty
                  ? EmptyPanel(
                      filter == 0
                          ? '还没有下载任务'
                          : '暂无${['', '进行中', '已完成', '失败', '文件异常'][filter]}任务',
                      '从解析结果或网盘文件列表中添加下载',
                      icon: CupertinoIcons.arrow_down_circle,
                    )
                  : RefreshIndicator(
                      onRefresh: () => files.refresh(force: true),
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        key: const PageStorageKey('downloads'),
                        padding: EdgeInsets.only(
                          bottom: 12 + MediaQuery.paddingOf(context).bottom,
                        ),
                        itemCount: tasks.length,
                        findChildIndexCallback: (key) => taskIndices[key],
                        itemBuilder: (context, index) =>
                            _row(context, tasks[index]),
                      ),
                    ),
            ),
            if (_selecting) _selectionActions(),
          ],
        ),
      );
    },
  );

  Future<void> _showDownloadHelp() async {
    final action = await showDialog<_DownloadHelpAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法下载？'),
        scrollable: true,
        content: const Text('下载失败时，可查看 App 公告寻找解决办法，或使用「查找资源」功能更换网盘资源。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
          TextButton.icon(
            key: const Key('download-help-announcements'),
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(_DownloadHelpAction.announcements),
            icon: const Icon(CupertinoIcons.bell, size: 18),
            label: const Text('查看公告'),
          ),
          FilledButton.icon(
            key: const Key('download-help-resources'),
            onPressed: () =>
                Navigator.of(dialogContext).pop(_DownloadHelpAction.resources),
            icon: const Icon(CupertinoIcons.search, size: 18),
            label: const Text('查找资源'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _DownloadHelpAction.announcements:
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => AnnouncementsPage(widget.services.announcements),
          ),
        );
      case _DownloadHelpAction.resources:
        widget.services.requestResourceSearch();
      case null:
        break;
    }
  }

  List<DownloadTask> get _selectedTasks => _selected
      .map(widget.services.downloads.task)
      .whereType<DownloadTask>()
      .toList(growable: false);

  Widget _selectionBar(List<DownloadTask> tasks) {
    final allSelected =
        tasks.isNotEmpty && tasks.every((task) => _selected.contains(task.id));
    return Container(
      key: const Key('downloads-selection-bar'),
      decoration: BoxDecoration(
        color: themeAccent(context).withValues(alpha: .04),
        border: Border(bottom: BorderSide(color: border(context), width: .5)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '退出多选',
            onPressed: _batching ? null : _exitSelection,
            style: IconButton.styleFrom(
              minimumSize: const Size(36, 36),
              foregroundColor: secondary(context),
            ),
            icon: const Icon(CupertinoIcons.xmark, size: 18),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '已选 ${_selected.length} 项',
              key: const Key('downloads-selected-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            key: const Key('downloads-select-all'),
            onPressed: _batching || tasks.isEmpty
                ? null
                : () => setState(() {
                    _selected.clear();
                    if (!allSelected) {
                      _selected.addAll(tasks.map((task) => task.id));
                    }
                  }),
            child: Text(allSelected ? '取消全选' : '全选'),
          ),
        ],
      ),
    );
  }

  Widget _selectionActions() {
    final selected = _selectedTasks;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Material(
            key: const Key('downloads-selection-actions'),
            color: Theme.of(context).colorScheme.surface,
            elevation: 2,
            shadowColor: Colors.black.withValues(alpha: .12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: border(context).withValues(alpha: .6)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_selectionNotice != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                      child: Text(
                        _selectionNotice!,
                        key: const Key('downloads-selection-notice'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      for (final action in DownloadBatchAction.values) ...[
                        if (action != DownloadBatchAction.pause)
                          const SizedBox(width: 8),
                        Expanded(
                          child: _selectionActionButton(
                            key: Key('downloads-batch-${action.name}'),
                            label: action.label,
                            icon: switch (action) {
                              DownloadBatchAction.pause => CupertinoIcons.pause,
                              DownloadBatchAction.resume => CupertinoIcons.play,
                              DownloadBatchAction.delete =>
                                CupertinoIcons.trash,
                            },
                            destructive: action == DownloadBatchAction.delete,
                            primary: action == DownloadBatchAction.resume,
                            onPressed:
                                _batching || !selected.any(action.accepts)
                                ? null
                                : () => action == DownloadBatchAction.delete
                                      ? _deleteSelectedDialog()
                                      : _runSelectedAction(action),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (_supportsFileTransfer) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Divider(height: 1),
                    ),
                    Row(
                      children: [
                        for (final move in [false, true]) ...[
                          if (move) const SizedBox(width: 8),
                          Expanded(
                            child: _selectionActionButton(
                              key: Key(
                                move
                                    ? 'downloads-batch-move'
                                    : 'downloads-batch-copy',
                              ),
                              icon: move
                                  ? CupertinoIcons.folder
                                  : CupertinoIcons.doc_on_doc,
                              label: move ? '移动文件' : '复制文件',
                              onPressed:
                                  _batching || !selected.any(_transferable)
                                  ? null
                                  : () => _transferSelected(move: move),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectionActionButton({
    required Key key,
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool destructive = false,
    bool primary = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final foreground = destructive
        ? colors.error
        : primary
        ? themeAccent(context)
        : colors.onSurface;
    return TextButton(
      key: key,
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        foregroundColor: foreground,
        backgroundColor: destructive || primary
            ? foreground.withValues(alpha: .08)
            : fill(context),
        disabledForegroundColor: colors.onSurface.withValues(alpha: .3),
        disabledBackgroundColor: fill(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 4,
        children: [Icon(icon, size: 18), Text(label)],
      ),
    );
  }

  bool get _supportsFileTransfer =>
      Platform.isWindows &&
      Theme.of(context).platform == TargetPlatform.windows;
  bool _transferable(DownloadTask task) =>
      task.status == DownloadStatus.completed &&
      task.savedPath?.isNotEmpty == true;

  Future<void> _transferSelected({
    required bool move,
    List<String>? ids,
  }) async {
    if (_batching || !_supportsFileTransfer) return;
    final targets =
        ids ??
        _selectedTasks.where(_transferable).map((task) => task.id).toList();
    if (targets.isEmpty) return;
    setState(() {
      _batching = true;
      _selectionNotice = null;
    });
    DownloadBatchResult? result;
    try {
      final destination = await widget.services.downloads.files
          .chooseDirectory();
      if (!mounted || destination == null) return;
      result = await busy(
        context,
        () => widget.services.downloads.transferCompletedFiles(
          targets,
          destination,
          move: move,
        ),
        label: '正在${move ? '移动' : '复制'} ${targets.length} 个文件…',
      );
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _batching = false);
    }
    if (!mounted || result == null) return;
    setState(() {
      _selected.removeAll([...result!.succeeded, ...result.skipped]);
      if (_selected.isEmpty) _setSelecting(false);
    });
    final notice =
        '已${move ? '移动' : '复制'} ${result.succeeded.length} 个文件'
        '${result.failed.isEmpty ? '' : '，${result.failed.length} 项失败：${errorText(result.failed.values.first)}'}';
    if (_selecting && result.failed.isNotEmpty) {
      setState(() => _selectionNotice = notice);
    } else {
      message(context, notice);
    }
  }

  Future<void> _runSelectedAction(
    DownloadBatchAction action, {
    List<String>? ids,
    bool deleteFiles = false,
  }) async {
    if (_batching) return;
    final targets =
        ids ??
        _selectedTasks
            .where(action.accepts)
            .map((task) => task.id)
            .toList(growable: false);
    if (targets.isEmpty) return;
    setState(() {
      _batching = true;
      _selectionNotice = null;
    });
    DownloadBatchResult? result;
    try {
      result = await busy(
        context,
        () => widget.services.downloads.batch(
          targets,
          action,
          deleteFiles: deleteFiles,
        ),
        label: '正在${action.label} ${targets.length} 项…',
      );
    } finally {
      if (mounted) setState(() => _batching = false);
    }
    if (!mounted || result == null) return;
    setState(() {
      _selected.removeAll([...result!.succeeded, ...result.skipped]);
      if (_selected.isEmpty) _setSelecting(false);
    });
    final summary = '已${action.label} ${result.succeeded.length} 项';
    final notice = result.failed.isEmpty
        ? summary
        : '$summary，${result.failed.length} 项失败，失败项已保留：${errorText(result.failed.values.first)}';
    if (_selecting && result.failed.isNotEmpty) {
      setState(() => _selectionNotice = notice);
    } else {
      message(context, notice);
    }
  }

  Future<void> _deleteSelectedDialog() async {
    final selected = _selectedTasks;
    if (_batching || selected.isEmpty) return;
    final completed = selected.every(
      (task) => task.status == DownloadStatus.completed,
    );
    final missing = selected
        .where((task) => files.state(task) == FileAvailability.missing)
        .length;
    var deleteFiles = false;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(
            completed
                ? '移除 ${selected.length} 条下载记录'
                : '删除 ${selected.length} 个任务',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final task in selected.take(3))
                  Text(
                    task.spec.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (selected.length > 3) Text('等 ${selected.length} 个任务'),
                const SizedBox(height: 12),
                Text(
                  completed
                      ? '从列表移除所选记录，已下载的文件默认保留。文件无法识别或已被外部删除，也能移除记录。'
                      : '会先停止所选下载。未完成缓存随任务自动清理，删除后无法续传；已保存到下载目录的文件默认保留。',
                ),
                if (missing > 0) Text('其中 $missing 个文件已不存在，将移除对应的下载记录。'),
                if (selected.any(
                  (task) =>
                      task.status != DownloadStatus.completed ||
                      task.savedPath != null &&
                          files.state(task) != FileAvailability.missing,
                ))
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(completed ? '同时删除已下载的文件' : '同时删除本地文件'),
                    subtitle: completed
                        ? null
                        : const Text('包括已保存的文件和保存中断后的残留文件'),
                    value: deleteFiles,
                    onChanged: (value) =>
                        setLocal(() => deleteFiles = value ?? false),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('downloads-confirm-delete'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                completed && !deleteFiles ? '移除记录' : '删除',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    );
    if (approved == true && mounted) {
      await _runSelectedAction(
        DownloadBatchAction.delete,
        ids: selected.map((task) => task.id).toList(growable: false),
        deleteFiles: deleteFiles,
      );
    }
  }

  Widget _row(BuildContext context, DownloadTask task) {
    return AppContextMenu<String>(
      key: ValueKey(task.id),
      enabled: !_batching,
      identity: (
        task.id,
        _selected.contains(task.id)
            ? (_selected.toList()..sort()).join('\u0000')
            : '',
      ),
      actions: () => _taskContextActions(task.id),
      onSelected: (action) => _taskAction(task.id, action),
      child: _rowContent(context, task),
    );
  }

  List<AppMenuAction<String>> _taskContextActions(String id) {
    final task = widget.services.downloads.task(id);
    if (task == null || _batching) return [];
    if (_selected.contains(id) && _selectedTasks.length > 1) {
      return [
        if (_supportsFileTransfer)
          for (final move in [false, true])
            AppMenuAction(
              value: move ? 'batch-move' : 'batch-copy',
              label:
                  '${move ? '移动文件' : '复制文件'}（${_selectedTasks.where(_transferable).length} 项）',
              icon: move ? CupertinoIcons.folder : CupertinoIcons.doc_on_doc,
              enabled: _selectedTasks.any(_transferable),
            ),
        for (final action in DownloadBatchAction.values)
          AppMenuAction(
            value: 'batch-${action.name}',
            label: '${action.label}（${_selectedTasks.length} 项）',
            icon: switch (action) {
              DownloadBatchAction.pause => CupertinoIcons.pause,
              DownloadBatchAction.resume => CupertinoIcons.play,
              DownloadBatchAction.delete => CupertinoIcons.trash,
            },
            enabled: _selectedTasks.any(action.accepts),
            destructive: action == DownloadBatchAction.delete,
          ),
        const AppMenuAction(
          value: 'select',
          label: '取消选择此项',
          icon: CupertinoIcons.checkmark_circle,
        ),
        const AppMenuAction(
          value: 'clear-selection',
          label: '退出多选',
          icon: CupertinoIcons.xmark_circle,
        ),
      ];
    }
    final completed = task.status == DownloadStatus.completed;
    final kind = fileKind(task.spec.fileName);
    return [
      const AppMenuAction(
        value: 'details',
        label: '任务详情',
        icon: CupertinoIcons.info_circle,
      ),
      if (completed && files.state(task) == FileAvailability.present) ...[
        if (_supportsFileTransfer)
          for (final move in [false, true])
            AppMenuAction(
              value: move ? 'move-file' : 'copy-file',
              label: move ? '移动文件' : '复制文件',
              icon: move ? CupertinoIcons.folder : CupertinoIcons.doc_on_doc,
            ),
        if (kind == FileKind.video || kind == FileKind.text)
          AppMenuAction(
            value: 'open',
            label: kind == FileKind.video ? '播放视频' : '预览文本 / 代码',
            icon: CupertinoIcons.play_rectangle,
          ),
        if (kind == FileKind.audio)
          const AppMenuAction(
            value: 'play',
            label: '播放音频',
            icon: CupertinoIcons.play_rectangle,
          ),
        const AppMenuAction(
          value: 'open-with',
          label: '用其他应用打开',
          icon: CupertinoIcons.arrow_up_right_square,
        ),
        const AppMenuAction(
          value: 'folder',
          label: '打开所在文件夹',
          icon: CupertinoIcons.folder_open,
        ),
        const AppMenuAction(
          value: 'share',
          label: '分享文件',
          icon: CupertinoIcons.share,
        ),
      ],
      if (!completed)
        AppMenuAction(
          value: task.active
              ? 'pause'
              : task.needsUcAuthorization
              ? 'authorize'
              : 'resume',
          label: task.active
              ? '暂停下载'
              : task.needsUcAuthorization
              ? '授权并继续下载'
              : '继续下载',
          icon: task.active ? CupertinoIcons.pause : CupertinoIcons.play,
          enabled: _authorizingDownload != id,
        ),
      if (canRecoverUcPlayable(task))
        const AppMenuAction(
          value: 'uc-playable',
          label: '下载可播放版本',
          icon: CupertinoIcons.film,
        ),
      if (!completed &&
          task.spec.isTorrent &&
          {FileKind.video, FileKind.audio}.contains(kind))
        const AppMenuAction(
          value: 'torrent-play',
          label: '在线播放',
          icon: CupertinoIcons.play_rectangle,
        ),
      if (!completed && widget.services.downloads.canPlayOnline(task))
        AppMenuAction(
          value: 'download-play',
          label: task.isStreamingPlaylist ? '在线播放' : '边下边播',
          icon: CupertinoIcons.play_rectangle,
        ),
      AppMenuAction(
        value: 'copy',
        label: '复制下载链接',
        icon: CupertinoIcons.link,
        enabled: !task.spec.needsPreparation,
      ),
      const AppMenuAction(
        value: 'copy-name',
        label: '复制文件名',
        icon: CupertinoIcons.doc_on_doc,
      ),
      if (completed)
        const AppMenuAction(
          value: 'check',
          label: '重新检查文件',
          icon: CupertinoIcons.refresh,
        ),
      AppMenuAction(
        value: 'select',
        label: _selected.contains(id) ? '取消选择此项' : '选择此项',
        icon: CupertinoIcons.checkmark_circle,
      ),
      AppMenuAction(
        value: 'delete',
        label: completed ? '移除下载记录' : '删除任务',
        icon: CupertinoIcons.trash,
        destructive: true,
      ),
    ];
  }

  Widget _rowContent(BuildContext context, DownloadTask task) {
    final running = task.active, done = task.status == DownloadStatus.completed;
    final availability = files.state(task);
    final missing = done && availability == FileAvailability.missing;
    final inaccessible = done && availability == FileAvailability.inaccessible;
    final unavailable = missing || inaccessible;
    final statusColor = missing
        ? const Color(0xffff3b30)
        : const Color(0xffff9500);
    return Material(
      key: ValueKey(task.id),
      color: _selected.contains(task.id)
          ? themeAccent(context).withValues(alpha: .08)
          : Colors.transparent,
      child: InkWell(
        key: ValueKey('download-row-${task.id}'),
        onTap: _batching
            ? null
            : () => _selecting
                  ? _toggleSelection(task.id)
                  : _details(context, task.id),
        onLongPress: _batching
            ? null
            : () {
                if (!_selecting || !_selected.contains(task.id)) {
                  _toggleSelection(task.id);
                }
              },
        child: Container(
          constraints: const BoxConstraints(minHeight: 66),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: border(context), width: .5),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
          child: Row(
            children: [
              if (_selecting)
                SizedBox(
                  width: 32,
                  child: Checkbox(
                    key: ValueKey('download-select-${task.id}'),
                    semanticLabel: '选择 ${task.spec.fileName}',
                    value: _selected.contains(task.id),
                    onChanged: _batching
                        ? null
                        : (_) => _toggleSelection(task.id),
                  ),
                )
              else
                FileGlyph(task.spec.fileName, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.spec.fileName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (task.spec.platform != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 5),
                            child: PlatformMark(
                              platform: task.spec.platform,
                              size: 14,
                            ),
                          ),
                        const SizedBox(width: 5),
                        Tooltip(
                          message: _connectionDescription(task),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: fill(context),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              _connectionLabel(task),
                              key: ValueKey('download-connections-${task.id}'),
                              style: TextStyle(
                                fontSize: 9,
                                color: secondary(context),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (unavailable)
                      Container(
                        key: ValueKey('file-status-${task.id}'),
                        margin: const EdgeInsets.only(bottom: 5),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: .12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.exclamationmark_triangle_fill,
                              size: 12,
                              color: statusColor,
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                availability.label,
                                style: TextStyle(
                                  color: statusColor,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Text(
                      done
                          ? unavailable
                                ? missing
                                      ? '文件已被移动或删除'
                                      : '请检查目录权限或存储设备'
                                : '${availability.label} · ${formatBytes(task.total)}'
                          : task.needsUcAuthorization
                          ? '需要 UC 扫码授权，完成后继续下载'
                          : task.error.isNotEmpty
                          ? task.error
                          : task.phase.isNotEmpty
                          ? task.phase
                          : running
                          ? '${formatBytes(task.downloaded)} / ${task.total > 0 ? formatBytes(task.total) : '未知大小'} · ${formatBytes(task.speed)}/s'
                          : '${task.status.label} · ${formatBytes(task.downloaded)} / ${formatBytes(task.total)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: task.error.isNotEmpty
                            ? const Color(0xffff3b30)
                            : secondary(context),
                      ),
                    ),
                    DownloadProgress(
                      task: task,
                      compact: true,
                      enabled:
                          widget.active &&
                          _foreground &&
                          ModalRoute.of(context)?.isCurrent != false,
                    ),
                  ],
                ),
              ),
              if (!_selecting) ...[
                const SizedBox(width: 6),
                if (task.needsUcAuthorization)
                  TextButton(
                    key: ValueKey('download-authorize-${task.id}'),
                    onPressed: _authorizingDownload == null
                        ? () => _authorizeDownload(task.id)
                        : null,
                    child: const Text('授权并继续'),
                  )
                else
                  TransferActionButton(
                    key: ValueKey('download-primary-action-${task.id}'),
                    label: done
                        ? unavailable
                              ? '查看文件异常'
                              : isDesktopPlatform &&
                                    fileKind(task.spec.fileName) ==
                                        FileKind.video
                              ? '播放视频'
                              : fileKind(task.spec.fileName) == FileKind.text
                              ? '预览文本'
                              : '打开文件'
                        : running
                        ? '暂停下载'
                        : '继续下载',
                    icon: done
                        ? unavailable
                              ? CupertinoIcons.exclamationmark_circle
                              : isDesktopPlatform &&
                                    fileKind(task.spec.fileName) ==
                                        FileKind.video
                              ? CupertinoIcons.play_rectangle
                              : fileKind(task.spec.fileName) == FileKind.text
                              ? CupertinoIcons.doc_text
                              : CupertinoIcons.folder
                        : running
                        ? CupertinoIcons.pause
                        : CupertinoIcons.play,
                    color: unavailable ? statusColor : themeAccent(context),
                    onPressed: () => done
                        ? unavailable
                              ? _details(context, task.id)
                              : _open(task)
                        : busy(
                            context,
                            () => running
                                ? widget.services.downloads.pause(task.id)
                                : widget.services.downloads.resume(task.id),
                          ),
                  ),
                if (done && !unavailable)
                  AppPopupMenuButton<String>(
                    key: ValueKey('download-file-actions-${task.id}'),
                    tooltip: '更多文件操作',
                    icon: CupertinoIcons.ellipsis,
                    actions: [
                      const AppMenuAction(
                        value: 'open-with',
                        label: '用其他应用打开',
                        icon: CupertinoIcons.arrow_up_right_square,
                      ),
                      const AppMenuAction(
                        value: 'share',
                        label: '分享文件',
                        icon: CupertinoIcons.share,
                      ),
                      if (isDesktopPlatform)
                        const AppMenuAction(
                          value: 'folder',
                          label: '打开所在文件夹',
                          icon: CupertinoIcons.folder_open,
                        ),
                    ],
                    onSelected: (action) => _taskAction(task.id, action),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _authorizeDownload(String id) async {
    if (_authorizingDownload != null) return;
    setState(() => _authorizingDownload = id);
    try {
      await authorizeUcDownload(context, widget.services, id);
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _authorizingDownload = null);
    }
  }

  Future<bool> _checkOpen(DownloadTask task) async {
    final availability = await files.check(task);
    if (!mounted || widget.services.downloads.task(task.id) == null) {
      return false;
    }
    if (availability == FileAvailability.present) return true;
    if (mounted) {
      message(
        context,
        availability == FileAvailability.missing
            ? '文件不存在或已被移动，下载记录已标记'
            : '无法访问文件，请检查目录权限或存储设备',
      );
      await _details(context, task.id);
    }
    return false;
  }

  Future<void> _open(
    DownloadTask task, {
    bool play = false,
    bool reveal = false,
  }) async {
    if (!await _checkOpen(task) || !mounted) return;
    final path = task.savedPath;
    if (path == null) return;
    final kind = fileKind(task.spec.fileName);
    if (!reveal && kind == FileKind.text) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              LocalTextPreviewPage(path: path, name: task.spec.fileName),
        ),
      );
      return;
    }
    if ((Platform.isWindows || Platform.isMacOS) &&
        (reveal || (!play && kind != FileKind.video))) {
      await busy(
        context,
        () => revealDesktopFile(path, widget.services.windows),
        label: Platform.isMacOS ? '在访达中显示…' : '打开资源管理器…',
      );
      return;
    }
    if (kind == FileKind.video || kind == FileKind.audio) {
      if (widget.onPlay != null) {
        await widget.onPlay!(task);
        return;
      }
      final controller = downloadedPlayback(
        widget.services,
        task,
        widget.services.downloads.tasks,
      );
      try {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => PlayerPage(
              controller,
              subtitleDirectory: Directory(
                '${widget.services.cacheDirectory.path}/playback-subtitles',
              ),
            ),
          ),
        );
      } finally {
        widget.services.finishPlaybackInBackground(controller.close());
      }
      return;
    }
    await busy(context, () async {
      if (Platform.isAndroid) {
        await nativeChannelOpen(path, name: task.spec.fileName, share: false);
      } else {
        final result = await OpenFilex.open(path);
        if (result.type != ResultType.done && mounted) {
          message(context, result.message);
        }
      }
    }, label: '打开文件…');
  }

  Future<void> _share(DownloadTask task) async {
    await _externalFileAction(task, share: true);
  }

  Future<void> _externalFileAction(
    DownloadTask task, {
    bool share = false,
  }) async {
    if (_externalFileActionPending) return;
    _externalFileActionPending = true;
    try {
      if (!await _checkOpen(task) || !mounted || task.savedPath == null) return;
      final box = context.findRenderObject() as RenderBox?;
      final origin = box != null && box.hasSize && !box.size.isEmpty
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      if (share) {
        await _fileActions.share(
          task.savedPath!,
          task.spec.fileName,
          origin: origin,
        );
      } else {
        await _fileActions.openWith(
          task.savedPath!,
          task.spec.fileName,
          origin: origin,
        );
      }
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      _externalFileActionPending = false;
    }
  }

  String _connectionLabel(DownloadTask task) {
    if (task.spec.isEd2k) {
      final counts = widget.services.downloads.httpConnections(task.id);
      return counts == null ? 'ED2K' : '${counts.active} 来源';
    }
    if (task.spec.isTorrent) {
      final sources = widget.services.downloads.btSources(task.id);
      return sources == null
          ? 'BT'
          : '${sources.connected + sources.webseeds} 来源';
    }
    if (task.hls.isNotEmpty) return 'HLS';
    final counts = widget.services.downloads.httpConnections(task.id);
    if (counts != null) return '${counts.active} 连接';
    if (task.status == DownloadStatus.running && !task.payloadReady) {
      return '连接中';
    }
    return 'HTTP';
  }

  String _connectionDescription(DownloadTask task) {
    if (task.spec.isEd2k) {
      final counts = widget.services.downloads.httpConnections(task.id);
      return counts == null
          ? 'ED2K · 自动找源与排队'
          : 'ED2K · 传输来源 ${counts.active} / 已知来源 ${counts.total}';
    }
    if (task.spec.isTorrent) {
      final sources = widget.services.downloads.btSources(task.id);
      if (sources == null) return 'BT · 最多 80 个对等节点';
      return 'BT · 已连接 ${sources.connected} / 已知 ${sources.known}\n'
          '完整做种者 ${sources.seeders} · 网页源 ${sources.webseeds} · Tracker ${sources.trackers}\n'
          '上传上限 ${sources.uploadLimit == 0 ? '不限速' : '${formatBytes(sources.uploadLimit)}/s'}'
          '${sources.sessionReused ? '\n已复用同种子连接' : ''}';
    }
    if (task.hls.isNotEmpty) return 'HLS 分片下载 · ${task.retries} 次重试';
    final counts = widget.services.downloads.httpConnections(task.id);
    final active = counts == null
        ? ''
        : '工作连接 ${counts.active} · 分段 ${counts.total}\n';
    final ceiling =
        task.spec.platform == CloudPlatform.aliyun ||
            {'aliyun', 'baidu_direct'}.contains(task.spec.profile)
        ? task.connections.clamp(1, 8)
        : task.connections;
    return '$active连接上限 $ceiling · ${task.retries} 次重试';
  }

  Future<void> _details(BuildContext context, String id) async {
    if (_detailsOpen) return;
    final initial = widget.services.downloads.task(id);
    if (initial == null) return;
    _detailsOpen = true;
    if (initial.status == DownloadStatus.completed) {
      unawaited(files.check(initial));
    }
    String? action;
    try {
      action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: AnimatedBuilder(
            animation: Listenable.merge([widget.services.downloads, files]),
            builder: (context, _) {
              final task = widget.services.downloads.task(id);
              if (task == null) return const SizedBox.shrink();
              final availability = files.state(task);
              return SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.spec.fileName,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (task.status == DownloadStatus.completed &&
                          availability != FileAvailability.present)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '${availability.label}：${availability == FileAvailability.missing ? '文件已被移动或删除，下载记录仍保留。' : '可重新检查文件，也可直接移除下载记录。'}',
                            style: TextStyle(
                              color: availability == FileAvailability.missing
                                  ? Colors.red
                                  : Colors.orange,
                              height: 1.5,
                            ),
                          ),
                        ),
                      Text(
                        '${task.status.label} · ${formatBytes(task.downloaded)} / ${formatBytes(task.total)}\n${_connectionDescription(task)}\n${formatDate(task.createdAt)}',
                        style: TextStyle(
                          height: 1.8,
                          fontSize: 13,
                          color: secondary(context),
                        ),
                      ),
                      if (task.error.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            task.error,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      if (task.savedPath != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: SelectableText(
                            task.savedPath!,
                            style: TextStyle(
                              fontSize: 12,
                              color: secondary(context),
                            ),
                          ),
                        ),
                      const Divider(),
                      if (task.status == DownloadStatus.completed &&
                          availability == FileAvailability.present) ...[
                        ListTile(
                          leading: const Icon(CupertinoIcons.folder),
                          title: Text(
                            isDesktopPlatform &&
                                    fileKind(task.spec.fileName) ==
                                        FileKind.video
                                ? '播放视频'
                                : fileKind(task.spec.fileName) == FileKind.text
                                ? '预览文本 / 代码'
                                : '打开文件',
                          ),
                          subtitle:
                              isDesktopPlatform &&
                                  !{
                                    FileKind.video,
                                    FileKind.text,
                                  }.contains(fileKind(task.spec.fileName))
                              ? Text(Platform.isMacOS ? '在访达中显示' : '在资源管理器中定位')
                              : null,
                          onTap: () => Navigator.pop(context, 'open'),
                        ),
                        if (isDesktopPlatform &&
                            fileKind(task.spec.fileName) == FileKind.audio)
                          ListTile(
                            leading: const Icon(CupertinoIcons.play_rectangle),
                            title: const Text('播放音频'),
                            onTap: () => Navigator.pop(context, 'play'),
                          ),
                        if (isDesktopPlatform &&
                            {
                              FileKind.video,
                              FileKind.text,
                            }.contains(fileKind(task.spec.fileName)))
                          ListTile(
                            leading: const Icon(CupertinoIcons.folder_open),
                            title: const Text('打开所在文件夹'),
                            onTap: () => Navigator.pop(context, 'folder'),
                          ),
                        ListTile(
                          leading: const Icon(CupertinoIcons.share),
                          title: const Text('分享文件'),
                          onTap: () => Navigator.pop(context, 'share'),
                        ),
                        ListTile(
                          leading: const Icon(
                            CupertinoIcons.arrow_up_right_square,
                          ),
                          title: const Text('用其他应用打开'),
                          onTap: () => Navigator.pop(context, 'open-with'),
                        ),
                      ] else if (task.status != DownloadStatus.completed)
                        ListTile(
                          leading: Icon(
                            task.active
                                ? CupertinoIcons.pause
                                : task.needsUcAuthorization
                                ? CupertinoIcons.qrcode
                                : CupertinoIcons.play,
                          ),
                          title: Text(
                            task.active
                                ? '暂停下载'
                                : task.needsUcAuthorization
                                ? '授权并继续下载'
                                : '继续下载',
                          ),
                          subtitle: task.needsUcAuthorization
                              ? const Text('使用原下载账号扫码，完成后自动继续')
                              : null,
                          onTap: () => Navigator.pop(
                            context,
                            task.needsUcAuthorization ? 'authorize' : 'toggle',
                          ),
                        ),
                      if (canRecoverUcPlayable(task))
                        ListTile(
                          leading: const Icon(CupertinoIcons.film),
                          title: const Text('下载可播放版本'),
                          subtitle: const Text('先查看画质和大小，确认后新建任务'),
                          onTap: () => Navigator.pop(context, 'uc-playable'),
                        ),
                      if (task.spec.isTorrent &&
                          task.status != DownloadStatus.completed &&
                          {
                            FileKind.video,
                            FileKind.audio,
                          }.contains(fileKind(task.spec.fileName)))
                        ListTile(
                          key: const Key('torrent-stream-download'),
                          leading: const Icon(CupertinoIcons.play_rectangle),
                          title: const Text('在线播放'),
                          onTap: () => Navigator.pop(context, 'torrent-play'),
                        ),
                      if (task.status != DownloadStatus.completed &&
                          widget.services.downloads.canPlayOnline(task))
                        ListTile(
                          key: const Key('download-stream-play'),
                          leading: const Icon(CupertinoIcons.play_rectangle),
                          title: Text(
                            task.isStreamingPlaylist ? '在线播放' : '边下边播',
                          ),
                          subtitle: Text(
                            task.isStreamingPlaylist
                                ? '播放与下载独立取流，不复用已下载片段'
                                : '开始播放，退出播放器后继续下载',
                          ),
                          onTap: () => Navigator.pop(context, 'download-play'),
                        ),
                      ListTile(
                        leading: const Icon(CupertinoIcons.link),
                        title: const Text('复制下载链接'),
                        enabled: !task.spec.needsPreparation,
                        onTap: task.spec.needsPreparation
                            ? null
                            : () => Navigator.pop(context, 'copy'),
                      ),
                      if (task.status == DownloadStatus.completed)
                        ListTile(
                          leading: const Icon(CupertinoIcons.refresh),
                          title: const Text('重新检查文件'),
                          onTap: () => files.check(task),
                        ),
                      ListTile(
                        key: const Key('downloads-remove-record'),
                        leading: const Icon(
                          CupertinoIcons.trash,
                          color: Colors.red,
                        ),
                        title: Text(
                          task.status == DownloadStatus.completed
                              ? '移除下载记录'
                              : '删除任务',
                          style: const TextStyle(color: Colors.red),
                        ),
                        onTap: () => Navigator.pop(context, 'delete'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    } finally {
      _detailsOpen = false;
    }
    if (!mounted || action == null) return;
    await _taskAction(id, action);
  }

  Future<void> _taskAction(String id, String action) async {
    if (!mounted || _batching) return;
    final task = widget.services.downloads.task(id);
    if (task == null) return;
    switch (action) {
      case 'batch-copy':
      case 'batch-move':
        await _transferSelected(move: action == 'batch-move');
      case 'copy-file':
      case 'move-file':
        await _transferSelected(move: action == 'move-file', ids: [id]);
      case 'details':
        await _details(context, id);
      case 'select':
        _toggleSelection(id);
      case 'clear-selection':
        _exitSelection();
      case 'batch-pause':
        await _runSelectedAction(DownloadBatchAction.pause);
      case 'batch-resume':
        await _runSelectedAction(DownloadBatchAction.resume);
      case 'batch-delete':
        await _deleteSelectedDialog();
      case 'copy-name':
        await widget.services.copyText(task.spec.fileName);
        if (mounted) message(context, '文件名已复制');
      case 'check':
        await files.check(task);
      case 'pause':
        if (task.active) {
          await busy(context, () => widget.services.downloads.pause(id));
        }
      case 'resume':
        if (!task.active &&
            task.status != DownloadStatus.completed &&
            !task.needsUcAuthorization) {
          await busy(context, () => widget.services.downloads.resume(id));
        }
      case 'authorize':
        await _authorizeDownload(id);
      case 'uc-playable':
        if (canRecoverUcPlayable(task)) {
          await downloadUcPlayable(
            context,
            widget.services,
            origin: DownloadOrigin.fromJson(task.spec.source!),
          );
        }
      case 'torrent-play':
      case 'download-play':
        try {
          final controller = action == 'torrent-play'
              ? torrentDownloadPlayback(widget.services, task)
              : downloadPlayback(widget.services, task);
          try {
            await Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => PlayerPage(
                  controller,
                  subtitleDirectory: Directory(
                    '${widget.services.cacheDirectory.path}/playback-subtitles',
                  ),
                ),
              ),
            );
          } finally {
            widget.services.finishPlaybackInBackground(controller.close());
          }
        } catch (e) {
          if (mounted) {
            message(context, e is AppException ? e.message : '无法开始播放，请重试');
          }
        }
      case 'open':
        await _open(task);
      case 'play':
        await _open(task, play: true);
      case 'folder':
        await _open(task, reveal: true);
      case 'share':
        await _share(task);
      case 'open-with':
        await _externalFileAction(task);
      case 'copy':
        if (task.spec.needsPreparation) {
          message(context, '下载链接尚未准备好，请稍后重试');
          return;
        }
        await Clipboard.setData(ClipboardData(text: task.spec.url));
        if (mounted) message(context, '下载链接已复制');
      case 'toggle':
        await busy(
          context,
          () => task.active
              ? widget.services.downloads.pause(id)
              : widget.services.downloads.resume(id),
        );
      case 'delete':
        await _deleteDialog(task);
    }
  }

  Future<void> _deleteDialog(DownloadTask task) async {
    final availability = files.state(task);
    final missing = availability == FileAvailability.missing;
    final completed = task.status == DownloadStatus.completed;
    var deleteFile = false;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(completed ? '移除下载记录' : '删除任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.spec.fileName,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Text(
                  completed
                      ? switch (availability) {
                          FileAvailability.missing =>
                            '文件已不存在，将移除这条下载记录。残留缓存会自动清理。',
                          FileAvailability.inaccessible =>
                            '当前无法访问原文件，仍可直接移除这条下载记录。',
                          FileAvailability.unknown => '文件状态尚未确认，仍可直接移除这条下载记录。',
                          FileAvailability.present => '从下载列表移除这条记录，已下载的文件默认保留。',
                        }
                      : '会先停止下载并自动清理未完成缓存，删除后无法续传。未勾选下方选项时，已保存到下载目录的文件会保留。',
                ),
                if (!completed || task.savedPath != null && !missing)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(completed ? '同时删除已下载的文件' : '同时删除本地文件'),
                    subtitle: completed
                        ? null
                        : const Text('包括已保存的文件和保存中断后的残留文件'),
                    value: deleteFile,
                    onChanged: (v) => setLocal(() => deleteFile = v ?? false),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              key: const Key('downloads-confirm-single-delete'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                completed && !deleteFile ? '移除记录' : '删除',
                style: const TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      ),
    );
    if (approved == true && mounted) {
      await busy(
        context,
        () => widget.services.downloads.delete(task.id, deleteFile: deleteFile),
        label: completed && !deleteFile ? '正在移除记录…' : '正在删除…',
      );
    }
  }
}

Future<void> nativeChannelOpen(
  String path, {
  required String name,
  required bool share,
}) async {
  try {
    await const MethodChannel('com.asterlink.app/native').invokeMethod<void>(
      share ? 'shareFile' : 'openFile',
      {'path': path, 'name': name},
    );
  } on PlatformException catch (error) {
    throw AppException(error.message ?? '无法打开此文件，请检查文件权限');
  }
}
