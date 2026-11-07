import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../platform/link_opening.dart';
import 'common.dart';

class LinkOpeningPage extends StatefulWidget {
  const LinkOpeningPage({
    super.key,
    this.platform = const LinkOpeningPlatform(),
  });
  final LinkOpeningPlatform platform;

  @override
  State<LinkOpeningPage> createState() => _LinkOpeningPageState();
}

class _LinkOpeningPageState extends State<LinkOpeningPage>
    with WidgetsBindingObserver {
  List<LinkOpeningTarget>? _targets;
  String? _error;
  bool _reading = false, _changing = false, _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_reading || _changing) return;
    _reading = true;
    try {
      final values = await widget.platform.status();
      if (mounted) {
        setState(() {
          _targets = values;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法读取链接设置，请重试');
    } finally {
      _reading = false;
    }
  }

  Future<void> _set(LinkOpeningTarget target, bool enabled) async {
    if (_changing || _reading) return;
    setState(() => _changing = true);
    try {
      final values = await widget.platform.setEnabled(target.id, enabled);
      if (mounted) {
        setState(() {
          _targets = values;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) message(context, '无法更改链接入口，请重试或检查系统默认打开设置');
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _settings() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await widget.platform.openSettings();
    } catch (_) {
      if (mounted) message(context, '无法打开系统设置，请从应用信息中手动打开默认打开设置');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _group(List<Widget> children) => Material(
    color: backgroundSurface(context),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: border(context), width: .7),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0)
            Divider(
              height: 1,
              indent: 16,
              endIndent: 16,
              color: border(context),
            ),
          children[index],
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final android = widget.platform.android;
    final targets = _targets;
    return PageFrame(
      title: '链接唤起',
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            Text('用文析助手打开网盘链接', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            Text(
              android
                  ? '点击已关联的网盘链接，或通过分享菜单、选中文字发送到文析助手，即可进入解析页并识别提取码。'
                  : switch (widget.platform.operatingSystem) {
                      'ios' => '点击网页上的“用文析助手打开”，即可将网盘链接和提取码带入解析页。也可复制链接后进入应用。',
                      'macos' =>
                        '将文析助手放入“应用程序”并启动一次后，点击网页上的“用文析助手打开”，即可带入链接和提取码。也可复制链接后进入应用。',
                      _ =>
                        '点击网页上的“用文析助手打开”，即可将网盘链接和提取码带入解析页。请使用 Windows 安装版完成关联。',
                    },
              style: TextStyle(color: secondary(context), height: 1.6),
            ),
            if (android) ...[
              const SizedBox(height: 16),
              _group([
                ListTile(
                  leading: Icon(
                    CupertinoIcons.link,
                    color: themeAccent(context),
                  ),
                  title: const Text('系统默认打开设置'),
                  subtitle: const Text('开启“打开支持的链接”，选择需要关联的网盘域名'),
                  trailing: const Icon(CupertinoIcons.arrow_up_right, size: 18),
                  onTap: _opening ? null : _settings,
                ),
              ]),
              const SizedBox(height: 10),
              Text(
                'Android 12 及以上通常需要在系统中手动关联。部分应用会在内部浏览器打开链接，可改用分享菜单或先在外部浏览器打开。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: secondary(context),
                ),
              ),
              const SizedBox(height: 24),
              if (_error != null) ...[
                Text(_error!),
                TextButton(onPressed: _refresh, child: const Text('重试')),
              ] else if (targets == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 10),
                  child: Text(
                    '解析入口 · 已开启 ${targets.where((t) => t.enabled).length} / ${targets.length}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                _group([
                  for (final target in targets)
                    SwitchListTile.adaptive(
                      key: ValueKey('link-opening-${target.id}'),
                      title: Text(
                        target.label,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        target.sample,
                        style: TextStyle(
                          fontSize: 12,
                          color: secondary(context),
                        ),
                      ),
                      value: target.enabled,
                      onChanged: _changing || _reading
                          ? null
                          : (enabled) => _set(target, enabled),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                    ),
                ]),
              ],
            ] else ...[
              const SizedBox(height: 24),
              _group(const [
                ListTile(
                  leading: Icon(CupertinoIcons.link),
                  title: Text('网页一键打开'),
                  subtitle: Text('浏览器提示是否打开文析助手时，允许本次打开即可。'),
                ),
                ListTile(
                  leading: Icon(CupertinoIcons.doc_on_clipboard),
                  title: Text('复制链接后打开软件'),
                  subtitle: Text('也可以使用剪贴板识别，将网页中的分享文案带入解析页。'),
                ),
              ]),
            ],
            const SizedBox(height: 16),
            Text(
              '进入解析页后可沿用账号解析或已配置的公益解析。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: secondary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
