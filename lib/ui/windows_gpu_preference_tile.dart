import 'package:flutter/material.dart';
import '../platform/windows_gpu_preference.dart';

class WindowsGpuPreferenceTile extends StatefulWidget {
  const WindowsGpuPreferenceTile({
    super.key,
    this.preference = const WindowsGpuPreference(),
  });
  final WindowsGpuPreference preference;
  @override
  State<WindowsGpuPreferenceTile> createState() =>
      _WindowsGpuPreferenceTileState();
}

class _WindowsGpuPreferenceTileState extends State<WindowsGpuPreferenceTile> {
  WindowsGpuPreferenceState? _value;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final value = await widget.preference.read();
      if (mounted) {
        setState(() {
          _value = value;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取显卡设置，点击重试');
    }
  }

  Future<void> _set(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final value = await widget.preference.setEnabled(enabled);
      if (mounted) {
        setState(() {
          _value = value;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('显卡设置未能更改，请重试')));
      }
      await _read();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.preference.supported) return const SizedBox.shrink();
    if (_error != null) {
      return ListTile(
        key: const Key('player-gpu-preference-retry'),
        title: const Text('优先高性能显卡'),
        subtitle: Text(_error!),
        trailing: const Icon(Icons.refresh),
        onTap: _busy ? null : _read,
      );
    }
    return SwitchListTile(
      key: const Key('player-high-performance-gpu'),
      title: const Text('优先高性能显卡'),
      subtitle: Text(
        _value == null
            ? '正在读取显卡设置'
            : '${_value!.enabled ? '适合双显卡电脑播放高码率视频，可能增加功耗' : '遵循 Windows 显卡设置'}'
                  '${_value!.restartRequired ? '；完全退出并重新启动软件后生效' : ''}',
      ),
      value: _value?.enabled ?? false,
      onChanged: _value == null || _busy || _error != null ? null : _set,
    );
  }
}
