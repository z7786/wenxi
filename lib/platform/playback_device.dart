import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import 'windows_pip.dart';
import 'windows_external_player.dart';

abstract class PlaybackDevice extends ChangeNotifier {
  bool get supportsOrientation => false;
  bool get supportsPip;
  bool get supportsDesktopPip => false;
  bool get supportsExternalPlayer => false;
  WindowsExternalPlayer? get windowsExternalPlayer => null;
  bool get supportsBrightness;
  bool get inPip;
  double get brightness;
  Stream<String> get actions;
  Future<void> start({required bool video});
  Future<void> update({
    required bool playing,
    int? width,
    int? height,
    bool autoRotate = true,
    PlaybackOrientation? orientation,
    bool locked = false,
    bool controlsVisible = true,
  });
  Future<void> setBrightness(double value);
  Future<void> fullscreen(bool enabled);
  Future<bool> enterPip();
  Future<void> exitPip() async {}
  Future<void> dragPip() async {}
  Future<void> resizePip(ResizeEdge edge) async {}
  Future<bool> queryPip();
  Future<void> finish();
  Future<bool> openExternalPlayer({
    required String url,
    required String title,
    required Duration position,
  }) async => false;
}

class NativePlaybackDevice extends PlaybackDevice {
  NativePlaybackDevice({
    TargetPlatform? targetPlatform,
    WindowsExternalPlayer? windowsExternalPlayer,
  }) : _platform = targetPlatform ?? defaultTargetPlatform,
       _windowsPlayer = windowsExternalPlayer ?? WindowsExternalPlayer();
  final WindowsExternalPlayer _windowsPlayer;
  final TargetPlatform _platform;
  bool get _android => _platform == TargetPlatform.android;
  bool get _windows => _platform == TargetPlatform.windows;
  @override
  bool get supportsOrientation => _android;
  @override
  bool get supportsExternalPlayer => _android || _windows;
  @override
  WindowsExternalPlayer? get windowsExternalPlayer =>
      _windows ? _windowsPlayer : null;
  static const _channel = MethodChannel('com.asterlink.app/playback');
  static const _nativeChannel = MethodChannel('com.asterlink.app/native');
  static NativePlaybackDevice? _handlerOwner;
  final String _session = newId();
  final _actions = StreamController<String>.broadcast();
  final _windowsPip = WindowsPipWindow();
  bool _supportsPip = false, _inPip = false, _closed = false, _started = false;
  bool _fullscreen = false, _previousWindowsFullscreen = false;
  bool _video = false;
  double _brightness = .5;
  String _lastUpdate = '';
  @override
  bool get supportsPip => _supportsPip;
  @override
  bool get supportsDesktopPip => _windows && _supportsPip;
  @override
  bool get supportsBrightness => _android;
  @override
  bool get inPip => _windows ? _windowsPip.active : _inPip;
  @override
  double get brightness => _brightness;
  @override
  Stream<String> get actions => _actions.stream;
  Future<T?> _invoke<T>(String name, [Json arguments = const {}]) =>
      _channel.invokeMethod<T>(name, {'session': _session, ...arguments});
  @override
  Future<void> start({required bool video}) async {
    if (_closed || _started) return;
    _started = true;
    _video = video;
    if (_android) {
      _handlerOwner = this;
      _channel.setMethodCallHandler((call) async {
        final args = asJson(call.arguments);
        if (_closed || args.str('session') != _session) return;
        if (call.method == 'pip') {
          _inPip = args.boolean('active');
          notifyListeners();
        } else if (call.method == 'action') {
          _actions.add(args.str('action'));
        }
      });
      final values = asJson(await _invoke<Object?>('begin', {'video': video}));
      if (_closed) return;
      _supportsPip = values.boolean('pip');
      _brightness = values.number('brightness', .5).clamp(.05, 1).toDouble();
    } else if (_windows) {
      _previousWindowsFullscreen = await windowManager.isFullScreen();
      _supportsPip = video;
    }
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> update({
    required bool playing,
    int? width,
    int? height,
    bool autoRotate = true,
    PlaybackOrientation? orientation,
    bool locked = false,
    bool controlsVisible = true,
  }) async {
    if (_closed || !_started) return;
    if (_windows) {
      _windowsPip.videoSize(width, height);
      return;
    }
    if (!_android) return;
    final targetOrientation = _video && orientation != null
        ? orientation
        : playbackOrientation(
            video: _video,
            automatic: autoRotate,
            width: width,
            height: height,
          );
    final signature =
        '$playing/$width/$height/${targetOrientation?.name}/$locked/$controlsVisible';
    if (_lastUpdate == signature) return;
    _lastUpdate = signature;
    try {
      await _invoke<void>('state', {
        'playing': playing,
        'width': width,
        'height': height,
        'orientation': targetOrientation?.name,
        'locked': locked,
        'controlsVisible': controlsVisible,
      });
    } catch (_) {
      _lastUpdate = '';
    }
  }

  @override
  Future<void> setBrightness(double value) async {
    if (_closed || !supportsBrightness) return;
    _brightness = value.clamp(.05, 1).toDouble();
    await _invoke<void>('brightness', {'value': _brightness});
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> fullscreen(bool enabled) async {
    if (_closed) return;
    if (_android) {
      await _invoke<void>('fullscreen', {'enabled': enabled});
    } else if (_windows) {
      await exitPip();
      await windowManager.setFullScreen(
        enabled ? true : _previousWindowsFullscreen,
      );
    }
    _fullscreen = enabled;
  }

  @override
  Future<bool> enterPip() async {
    if (_closed || !supportsPip) return false;
    final entered = _windows
        ? await _windowsPip.enter()
        : await _invoke<bool>('enterPip') ?? false;
    if (_closed) return false;
    if (entered) {
      _inPip = true;
      notifyListeners();
    }
    return entered;
  }

  @override
  Future<void> exitPip() async {
    if (_closed || !_windows) return;
    await _windowsPip.exit();
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> dragPip() => _windowsPip.drag();

  @override
  Future<void> resizePip(ResizeEdge edge) => _windowsPip.resize(edge);

  @override
  Future<bool> queryPip() async {
    if (!_closed && _windows) {
      return _windowsPip.active &&
          await windowManager.isVisible() &&
          !await windowManager.isMinimized();
    }
    if (_closed || !_android) return false;
    return await _invoke<bool>('isPip') ?? false;
  }

  @override
  Future<void> finish() async {
    if (_closed) return;
    _closed = true;
    try {
      if (_android) {
        await _nativeChannel.invokeMethod<void>('cancelExternalPlayer', {
          'session': _session,
        });
      }
      if (_android && _started) await _invoke<void>('end');
      if (_windows) await _windowsPip.exit();
      if (_windows && _fullscreen) {
        await windowManager.setFullScreen(_previousWindowsFullscreen);
      }
    } finally {
      if (identical(_handlerOwner, this)) {
        _channel.setMethodCallHandler(null);
        _handlerOwner = null;
      }
      await _actions.close();
      super.dispose();
    }
  }

  @override
  Future<bool> openExternalPlayer({
    required String url,
    required String title,
    required Duration position,
  }) async {
    require(supportsExternalPlayer && !_closed, '当前设备不支持选择第三方播放器');
    if (_windows) return _windowsPlayer.open(url);
    try {
      return await _nativeChannel.invokeMethod<bool>('openExternalPlayer', {
            'session': _session,
            'url': url,
            'title': title,
            'positionMs': position.inMilliseconds,
          }) ??
          false;
    } on PlatformException catch (error) {
      throw AppException(error.message ?? '无法打开第三方播放器，请重试');
    }
  }
}
