import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../app_services.dart';
import '../domain/background.dart';
import '../domain/settings.dart';
import 'app_background.dart';
import 'appearance_preview.dart';
import 'background_crop_page.dart';
import 'common.dart';

class BackgroundPage extends StatefulWidget {
  const BackgroundPage(
    this.services, {
    super.key,
    required this.initial,
    this.pickImage,
  });
  final AppServices services;
  final AppSettings initial;
  final Future<XFile?> Function()? pickImage;
  @override
  State<BackgroundPage> createState() => _BackgroundPageState();
}

class _BackgroundPageState extends State<BackgroundPage> {
  late AppSettings _draft = widget.initial;
  late final Object _lease;
  bool _busy = false, _saving = false;
  bool? _dark, _desktop;
  BackgroundSettings get background => _draft.background;

  @override
  void initState() {
    super.initState();
    // Reserve the existing pictures for the full lifetime of this draft.
    _lease = widget.services.backgrounds.beginDraft();
  }

  @override
  void dispose() {
    unawaited(widget.services.backgrounds.endDraft(_lease));
    super.dispose();
  }

  void _change(BackgroundSettings value) =>
      setState(() => _draft = _draft.update({'background': value.toJson()}));

  Future<void> _choose(bool night) async {
    if (_busy || _saving) return;
    setState(() => _busy = true);
    try {
      final source = widget.pickImage != null
          ? await widget.pickImage!()
          : await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: '背景图片',
                  extensions: ['jpg', 'jpeg', 'png', 'webp'],
                  mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
                ),
              ],
              confirmButtonText: '选择背景',
            );
      if (source == null || !mounted) return;
      final picture = await widget.services.backgrounds.importFile(
        source,
        _lease,
      );
      if (!mounted) return;
      _change(background.withPicture(picture, dark: night));
      setState(() => _dark = night);
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _crop(bool night) async {
    final image = night ? background.night : background.day;
    if (image == null) return;
    final result = await Navigator.push<BackgroundPicture>(
      context,
      MaterialPageRoute(
        builder: (_) => BackgroundCropPage(
          repository: widget.services.backgrounds,
          picture: image,
          desktop: _desktop ?? desktopBackground(context),
        ),
      ),
    );
    if (result != null && mounted) {
      _change(background.withPicture(result, dark: night));
    }
  }

  Future<void> _apply() async {
    if (_busy || _saving) return;
    setState(() => _saving = true);
    try {
      await widget.services.updateAppearance(
        mode: _draft.theme,
        palette: _draft.themePalette,
        glassStyle: _draft.glassStyle,
        glassControls: _draft.glassControls,
        glassLowPower: _draft.glassLowPower,
        background: background,
        hideResourceNavigation: _draft.hideResourceNavigation,
      );
      if (mounted) Navigator.pop(context, _draft);
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark =
        _dark ??
        switch (_draft.theme) {
          'Dark' => true,
          'Light' => false,
          _ => MediaQuery.platformBrightnessOf(context) == Brightness.dark,
        };
    final desktop = _desktop ?? desktopBackground(context);
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('自定义背景')),
        body: SafeArea(
          top: false,
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 860;
              final preview = Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                    child: Wrap(
                      spacing: 14,
                      runSpacing: 10,
                      alignment: WrapAlignment.center,
                      children: [
                        CupertinoSlidingSegmentedControl<bool>(
                          groupValue: desktop,
                          children: const {
                            false: Text('手机', style: TextStyle(fontSize: 12)),
                            true: Text('电脑', style: TextStyle(fontSize: 12)),
                          },
                          onValueChanged: (v) {
                            if (v != null) setState(() => _desktop = v);
                          },
                        ),
                        CupertinoSlidingSegmentedControl<bool>(
                          groupValue: dark,
                          children: const {
                            false: Tooltip(
                              message: '预览浅色效果',
                              child: Text('浅色', style: TextStyle(fontSize: 12)),
                            ),
                            true: Tooltip(
                              message: '预览深色效果',
                              child: Text('深色', style: TextStyle(fontSize: 12)),
                            ),
                          },
                          onValueChanged: (v) {
                            if (v != null) setState(() => _dark = v);
                          },
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox(
                            width: desktop ? 1000 : 393,
                            height:
                                (desktop ? 1000 : 393) /
                                backgroundPreviewRatio(context, desktop),
                            child: IgnorePointer(
                              child: AppearancePreview(
                                repository: widget.services.backgrounds,
                                settings: _draft,
                                dark: dark,
                                desktop: desktop,
                                expanded: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                    child: Text(
                      _busy ? '正在处理图片…' : '四个主页面共用背景',
                      style: TextStyle(fontSize: 12, color: secondary(context)),
                    ),
                  ),
                ],
              );
              final controls = SingleChildScrollView(
                key: const Key('background-controls'),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: _controls(),
              );
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1140),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                child: preview,
                              ),
                            ),
                            SizedBox(width: 420, child: controls),
                          ],
                        )
                      : Column(
                          children: [
                            SizedBox(
                              height: (constraints.maxHeight * .43).clamp(
                                180,
                                310,
                              ),
                              child: preview,
                            ),
                            const Divider(height: 1),
                            Expanded(child: controls),
                          ],
                        ),
                ),
              );
            },
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            children: [
              TextButton(
                key: const Key('background-remove-all'),
                onPressed: !_busy && !_saving && background.hasImage
                    ? () => _change(background.withoutImages())
                    : null,
                child: const Text('移除背景'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  key: const Key('background-apply'),
                  onPressed: _busy || _saving ? null : _apply,
                  child: Text(_saving ? '正在保存…' : '应用主题'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _imageTile(false),
      const SizedBox(height: 10),
      _imageTile(true),
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 10, 2, 16),
        child: Text(
          '夜间图片可选；未设置时自动压暗日间背景。图片保存在软件内，删除原图不影响使用。',
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: secondary(context),
          ),
        ),
      ),
      _slider(
        '背景亮度',
        'background-brightness',
        background.brightness,
        .35,
        1,
        65,
        '${(background.brightness * 100).round()}%',
        (v) => _change(background.copyWith(brightness: v)),
      ),
      _slider(
        '背景模糊程度',
        'background-blur',
        background.blur,
        0,
        20,
        40,
        background.blur == 0 ? '清晰' : '${(background.blur * 5).round()}%',
        (v) => _change(background.copyWith(blur: v)),
      ),
      _slider(
        '内容卡片透明度',
        'background-transparency',
        1 - background.cardOpacity,
        0,
        .4,
        40,
        '${((1 - background.cardOpacity) * 100).round()}%',
        (v) => _change(background.copyWith(cardOpacity: 1 - v)),
      ),
    ],
  );

  Widget _imageTile(bool night) {
    final image = night ? background.night : background.day;
    final slot = night ? 'night' : 'day';
    return Material(
      color: fill(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 68,
                child: image == null
                    ? ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: Icon(
                          night
                              ? CupertinoIcons.moon_stars
                              : CupertinoIcons.photo,
                          color: secondary(context),
                          size: 25,
                        ),
                      )
                    : BackgroundImageView(
                        repository: widget.services.backgrounds,
                        picture: image,
                        crop: image.cropFor(
                          _desktop ?? desktopBackground(context),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    night ? '夜间背景' : '日间背景',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        key: ValueKey('background-$slot-select'),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                        onPressed: _busy || _saving
                            ? null
                            : () => _choose(night),
                        child: Text(image == null ? '选择图片' : '更换图片'),
                      ),
                      if (image != null)
                        TextButton(
                          key: ValueKey('background-$slot-crop'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          onPressed: _busy || _saving
                              ? null
                              : () => _crop(night),
                          child: const Text('调整位置'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (image != null)
              IconButton(
                key: ValueKey('background-$slot-remove'),
                tooltip: '移除${night ? '夜间' : '日间'}背景',
                onPressed: _busy || _saving
                    ? null
                    : () => _change(background.withPicture(null, dark: night)),
                icon: const Icon(CupertinoIcons.xmark_circle, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    String title,
    String key,
    double value,
    double min,
    double max,
    int divisions,
    String label,
    ValueChanged<double> onChanged,
  ) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 14))),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: secondary(context)),
            ),
          ],
        ),
        Slider(
          key: ValueKey(key),
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: background.hasImage && !_busy && !_saving
              ? onChanged
              : null,
        ),
      ],
    ),
  );
}
