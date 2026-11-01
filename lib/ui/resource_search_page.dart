import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../app_services.dart';
import '../data/resource_search.dart';
import '../data/resource_link_checks.dart';
import '../domain/models.dart';
import '../domain/resource_search.dart';
import 'common.dart';
import 'resource_search_bar.dart';
import 'resource_preferences.dart';

class ResourceSearchPage extends StatefulWidget {
  const ResourceSearchPage(
    this.services, {
    super.key,
    required this.onOpen,
    this.active = true,
    this.embedded = false,
  });
  final AppServices services;
  final Future<void> Function(ResourceSearchHit) onOpen;
  final bool active, embedded;
  @override
  State<ResourceSearchPage> createState() => _ResourceSearchPageState();
}

class _ResourceSearchPageState extends State<ResourceSearchPage>
    with WidgetsBindingObserver {
  ResourceSearch get search => widget.services.resourceSearch;
  late final input = TextEditingController(text: search.keyword);
  late final include = TextEditingController(
    text: search.includeTerms.join(' '),
  );
  late final exclude = TextEditingController(
    text: search.excludeTerms.join(' '),
  );
  final focus = FocusNode();
  final scroll = ScrollController();
  final _viewportKey = GlobalKey();
  final _rows = <String, BuildContext>{};
  final _displayed = <ResourceSearchHit>[];
  int _displayGeneration = -1;
  String _displayFilters = '';
  bool _waitingUpdate = false;
  bool _visibilityScheduled = false;
  String? opening;
  bool advanced = false, showTop = false;
  final _tabKeys = <String, GlobalKey>{};
  double _swipeDistance = 0;
  int visibleLimit = 15;
  static const batchSize = 15;
  static const suggestions = ['Python 教程', '英语学习', '电子书', '设计素材', '开源软件'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(onScroll);
    if (widget.active) search.resumeChecks();
    if (widget.active) unawaited(search.loadRecommendations());
  }

  @override
  void didUpdateWidget(ResourceSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      unawaited(search.loadRecommendations());
      search.resumeChecks();
      scheduleVisibility();
    } else if (!widget.active && oldWidget.active) {
      search.stop();
      search.linkChecks?.clearVisible();
      focus.unfocus();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.active) search.resumeChecks();
      scheduleVisibility();
    } else {
      if (widget.active) search.pauseChecks();
      search.linkChecks?.clearVisible();
    }
  }

  @override
  void didChangeMetrics() => scheduleVisibility();

  void trackRow(String key, BuildContext? context) {
    if (context == null) {
      _rows.remove(key);
    } else {
      _rows[key] = context;
    }
    scheduleVisibility();
  }

  void scheduleVisibility() {
    if (!mounted ||
        !widget.active ||
        search.phase != ResourceSearchPhase.idle ||
        search.linkChecks == null ||
        _visibilityScheduled) {
      return;
    }
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted ||
          !widget.active ||
          opening != null ||
          WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final viewport = _viewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
        return;
      }
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      final visible = <ResourceSearchHit>[];
      for (final hit in search.recommendations) {
        final element = _rows[resourceLinkKey(hit)];
        if (element == null || !element.mounted) continue;
        final box = element.findRenderObject();
        if (box is RenderBox &&
            box.attached &&
            box.hasSize &&
            bounds.overlaps(box.localToGlobal(Offset.zero) & box.size)) {
          visible.add(hit);
        }
      }
      // Search results were checked before publication. Scrolling must not
      // restart probes or alter the order; recommendations remain lazy.
      if (search.phase == ResourceSearchPhase.idle) {
        search.linkChecks?.setVisible(visible);
      }
    });
  }

  void onScroll() {
    if (!mounted || !scroll.hasClients) return;
    scheduleVisibility();
    final top = scroll.offset > 500;
    final more =
        scroll.position.extentAfter < 240 &&
        visibleLimit <
            (search.linkChecks == null
                ? search.items.length
                : _displayed.length);
    if (top != showTop ||
        more ||
        search.linkChecks != null && scroll.offset < 16 && _waitingUpdate) {
      setState(() {
        showTop = top;
        if (more) visibleLimit += batchSize;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    search.linkChecks?.clearVisible();
    search.stop();
    input.dispose();
    include.dispose();
    exclude.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  void resetVisible() {
    setState(() => visibleLimit = batchSize);
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  List<ResourceSearchHit> displayedItems() {
    final sorted = search.items;
    if (search.linkChecks == null) {
      _waitingUpdate = false;
      return sorted;
    }
    final filters =
        '${search.cloudFilter}\u0000${search.includeTerms.join('\u0000')}\u0001${search.excludeTerms.join('\u0000')}\u0001${search.cloudPriority.map((p) => p.key).join(',')}\u0001${search.preferSupported}';
    if (_displayGeneration != search.resultGeneration ||
        _displayFilters != filters ||
        !scroll.hasClients ||
        scroll.offset < 16) {
      _displayGeneration = search.resultGeneration;
      _displayFilters = filters;
      _displayed
        ..clear()
        ..addAll(sorted);
    } else if (sorted.length >= _displayed.length &&
        _displayed.indexed.every(
          (entry) => sameRow(entry.$2, sorted[entry.$1]),
        )) {
      // Appending after the current list is safe; inserting before it waits
      // until the user returns to the top.
      _displayed.addAll(sorted.skip(_displayed.length));
    }
    _waitingUpdate =
        sorted.length != _displayed.length ||
        !_displayed.indexed.every(
          (entry) => sameRow(entry.$2, sorted[entry.$1]),
        );
    return List.of(_displayed);
  }

  bool sameRow(ResourceSearchHit a, ResourceSearchHit b) =>
      a.identity == b.identity &&
      a.title == b.title &&
      a.description == b.description &&
      a.category == b.category &&
      a.cloudName == b.cloudName &&
      a.password == b.password &&
      a.date == b.date;

  int get waitingResults {
    if (search.linkChecks == null) return 0;
    final displayed = _displayed.map((hit) => hit.identity).toSet();
    return search.items
        .where((hit) => !displayed.contains(hit.identity))
        .length;
  }

  void showReadyResults() {
    if (scroll.hasClients) scroll.jumpTo(0);
    setState(() {
      visibleLimit = batchSize;
      _displayed
        ..clear()
        ..addAll(search.items);
    });
  }

  void submit([String? term, bool refresh = false]) {
    if (opening != null) return;
    if (term != null) input.text = term;
    focus.unfocus();
    resetVisible();
    unawaited(search.search(input.text, refresh: refresh));
  }

  void applyFilters() {
    FocusManager.instance.primaryFocus?.unfocus();
    search.setKeywordFilters(include: include.text, exclude: exclude.text);
    resetVisible();
  }

  void resetFilters({bool all = false}) {
    include.clear();
    exclude.clear();
    search.setKeywordFilters();
    if (all) search.filter(null);
    resetVisible();
  }

  bool canOpen(ResourceSearchHit hit) =>
      hit.canParse &&
          (hit.platform == null ||
              widget.services.control.cloudEnabled(hit.platform!)) ||
      widget.services.sources.candidates(hit.url).isNotEmpty;

  Future<void> open(ResourceSearchHit hit) async {
    if (opening != null) return;
    final selected = await _selectLink(hit);
    if (selected == null) return;
    if (!canOpen(selected)) {
      await external(selected);
      return;
    }
    search.stop();
    focus.unfocus();
    search.linkChecks?.clearVisible();
    setState(() => opening = selected.identity);
    try {
      await widget.onOpen(selected);
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

  Future<void> external(ResourceSearchHit hit) async {
    try {
      final launched = await launchUrl(
        Uri.parse(hit.url),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && mounted) message(context, '无法打开浏览器，可以复制链接后打开');
    } catch (_) {
      if (mounted) message(context, '无法打开浏览器，可以复制链接后打开');
    }
  }

  Future<void> copy(ResourceSearchHit hit) async {
    await Clipboard.setData(ClipboardData(text: hit.copyText));
    await widget.services.clipboard.acknowledgeText(hit.copyText);
    if (mounted) {
      message(context, hit.password.isEmpty ? '已复制分享链接' : '已复制链接和提取码');
    }
  }

  Future<void> clearHistory() async {
    try {
      await search.clearHistory();
    } catch (e) {
      if (mounted) message(context, errorText(e));
    }
  }

  Future<void> showHistory() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 700),
    builder: (sheetContext) => AnimatedBuilder(
      animation: search,
      builder: (context, _) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: historyPanel(
            onSelect: (term) {
              Navigator.of(sheetContext).pop();
              submit(term);
            },
          ),
        ),
      ),
    ),
  );

  Future<void> details(ResourceSearchHit hit) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 700),
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * .85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('资源详情', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            SelectableText(
              hit.title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                _CloudBadge(hit),
                if (hit.date.isNotEmpty)
                  Text(
                    hit.date,
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
              ],
            ),
            if (search.linkChecks case final checks?) ...[
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: checks,
                builder: (context, _) {
                  final health = search.health(hit)!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _ResourceHealthBadge(health),
                          Text(
                            '本机网络检测',
                            style: TextStyle(
                              fontSize: 11,
                              color: secondary(context),
                            ),
                          ),
                          if (canCheckResourceLink(hit))
                            TextButton(
                              key: const Key('resource-health-recheck'),
                              onPressed:
                                  health.state == ResourceLinkState.checking
                                  ? null
                                  : () => checks.retry(hit),
                              child: const Text('重新检测'),
                            ),
                        ],
                      ),
                      if (health.message.isNotEmpty)
                        Text(
                          health.message,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: secondary(context),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
            if (hit.description.isNotEmpty) ...[
              const SizedBox(height: 14),
              SelectableText(
                hit.description,
                style: const TextStyle(fontSize: 14, height: 1.7),
              ),
            ],
            const SizedBox(height: 20),
            const Text('分享链接', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            SelectableText(
              hit.url,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: themeAccent(context),
              ),
            ),
            if (hit.password.isNotEmpty) ...[
              const SizedBox(height: 12),
              SelectableText(
                '提取码：${hit.password}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 22),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: opening == null
                      ? () {
                          Navigator.of(sheetContext).pop();
                          unawaited(open(hit));
                        }
                      : null,
                  icon: const Icon(CupertinoIcons.arrow_up_right, size: 15),
                  label: Text(canOpen(hit) ? '打开资源' : '浏览器打开'),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(copy(hit)),
                  icon: const Icon(CupertinoIcons.doc_on_doc, size: 15),
                  label: const Text('复制分享链接'),
                ),
                if (canOpen(hit))
                  TextButton(
                    onPressed: () => unawaited(external(hit)),
                    child: const Text('浏览器打开'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  ).whenComplete(scheduleVisibility);

  Widget searchBox() {
    final field = TextField(
      key: const Key('resource-search-input'),
      controller: input,
      focusNode: focus,
      enabled: opening == null,
      textInputAction: TextInputAction.search,
      maxLength: 120,
      onSubmitted: (_) => submit(),
      onChanged: (_) => setState(() {}),
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        counterText: '',
        hintText: '搜索资源名称或关键词',
        hintStyle: TextStyle(color: secondary(context), fontSize: 13),
        prefixIcon: Icon(
          CupertinoIcons.search,
          size: 20,
          color: secondary(context),
        ),
        suffixIcon: input.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清空关键词',
                onPressed: () {
                  input.clear();
                  focus.requestFocus();
                  setState(() {});
                },
                icon: const Icon(CupertinoIcons.xmark_circle_fill, size: 17),
              ),
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
    );
    final bar = ResourceSearchBar(
      field: field,
      buttonKey: Key(
        search.searching ? 'resource-search-stop' : 'resource-search-submit',
      ),
      onPressed: search.searching
          ? search.stop
          : opening != null || input.text.trim().isEmpty
          ? null
          : () => submit(),
      label: search.searching ? '停止' : '搜索',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar,
        const SizedBox(height: 4),
        SizedBox(
          height: 2,
          child: search.searching
              ? LinearProgressIndicator(
                  key: const Key('resource-search-progress'),
                  minHeight: 2,
                  value: search.checking && search.checkTotal > 0
                      ? search.checkCompleted / search.checkTotal
                      : null,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget header(bool wide, bool idle) {
    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: themeAccent(context).withValues(alpha: .1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            CupertinoIcons.cloud,
            size: idle ? 30 : 24,
            color: themeAccent(context),
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              idle ? '发现所需，随时检索' : '资源搜索',
              style: TextStyle(
                fontSize: idle ? 23 : 20,
                fontWeight: FontWeight.w700,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '课程 · 电子书 · 软件 · 更多分享',
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.only(
        top: idle
            ? 36
            : wide
            ? 18
            : 8,
        bottom: 12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide && !idle)
            Row(
              children: [
                brand,
                const SizedBox(width: 40),
                Expanded(child: searchBox()),
              ],
            )
          else ...[
            if (idle) ...[
              Align(
                alignment: Alignment.center,
                child: FittedBox(fit: BoxFit.scaleDown, child: brand),
              ),
              const SizedBox(height: 26),
            ],
            searchBox(),
          ],
          if (idle) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '试试：',
                  style: TextStyle(fontSize: 12, color: secondary(context)),
                ),
                for (final term in suggestions)
                  TextButton(
                    key: ValueKey('resource-suggestion-$term'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      minimumSize: const Size(0, 40),
                    ),
                    onPressed: () => submit(term),
                    child: Text(
                      '# $term',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void showRecommendations() {
    input.clear();
    search.showRecommendations();
    resetVisible();
    unawaited(search.loadRecommendations());
  }

  Widget recommendationPanel() {
    if (search.recommendationsLoaded &&
        search.recommendations.isEmpty &&
        search.recommendationsError.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: const Key('resource-recommendations'),
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(CupertinoIcons.square_grid_2x2, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '推荐资源',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                key: const Key('resource-recommendations-refresh'),
                onPressed: search.recommendationsLoading || opening != null
                    ? null
                    : () => search.loadRecommendations(refresh: true),
                icon: const Icon(CupertinoIcons.arrow_clockwise, size: 15),
                label: Text(search.recommendationsLoading ? '加载中' : '换一批'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (search.recommendationsLoading && search.recommendations.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (search.recommendationsError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                search.recommendationsError,
                style: TextStyle(color: secondary(context), fontSize: 12),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns =
                  constraints.maxWidth >= 640 &&
                      MediaQuery.textScalerOf(context).scale(14) < 24
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final hit in search.recommendations)
                    SizedBox(
                      width: width,
                      child: _TrackedResourceRow(
                        key: ValueKey(
                          'resource-recommendation-${hit.recommendationId}-${hit.identity}',
                        ),
                        trackingKey: resourceLinkKey(hit),
                        onTrack: trackRow,
                        child: Material(
                          color: backgroundSurface(context),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(color: border(context)),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: opening != null
                                ? null
                                : () => unawaited(open(hit)),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: themeAccent(
                                            context,
                                          ).withValues(alpha: .09),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          CupertinoIcons.doc_text,
                                          color: themeAccent(context),
                                          size: 22,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              [
                                                if (hit.category.isNotEmpty)
                                                  hit.category,
                                                _cloudLabel(hit.cloudName),
                                              ].join(' · '),
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: secondary(context),
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            Text(
                                              hit.title,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 14,
                                                height: 1.5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (hit.description.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    Text(
                                      hit.description,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.6,
                                        color: secondary(context),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 14),
                                  Row(
                                    children: [
                                      if (search.linkChecks != null)
                                        Flexible(
                                          child: _ResourceHealthBadge(
                                            search.linkChecks!.health(hit),
                                          ),
                                        ),
                                      const Spacer(),
                                      if (opening == hit.identity)
                                        const SizedBox(
                                          width: 15,
                                          height: 15,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      else
                                        Text(
                                          canOpen(hit) ? '打开资源' : '浏览器打开',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: themeAccent(context),
                                          ),
                                        ),
                                      const SizedBox(width: 5),
                                      Icon(
                                        CupertinoIcons.arrow_up_right,
                                        size: 13,
                                        color: themeAccent(context),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget historyPanel({ValueChanged<String>? onSelect}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(CupertinoIcons.clock, size: 16, color: secondary(context)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '最近搜索',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            if (search.history.isNotEmpty)
              IconButton(
                key: const Key('resource-clear-history'),
                tooltip: '清空搜索历史',
                onPressed: () => unawaited(clearHistory()),
                icon: Icon(
                  CupertinoIcons.trash,
                  size: 16,
                  color: secondary(context),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (search.history.isEmpty)
          Text(
            '搜索过的关键词会保存在这里。',
            style: TextStyle(fontSize: 12, color: secondary(context)),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final term in search.history)
              ActionChip(
                key: ValueKey('resource-history-$term'),
                label: Text(term),
                onPressed: opening == null
                    ? () => (onSelect ?? submit)(term)
                    : null,
                labelStyle: const TextStyle(fontSize: 12),
                side: BorderSide.none,
                backgroundColor: fill(context),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  void selectCloud(String? name) {
    search.filter(name);
    resetVisible();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _tabKeys[name ?? 'all']?.currentContext;
      if (target != null) {
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: .5,
            duration: const Duration(milliseconds: 180),
          ),
        );
      }
    });
  }

  void swipeCloud(DragEndDetails details) {
    if (opening != null || search.allItems.isEmpty) return;
    final velocity = details.primaryVelocity ?? 0;
    if (_swipeDistance.abs() < 45 && velocity.abs() < 250) return;
    final names = <String?>[null, ...search.orderedClouds];
    final index = names.indexOf(search.cloudFilter);
    final direction =
        (_swipeDistance.abs() >= 45 ? _swipeDistance : velocity) < 0 ? 1 : -1;
    final next = (math.max(index, 0) + direction).clamp(0, names.length - 1);
    if (next != index) selectCloud(names[next]);
    _swipeDistance = 0;
  }

  Widget cloudFilters(bool wide) {
    final counts = <String, int>{};
    for (final hit in search.allItems) {
      counts.update(hit.cloudName, (v) => v + 1, ifAbsent: () => 1);
    }
    final names = search.orderedClouds;
    if (search.cloudFilter != null && !names.contains(search.cloudFilter)) {
      names.add(search.cloudFilter!);
    }
    Widget tab(String? name) {
      final selected = search.cloudFilter == name;
      final platform = CloudPlatform.values
          .where((p) => p.label == name)
          .firstOrNull;
      return Padding(
        key: _tabKeys.putIfAbsent(name ?? 'all', GlobalKey.new),
        padding: const EdgeInsets.only(right: 8, bottom: 4),
        child: Semantics(
          selected: selected,
          child: Material(
            color: selected ? themeAccent(context) : Colors.transparent,
            borderRadius: BorderRadius.circular(26),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('resource-filter-${name ?? 'all'}'),
              onTap: () => selectCloud(name),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (platform != null) ...[
                      PlatformMark(platform: platform, size: 19),
                      const SizedBox(width: 6),
                    ],
                    Text(
                      name == null ? '全部' : _cloudLabel(name),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected
                            ? themeOnAccent(context)
                            : secondary(context),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '${name == null ? search.allItems.length : counts[name] ?? 0}',
                      style: TextStyle(
                        fontSize: 10,
                        color: selected
                            ? themeOnAccent(context).withValues(alpha: .8)
                            : secondary(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [tab(null), for (final name in names) tab(name)]),
      ),
    );
  }

  Widget advancedFilters(bool wide) {
    Widget field(
      String label,
      String hint,
      TextEditingController controller,
      String key,
    ) => TextField(
      key: Key(key),
      controller: controller,
      maxLength: 120,
      style: const TextStyle(fontSize: 13),
      onSubmitted: (_) => applyFilters(),
      decoration: InputDecoration(
        counterText: '',
        labelText: label,
        hintText: hint,
        isDense: true,
        filled: false,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
      ),
    );
    final includeField = field(
      '包含关键词',
      '多个词用空格分隔，需全部包含',
      include,
      'resource-include-input',
    );
    final excludeField = field(
      '排除关键词',
      '排除含有任一关键词的标题',
      exclude,
      'resource-exclude-input',
    );
    return Container(
      key: const Key('resource-advanced-panel'),
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fill(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border(context).withValues(alpha: .6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            Row(
              children: [
                Expanded(child: includeField),
                const SizedBox(width: 12),
                Expanded(child: excludeField),
              ],
            )
          else ...[
            includeField,
            const SizedBox(height: 14),
            excludeField,
          ],
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    key: const Key('resource-prefer-supported'),
                    value: search.preferSupported,
                    onChanged: (value) =>
                        unawaited(search.setPreferSupported(value ?? false)),
                  ),
                  const Text('优先可解析', style: TextStyle(fontSize: 12)),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('resource-reset-filters'),
                    onPressed: resetFilters,
                    child: const Text('重置关键词'),
                  ),
                  FilledButton(
                    key: const Key('resource-apply-filters'),
                    onPressed: applyFilters,
                    child: const Text('应用筛选'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget toolbar(bool wide, int count) {
    final phaseText = switch (search.phase) {
      ResourceSearchPhase.searching =>
        search.checkTotal > 0
            ? '正在搜索 · 链接检测 ${search.checkCompleted}/${search.checkTotal}'
            : '正在搜索',
      ResourceSearchPhase.checking =>
        '${search.checksPaused ? '检测已暂停' : '正在检测链接'} ${search.checkCompleted}/${search.checkTotal}',
      ResourceSearchPhase.stopped => '搜索已停止',
      ResourceSearchPhase.failed =>
        search.allItems.isNotEmpty ? '已保留部分结果' : '搜索未完成',
      _ =>
        search.fromCache
            ? '最近搜索'
            : search.linkChecks != null
            ? '链接检测完成'
            : '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 2,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: '共找到 '),
                  TextSpan(
                    text: '$count',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  TextSpan(
                    text:
                        ' 个结果${search.cloudFilter == null ? '' : ' · ${_cloudLabel(search.cloudFilter!)}'}',
                  ),
                ],
              ),
              style: TextStyle(fontSize: 13, color: secondary(context)),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!search.searching || search.linkChecks != null)
                  IconButton(
                    key: const Key('resource-search-refresh'),
                    tooltip: '重新搜索',
                    onPressed: opening == null && !search.searching
                        ? () => submit(search.keyword, true)
                        : null,
                    icon: const Icon(CupertinoIcons.refresh, size: 17),
                  ),
                TextButton.icon(
                  key: const Key('resource-advanced-toggle'),
                  onPressed: () => setState(() => advanced = !advanced),
                  style: TextButton.styleFrom(
                    foregroundColor: advanced || search.hasKeywordFilters
                        ? themeAccent(context)
                        : secondary(context),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 10,
                    ),
                    minimumSize: const Size(0, 44),
                  ),
                  icon: const Icon(
                    CupertinoIcons.slider_horizontal_3,
                    size: 16,
                  ),
                  label: Text(
                    search.hasKeywordFilters ? '筛选 · 已应用' : '筛选',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
        if (phaseText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              phaseText,
              maxLines: search.linkChecks != null ? 1 : null,
              overflow: search.linkChecks != null
                  ? TextOverflow.ellipsis
                  : null,
              style: TextStyle(
                fontSize: 11,
                height: search.linkChecks != null ? 1.6 : null,
                color: search.searching
                    ? themeAccent(context)
                    : secondary(context),
              ),
            ),
          ),
        if (advanced) advancedFilters(wide),
        if (search.hasKeywordFilters && !advanced)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (search.includeTerms.isNotEmpty)
                  Text(
                    '包含：${search.includeTerms.join('、')}',
                    style: TextStyle(fontSize: 11, color: secondary(context)),
                  ),
                if (search.excludeTerms.isNotEmpty)
                  Text(
                    '排除：${search.excludeTerms.join('、')}',
                    style: TextStyle(fontSize: 11, color: secondary(context)),
                  ),
                TextButton(
                  onPressed: resetFilters,
                  style: TextButton.styleFrom(minimumSize: const Size(0, 32)),
                  child: const Text('清除', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget empty() {
    final filtered = search.cloudFilter != null || search.hasKeywordFilters;
    final failed = search.phase == ResourceSearchPhase.failed;
    final loading = search.searching;
    final waitingChecks = loading && search.linkChecks != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 50),
      child: Column(
        children: [
          Icon(
            failed
                ? CupertinoIcons.wifi_exclamationmark
                : CupertinoIcons.doc_text_search,
            size: 32,
            color: secondary(context),
          ),
          const SizedBox(height: 16),
          Text(
            loading
                ? search.checking
                      ? '正在检测分享链接'
                      : '正在查找资源'
                : filtered
                ? '没有符合筛选条件的资源'
                : failed
                ? '暂时没能完成搜索'
                : '暂时没有找到资源',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text(
            loading
                ? waitingChecks
                      ? '每批链接检测完成后按有效、无法检测、失效排序显示。'
                      : '结果会陆续显示，请稍等片刻。'
                : failed
                ? search.error
                : filtered
                ? '可以调整关键词筛选，或切换网盘。'
                : '试试更短的名称，或换一个关键词。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.7,
              color: secondary(context),
            ),
          ),
          if (!loading) ...[
            const SizedBox(height: 12),
            if (filtered)
              TextButton(
                onPressed: () => resetFilters(all: true),
                child: const Text('清除全部筛选'),
              )
            else if (failed)
              TextButton(
                onPressed: () => submit(search.keyword, true),
                child: const Text('重试'),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      search,
      if (search.linkChecks != null) search.linkChecks!,
    ]),
    builder: (context, _) {
      scheduleVisibility();
      final idle = search.phase == ResourceSearchPhase.idle;
      final items = displayedItems();
      final shown = math.min(visibleLimit, items.length);
      final waiting = waitingResults;
      return Scaffold(
        backgroundColor: widget.embedded ? Colors.transparent : null,
        appBar: widget.embedded
            ? null
            : AppBar(
                title: Text(idle ? '资源搜索' : '搜索结果'),
                actions: [
                  IconButton(
                    key: const Key('resource-priority-settings'),
                    tooltip: '网盘展示优先级',
                    onPressed: opening == null
                        ? () => showResourcePrioritySheet(context, search)
                        : null,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                  TextButton.icon(
                    key: const Key('resource-search-history'),
                    onPressed: opening == null ? showHistory : null,
                    icon: const Icon(CupertinoIcons.clock, size: 17),
                    label: const Text('历史'),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
        floatingActionButton: _waitingUpdate
            ? FloatingActionButton.extended(
                key: const Key('resource-search-new-results'),
                tooltip: '回到顶部查看更新后的结果',
                onPressed: showReadyResults,
                icon: const Icon(CupertinoIcons.arrow_up, size: 17),
                label: Text(
                  waiting > 0 ? '$waiting 条新结果' : '结果已更新',
                  style: const TextStyle(fontSize: 12),
                ),
              )
            : showTop
            ? FloatingActionButton.small(
                tooltip: '回到搜索与筛选',
                onPressed: () => scroll.animateTo(
                  0,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                ),
                child: const Icon(CupertinoIcons.arrow_up, size: 18),
              )
            : null,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => _swipeDistance = 0,
          onHorizontalDragUpdate: (details) =>
              _swipeDistance += details.delta.dx,
          onHorizontalDragEnd: swipeCloud,
          child: SafeArea(
            top: false,
            bottom: !widget.embedded,
            child: LayoutBuilder(
              builder: (context, bounds) {
                final wide =
                    bounds.maxWidth >= 800 &&
                    MediaQuery.textScalerOf(context).scale(14) < 23;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Scrollbar(
                      key: _viewportKey,
                      controller: scroll,
                      thumbVisibility: wide,
                      child: CustomScrollView(
                        key: const PageStorageKey('resource-search-results'),
                        controller: scroll,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.symmetric(
                              horizontal: wide ? 28 : 14,
                            ),
                            sliver: SliverList(
                              delegate: SliverChildListDelegate([
                                if (widget.embedded)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (!idle)
                                          TextButton.icon(
                                            onPressed: opening == null
                                                ? showRecommendations
                                                : null,
                                            icon: const Icon(
                                              CupertinoIcons.square_grid_2x2,
                                              size: 16,
                                            ),
                                            label: const Text('推荐'),
                                          ),
                                        TextButton.icon(
                                          onPressed: opening == null
                                              ? showHistory
                                              : null,
                                          icon: const Icon(
                                            CupertinoIcons.clock,
                                            size: 16,
                                          ),
                                          label: const Text('历史'),
                                        ),
                                      ],
                                    ),
                                  ),
                                header(wide, idle),
                                if (idle) ...[
                                  recommendationPanel(),
                                  const SizedBox(height: 12),
                                  historyPanel(),
                                  const SizedBox(height: 32),
                                  Text(
                                    '找到分享后，打开即可继续解析、播放或下载。',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 12,
                                      height: 1.7,
                                      color: secondary(context),
                                    ),
                                  ),
                                ] else ...[
                                  cloudFilters(wide),
                                  toolbar(wide, items.length),
                                  if (search.error.isNotEmpty &&
                                      items.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      child: Text(
                                        search.error,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.6,
                                          color: secondary(context),
                                        ),
                                      ),
                                    ),
                                  if (items.isEmpty) empty(),
                                ],
                              ]),
                            ),
                          ),
                          if (!idle && items.isNotEmpty)
                            SliverPadding(
                              padding: EdgeInsets.symmetric(
                                horizontal: wide ? 28 : 14,
                              ),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    final hit = items[index];
                                    final row = ResourceSearchResultRow(
                                      key: ValueKey(
                                        'resource-result-${hit.identity}',
                                      ),
                                      hit: hit,
                                      keyword: search.keyword,
                                      wide: wide,
                                      first: index == 0,
                                      last: index == shown - 1,
                                      canOpen: canOpen(hit),
                                      opening: opening == hit.identity,
                                      enabled: opening == null,
                                      health: search.health(hit),
                                      onOpen: () => unawaited(
                                        open(search.currentHit(hit)),
                                      ),
                                      onCopy: () => unawaited(
                                        copy(search.currentHit(hit)),
                                      ),
                                      onDetails: () => unawaited(
                                        details(search.currentHit(hit)),
                                      ),
                                    );
                                    return row;
                                  },
                                  childCount: shown,
                                  findChildIndexCallback: (key) {
                                    if (key is! ValueKey<String>) return null;
                                    final index = items.indexWhere(
                                      (hit) =>
                                          'resource-result-${hit.identity}' ==
                                          key.value,
                                    );
                                    return index < 0 || index >= shown
                                        ? null
                                        : index;
                                  },
                                ),
                              ),
                            ),
                          if (!idle && items.isNotEmpty)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  12,
                                  16,
                                  24,
                                ),
                                child: Column(
                                  children: [
                                    if (shown < items.length)
                                      TextButton(
                                        key: const Key('resource-search-more'),
                                        onPressed: () => setState(
                                          () => visibleLimit += batchSize,
                                        ),
                                        child: Text(
                                          '加载更多 · 已显示 $shown / ${items.length} 条',
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      )
                                    else
                                      Text(
                                        search.searching
                                            ? '已显示 $shown 条，正在继续查找…'
                                            : '已显示全部 $shown 条结果',
                                        style: TextStyle(
                                          fontSize: 11,
                                          height: 1.8,
                                          color: secondary(context),
                                        ),
                                      ),
                                    if (!search.searching ||
                                        search.linkChecks != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        search.linkChecks != null
                                            ? '有效 → 无法检测 → 失效 · 同组按网盘优先级'
                                            : search.preferSupported
                                            ? '按网盘优先级展示 · 同一网盘优先可解析'
                                            : '按网盘优先级展示 · 同一网盘按相关性排序',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: secondary(context),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          SliverToBoxAdapter(
                            child: SizedBox(
                              height: 30 + MediaQuery.paddingOf(context).bottom,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
    },
  );
}

String _cloudLabel(String name) =>
    CloudPlatform.values
        .where((platform) => platform.label == name)
        .firstOrNull
        ?.shortName ??
    name;

class _CloudBadge extends StatelessWidget {
  const _CloudBadge(this.hit);
  final ResourceSearchHit hit;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = switch (hit.platform) {
      CloudPlatform.baidu => const Color(0xff3478ef),
      CloudPlatform.quark => const Color(0xff6464dc),
      CloudPlatform.aliyun => const Color(0xff6758d6),
      CloudPlatform.uc => const Color(0xffd66c25),
      CloudPlatform.pan123 => const Color(0xff0a8b9a),
      CloudPlatform.xunlei => const Color(0xff1e87d6),
      _ => const Color(0xff738096),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .2 : .09),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _cloudLabel(hit.cloudName),
        style: TextStyle(
          fontSize: 10,
          height: 1.2,
          fontWeight: FontWeight.w500,
          color: dark ? Color.lerp(color, Colors.white, .35) : color,
        ),
      ),
    );
  }
}

class _TrackedResourceRow extends StatefulWidget {
  const _TrackedResourceRow({
    super.key,
    required this.trackingKey,
    required this.onTrack,
    required this.child,
  });
  final String trackingKey;
  final void Function(String, BuildContext?) onTrack;
  final Widget child;
  @override
  State<_TrackedResourceRow> createState() => _TrackedResourceRowState();
}

class _TrackedResourceRowState extends State<_TrackedResourceRow> {
  @override
  void initState() {
    super.initState();
    widget.onTrack(widget.trackingKey, context);
  }

  @override
  void didUpdateWidget(_TrackedResourceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackingKey != widget.trackingKey) {
      oldWidget.onTrack(oldWidget.trackingKey, null);
      widget.onTrack(widget.trackingKey, context);
    }
  }

  @override
  void dispose() {
    widget.onTrack(widget.trackingKey, null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ResourceHealthBadge extends StatelessWidget {
  const _ResourceHealthBadge(this.health);
  final ResourceLinkHealth health;
  @override
  Widget build(BuildContext context) {
    final color = switch (health.state) {
      ResourceLinkState.valid =>
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0xff81c995)
            : const Color(0xff237a49),
      ResourceLinkState.invalid => Theme.of(context).colorScheme.error,
      ResourceLinkState.locked =>
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0xffffd180)
            : const Color(0xff986600),
      ResourceLinkState.checking => themeAccent(context),
      _ => secondary(context),
    };
    return Tooltip(
      message: health.message.isEmpty ? health.label : health.message,
      child: Semantics(
        label: '链接状态：${health.label}',
        excludeSemantics: true,
        child: Text(
          health.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            height: 1.3,
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class ResourceSearchResultRow extends StatelessWidget {
  const ResourceSearchResultRow({
    super.key,
    required this.hit,
    required this.keyword,
    required this.wide,
    required this.first,
    required this.last,
    required this.canOpen,
    required this.opening,
    required this.enabled,
    required this.onOpen,
    required this.onCopy,
    required this.onDetails,
    this.health,
  });
  final ResourceSearchHit hit;
  final String keyword;
  final bool wide, first, last, canOpen, opening, enabled;
  final VoidCallback onOpen, onCopy, onDetails;
  final ResourceLinkHealth? health;

  TextSpan title(BuildContext context) {
    final terms = keyword
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .take(8);
    if (terms.isEmpty) return TextSpan(text: hit.title);
    final pattern = RegExp(
      terms.map(RegExp.escape).join('|'),
      caseSensitive: false,
    );
    final spans = <InlineSpan>[];
    var offset = 0;
    for (final match in pattern.allMatches(hit.title)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: hit.title.substring(offset, match.start)));
      }
      spans.add(
        TextSpan(
          text: match[0],
          style: TextStyle(color: themeAccent(context)),
        ),
      );
      offset = match.end;
    }
    spans.add(TextSpan(text: hit.title.substring(offset)));
    return TextSpan(children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final description = hit.description.isNotEmpty
        ? hit.description
        : hit.category;
    final size = RegExp(
      r'\b\d+(?:\.\d+)?\s*(?:TB|GB|MB|KB|TiB|GiB|MiB)\b',
      caseSensitive: false,
    ).firstMatch(description)?.group(0);
    final large = MediaQuery.textScalerOf(context).scale(14) > 23;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          title(context),
          maxLines: large ? 4 : 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.5,
          ),
        ),
        if (description.isNotEmpty) ...[
          const SizedBox(height: 7),
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: secondary(context),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _CloudBadge(hit),
            if (size != null)
              Text(
                size,
                style: TextStyle(fontSize: 11, color: secondary(context)),
              ),
            if (health != null)
              SizedBox(
                width: MediaQuery.textScalerOf(context).scale(10) * 7,
                child: _ResourceHealthBadge(health!),
              ),
            if (hit.password.isNotEmpty)
              Text(
                '提取码 ${hit.password}',
                style: TextStyle(fontSize: 11, color: secondary(context)),
              ),
            if (hit.date.isNotEmpty)
              Text(
                hit.date.split(RegExp(r'[ T]')).first,
                style: TextStyle(fontSize: 10, color: secondary(context)),
              ),
          ],
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: backgroundSurface(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: themeAccent(context).withValues(alpha: .13)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onDetails,
          child: Semantics(
            label: '查看资源详情',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(15, 16, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!large) ...[
                        Container(
                          width: wide ? 66 : 54,
                          height: wide ? 78 : 68,
                          decoration: BoxDecoration(
                            color: themeAccent(context).withValues(alpha: .07),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(
                            Icons.folder_outlined,
                            size: 29,
                            color: themeAccent(context),
                          ),
                        ),
                        const SizedBox(width: 13),
                      ],
                      Expanded(child: content),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        key: ValueKey('resource-copy-${hit.identity}'),
                        tooltip: '复制分享链接',
                        onPressed: onCopy,
                        icon: Icon(
                          Icons.copy_outlined,
                          size: 17,
                          color: secondary(context),
                        ),
                      ),
                      const SizedBox(width: 3),
                      TextButton(
                        key: ValueKey('resource-open-${hit.identity}'),
                        onPressed: enabled ? onOpen : null,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(64, 40),
                          backgroundColor: themeAccent(
                            context,
                          ).withValues(alpha: .07),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                        child: opening
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                canOpen ? '打开资源' : '查看链接',
                                style: const TextStyle(fontSize: 12),
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ResourceSearchEntry extends StatelessWidget {
  const ResourceSearchEntry({super.key, required this.onTap});
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: backgroundSurface(context),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: BorderSide(color: themeAccent(context).withValues(alpha: .24)),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      key: const Key('parse-resource-search'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: themeAccent(context).withValues(alpha: .10),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                CupertinoIcons.search,
                color: themeAccent(context),
                size: 24,
              ),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '资源搜索',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '课程 · 电子书 · 软件 · 更多分享',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: secondary(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              CupertinoIcons.arrow_right,
              size: 18,
              color: themeAccent(context),
            ),
          ],
        ),
      ),
    ),
  );
}
