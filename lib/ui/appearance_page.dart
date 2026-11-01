import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../app_services.dart';
import '../domain/appearance.dart';
import '../domain/settings.dart';
import 'appearance_preview.dart';
import 'background_page.dart';
import 'common.dart';

class AppearancePage extends StatefulWidget {
  const AppearancePage(this.services, {super.key});
  final AppServices services;

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  late AppSettings _draft = widget.services.settings;
  bool _saving = false;

  static const modes = [
    ('System', '跟随系统', CupertinoIcons.device_desktop),
    ('Light', '浅色', CupertinoIcons.sun_max),
    ('Dark', '深色', CupertinoIcons.moon),
  ];

  bool get _changed {
    final saved = widget.services.settings;
    return _draft.theme != saved.theme ||
        _draft.themePalette != saved.themePalette ||
        _draft.glassStyle != saved.glassStyle ||
        _draft.hideResourceNavigation != saved.hideResourceNavigation ||
        _draft.background != saved.background;
  }

  Future<void> _apply() async {
    if (_saving || !_changed) return;
    setState(() => _saving = true);
    try {
      await widget.services.updateAppearance(
        mode: _draft.theme,
        palette: _draft.themePalette,
        glassStyle: _draft.glassStyle,
        background: _draft.background,
        hideResourceNavigation: _draft.hideResourceNavigation,
      );
      if (mounted) message(context, '主题已应用');
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _update(Map<String, Object?> values) {
    if (!_saving) setState(() => _draft = _draft.update(values));
  }

  Future<void> _background() async {
    final result = await Navigator.push<AppSettings>(
      context,
      MaterialPageRoute(
        builder: (_) => BackgroundPage(widget.services, initial: _draft),
      ),
    );
    if (result != null && mounted) {
      setState(() => _draft = result);
      message(context, '主题与背景已应用');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.services.store,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('主题与外观')),
      body: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 860;
            final controls = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section('外观模式', _modes()),
                const SizedBox(height: 24),
                _section('主题配色', _palettes()),
                const SizedBox(height: 24),
                _section('玻璃效果', _glassStyles()),
                const SizedBox(height: 24),
                _section(
                  '导航入口',
                  Material(
                    color: fill(context),
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: SwitchListTile.adaptive(
                      key: const Key('appearance-hide-resource-navigation'),
                      secondary: SvgPicture.asset(
                        'assets/navigation/search.svg',
                        width: 24,
                        height: 24,
                        colorFilter: ColorFilter.mode(
                          themeAccent(context),
                          BlendMode.srcIn,
                        ),
                        excludeFromSemantics: true,
                      ),
                      title: const Text('隐藏底栏资源入口'),
                      subtitle: const Text('隐藏后从解析页的「资源」按钮进入，桌面侧栏同步隐藏。'),
                      value: _draft.hideResourceNavigation,
                      onChanged: _saving
                          ? null
                          : (value) =>
                                _update({'hideResourceNavigation': value}),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Material(
                  color: fill(context),
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    key: const Key('appearance-background'),
                    leading: Icon(
                      CupertinoIcons.photo,
                      color: themeAccent(context),
                    ),
                    title: const Text('自定义背景'),
                    subtitle: Text(
                      _draft.background.hasImage
                          ? '已设置 · 图片、位置与显示效果'
                          : '选择自己的图片，预览四个主页面',
                    ),
                    trailing: const Icon(
                      CupertinoIcons.chevron_right,
                      size: 16,
                    ),
                    onTap: _saving ? null : _background,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '选择后可预览，点击「应用主题」保存。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: secondary(context),
                  ),
                ),
              ],
            );
            final preview = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const Text(
                        '效果预览',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Text(
                        _draft.themePalette.label,
                        style: TextStyle(
                          fontSize: 12,
                          color: secondary(context),
                        ),
                      ),
                    ],
                  ),
                ),
                AppearancePreview(
                  settings: _draft,
                  repository: widget.services.backgrounds,
                ),
              ],
            );
            return SingleChildScrollView(
              key: const Key('appearance-scroll'),
              padding: EdgeInsets.fromLTRB(
                wide ? 32 : 16,
                12,
                wide ? 32 : 16,
                28,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1020),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(width: 340, child: preview),
                            const SizedBox(width: 36),
                            Expanded(child: controls),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            preview,
                            const SizedBox(height: 28),
                            controls,
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1020),
            child: Row(
              children: [
                TextButton(
                  key: const Key('appearance-reset'),
                  onPressed: _saving
                      ? null
                      : () => setState(() => _draft = const AppSettings()),
                  child: const Text('恢复默认'),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    key: const Key('appearance-apply'),
                    onPressed: _saving || !_changed ? null : _apply,
                    child: Text(_saving ? '正在保存…' : '应用主题'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _section(String title, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      child,
    ],
  );

  Widget _modes() => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: fill(context),
      borderRadius: BorderRadius.circular(16),
    ),
    child: IntrinsicHeight(
      child: Row(
        children: [
          for (final mode in modes)
            Expanded(
              child: _Choice(
                key: ValueKey('appearance-mode-${mode.$1}'),
                selected: _draft.theme == mode.$1,
                label: mode.$2,
                onTap: _saving ? null : () => _update({'theme': mode.$1}),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 12,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        mode.$3,
                        size: 21,
                        color: _draft.theme == mode.$1
                            ? themeAccent(context)
                            : secondary(context),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        mode.$2,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _palettes() => LayoutBuilder(
    builder: (context, constraints) {
      final columns =
          constraints.maxWidth < 330 ||
              MediaQuery.textScalerOf(context).scale(14) > 18
          ? 2
          : 3;
      final width = (constraints.maxWidth - 10 * (columns - 1)) / columns;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final palette in AppPalette.values)
            SizedBox(
              width: width,
              child: _Choice(
                key: ValueKey('appearance-palette-${palette.name}'),
                selected: _draft.themePalette == palette,
                label: palette.label,
                accent: Color(
                  palette
                      .colors(Theme.of(context).brightness == Brightness.dark)
                      .accent,
                ),
                outlined: true,
                onTap: _saving
                    ? null
                    : () => _update({'themePalette': palette.name}),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 14,
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _swatch(Color(palette.lightAccent), 22),
                          const SizedBox(width: 4),
                          _swatch(Color(palette.darkAccent), 16),
                          const SizedBox(width: 4),
                          _swatch(Color(palette.colors(false).fill), 12),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        palette.label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _swatch(Color color, double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: border(context), width: .5),
    ),
  );

  Widget _glassStyles() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          '调整底部和侧边导航的透明与模糊效果。未设置背景时，预览使用示例底色。',
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: secondary(context),
          ),
        ),
      ),
      for (final style in GlassStyle.values)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _Choice(
            key: ValueKey('appearance-glass-${style.name}'),
            selected: _draft.glassStyle == style,
            label: style.label,
            outlined: true,
            onTap: _saving ? null : () => _update({'glassStyle': style.name}),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  Icon(
                    switch (style) {
                      GlassStyle.clear => CupertinoIcons.drop,
                      GlassStyle.frosted => CupertinoIcons.square_stack_3d_up,
                      GlassStyle.solid => CupertinoIcons.square_fill,
                    },
                    size: 22,
                    color: _draft.glassStyle == style
                        ? themeAccent(context)
                        : secondary(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          style.label,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          style.description,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: secondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _draft.glassStyle == style
                        ? CupertinoIcons.checkmark_circle_fill
                        : CupertinoIcons.circle,
                    size: 20,
                    color: _draft.glassStyle == style
                        ? themeAccent(context)
                        : border(context),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.selected,
    required this.label,
    required this.onTap,
    required this.child,
    this.accent,
    this.outlined = false,
  });
  final bool selected, outlined;
  final String label;
  final VoidCallback? onTap;
  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? themeAccent(context);
    final radius = BorderRadius.circular(12);
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Material(
        color: selected
            ? Color.alphaBlend(
                color.withValues(alpha: .075),
                Theme.of(context).colorScheme.surface,
              )
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: outlined
              ? BorderSide(
                  color: selected ? color : border(context),
                  width: selected ? 1.5 : .8,
                )
              : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(borderRadius: radius, onTap: onTap, child: child),
      ),
    );
  }
}
