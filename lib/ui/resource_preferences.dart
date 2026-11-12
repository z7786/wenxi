import 'package:flutter/material.dart';
import '../data/resource_search.dart';
import '../domain/baidu_share_route.dart';
import '../domain/models.dart';
import 'common.dart';

Future<void> showResourcePrioritySheet(
  BuildContext context,
  ResourceSearch search,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ResourcePrioritySheet(search),
);

class _ResourcePrioritySheet extends StatefulWidget {
  const _ResourcePrioritySheet(this.search);
  final ResourceSearch search;
  @override
  State<_ResourcePrioritySheet> createState() => _ResourcePrioritySheetState();
}

class _ResourcePrioritySheetState extends State<_ResourcePrioritySheet> {
  late List<CloudPlatform> order = widget.search.cloudPriority
      .where((p) => p != CloudPlatform.github)
      .toList();
  bool saving = false;
  late bool incognito = widget.search.incognito;
  bool updatingIncognito = false;

  Future<void> setIncognito(bool value) async {
    setState(() {
      incognito = value;
      updatingIncognito = true;
    });
    try {
      await widget.search.setIncognito(value);
    } catch (e) {
      if (mounted) message(context, errorText(e));
    } finally {
      if (mounted) {
        setState(() {
          incognito = widget.search.incognito;
          updatingIncognito = false;
        });
      }
    }
  }

  void move(int from, int to) {
    if (saving || to < 0 || to >= order.length) return;
    setState(() => order.insert(to, order.removeAt(from)));
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      await widget.search.setCloudPriority(order);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => saving = false);
        message(context, errorText(e));
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .82,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              header: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                    child: Text(
                      '搜索设置',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    key: const Key('resource-search-incognito'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                    title: const Text('无痕模式'),
                    subtitle: const Text('开启后不保存新的资源搜索和网盘搜索记录'),
                    value: incognito,
                    onChanged: saving || updatingIncognito
                        ? null
                        : setIncognito,
                  ),
                  const Divider(indent: 24, endIndent: 24),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '网盘展示优先级',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton(
                          key: const Key('resource-priority-reset'),
                          onPressed: saving
                              ? null
                              : () => setState(
                                  () => order = ResourceSearch
                                      .defaultCloudPriority
                                      .where((p) => p != CloudPlatform.github)
                                      .toList(),
                                ),
                          child: const Text('恢复默认'),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      '拖动调整顺序，也可点击箭头移动。设置保存在本机，并应用于搜索结果和网盘标签。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: secondary(context),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
              itemCount: order.length,
              onReorder: (from, to) {
                if (to > from) to--;
                move(from, to);
              },
              itemBuilder: (context, index) {
                final platform = order[index];
                return ListTile(
                  key: ValueKey('resource-priority-${platform.key}'),
                  leading: PlatformMark(platform: platform, size: 28),
                  title: Text(
                    platform.label,
                    style: const TextStyle(fontSize: 14),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '上移${platform.shortName}',
                        onPressed: saving || index == 0
                            ? null
                            : () => move(index, index - 1),
                        icon: const Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 22,
                        ),
                      ),
                      IconButton(
                        tooltip: '下移${platform.shortName}',
                        onPressed: saving || index == order.length - 1
                            ? null
                            : () => move(index, index + 1),
                        icon: const Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 22,
                        ),
                      ),
                      ReorderableDragStartListener(
                        index: index,
                        enabled: !saving,
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.drag_handle_rounded, size: 20),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: FilledButton(
              key: const Key('resource-priority-save'),
              onPressed: saving || updatingIncognito ? null : save,
              child: Text(saving ? '保存中…' : '保存顺序'),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<BaiduShareRoute?> showResourceParseRoute(
  BuildContext context,
  CloudPlatform platform,
) => showModalBottomSheet<BaiduShareRoute>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PlatformMark(platform: platform, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '选择解析方式',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${platform.label}已配置公益通道，请选择本次打开方式。',
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: secondary(context),
            ),
          ),
          const SizedBox(height: 20),
          for (final route in BaiduShareRoute.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Material(
                color: fill(context),
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  key: ValueKey('resource-parse-${route.key}'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  leading: Icon(
                    route == BaiduShareRoute.account
                        ? Icons.person_outline_rounded
                        : Icons.volunteer_activism_outlined,
                    color: themeAccent(context),
                  ),
                  title: Text(
                    route == BaiduShareRoute.account ? '账号解析' : '公益解析',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    route == BaiduShareRoute.account
                        ? '使用网盘账号或原有常规通道'
                        : '使用已配置的公益通道，可能有额度或密码要求',
                    style: const TextStyle(fontSize: 12, height: 1.6),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.pop(context, route),
                ),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  ),
);
