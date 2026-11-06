import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../data/cloud_favorites.dart';
import '../domain/models.dart';
import 'app_popup_menu.dart';
import 'app_context_menu.dart';
import 'browser_page.dart';
import 'common.dart';

Future<void> openCloudFavorite(
  BuildContext context,
  AppServices services,
  CloudFavorite favorite,
) async {
  final value = await busy(
    context,
    () => services.favorites.open(favorite),
    label: '正在打开收藏位置…',
  );
  if (value == null || !context.mounted) return;
  await Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => BrowserPage(
        services,
        value.session,
        initialItems: value.files,
        initialTrail: value.trail,
        highlightedFileId: value.highlight,
      ),
    ),
  );
}

Future<void> _renameCloudFavorite(
  BuildContext context,
  AppServices services,
  CloudFavorite favorite,
) async {
  final name = await askText(
    context,
    '自定义收藏名称',
    initial: favorite.customName,
    hint: '最多 80 字，留空恢复原名称',
  );
  if (name == null || !context.mounted) return;
  await busy(context, () => services.favorites.rename(favorite.id, name));
}

ParsedLink? _favoriteCopyLink(CloudFavorite favorite) {
  final link = favorite.session.sourceLink;
  return link != null && link.url.isNotEmpty ? link : null;
}

String _favoriteCopyLabel(CloudFavorite favorite) =>
    _favoriteCopyLink(favorite) == null ? '复制名称' : '复制分享链接';

Future<void> _copyCloudFavorite(
  BuildContext context,
  AppServices services,
  CloudFavorite favorite,
) async {
  final link = _favoriteCopyLink(favorite);
  try {
    await services.copyText(link?.textForCopy ?? favorite.name);
    if (context.mounted) {
      message(context, link == null ? '名称已复制' : '分享链接已复制');
    }
  } catch (e) {
    if (context.mounted) message(context, errorText(e));
  }
}

List<AppMenuAction<String>> _favoriteActions(CloudFavorite favorite) => [
  const AppMenuAction(
    value: 'open',
    label: '打开收藏位置',
    icon: CupertinoIcons.folder_open,
  ),
  const AppMenuAction(
    value: 'rename',
    label: '自定义名称',
    icon: CupertinoIcons.pencil,
  ),
  AppMenuAction(
    value: favorite.pinned ? 'unpin' : 'pin',
    label: favorite.pinned ? '取消置顶' : '置顶',
    icon: favorite.pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
  ),
  AppMenuAction(
    value: 'copy',
    label: _favoriteCopyLabel(favorite),
    icon: CupertinoIcons.doc_on_doc,
  ),
  if (_favoriteCopyLink(favorite) != null)
    const AppMenuAction(
      value: 'copy-name',
      label: '复制名称',
      icon: CupertinoIcons.textformat,
    ),
  const AppMenuAction(
    value: 'remove',
    label: '取消收藏',
    icon: CupertinoIcons.star_slash,
  ),
];

class _FavoriteSortMenu extends StatelessWidget {
  const _FavoriteSortMenu(this.services, {this.enabled = true});
  final AppServices services;
  final bool enabled;

  @override
  Widget build(BuildContext context) => AppPopupMenuButton<CloudFavoriteSort>(
    tooltip: '收藏排序',
    icon: CupertinoIcons.sort_down,
    actions: [
      for (final sort in CloudFavoriteSort.values)
        AppMenuAction(
          value: sort,
          label: sort.label,
          icon: switch (sort) {
            CloudFavoriteSort.manual => CupertinoIcons.hand_draw,
            CloudFavoriteSort.newest => CupertinoIcons.star,
            CloudFavoriteSort.recent => CupertinoIcons.clock,
            CloudFavoriteSort.name => CupertinoIcons.textformat_abc,
          },
          selected: services.favorites.sort == sort,
          enabled: enabled,
        ),
    ],
    onSelected: (sort) async {
      try {
        await services.favorites.setSort(sort);
      } catch (e) {
        if (context.mounted) message(context, errorText(e));
      }
    },
  );
}

class CloudFavoritesPage extends StatefulWidget {
  const CloudFavoritesPage(
    this.services, {
    super.key,
    this.platform,
    this.accountId,
    this.organize = false,
  });
  final AppServices services;
  final CloudPlatform? platform;
  final String? accountId;
  final bool organize;
  @override
  State<CloudFavoritesPage> createState() => _CloudFavoritesPageState();
}

class _CloudFavoritesPageState extends State<CloudFavoritesPage> {
  final _search = TextEditingController();
  late bool _organizing = widget.organize;
  bool _saving = false;
  bool get _desktop => const {
    TargetPlatform.windows,
    TargetPlatform.macOS,
  }.contains(Theme.of(context).platform);
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(CloudFavorite favorite) =>
      openCloudFavorite(context, widget.services, favorite);

  Future<void> _rename(CloudFavorite favorite) =>
      _renameCloudFavorite(context, widget.services, favorite);

  Future<void> _action(CloudFavorite selected, String action) async {
    final favorite = widget.services.favorites.all
        .where((f) => f.id == selected.id)
        .firstOrNull;
    if (favorite == null) return;
    switch (action) {
      case 'open':
        await _open(favorite);
      case 'rename':
        await _rename(favorite);
      case 'pin':
      case 'unpin':
        await busy(
          context,
          () =>
              widget.services.favorites.setPinned(favorite.id, action == 'pin'),
        );
      case 'copy':
        await _copyCloudFavorite(context, widget.services, favorite);
      case 'remove':
        await busy(
          context,
          () => widget.services.favorites.remove(favorite.id),
        );
      case 'copy-name':
        await widget.services.copyText(favorite.name);
        if (mounted) message(context, '名称已复制');
    }
  }

  Future<void> _reorder(
    List<CloudFavorite> visible,
    int oldIndex,
    int newIndex,
  ) async {
    if (_saving || (!_organizing && !_desktop)) return;
    if (oldIndex < newIndex) newIndex--;
    if (oldIndex == newIndex) return;
    final favorite = visible[oldIndex];
    final ids = visible.map((item) => item.id).toList();
    ids.removeAt(oldIndex);
    final pinnedCount = visible.where((item) => item.pinned).length;
    final destination = favorite.pinned
        ? newIndex.clamp(0, pinnedCount - 1)
        : newIndex.clamp(pinnedCount, ids.length);
    if (destination == oldIndex) return;
    ids.insert(destination, favorite.id);
    setState(() => _saving = true);
    try {
      await widget.services.favorites.reorder(ids);
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _contextMenu(CloudFavorite favorite, Widget child) =>
      AppContextMenu<String>(
        key: ValueKey(favorite.id),
        identity: favorite.id,
        enabled: !_organizing && !_saving,
        actions: () =>
            widget.services.favorites.all.any((f) => f.id == favorite.id)
            ? _favoriteActions(favorite)
            : [],
        onSelected: (action) => _action(favorite, action),
        child: child,
      );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.services.store,
    builder: (context, _) => PageFrame(
      title: '网盘收藏',
      actions: [
        if (!_organizing) _FavoriteSortMenu(widget.services, enabled: !_saving),
        TextButton(
          key: const Key('favorites-organize'),
          onPressed: _saving
              ? null
              : () => setState(() => _organizing = !_organizing),
          child: Text(_organizing ? '完成' : '整理'),
        ),
        const SizedBox(width: 8),
      ],
      child: Builder(
        builder: (context) {
          final query = _search.text.trim().toLowerCase();
          final favorites = widget.services.favorites.all
              .where(
                (f) =>
                    (widget.platform == null ||
                        widget.platform == f.session.platform) &&
                    (widget.accountId == null ||
                        widget.accountId == f.session.accountId) &&
                    (query.isEmpty ||
                        f.name.toLowerCase().contains(query) ||
                        f.file.name.toLowerCase().contains(query) ||
                        (f.isShareLink &&
                            (f.session.sourceLink?.url.toLowerCase().contains(
                                  query,
                                ) ??
                                false)) ||
                        f.location.toLowerCase().contains(query)),
              )
              .toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    hintText: '搜索收藏名称、目录或分享链接',
                    prefixIcon: Icon(CupertinoIcons.search, size: 19),
                  ),
                ),
              ),
              if (_organizing || _desktop)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '拖动右侧手柄调整顺序，自动保存。置顶收藏始终在前。',
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                  ),
                ),
              Expanded(
                child: favorites.isEmpty
                    ? const EmptyPanel(
                        '暂无收藏',
                        '可收藏文件、文件夹，也可在解析结果顶部收藏分享链接。',
                        icon: CupertinoIcons.star,
                      )
                    : ReorderableListView.builder(
                        key: const Key('favorites-reorder-list'),
                        buildDefaultDragHandles: false,
                        onReorder: (oldIndex, newIndex) =>
                            unawaited(_reorder(favorites, oldIndex, newIndex)),
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: favorites.length,
                        itemBuilder: (context, index) {
                          final favorite = favorites[index];
                          final account = widget.services.vault
                              .profiles(favorite.session.platform)
                              .where((a) => a.id == favorite.session.accountId)
                              .firstOrNull;
                          return Padding(
                            key: ValueKey('favorite-row-${favorite.id}'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _contextMenu(
                              favorite,
                              Material(
                                color: Theme.of(context).colorScheme.surface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: border(context)),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: ListTile(
                                  key: ValueKey('favorite-${favorite.id}'),
                                  leading: favorite.isShareLink
                                      ? const Icon(
                                          CupertinoIcons.link,
                                          color: Color(0xffe6a23c),
                                        )
                                      : FileGlyph(
                                          favorite.file.name,
                                          directory: favorite.file.isDirectory,
                                        ),
                                  title: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          favorite.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (favorite.pinned) ...[
                                        const SizedBox(width: 6),
                                        Icon(
                                          CupertinoIcons.pin_fill,
                                          key: ValueKey(
                                            'favorite-pin-${favorite.id}',
                                          ),
                                          size: 14,
                                          color: themeAccent(context),
                                          semanticLabel: '已置顶',
                                        ),
                                      ],
                                    ],
                                  ),
                                  subtitle: Text(
                                    '${favorite.session.platform.shortName}${account == null ? '' : ' · ${account.name}'}\n${favorite.location}',
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  isThreeLine: true,
                                  onTap: _organizing || _saving
                                      ? null
                                      : () => _open(favorite),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!_organizing) ...[
                                        IconButton(
                                          key: ValueKey(
                                            'favorite-copy-${favorite.id}',
                                          ),
                                          tooltip: _favoriteCopyLabel(favorite),
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(
                                            CupertinoIcons.doc_on_doc,
                                            size: 19,
                                          ),
                                          onPressed: () =>
                                              _action(favorite, 'copy'),
                                        ),
                                        AppPopupMenuButton<String>(
                                          tooltip: '${favorite.name}的收藏操作',
                                          icon: CupertinoIcons.ellipsis,
                                          actions: _favoriteActions(favorite)
                                              .where(
                                                (action) =>
                                                    action.value != 'open',
                                              )
                                              .toList(),
                                          onSelected: (action) =>
                                              _action(favorite, action),
                                        ),
                                      ],
                                      if (_organizing || _desktop)
                                        ReorderableDragStartListener(
                                          key: ValueKey(
                                            'favorite-drag-${favorite.id}',
                                          ),
                                          index: index,
                                          enabled: !_saving,
                                          child: Tooltip(
                                            message: '拖动排序',
                                            child: MouseRegion(
                                              cursor: _saving
                                                  ? SystemMouseCursors.basic
                                                  : SystemMouseCursors.grab,
                                              child: const SizedBox(
                                                width: 36,
                                                height: 48,
                                                child: Icon(
                                                  CupertinoIcons
                                                      .line_horizontal_3,
                                                  size: 20,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class CloudFavoritesSummary extends StatefulWidget {
  const CloudFavoritesSummary(
    this.services, {
    super.key,
    required this.desktop,
    this.enabled = true,
  });
  final AppServices services;
  final bool desktop, enabled;

  @override
  State<CloudFavoritesSummary> createState() => _CloudFavoritesSummaryState();
}

class _CloudFavoritesSummaryState extends State<CloudFavoritesSummary> {
  final _scroll = ScrollController();
  bool _opening = false, _menuOpen = false, _saving = false;
  String? _dragging;
  bool get _android => Theme.of(context).platform == TargetPlatform.android;

  List<AppMenuAction<String>> _homeActions(CloudFavorite favorite) => [
    ..._favoriteActions(
      favorite,
    ).where((action) => action.value != 'copy' && action.value != 'copy-name'),
    const AppMenuAction(
      value: 'organize',
      label: '整理收藏',
      icon: CupertinoIcons.line_horizontal_3,
    ),
  ];

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open(CloudFavorite favorite) async {
    if (_opening || _saving || _dragging != null || !widget.enabled) return;
    setState(() => _opening = true);
    try {
      await openCloudFavorite(context, widget.services, favorite);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _action(String id, String action) async {
    if (!mounted || !widget.enabled || _opening || _saving) return;
    final favorite = widget.services.favorites.all
        .where((f) => f.id == id)
        .firstOrNull;
    if (favorite == null) return;
    switch (action) {
      case 'open':
        await _open(favorite);
      case 'rename':
        await _renameCloudFavorite(context, widget.services, favorite);
      case 'pin':
      case 'unpin':
        await busy(
          context,
          () => widget.services.favorites.setPinned(id, action == 'pin'),
        );
      case 'organize':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => CloudFavoritesPage(widget.services, organize: true),
          ),
        );
      case 'remove':
        await busy(context, () => widget.services.favorites.remove(id));
    }
  }

  Future<void> _menu(CloudFavorite favorite) async {
    if (_menuOpen || _opening || _saving || !widget.enabled) return;
    _menuOpen = true;
    String? action;
    try {
      action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    favorite.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(_location(favorite)),
                ),
                for (final action in _homeActions(favorite))
                  ListTile(
                    leading: Icon(action.icon),
                    title: Text(action.label),
                    onTap: () => Navigator.pop(context, action.value),
                  ),
              ],
            ),
          ),
        ),
      );
    } finally {
      _menuOpen = false;
    }
    if (action != null) await _action(favorite.id, action);
  }

  Future<void> _drop(String source, String target) async {
    if (!mounted || !widget.enabled || _saving || _opening) return;
    final favorites = widget.services.favorites.all;
    final from = favorites.indexWhere((favorite) => favorite.id == source);
    final to = favorites.indexWhere((favorite) => favorite.id == target);
    if (from < 0 ||
        to < 0 ||
        from == to ||
        favorites[from].pinned != favorites[to].pinned) {
      return;
    }
    final ids = favorites.map((favorite) => favorite.id).toList();
    ids.removeAt(from);
    ids.insert(to, source);
    setState(() => _saving = true);
    try {
      await widget.services.favorites.reorder(ids);
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _dragTarget(CloudFavorite favorite, Widget child, bool enabled) {
    if (!const {
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }.contains(Theme.of(context).platform)) {
      return child;
    }
    return DragTarget<String>(
      key: ValueKey('home-favorite-drag-${favorite.id}'),
      onWillAcceptWithDetails: (details) {
        final source = widget.services.favorites.all
            .where((item) => item.id == details.data)
            .firstOrNull;
        return enabled &&
            source != null &&
            source.id != favorite.id &&
            source.pinned == favorite.pinned;
      },
      onAcceptWithDetails: (details) =>
          unawaited(_drop(details.data, favorite.id)),
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? null
              : themeAccent(context).withValues(alpha: .12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Draggable<String>(
          data: favorite.id,
          maxSimultaneousDrags: enabled ? 1 : 0,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          onDragStarted: () => setState(() => _dragging = favorite.id),
          onDragEnd: (_) {
            if (mounted) setState(() => _dragging = null);
          },
          feedback: Material(
            color: Colors.transparent,
            child: Opacity(
              opacity: .85,
              child: Container(
                width: 88,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: border(context)),
                  boxShadow: const [
                    BoxShadow(color: Color(0x24000000), blurRadius: 14),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      backgroundColor: _favoriteColor(favorite.id),
                      foregroundColor: Colors.white,
                      child: Text(_favoriteInitial(favorite.name)),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      favorite.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: .3, child: child),
          child: child,
        ),
      ),
    );
  }

  Widget _grid(List<CloudFavorite> favorites, bool enabled) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 8.0;
      final android = _android;
      final displayed = android
          ? favorites.take(12).toList(growable: false)
          : favorites;
      final fontSize = android ? 11.0 : 13.0;
      final scaler = MediaQuery.textScalerOf(context);
      final scale = scaler.scale(fontSize) / fontSize;
      final minWidth = widget.desktop ? 64.0 : 68.0;
      final columns = android
          ? 4
          : ((constraints.maxWidth + gap) /
                    (minWidth * scale.clamp(1, 2.5) + gap))
                .floor()
                .clamp(1, 8);
      final diameter = android
          ? 40.0
          : (widget.desktop ? 46.0 : 50.0) * scale.clamp(1, 1.35);
      final captionHeight =
          (scaler.scale(fontSize) * 1.3 * (android ? 1 : 2)).ceilToDouble() + 2;
      final extent = diameter + 14 + captionHeight;
      final rows = (displayed.length / columns).ceil();
      final visibleRows = android ? rows : rows.clamp(1, 4);
      // Android previews twelve favorites; the full collection stays in All.
      final grid = GridView.builder(
        key: const Key('home-favorites-grid'),
        controller: _scroll,
        primary: false,
        physics: rows > visibleRows
            ? const ClampingScrollPhysics()
            : const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: gap,
          mainAxisSpacing: gap,
          mainAxisExtent: extent,
        ),
        itemCount: displayed.length,
        itemBuilder: (context, index) {
          final favorite = displayed[index];
          return _dragTarget(
            favorite,
            AppContextMenu<String>(
              key: ValueKey('home-favorite-${favorite.id}'),
              identity: favorite.id,
              enabled: enabled,
              actions: () =>
                  widget.services.favorites.all.any((f) => f.id == favorite.id)
                  ? _homeActions(favorite)
                  : [],
              onSelected: (action) => _action(favorite.id, action),
              child: Tooltip(
                message: '${favorite.name}\n${_location(favorite)}',
                excludeFromSemantics: true,
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: enabled ? () => _open(favorite) : null,
                    onLongPress: enabled ? () => _menu(favorite) : null,
                    child: Opacity(
                      opacity: enabled ? 1 : .5,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          children: [
                            Stack(
                              children: [
                                SizedBox(
                                  height: diameter,
                                  width: diameter,
                                  child: ExcludeSemantics(
                                    child: CircleAvatar(
                                      key: ValueKey(
                                        'favorite-avatar-${favorite.id}',
                                      ),
                                      radius: diameter / 2,
                                      backgroundColor: _favoriteColor(
                                        favorite.id,
                                      ),
                                      foregroundColor: Colors.white,
                                      child: Padding(
                                        padding: const EdgeInsets.all(6),
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            _favoriteInitial(favorite.name),
                                            style: TextStyle(
                                              fontSize: android ? 20 : 25,
                                              height: 1.1,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (favorite.pinned)
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.surface,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(2),
                                        child: Icon(
                                          CupertinoIcons.pin_fill,
                                          key: ValueKey(
                                            'home-favorite-pin-${favorite.id}',
                                          ),
                                          size: 12,
                                          color: themeAccent(context),
                                          semanticLabel: '已置顶',
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            SizedBox(height: android ? 6 : 4),
                            Text(
                              android
                                  ? _favoriteCaption(favorite.name)
                                  : favorite.name,
                              key: ValueKey('favorite-caption-${favorite.id}'),
                              semanticsLabel: favorite.name,
                              maxLines: android ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: fontSize,
                                height: 1.3,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            enabled,
          );
        },
      );
      return SizedBox(
        height: visibleRows * extent + (visibleRows - 1) * gap,
        child: android
            ? grid
            : Scrollbar(
                controller: _scroll,
                thumbVisibility: rows > visibleRows,
                thickness: 3,
                radius: const Radius.circular(3),
                child: grid,
              ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.services.store,
    builder: (context, _) {
      final favorites = widget.services.favorites.all;
      final enabled = widget.enabled && !_opening && !_saving;
      final accent = Theme.of(context).brightness == Brightness.dark
          ? const Color(0xffffca70)
          : const Color(0xffa66b0a);
      return Padding(
        padding: EdgeInsets.all(
          widget.desktop ? (favorites.isEmpty ? 20 : 16) : 18,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    key: const Key('parse-favorites'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: enabled
                        ? () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  CloudFavoritesPage(widget.services),
                            ),
                          )
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Icon(
                            CupertinoIcons.star_fill,
                            size: 18,
                            color: accent,
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Text(
                              '网盘收藏',
                              style: TextStyle(
                                fontSize: widget.desktop ? 14 : 18,
                                fontWeight: widget.desktop
                                    ? FontWeight.w600
                                    : FontWeight.w800,
                              ),
                            ),
                          ),
                          Text(
                            favorites.isEmpty ? '全部' : '全部 ${favorites.length}',
                            style: TextStyle(fontSize: 12, color: accent),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            CupertinoIcons.chevron_right,
                            size: 14,
                            color: accent,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (favorites.isNotEmpty)
                  _FavoriteSortMenu(
                    widget.services,
                    enabled: enabled && _dragging == null,
                  ),
              ],
            ),
            SizedBox(height: favorites.isEmpty ? 10 : 14),
            if (favorites.isEmpty)
              Text(
                '收藏分享链接、文件或文件夹，下次从这里直达',
                style: TextStyle(fontSize: 13, color: secondary(context)),
              )
            else
              _grid(favorites, enabled),
          ],
        ),
      );
    },
  );

  String _location(CloudFavorite favorite) {
    final account = widget.services.vault
        .profiles(favorite.session.platform)
        .where((a) => a.id == favorite.session.accountId)
        .firstOrNull;
    return '${favorite.session.platform.shortName}'
        '${account == null ? '' : ' · ${account.name}'}'
        ' · ${favorite.isShareLink
            ? '分享链接 · ${favorite.session.sourceLink?.url ?? ''}'
            : favorite.file.isDirectory
            ? '直达文件夹'
            : '打开所在文件夹'}';
  }
}

String _favoriteInitial(String name) {
  final first = name.trim().characters.firstOrNull;
  return first == null ? '藏' : first.toUpperCase().characters.first;
}

String _favoriteCaption(String name) {
  final characters = name.trim().replaceAll(RegExp(r'\s+'), ' ').characters;
  return characters.length <= 6
      ? characters.toString()
      : '${characters.take(5)}…';
}

Color _favoriteColor(String id) {
  const colors = [
    Color(0xff56877f),
    Color(0xff7b8d50),
    Color(0xff6385af),
    Color(0xff9b6a80),
    Color(0xff8870a6),
    Color(0xffaa784b),
    Color(0xff558b9e),
    Color(0xff828076),
    Color(0xff63896e),
    Color(0xff777f9f),
  ];
  // The same favorite keeps its color after a rename, reorder or app restart.
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return colors[hash % colors.length];
}
