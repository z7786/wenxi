import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../domain/cloud_search_options.dart';
import '../domain/models.dart';
import 'browser_page.dart';
import 'common.dart';

/// A separate route sharing the browser's account checks and file actions.
class CloudSearchPage extends BrowserPage {
  const CloudSearchPage(
    super.services,
    super.session, {
    super.key,
    super.poolPreview,
    List<CloudFile>? currentItems,
    List<(String, String)>? currentTrail,
  }) : super(
         searchPage: true,
         initialItems: currentItems,
         initialTrail: currentTrail,
       );
}

class CloudSearchEntry extends StatelessWidget {
  const CloudSearchEntry({super.key, required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: fill(context),
    borderRadius: BorderRadius.circular(13),
    child: InkWell(
      key: const Key('browser-search-entry'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.search,
              size: 19,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '搜索网盘文件',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Icon(
              CupertinoIcons.chevron_right,
              size: 13,
              color: secondary(context),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SearchScopeControl extends StatelessWidget {
  const _SearchScopeControl({
    required this.platform,
    required this.entireDrive,
    required this.currentFolder,
    required this.onChanged,
  });

  final CloudPlatform platform;
  final bool entireDrive;
  final String currentFolder;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final description = entireDrive
        ? '搜索整个网盘，包含子文件夹'
        : '$currentFolder · 包含子文件夹';
    final identity = Row(
      children: [
        PlatformMark(platform: platform, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                platform.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Tooltip(
                message: description,
                child: Text(
                  description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final control = CupertinoSlidingSegmentedControl<bool>(
      key: const Key('browser-search-scope'),
      groupValue: entireDrive,
      padding: const EdgeInsets.all(4),
      backgroundColor: fill(context),
      thumbColor: colors.surface,
      onValueChanged: (value) {
        if (value != null && value != entireDrive) onChanged(value);
      },
      children: {
        for (final all in [true, false])
          all: Padding(
            key: ValueKey(
              all ? 'browser-search-scope-all' : 'browser-search-scope-folder',
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (MediaQuery.textScalerOf(context).scale(13) <= 22) ...[
                  Icon(
                    all
                        ? CupertinoIcons.square_grid_2x2
                        : CupertinoIcons.folder,
                    size: 16,
                    color: entireDrive == all
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(
                    all ? '全部文件' : '当前文件夹',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: entireDrive == all
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: entireDrive == all
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      },
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      child: LayoutBuilder(
        builder: (context, bounds) => bounds.maxWidth >= 600
            ? Row(
                children: [
                  Expanded(child: identity),
                  const SizedBox(width: 24),
                  SizedBox(width: 360, child: control),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [identity, const SizedBox(height: 10), control],
              ),
      ),
    );
  }
}

class CloudSearchLayout extends StatelessWidget {
  const CloudSearchLayout({
    super.key,
    required this.platform,
    required this.controller,
    required this.onChanged,
    required this.onSubmit,
    required this.onClear,
    required this.onBack,
    required this.category,
    required this.onCategory,
    required this.entireDrive,
    required this.onScope,
    required this.currentFolder,
    required this.child,
    this.resultHeader,
    this.footer,
  });
  final CloudPlatform platform;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit, onClear, onBack;
  final CloudSearchCategory category;
  final ValueChanged<CloudSearchCategory> onCategory;
  final bool entireDrive;
  final ValueChanged<bool> onScope;
  final String currentFolder;
  final Widget child;
  final Widget? resultHeader, footer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      key: const Key('cloud-search-page'),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 4,
        toolbarHeight: MediaQuery.textScalerOf(context).scale(14) > 20
            ? 76
            : 64,
        title: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回文件列表',
                  onPressed: onBack,
                  icon: const Icon(CupertinoIcons.chevron_left, size: 23),
                ),
                Expanded(
                  child: TextField(
                    key: const Key('browser-search-input'),
                    controller: controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 15),
                    onChanged: onChanged,
                    onSubmitted: (_) => onSubmit(),
                    decoration: InputDecoration(
                      hintText: '搜索文件名',
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      prefixIcon: const Icon(CupertinoIcons.search, size: 19),
                      prefixIconConstraints: const BoxConstraints(minWidth: 38),
                      suffixIcon: controller.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              onPressed: onClear,
                              icon: const Icon(
                                CupertinoIcons.xmark_circle_fill,
                                size: 18,
                              ),
                            ),
                      filled: true,
                      fillColor: fill(context),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide(
                          color: colors.primary.withValues(alpha: .35),
                        ),
                      ),
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('browser-search-submit'),
                  onPressed: onSubmit,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(54, 46),
                  ),
                  child: const Text(
                    '搜索',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SearchScopeControl(
                  platform: platform,
                  entireDrive: entireDrive,
                  currentFolder: currentFolder,
                  onChanged: onScope,
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const SizedBox(width: 6),
                      for (final type in CloudSearchCategory.values)
                        Semantics(
                          selected: category == type,
                          button: true,
                          child: InkWell(
                            key: ValueKey('cloud-search-type-${type.name}'),
                            onTap: () => onCategory(type),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 15,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                    ),
                                    child: Text(
                                      type.label,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: category == type
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: category == type
                                            ? colors.primary
                                            : colors.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 20,
                                    height: 3,
                                    decoration: BoxDecoration(
                                      color: category == type
                                          ? colors.primary
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
                Divider(height: 1, thickness: .6, color: border(context)),
                ?resultHeader,
                Expanded(child: child),
                ?footer,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CloudSearchLanding extends StatelessWidget {
  const CloudSearchLanding({
    super.key,
    required this.history,
    required this.onSearch,
    required this.onClear,
    required this.onRemove,
  });
  final List<String> history;
  final ValueChanged<String> onSearch, onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('cloud-search-history'),
    padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              '搜索历史',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          if (history.isNotEmpty)
            IconButton(
              tooltip: '清空搜索历史',
              onPressed: onClear,
              icon: Icon(
                CupertinoIcons.trash,
                size: 18,
                color: secondary(context),
              ),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (history.isEmpty)
        Text(
          '搜索过的关键词会保存在这里',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 7,
          children: [
            for (final term in history)
              Tooltip(
                message: term,
                child: InputChip(
                  key: ValueKey('cloud-search-history-$term'),
                  label: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: (MediaQuery.sizeOf(context).width - 120).clamp(
                        120,
                        280,
                      ),
                    ),
                    child: Text(
                      term,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  backgroundColor: fill(context),
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                  deleteIcon: Icon(
                    CupertinoIcons.xmark,
                    size: 12,
                    color: secondary(context),
                  ),
                  deleteButtonTooltipMessage: '删除这条搜索历史',
                  onPressed: () => onSearch(term),
                  onDeleted: () => onRemove(term),
                ),
              ),
          ],
        ),
      const SizedBox(height: 38),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            CupertinoIcons.doc_text_search,
            size: 18,
            color: secondary(context),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '输入文件名查找，也可以直接选择上方文件类型。',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    ],
  );
}

class CloudSearchFileName extends StatelessWidget {
  const CloudSearchFileName(this.name, this.query, {super.key});
  final String name, query;

  @override
  Widget build(BuildContext context) {
    if (query.trim().isEmpty) {
      return Text(
        name,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          height: 1.4,
        ),
      );
    }
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in RegExp(
      RegExp.escape(query.trim()),
      caseSensitive: false,
    ).allMatches(name)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: name.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: name.substring(match.start, match.end),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < name.length) spans.add(TextSpan(text: name.substring(cursor)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.4,
      ),
    );
  }
}
