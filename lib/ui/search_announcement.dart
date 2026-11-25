import 'package:flutter/material.dart';
import '../domain/remote_control.dart';
import 'announcement_markdown.dart';
import 'common.dart';
import 'remote_links.dart';

/// A single passive notice; the parent omits this widget when none is active.
class SearchAnnouncementBar extends StatefulWidget {
  const SearchAnnouncementBar({
    super.key,
    required this.notice,
    required this.copyText,
    this.active = true,
    this.linkLauncher,
  });
  final SearchAnnouncement notice;
  final Future<void> Function(String) copyText;
  final bool active;
  final RemoteLinkLauncher? linkLauncher;

  @override
  State<SearchAnnouncementBar> createState() => _SearchAnnouncementBarState();
}

class _SearchAnnouncementBarState extends State<SearchAnnouncementBar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _motion = AnimationController(vsync: this);
  bool _hovered = false, _focused = false, _details = false;
  bool _foreground = true;
  double _distance = 0;
  String _measuredText = '';

  String get _text => widget.notice.title.replaceAll(RegExp(r'\s+'), ' ');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _foreground = state == AppLifecycleState.resumed);
  }

  void _configure(double distance, bool allowed) {
    final text = _text;
    // Layout and inherited route state can change while the controller ticks.
    // Apply those changes after layout, never rebuild the page on every tick.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_distance != distance || _measuredText != text) {
        _motion.stop();
        _motion.value = 0;
        _distance = distance;
        _measuredText = text;
        _motion.duration = Duration(
          milliseconds: (2000 + distance / 24 * 1000).round(),
        );
      }
      if (allowed && !_motion.isAnimating) {
        _motion.repeat();
      } else if (!allowed) {
        _motion.stop();
      }
    });
  }

  Future<void> _open() async {
    if (_details) return;
    _motion.stop();
    setState(() => _details = true);
    try {
      await _showDetails(
        context,
        widget.notice,
        widget.copyText,
        widget.linkLauncher,
      );
    } finally {
      if (mounted) setState(() => _details = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = themeAccent(context);
    final style = Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontSize: 13,
      height: 1.4,
      color: Theme.of(context).colorScheme.onSurface,
    );
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final allowed =
        widget.active &&
        _foreground &&
        !_details &&
        !_hovered &&
        !_focused &&
        !reduced &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    return Semantics(
      label: '公告：${widget.notice.title}，查看全文',
      button: true,
      child: Material(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('search-announcement-bar'),
          onTap: _open,
          onHover: (value) => setState(() => _hovered = value),
          onFocusChange: (value) => setState(() => _focused = value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Icon(Icons.campaign_outlined, size: 18, color: color),
                  const SizedBox(width: 9),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final painter = TextPainter(
                          text: TextSpan(text: _text, style: style),
                          textDirection: Directionality.of(context),
                          textScaler: MediaQuery.textScalerOf(context),
                          maxLines: 1,
                        )..layout();
                        final width = painter.width, height = painter.height;
                        painter.dispose();
                        final overflow = width > constraints.maxWidth;
                        final distance = overflow ? width + 40 : 0.0;
                        _configure(distance, allowed && overflow);
                        if (!overflow || reduced) {
                          return Text(
                            _text,
                            style: style,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          );
                        }
                        return ClipRect(
                          child: SizedBox(
                            height: height,
                            child: AnimatedBuilder(
                              animation: _motion,
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                minWidth: distance * 2,
                                maxWidth: distance * 2,
                                child: Row(
                                  children: [
                                    Text(_text, style: style, maxLines: 1),
                                    const SizedBox(width: 40),
                                    Text(_text, style: style, maxLines: 1),
                                  ],
                                ),
                              ),
                              builder: (_, child) {
                                final seconds =
                                    _motion.value * (2 + distance / 24);
                                final offset = ((seconds - 2) * 24).clamp(
                                  0.0,
                                  distance,
                                );
                                return Transform.translate(
                                  key: const Key('search-announcement-motion'),
                                  offset: Offset(-offset, 0),
                                  child: child,
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: secondary(context),
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

Future<void> _showDetails(
  BuildContext context,
  SearchAnnouncement notice,
  Future<void> Function(String) copyText,
  RemoteLinkLauncher? launcher,
) async {
  final desktop = switch (Theme.of(context).platform) {
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => true,
    _ => false,
  };
  ModalRoute<void>? route;
  Widget content(BuildContext context) {
    route = ModalRoute.of<void>(context);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: _AnnouncementDetails(notice, copyText, launcher),
      ),
    );
  }

  FocusManager.instance.primaryFocus?.unfocus();
  if (desktop) {
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      routeSettings: const RouteSettings(name: '/resources/announcement'),
      builder: (context) => Dialog(
        constraints: const BoxConstraints(maxWidth: 760),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        clipBehavior: Clip.antiAlias,
        child: content(context),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 700),
      routeSettings: const RouteSettings(name: '/resources/announcement'),
      builder: content,
    );
  }
  await route?.completed;
}

class _AnnouncementDetails extends StatefulWidget {
  const _AnnouncementDetails(this.notice, this.copyText, this.launcher);
  final SearchAnnouncement notice;
  final Future<void> Function(String) copyText;
  final RemoteLinkLauncher? launcher;
  @override
  State<_AnnouncementDetails> createState() => _AnnouncementDetailsState();
}

class _AnnouncementDetailsState extends State<_AnnouncementDetails> {
  bool _copying = false;
  String _feedback = '';
  Future<void> _copy() async {
    setState(() => _copying = true);
    try {
      final notice = widget.notice;
      await widget.copyText(
        [
          notice.title,
          if (notice.content.isNotEmpty) notice.content,
        ].join('\n\n'),
      );
      if (mounted) setState(() => _feedback = '公告已复制');
    } catch (_) {
      if (mounted) setState(() => _feedback = '复制失败，请长按文本手动复制');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    return Column(
      key: const Key('search-announcement-details'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '公告',
                  style: TextStyle(fontSize: 13, color: secondary(context)),
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  notice.title,
                  style: const TextStyle(
                    fontSize: 20,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (notice.content.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  AnnouncementMarkdown(
                    notice.content,
                    linkLauncher: widget.launcher,
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_feedback.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _feedback,
                    style: TextStyle(color: secondary(context)),
                  ),
                ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: _copying ? null : _copy,
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    label: const Text('复制公告'),
                  ),
                  if (notice.buttonUrl case final url?)
                    FilledButton.icon(
                      onPressed: () => openAnnouncementLink(
                        context,
                        url,
                        launcher: widget.launcher,
                      ),
                      icon: const Icon(Icons.open_in_new, size: 17),
                      label: Text(notice.buttonText),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
