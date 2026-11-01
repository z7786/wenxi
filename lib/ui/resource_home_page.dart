import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/resource_link_checks.dart';
import '../domain/resource_search.dart';
import 'common.dart';
import 'resource_search_bar.dart';
import 'resource_preferences.dart';
import 'resource_search_page.dart';

class ResourceHomePage extends StatefulWidget {
  const ResourceHomePage(
    this.services, {
    super.key,
    required this.onOpen,
    this.active = true,
  });
  final AppServices services;
  final Future<void> Function(ResourceSearchHit) onOpen;
  final bool active;
  @override
  State<ResourceHomePage> createState() => _ResourceHomePageState();
}

class _ResourceHomePageState extends State<ResourceHomePage>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  final scroll = ScrollController();
  final viewportKey = GlobalKey();
  final rowKeys = <String, GlobalKey>{};
  bool visibilityScheduled = false;
  ResourceCatalog get catalog => widget.services.resourceSearch.catalog;
  Set<String> get loading => widget.services.resourceSearch.catalogLoading;
  String get error => widget.services.resourceSearch.catalogError;
  String? opening;
  bool get loaded => widget.services.resourceSearch.catalogLoaded;
  int catalogRevision = 0;
  String tileKey(ResourceSearchHit hit) =>
      '${hit.recommendationId}:${resourceLinkKey(hit)}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(scheduleVisibility);
    catalogRevision = widget.services.resourceSearch.catalogRevision;
    widget.services.resourceSearch.addListener(catalogChanged);
    if (widget.active) {
      unawaited(widget.services.resourceSearch.loadCatalog());
    }
  }

  @override
  void didUpdateWidget(ResourceHomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      unawaited(widget.services.resourceSearch.loadCatalog());
      scheduleVisibility();
    } else if (!widget.active && oldWidget.active) {
      widget.services.resourceSearch.linkChecks?.clearVisible();
    }
  }

  void catalogChanged() {
    final revision = widget.services.resourceSearch.catalogRevision;
    if (!mounted || revision == catalogRevision) return;
    setState(() => catalogRevision = revision);
    scheduleVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      scheduleVisibility();
    } else {
      widget.services.resourceSearch.linkChecks?.clearVisible();
    }
  }

  @override
  void didChangeMetrics() => scheduleVisibility();

  void scheduleVisibility() {
    final checks = widget.services.resourceSearch.linkChecks;
    if (!mounted || !widget.active || checks == null || visibilityScheduled) {
      return;
    }
    visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      visibilityScheduled = false;
      if (!mounted ||
          !widget.active ||
          opening != null ||
          ModalRoute.of(context)?.isCurrent == false ||
          WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed) {
        return;
      }
      final viewport = viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
        return;
      }
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      final rows = [
        ...catalog.popular,
        ...catalog.categories.expand((c) => c.resources),
      ];
      final currentKeys = rows.map(tileKey).toSet();
      rowKeys.removeWhere((key, _) => !currentKeys.contains(key));
      checks.setVisible(
        rows.where((hit) {
          final box = rowKeys[tileKey(hit)]?.currentContext?.findRenderObject();
          return box is RenderBox &&
              box.attached &&
              box.hasSize &&
              bounds.overlaps(box.localToGlobal(Offset.zero) & box.size);
        }),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    widget.services.resourceSearch.removeListener(catalogChanged);
    WidgetsBinding.instance.removeObserver(this);
    widget.services.resourceSearch.linkChecks?.clearVisible();
    scroll.dispose();
    input.dispose();
    super.dispose();
  }

  Future<void> load({String section = ''}) => widget.services.resourceSearch
      .loadCatalog(section: section, refresh: true);

  Future<void> submit([String? keyword]) async {
    final term = (keyword ?? input.text).trim();
    if (term.isEmpty || opening != null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final search = widget.services.resourceSearch;
    search.filter(null);
    search.setKeywordFilters();
    unawaited(search.search(term));
    search.linkChecks?.clearVisible();
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/resources/search'),
      builder: (_) =>
          ResourceSearchPage(widget.services, onOpen: widget.onOpen),
    );
    await Navigator.push<void>(context, route);
    await route.completed;
    if (mounted) {
      search.stop();
      scheduleVisibility();
    }
  }

  Future<void> clearHistory() async {
    try {
      await widget.services.resourceSearch.clearHistory();
    } catch (e) {
      if (mounted) message(context, errorText(e));
    }
  }

  Widget recentSearches(BuildContext context) {
    final search = widget.services.resourceSearch;
    final history = search.history;
    if (history.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_rounded, size: 17, color: secondary(context)),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  '最近搜索',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                key: const Key('resource-home-clear-history'),
                onPressed: clearHistory,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '清空',
                  style: TextStyle(fontSize: 12, color: secondary(context)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            key: ValueKey('resource-home-history-list-${history.first}'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final term in history)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      key: ValueKey('resource-home-history-$term'),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          term,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onPressed: opening == null
                          ? () {
                              input.value = TextEditingValue(
                                text: term,
                                selection: TextSelection.collapsed(
                                  offset: term.length,
                                ),
                              );
                              unawaited(submit(term));
                            }
                          : null,
                      labelStyle: const TextStyle(fontSize: 12),
                      backgroundColor: fill(context),
                      side: BorderSide(color: border(context), width: .6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> open(ResourceSearchHit hit) async {
    if (opening != null) return;
    final selected = await _selectLink(hit);
    if (selected == null) return;
    setState(() => opening = selected.identity);
    widget.services.resourceSearch.linkChecks?.clearVisible();
    try {
      if (selected.canParse ||
          widget.services.sources.candidates(selected.url).isNotEmpty) {
        await widget.onOpen(selected);
      } else if (!await launchUrl(
        Uri.parse(selected.url),
        mode: LaunchMode.externalApplication,
      )) {
        throw const AppException('无法打开资源链接');
      }
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) {
        setState(() => opening = null);
        scheduleVisibility();
      }
    }
  }

  Future<ResourceSearchHit?> _selectLink(ResourceSearchHit hit) async {
    if (hit.links.length <= 1 || !mounted) return hit;
    final selected = await showModalBottomSheet<ResourceSearchLink>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('选择网盘入口')),
            for (final link in hit.links)
              ListTile(
                leading: const Icon(Icons.cloud_outlined),
                title: Text(link.cloudName),
                subtitle: Text(
                  link.password.isEmpty
                      ? link.url
                      : '${link.url}\n提取码：${link.password}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(sheetContext, link),
              ),
          ],
        ),
      ),
    );
    return selected == null ? null : hit.withLink(selected);
  }

  Widget sectionHeader(String name, String section, {bool popular = false}) =>
      Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 10),
        child: Row(
          children: [
            if (popular) ...[
              const Icon(
                Icons.local_fire_department_rounded,
                color: Color(0xffff674c),
                size: 23,
              ),
              const SizedBox(width: 5),
            ],
            Expanded(
              child: Text(
                name,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.3,
                ),
              ),
            ),
            TextButton.icon(
              key: ValueKey('resource-section-refresh-$section'),
              onPressed:
                  loading.contains(section) ||
                      loading.contains('') ||
                      opening != null
                  ? null
                  : () => load(section: section),
              icon: loading.contains(section)
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.7),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('换一批', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    scheduleVisibility();
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final width = math.min(bounds.maxWidth, 1120.0);
          final padding = width >= 800 ? 32.0 : 20.0;
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final popularColumns = width >= 800 ? 4 : 2;
          final categoryColumns = width >= 800
              ? 6
              : scale > 1.6
              ? 2
              : 3;
          Widget grid(List<ResourceSearchHit> rows, bool popular) {
            final columns = popular ? popularColumns : categoryColumns;
            final tileWidth =
                (width - padding * 2 - 12 * (columns - 1)) / columns;
            return SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent:
                      tileWidth / (popular ? 1.85 : 1) +
                      (popular ? 68 : 48) * math.max(scale, 1),
                ),
                delegate: SliverChildBuilderDelegate((context, index) {
                  final hit = rows[index];
                  final checks = widget.services.resourceSearch.linkChecks;
                  Widget tile() => _ResourceCoverTile(
                    hit,
                    popular: popular,
                    opening: opening == hit.identity,
                    health: checks?.health(hit),
                    onTap: opening == null ? () => open(hit) : null,
                  );
                  return SizedBox(
                    key: rowKeys.putIfAbsent(tileKey(hit), GlobalKey.new),
                    child: checks == null
                        ? tile()
                        : ListenableBuilder(
                            listenable: checks,
                            builder: (_, _) => tile(),
                          ),
                  );
                }, childCount: rows.length),
              ),
            );
          }

          return Center(
            child: SizedBox(
              key: viewportKey,
              width: width,
              child: RefreshIndicator(
                onRefresh: () => load(),
                child: CustomScrollView(
                  controller: scroll,
                  key: const PageStorageKey('resource-catalog-home'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(padding, 24, padding, 0),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text.rich(
                                        TextSpan(
                                          children: [
                                            const TextSpan(text: '网盘'),
                                            TextSpan(
                                              text: '搜索',
                                              style: TextStyle(
                                                color: themeAccent(context),
                                              ),
                                            ),
                                          ],
                                        ),
                                        style: const TextStyle(
                                          fontSize: 30,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -1,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        '发现好资源，搜索更简单',
                                        style: TextStyle(
                                          fontSize: 13,
                                          color: secondary(context),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  key: const Key('resource-priority-settings'),
                                  tooltip: '网盘展示优先级',
                                  onPressed: () => showResourcePrioritySheet(
                                    context,
                                    widget.services.resourceSearch,
                                  ),
                                  icon: const Icon(
                                    Icons.settings_outlined,
                                    size: 23,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 23),
                            ResourceSearchBar(
                              buttonKey: const Key(
                                'resource-home-search-submit',
                              ),
                              onPressed: () => submit(),
                              field: TextField(
                                key: const Key('resource-home-search-input'),
                                controller: input,
                                maxLength: 120,
                                textInputAction: TextInputAction.search,
                                onSubmitted: (_) => submit(),
                                style: const TextStyle(fontSize: 15),
                                decoration: InputDecoration(
                                  counterText: '',
                                  hintText: '搜索电影、学习资料、软件…',
                                  hintStyle: TextStyle(
                                    fontSize: 13,
                                    color: secondary(context),
                                  ),
                                  prefixIcon: Icon(
                                    Icons.search_rounded,
                                    size: 20,
                                    color: secondary(context),
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                            AnimatedBuilder(
                              animation: widget.services.resourceSearch.store,
                              builder: (context, _) {
                                scheduleVisibility();
                                return recentSearches(context);
                              },
                            ),
                            if (error.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        error,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: secondary(context),
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => load(),
                                      child: const Text('重试'),
                                    ),
                                  ],
                                ),
                              ),
                            if (loading.contains('') && !loaded)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 32),
                                child: Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (catalog.popular.isNotEmpty) ...[
                      SliverPadding(
                        padding: EdgeInsets.symmetric(horizontal: padding),
                        sliver: SliverToBoxAdapter(
                          child: sectionHeader(
                            '热门推荐',
                            'popular',
                            popular: true,
                          ),
                        ),
                      ),
                      grid(catalog.popular, true),
                    ],
                    for (final category in catalog.categories)
                      if (category.resources.isNotEmpty) ...[
                        SliverPadding(
                          padding: EdgeInsets.symmetric(horizontal: padding),
                          sliver: SliverToBoxAdapter(
                            child: sectionHeader(
                              category.name,
                              '${category.id}',
                            ),
                          ),
                        ),
                        grid(category.resources, false),
                      ],
                    if (loaded &&
                        catalog.popular.isEmpty &&
                        catalog.categories.every((c) => c.resources.isEmpty))
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 40, 24, 64),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.travel_explore_rounded,
                                size: 100,
                                color: themeAccent(
                                  context,
                                ).withValues(alpha: .65),
                              ),
                              const SizedBox(height: 24),
                              const Text(
                                '发现你想要的资源',
                                style: TextStyle(
                                  fontSize: 23,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '输入关键词，搜索全网网盘资源\n支持电影、学习资料、软件等',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.9,
                                  color: secondary(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    // Scaffold.extendBody includes the floating navigation in
                    // this padding, including larger text and system insets.
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 32 + MediaQuery.paddingOf(context).bottom,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ResourceCoverTile extends StatelessWidget {
  const _ResourceCoverTile(
    this.hit, {
    required this.popular,
    required this.opening,
    required this.onTap,
    this.health,
  });
  final ResourceSearchHit hit;
  final bool popular, opening;
  final VoidCallback? onTap;
  final ResourceLinkHealth? health;
  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: backgroundSurface(
        context,
        color: Color.alphaBlend(
          themeAccent(context).withValues(alpha: .08),
          Theme.of(context).colorScheme.surface,
        ),
      ),
      child: Center(
        child: Icon(
          resourceTypeIcon(hit.title + hit.category),
          size: popular ? 44 : 32,
          color: themeAccent(context),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: hit.title,
      child: InkWell(
        key: ValueKey(
          'resource-catalog-item-${hit.recommendationId}-${hit.identity}',
        ),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: popular ? 1.85 : 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (hit.coverUrl.isEmpty)
                      fallback
                    else
                      Image.network(
                        hit.coverUrl,
                        fit: BoxFit.cover,
                        cacheWidth: popular ? 640 : 400,
                        errorBuilder: (_, _, _) => fallback,
                        loadingBuilder: (_, child, progress) =>
                            progress == null ? child : fallback,
                      ),
                    if (health != null &&
                        health!.state != ResourceLinkState.pending &&
                        health!.state != ResourceLinkState.unsupported)
                      Positioned(
                        left: 7,
                        bottom: 7,
                        child: Tooltip(
                          message: health!.message,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(
                                context,
                              ).colorScheme.surface.withValues(alpha: .95),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              child: Text(
                                health!.label,
                                style: TextStyle(
                                  fontSize: 10,
                                  color:
                                      health!.state == ResourceLinkState.invalid
                                      ? Theme.of(context).colorScheme.error
                                      : secondary(context),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (opening)
                      ColoredBox(
                        color: Colors.black.withValues(alpha: .25),
                        child: const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 9),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  hit.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: popular ? 14 : 12,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                if (popular && hit.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    hit.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: secondary(context)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData resourceTypeIcon(String text) {
  if (RegExp('电影|影视|电视剧|动画|4K|1080', caseSensitive: false).hasMatch(text)) {
    return Icons.movie_outlined;
  }
  if (RegExp('书|学习|课程|教程|考研|PDF|EPUB', caseSensitive: false).hasMatch(text)) {
    return Icons.menu_book_outlined;
  }
  if (RegExp('音乐|音频|有声|MP3|FLAC', caseSensitive: false).hasMatch(text)) {
    return Icons.headphones_rounded;
  }
  if (RegExp('软件|工具|应用|安装|APP|APK', caseSensitive: false).hasMatch(text)) {
    return Icons.apps_rounded;
  }
  return Icons.folder_outlined;
}
