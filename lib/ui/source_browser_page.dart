import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../core/json.dart';
import '../data/http.dart';
import '../data/sources/package.dart';
import '../data/sources/results.dart';
import '../data/sources/service.dart';
import '../domain/models.dart';
import 'common.dart';
import 'download_location_picker.dart';
import 'app_context_menu.dart';
import 'app_popup_menu.dart';

class SourceBrowserPage extends StatefulWidget {
  const SourceBrowserPage(this.services, this.initial, {super.key});
  final AppServices services;
  final SourceSession initial;
  @override
  State<SourceBrowserPage> createState() => _SourceBrowserPageState();
}

class _SourceBrowserPageState extends State<SourceBrowserPage> {
  late final List<SourceSession> trail = [widget.initial];
  final selected = <String>{};
  final search = TextEditingController();
  SourceSession get session => trail.last;
  RequestScope? request;
  bool working = false;
  String error = '', stage = '';
  int generation = 0;

  @override
  void dispose() {
    generation++;
    request?.cancel();
    search.dispose();
    super.dispose();
  }

  Future<void> run(String label, Future<void> Function() action) async {
    if (working) return;
    final current = ++generation, scope = RequestScope();
    request = scope;
    setState(() {
      working = true;
      stage = label;
      error = '';
    });
    try {
      await scope.run(
        () => RequestScope.guarded(action, () {
          require(mounted && current == generation, '操作已取消');
        }),
      );
    } catch (e) {
      if (mounted && current == generation) {
        setState(() => error = errorText(e));
      }
    } finally {
      if (mounted && current == generation) {
        setState(() {
          working = false;
          request = null;
          stage = '';
        });
      }
    }
  }

  void cancel() {
    generation++;
    request?.cancel();
    request = null;
    setState(() {
      working = false;
      stage = '';
      error = '操作已取消';
    });
  }

  Future<void> open(SourceResource resource) => run('正在读取目录…', () async {
    final next = await widget.services.sources.list(
      session,
      directory: resource,
    );
    RequestScope.checkpoint();
    setState(() {
      trail.add(next);
      selected.clear();
      search.clear();
    });
  });

  Widget _contextMenu(SourceResource item, Widget child) =>
      AppContextMenu<String>(
        key: ValueKey(item.id),
        enabled: !working,
        identity: (
          session,
          item.id,
          selected.contains(item.id)
              ? (selected.toList()..sort()).join('\u0000')
              : '',
        ),
        actions: () => [
          if (item.isDirectory)
            const AppMenuAction(
              value: 'open',
              label: '打开文件夹',
              icon: Icons.folder_open,
            )
          else ...[
            AppMenuAction(
              value: 'download',
              label: selected.contains(item.id) && selected.length > 1
                  ? '下载（${selected.length} 项）'
                  : '下载',
              icon: Icons.download_outlined,
            ),
            if (supportsDownloadLocationChoice)
              const AppMenuAction(
                value: 'download-to',
                label: '下载到…',
                icon: Icons.folder_open,
              ),
            if (session.release.package.operations.containsKey('detail'))
              const AppMenuAction(
                value: 'details',
                label: '文件详情',
                icon: Icons.info_outline,
              ),
            AppMenuAction(
              value: 'select',
              label: selected.contains(item.id) ? '取消选择此项' : '选择此项',
              icon: Icons.check_circle_outline,
            ),
          ],
          const AppMenuAction(
            value: 'copy-name',
            label: '复制文件名',
            icon: Icons.copy_outlined,
          ),
        ],
        onSelected: (action) async {
          switch (action) {
            case 'open':
              await open(item);
            case 'details':
              await details(item);
            case 'download':
            case 'download-to':
              await download(
                selected.contains(item.id) && selected.length > 1
                    ? session.items
                          .where(
                            (i) => selected.contains(i.id) && !i.isDirectory,
                          )
                          .toList()
                    : [item],
                chooseLocation: action == 'download-to',
              );
            case 'select':
              setState(
                () => selected.contains(item.id)
                    ? selected.remove(item.id)
                    : selected.add(item.id),
              );
            case 'copy-name':
              await widget.services.copyText(item.name);
              if (mounted) message(context, '文件名已复制');
          }
        },
        child: child,
      );
  Future<void> nextPage() => run('正在读取更多文件…', () async {
    final previous = session;
    final next = await widget.services.sources.list(previous, next: true);
    RequestScope.checkpoint();
    if (next.hasMore &&
        jsonEncode(next.cursor) == jsonEncode(previous.cursor)) {
      throw const SourceError('SOURCE_RESULT', '来源返回了重复的分页信息');
    }
    final page = SourcePage.fromJson(session.release.package, {
      'title': session.title,
      'state': next.state,
      'items': [
        ...session.items.map((i) => i.json),
        ...next.items.map((i) => i.json),
      ],
      'cursor': next.cursor,
      'hasMore': next.hasMore,
    });
    setState(
      () => trail[trail.length - 1] = SourceSession(
        session.release,
        session.input,
        page,
      ),
    );
  });
  Future<void> find(String query) => run('正在搜索…', () async {
    if (query.trim().isEmpty) {
      setState(() {
        trail.removeRange(1, trail.length);
        selected.clear();
      });
      return;
    }
    final result = await widget.services.sources.list(
      session,
      search: query.trim(),
    );
    RequestScope.checkpoint();
    setState(() {
      trail.add(result);
      selected.clear();
    });
  });
  Future<void> details(SourceResource resource) => run('正在读取详情…', () async {
    final result = await widget.services.sources.detail(session, resource);
    RequestScope.checkpoint();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(result.str('title', resource.name)),
        content: SingleChildScrollView(
          child: SelectableText(
            result
                .str('description', '暂无更多说明')
                .substring(
                  0,
                  result.str('description', '暂无更多说明').length.clamp(0, 10000),
                ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  });
  Future<void> download(
    List<SourceResource> resources, {
    bool chooseLocation = false,
  }) async {
    if (working) return;
    final origin = session;
    final location = await chooseDownloadLocation(
      context,
      widget.services,
      alwaysAsk: chooseLocation,
    );
    if (location == null || !mounted || session != origin) return;
    await run('正在准备下载…', () async {
      final specs = <DownloadSpec>[];
      for (final resource in resources) {
        specs.add(await widget.services.sources.download(origin, resource));
        RequestScope.checkpoint();
      }
      final ids = await widget.services.downloads.enqueueAll(
        specs,
        location: location,
      );
      RequestScope.checkpoint();
      setState(() => selected.clear());
      if (mounted) {
        message(
          context,
          '已添加 ${ids.length} 个下载任务',
          onTap: widget.services.requestDownloadManager,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = session.items,
        hasSearch = session.release.package.operations.containsKey('search');
    return PopScope(
      canPop: !working && trail.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (working) {
          cancel();
          return;
        }
        if (trail.length > 1) {
          setState(() {
            trail.removeLast();
            selected.clear();
            search.clear();
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '下载管理',
              onPressed: widget.services.requestDownloadManager,
              icon: const Icon(Icons.download_outlined),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Icon(Icons.public, color: themeAccent(context), size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(session.release.package.name)),
                      if (trail.length > 1)
                        TextButton.icon(
                          onPressed: working
                              ? null
                              : () => setState(() {
                                  trail.removeLast();
                                  selected.clear();
                                  search.clear();
                                }),
                          icon: const Icon(Icons.arrow_upward, size: 18),
                          label: const Text('返回上级'),
                        ),
                    ],
                  ),
                ),
                if (hasSearch)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: TextField(
                      controller: search,
                      enabled: !working,
                      onSubmitted: find,
                      decoration: InputDecoration(
                        hintText: '搜索此来源',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: IconButton(
                          tooltip: '搜索',
                          onPressed: working ? null : () => find(search.text),
                          icon: const Icon(Icons.arrow_forward),
                        ),
                      ),
                    ),
                  ),
                if (error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      error,
                      key: const Key('source-browser-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (working)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(stage)),
                        TextButton(onPressed: cancel, child: const Text('取消')),
                      ],
                    ),
                  ),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('此来源暂无文件'))
                      : ListView.separated(
                          key: const Key('source-file-list'),
                          itemCount: items.length + (session.hasMore ? 1 : 0),
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            if (index == items.length) {
                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: OutlinedButton(
                                  onPressed: working ? null : nextPage,
                                  child: const Text('加载更多'),
                                ),
                              );
                            }
                            final item = items[index];
                            return _contextMenu(
                              item,
                              ListTile(
                                key: ValueKey('source-item-${item.id}'),
                                leading: item.isDirectory
                                    ? const Icon(Icons.folder_outlined)
                                    : Checkbox(
                                        value: selected.contains(item.id),
                                        onChanged: working
                                            ? null
                                            : (value) => setState(() {
                                                value == true
                                                    ? selected.add(item.id)
                                                    : selected.remove(item.id);
                                              }),
                                      ),
                                title: Text(
                                  item.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: item.isDirectory
                                    ? const Text('文件夹')
                                    : Text(
                                        item.size > 0
                                            ? formatBytes(item.size)
                                            : '文件',
                                      ),
                                onTap: working
                                    ? null
                                    : () => item.isDirectory
                                          ? open(item)
                                          : setState(() {
                                              selected.contains(item.id)
                                                  ? selected.remove(item.id)
                                                  : selected.add(item.id);
                                            }),
                                trailing: item.isDirectory
                                    ? const Icon(Icons.chevron_right)
                                    : Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (session.release.package.operations
                                              .containsKey('detail'))
                                            IconButton(
                                              tooltip: '详情',
                                              onPressed: working
                                                  ? null
                                                  : () => details(item),
                                              icon: const Icon(
                                                Icons.info_outline,
                                              ),
                                            ),
                                          IconButton(
                                            tooltip: '下载',
                                            key: ValueKey(
                                              'source-download-${item.id}',
                                            ),
                                            onPressed: working
                                                ? null
                                                : () => download([item]),
                                            icon: const Icon(
                                              Icons.download_outlined,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            );
                          },
                        ),
                ),
                if (selected.isNotEmpty)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Text('已选 ${selected.length} 项'),
                          const Spacer(),
                          TextButton(
                            onPressed: working
                                ? null
                                : () => setState(() => selected.clear()),
                            child: const Text('清空'),
                          ),
                          FilledButton.icon(
                            onPressed: working
                                ? null
                                : () => download(
                                    items
                                        .where((i) => selected.contains(i.id))
                                        .toList(),
                                  ),
                            icon: const Icon(Icons.download),
                            label: const Text('下载所选'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
