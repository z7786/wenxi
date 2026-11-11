import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsGpuPreferenceState {
  const WindowsGpuPreferenceState({
    this.enabled = false,
    this.restartRequired = false,
  });
  final bool enabled, restartRequired;

  factory WindowsGpuPreferenceState.fromMap(Map<Object?, Object?> value) =>
      WindowsGpuPreferenceState(
        enabled: value['enabled'] == true,
        restartRequired: value['restartRequired'] == true,
      );
}

/// An explicit Windows setting; opening the app never changes OS preferences.
class WindowsGpuPreference {
  const WindowsGpuPreference({TargetPlatform? platform}) : _platform = platform;
  final TargetPlatform? _platform;
  bool get supported =>
      (_platform ?? defaultTargetPlatform) == TargetPlatform.windows;
  static const _channel = MethodChannel('com.asterlink.app/gpu_preference');

  Future<WindowsGpuPreferenceState> read() => _invoke('get');
  Future<WindowsGpuPreferenceState> setEnabled(bool enabled) =>
      _invoke('set', {'enabled': enabled});

  Future<WindowsGpuPreferenceState> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    if (!supported) return const WindowsGpuPreferenceState();
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    if (result == null) {
      throw PlatformException(code: 'gpu_preference', message: '无法读取显卡设置');
    }
    return WindowsGpuPreferenceState.fromMap(result);
  }
}
