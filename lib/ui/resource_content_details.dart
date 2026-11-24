import 'package:flutter/material.dart';
import '../domain/resource_search.dart';
import 'common.dart';

/// Details for content published to the resource home by the backend.
/// A selected link is returned only after the details route has closed.
Future<ResourceSearchHit?> showResourceContentDetails(
  BuildContext context, {
  required ResourceSearchHit hit,
  required Future<void> Function(String) copyText,
  required bool Function(ResourceSearchHit) canOpen,
}) async {
  final desktop = switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
  ModalRoute<ResourceSearchHit>? route;
  Widget content(BuildContext modalContext) {
    route = ModalRoute.of<ResourceSearchHit>(modalContext);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(modalContext).height * .88,
        ),
        child: _ResourceContentDetails(
          hit: hit,
          copyText: copyText,
          canOpen: canOpen,
        ),
      ),
    );
  }

  FocusManager.instance.primaryFocus?.unfocus();
  final pending = desktop
      ? showDialog<ResourceSearchHit>(
          context: context,
          useRootNavigator: false,
          routeSettings: const RouteSettings(name: '/resources/content'),
          builder: (modalContext) => Dialog(
            constraints: const BoxConstraints(maxWidth: 840),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 24,
            ),
            clipBehavior: Clip.antiAlias,
            child: content(modalContext),
          ),
        )
      : showModalBottomSheet<ResourceSearchHit>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          showDragHandle: true,
          constraints: const BoxConstraints(maxWidth: 700),
          routeSettings: const RouteSettings(name: '/resources/content'),
          builder: content,
        );
  final selected = await pending;
  await route?.completed;
  return selected;
}

class _ResourceContentDetails extends StatefulWidget {
  const _ResourceContentDetails({
    required this.hit,
    required this.copyText,
    required this.canOpen,
  });
  final ResourceSearchHit hit;
  final Future<void> Function(String) copyText;
  final bool Function(ResourceSearchHit) canOpen;

  @override
  State<_ResourceContentDetails> createState() =>
      _ResourceContentDetailsState();
}

class _ResourceContentDetailsState extends State<_ResourceContentDetails> {
  int linkIndex = 0;
  bool copying = false;
  String feedback = '';
  ResourceSearchHit get selected => widget.hit.links.isEmpty
      ? widget.hit
      : widget.hit.withLink(widget.hit.links[linkIndex]);
  String get description => widget.hit.description.trim();

  Future<void> copy({required bool introduction}) async {
    if (copying || introduction && description.isEmpty) return;
    final hit = selected;
    final value = introduction ? description : hit.copyText;
    setState(() {
      copying = true;
      feedback = '';
    });
    try {
      await widget.copyText(value);
      if (mounted) {
        setState(() {
          feedback = introduction
              ? '简介已复制'
              : hit.password.isEmpty
              ? '链接已复制'
              : '链接和提取码已复制';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => feedback = '复制失败，请长按文本手动复制');
      }
    } finally {
      if (mounted) setState(() => copying = false);
    }
  }

  Widget provider(ResourceSearchHit hit) => Row(
    children: [
      PlatformMark(platform: hit.platform, size: 26),
      const SizedBox(width: 10),
      Expanded(child: Text(hit.cloudName, overflow: TextOverflow.ellipsis)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final hit = selected;
    final inset = MediaQuery.sizeOf(context).width < 400 ? 16.0 : 24.0;
    final open = FilledButton.icon(
      key: const Key('resource-content-open'),
      onPressed: copying ? null : () => Navigator.of(context).pop(hit),
      icon: const Icon(Icons.open_in_new, size: 17),
      label: Text(widget.canOpen(hit) ? '打开资源' : '浏览器打开'),
    );
    final copyActions = [
      TextButton.icon(
        key: const Key('resource-content-copy-description'),
        onPressed: copying || description.isEmpty
            ? null
            : () => copy(introduction: true),
        icon: const Icon(Icons.copy_outlined, size: 17),
        label: const Text('复制简介'),
      ),
      TextButton.icon(
        key: const Key('resource-content-copy-link'),
        onPressed: copying ? null : () => copy(introduction: false),
        icon: const Icon(Icons.link, size: 18),
        label: const Text('复制链接'),
      ),
    ];
    return Column(
      key: const Key('resource-content-details'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 8, inset - 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '资源详情',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                key: const Key('resource-content-close'),
                tooltip: '关闭简介',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 21),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            key: const Key('resource-content-scroll'),
            padding: EdgeInsets.fromLTRB(inset, 8, inset, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  widget.hit.title,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                if (widget.hit.category.isNotEmpty ||
                    widget.hit.date.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      if (widget.hit.category.isNotEmpty)
                        Text(
                          widget.hit.category,
                          style: TextStyle(
                            fontSize: 12,
                            color: secondary(context),
                          ),
                        ),
                      if (widget.hit.date.isNotEmpty)
                        Text(
                          widget.hit.date,
                          style: TextStyle(
                            fontSize: 12,
                            color: secondary(context),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                if (widget.hit.links.length > 1)
                  DropdownButtonFormField<int>(
                    key: const Key('resource-content-link-picker'),
                    isExpanded: true,
                    initialValue: linkIndex,
                    decoration: const InputDecoration(
                      labelText: '选择网盘入口',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final (index, link) in widget.hit.links.indexed)
                        DropdownMenuItem(
                          value: index,
                          child: provider(widget.hit.withLink(link)),
                        ),
                    ],
                    onChanged: copying
                        ? null
                        : (index) {
                            if (index == null) return;
                            setState(() {
                              linkIndex = index;
                              feedback = '';
                            });
                          },
                  )
                else
                  provider(hit),
                const SizedBox(height: 24),
                const Text(
                  '内容简介',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  description.isEmpty ? '暂未填写简介' : description,
                  key: const Key('resource-content-description'),
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.8,
                    color: description.isEmpty ? secondary(context) : null,
                  ),
                ),
                const Divider(height: 40),
                const Text('分享链接', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 8),
                SelectableText(
                  hit.url,
                  key: const Key('resource-content-link'),
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
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 12, inset, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (feedback.isNotEmpty) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    feedback,
                    key: const Key('resource-content-copy-feedback'),
                    style: TextStyle(fontSize: 12, color: secondary(context)),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              LayoutBuilder(
                builder: (context, bounds) {
                  if (bounds.maxWidth >= 480) {
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [...copyActions, open],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(spacing: 8, runSpacing: 4, children: copyActions),
                      const SizedBox(height: 8),
                      open,
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}
