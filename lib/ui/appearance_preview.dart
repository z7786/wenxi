import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../data/backgrounds.dart';
import '../domain/settings.dart';
import 'app_background.dart';
import 'app_navigation.dart';
import 'app_theme.dart';
import 'liquid_glass.dart';
import 'resource_search_bar.dart';

class AppearancePreview extends StatefulWidget {
  const AppearancePreview({
    super.key,
    required this.settings,
    required this.repository,
    this.dark,
    this.desktop = false,
    this.expanded = false,
  });
  final AppSettings settings;
  final BackgroundRepository repository;
  final bool? dark;
  final bool desktop, expanded;

  @override
  State<AppearancePreview> createState() => _AppearancePreviewState();
}

class _AppearancePreviewState extends State<AppearancePreview> {
  int selected = 0;
  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final brightness = widget.dark == null
        ? switch (settings.theme) {
            'Light' => Brightness.light,
            'Dark' => Brightness.dark,
            _ => MediaQuery.platformBrightnessOf(context),
          }
        : widget.dark!
        ? Brightness.dark
        : Brightness.light;
    return RepaintBoundary(
      key: const Key('appearance-preview'),
      child: AnimatedTheme(
        data: appTheme(
          brightness,
          palette: settings.themePalette,
          glassStyle: settings.glassStyle,
          glassControls: settings.glassControls,
          glassLowPower: settings.glassLowPower,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        ),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        child: Builder(
          builder: (context) {
            final colors = Theme.of(context).colorScheme;
            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: AppBackground(
                repository: widget.repository,
                settings: settings.background,
                desktop: widget.desktop,
                child: Builder(
                  builder: (context) {
                    final body = Column(
                      mainAxisSize: widget.expanded
                          ? MainAxisSize.max
                          : MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          color: backgroundSurface(
                            context,
                            fallback: Colors.transparent,
                          ),
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '文析助手',
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: colors.onSurface,
                                  ),
                                ),
                              ),
                              Icon(
                                CupertinoIcons.bell,
                                size: 20,
                                color: colors.primary,
                              ),
                            ],
                          ),
                        ),
                        if (widget.expanded) const SizedBox(height: 32),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: backgroundSurface(
                                context,
                                color: colors.surfaceContainerLow,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (settings.hideResourceNavigation)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      key: const Key(
                                        'appearance-preview-resources',
                                      ),
                                      onPressed: () =>
                                          setState(() => selected = 1),
                                      icon: SvgPicture.asset(
                                        'assets/navigation/search.svg',
                                        width: 17,
                                        height: 17,
                                        colorFilter: ColorFilter.mode(
                                          colors.primary,
                                          BlendMode.srcIn,
                                        ),
                                        excludeFromSemantics: true,
                                      ),
                                      label: const Text('资源'),
                                    ),
                                  ),
                                Text(
                                  '粘贴网盘分享链接',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                          child: LiquidGlassButton(
                            onPressed: () {},
                            child: const Text(
                              '解析链接',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: ResourceSearchBar(
                            buttonKey: const Key('appearance-preview-search'),
                            onPressed: () => setState(() => selected = 1),
                            field: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: Text(
                                '搜索资源',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: backgroundSurface(
                              context,
                              color: colors.surfaceContainerLow,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    CupertinoIcons.arrow_down_circle,
                                    size: 22,
                                    color: colors.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '项目资料.zip',
                                      style: TextStyle(
                                        fontSize: 13,
                                        color: colors.onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              LinearProgressIndicator(
                                value: .62,
                                minHeight: 4,
                                borderRadius: BorderRadius.circular(3),
                                color: colors.primary,
                                backgroundColor: colors.outlineVariant,
                              ),
                              const SizedBox(height: 7),
                              Text(
                                '正在下载 · 5.6 MB/s',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (widget.expanded) const Spacer(),
                        if (!widget.desktop)
                          Stack(
                            children: [
                              // A flat surface hides transparency and blur.
                              // Use sample content only when there is no wallpaper.
                              if (BackgroundScope.of(context)?.active != true)
                                Positioned.fill(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 14,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(32),
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          for (final color in [
                                            colors.primary,
                                            colors.secondary,
                                            colors.primary,
                                          ])
                                            Expanded(
                                              child: ColoredBox(color: color),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              MediaQuery.removePadding(
                                context: context,
                                removeTop: true,
                                removeBottom: true,
                                child: AppNavigation(
                                  selectedIndex: selected,
                                  hideResources:
                                      settings.hideResourceNavigation,
                                  onSelected: (index) =>
                                      setState(() => selected = index),
                                ),
                              ),
                            ],
                          ),
                      ],
                    );
                    return widget.desktop
                        ? Row(
                            children: [
                              AppNavigation(
                                rail: true,
                                selectedIndex: selected,
                                hideResources: settings.hideResourceNavigation,
                                onSelected: (index) =>
                                    setState(() => selected = index),
                              ),
                              Expanded(child: body),
                            ],
                          )
                        : body;
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
