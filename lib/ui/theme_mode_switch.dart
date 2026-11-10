import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import 'app_switch.dart';
import 'common.dart';
import 'theme_reveal.dart';

class ThemeModeSwitch extends StatefulWidget {
  const ThemeModeSwitch(this.services, {super.key, this.icon});

  final AppServices services;
  final Widget? icon;

  @override
  State<ThemeModeSwitch> createState() => _ThemeModeSwitchState();
}

class _ThemeModeSwitchState extends State<ThemeModeSwitch> {
  final _control = GlobalKey();
  bool _saving = false;

  Future<void> _change(bool dark) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ThemeRevealHost.change(
        context,
        origin: _control.currentContext,
        keepOriginVisible: true,
        dark: dark,
        update: () {
          final settings = widget.services.settings;
          return widget.services.updateAppearance(
            mode: dark ? 'Dark' : 'Light',
            palette: settings.themePalette,
            glassStyle: settings.glassStyle,
          );
        },
      );
    } catch (error) {
      if (mounted) message(context, errorText(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AppSwitchListTile(
    key: const Key('dark-mode-switch'),
    controlKey: _control,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    secondary: widget.icon ?? const Icon(CupertinoIcons.moon),
    title: const Text('深色模式', style: TextStyle(fontSize: 14)),
    subtitle: Text(
      widget.services.settings.theme == 'System' ? '当前跟随系统' : '切换应用的明暗外观',
      style: const TextStyle(fontSize: 12),
    ),
    value: Theme.of(context).brightness == Brightness.dark,
    onChanged: _saving ? null : _change,
  );
}
