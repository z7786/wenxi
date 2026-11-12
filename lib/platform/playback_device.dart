import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';
import '../core/json.dart';
import '../domain/models.dart';
import '../domain/playback.dart';
import '../playback/system_pip.dart';
import 'windows_pip.dart';
import 'windows_external_player.dart';
import 'macos_external_player.dart';

abstract class PlaybackDevice extends ChangeNotifier {
  bool get isTelevision => false;
  bool get supportsOrientation => false;

  /// Safe bounds independent of system bar visibility for the current viewport.
  EdgeInsets? systemInsetsFor(MediaQueryData media) => null;
  bool get supportsPip;
  bool get supportsDesktopPip => false;
  bool get supportsIndependentPlayerWindows => false;
  bool get supportsExternalPlayer => false;
  bool get externalPlayerNeedsDirectLink => false;
  SystemPipPlayback? get systemPip => null;
  WindowsExternalPlayer? get windowsExternalPlayer => null;
  bool get supportsBrightness;
  bool get supportsSystemVolume => false;
  bool get inPip;
  double get brightness;
  double get systemVolume => 100;
  Stream<String> get actions;
  Future<void> start({required bool video});
  Future<void> update({
    required bool playing,
    int? width,
    int? height,
    double? frameRate,
    bool autoRotate = true,
    PlaybackOrientation? orientation,
    bool locked = false,
    bool controlsVisible = true,
  });
  Future<void> setBrightness(double value);
  Future<double> setSystemVolume(double value) async => systemVolume;
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

class NativePlaybackDevice extends PlaybackDevice with WidgetsBindingObserver {
  NativePlaybackDevice({
    TargetPlatform? targetPlatform,
    WindowsExternalPlayer? windowsExternalPlayer,
  }) : _platform = targetPlatform ?? defaultTargetPlatform,
       _windowsPlayer = windowsExternalPlayer ?? WindowsExternalPlayer();
  final WindowsExternalPlayer _windowsPlayer;
  final _macosPlayer = MacOSExternalPlayer();
  final TargetPlatform _platform;
  bool get _android => _platform == TargetPlatform.android;
  bool get _ios => _platform == TargetPlatform.iOS;
  bool get _mobile => _android || _ios;
  bool get _windows => _platform == TargetPlatform.windows;
  bool get _macos => _platform == TargetPlatform.macOS;
  bool get _desktop => _windows || _macos;
  @override
  bool get supportsOrientation => _mobile && !isTelevision;
  @override
  bool get supportsExternalPlayer => _mobile || _desktop;
  @override
  bool get externalPlayerNeedsDirectLink => _ios;
  @override
  WindowsExternalPlayer? get windowsExternalPlayer => _windows
      ? _windowsPlayer
      : _macos
      ? _macosPlayer
      : null;
  static const _channel = MethodChannel('com.asterlink.app/playback');
  static const _nativeChannel = MethodChannel('com.asterlink.app/native');
  static NativePlaybackDevice? _handlerOwner;
  final String _session = newId();
  final _actions = StreamController<String>.broadcast();
  final _windowsPip = WindowsPipWindow();
  bool _supportsPip = false, _inPip = false, _closed = false, _started = false;
  bool _isTelevision = false;
  @override
  bool get isTelevision => _isTelevision;
  bool _fullscreen = false, _previousWindowsFullscreen = false;
  bool _video = false;
  bool? _iosUiHidden;
  PlaybackOrientation? _iosOrientation;
  double _brightness = .5;
  double _systemVolume = 100;
  bool _supportsSystemVolume = false;
  Size? _systemInsetsSize;
  EdgeInsets? _systemInsets;
  int _systemInsetsRevision = 0;
  final _volumeGate = AsyncGate();
  String _lastUpdate = '';
  @override
  bool get supportsPip => _supportsPip;
  @override
  bool get supportsDesktopPip => _windows && _supportsPip;
  @override
  bool get supportsIndependentPlayerWindows => _desktop;
  @override
  bool get supportsBrightness => _mobile && !isTelevision;
  @override
  bool get supportsSystemVolume => _mobile && _supportsSystemVolume;
  @override
  bool get inPip => _windows ? _windowsPip.active : _android && _inPip;
  @override
  double get brightness => _brightness;
  @override
  double get systemVolume => _systemVolume;
  @override
  Stream<String> get actions => _actions.stream;
  @override
  EdgeInsets? systemInsetsFor(MediaQueryData media) {
    final size = _systemInsetsSize;
    if (!_android ||
        size == null ||
        (size.width - media.size.width).abs() > 1 ||
        (size.height - media.size.height).abs() > 1) {
      return null;
    }
    return _systemInsets;
  }

  Future<T?> _invoke<T>(String name, [Json arguments = const {}]) =>
      _channel.invokeMethod<T>(name, {'session': _session, ...arguments});
  @override
  Future<void> start({required bool video}) async {
    if (_closed || _started) return;
    _started = true;
    _video = video;
    if (_mobile) {
      _handlerOwner = this;
      _channel.setMethodCallHandler((call) async {
        final args = asJson(call.arguments);
        if (_closed || args.str('session') != _session) return;
        if (_android && call.method == 'pip') {
          _inPip = args.boolean('active');
          notifyListeners();
        } else if (call.method == 'action') {
          _actions.add(args.str('action'));
        } else if (call.method == 'volume') {
          _readSystemVolume(args);
        }
      });
      final values = asJson(await _invoke<Object?>('begin', {'video': video}));
      if (_closed) return;
      _isTelevision = _android && values.boolean('television');
      if (identical(_handlerOwner, this)) {
        WidgetsBinding.instance.addObserver(this);
        if (_ios) await _syncIosSystemUi();
      }
      _supportsPip = _android && values.boolean('pip');
      _brightness = values.number('brightness', .5).clamp(0, 1).toDouble();
      _readSystemInsets(values);
      _readSystemVolume(values);
    } else if (_desktop) {
      _previousWindowsFullscreen = await windowManager.isFullScreen();
      _supportsPip = _windows && video;
    }
    if (!_closed) notifyListeners();
  }

  void _readSystemInsets(Json values) {
    if (!_android || _closed) return;
    final bounds = values.obj('systemInsets');
    final width = bounds.number('width', double.nan);
    final height = bounds.number('height', double.nan);
    final sides = [
      for (final side in ['left', 'top', 'right', 'bottom'])
        bounds.number(side, double.nan),
    ];
    if (!width.isFinite ||
        !height.isFinite ||
        width <= 0 ||
        height <= 0 ||
        sides.any((value) => !value.isFinite || value < 0) ||
        sides[0] + sides[2] >= width ||
        sides[1] + sides[3] >= height) {
      return;
    }
    final size = Size(width, height);
    final insets = EdgeInsets.fromLTRB(sides[0], sides[1], sides[2], sides[3]);
    if (size == _systemInsetsSize && insets == _systemInsets) return;
    _systemInsetsSize = size;
    _systemInsets = insets;
    notifyListeners();
  }

  Future<void> _refreshSystemInsets() async {
    if (!_android || _closed || !identical(_handlerOwner, this)) return;
    final revision = ++_systemInsetsRevision;
    try {
      final values = asJson(await _invoke<Object?>('systemInsets'));
      if (!_closed &&
          revision == _systemInsetsRevision &&
          identical(_handlerOwner, this)) {
        _readSystemInsets(values);
      }
    } catch (_) {
      // Keep the existing MediaQuery fallback on older native bridges.
    }
  }

  void _readSystemVolume(Json values) {
    final supported = values.boolean('systemVolumeSupported');
    final value = values.number('systemVolume', double.nan);
    if (!value.isFinite) return;
    final volume = value.clamp(0, 100).toDouble();
    if (_supportsSystemVolume == supported && _systemVolume == volume) return;
    _supportsSystemVolume = supported;
    _systemVolume = volume;
    if (!_closed) notifyListeners();
  }

  @override
  Future<double> setSystemVolume(double value) => _volumeGate.run(() async {
    if (_closed || !_started || !supportsSystemVolume) return _systemVolume;
    require(value.isFinite, '音量数值无效');
    final result = asJson(
      await _invoke<Object?>('volume', {'value': value.clamp(0, 100)}),
    );
    if (!_closed) _readSystemVolume(result);
    return _systemVolume;
  });

  @override
  Future<void> update({
    required bool playing,
    int? width,
    int? height,
    double? frameRate,
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
    if (!_mobile) return;
    final targetOrientation = isTelevision
        ? null
        : _video && orientation != null
        ? orientation
        : playbackOrientation(
            video: _video,
            automatic: autoRotate,
            width: width,
            height: height,
          );
    final cadence =
        _android &&
            _video &&
            playing &&
            frameRate != null &&
            frameRate.isFinite &&
            frameRate >= 1 &&
            frameRate <= 240
        ? (frameRate * 1000).round() / 1000.0
        : 0.0;
    final signature =
        '$playing/$width/$height/$cadence/${targetOrientation?.name}/$locked/$controlsVisible';
    if (_lastUpdate == signature) return;
    _lastUpdate = signature;
    try {
      if (_ios) {
        if (!identical(_handlerOwner, this)) return;
        if (targetOrientation != null && targetOrientation != _iosOrientation) {
          _iosOrientation = targetOrientation;
          await SystemChrome.setPreferredOrientations(
            targetOrientation == PlaybackOrientation.landscape
                ? [
                    DeviceOrientation.landscapeLeft,
                    DeviceOrientation.landscapeRight,
                  ]
                : targetOrientation == PlaybackOrientation.portrait
                ? [DeviceOrientation.portraitUp]
                : [],
          );
        }
        await _syncIosSystemUi();
        if (_closed || !identical(_handlerOwner, this)) return;
      }
      await _invoke<void>('state', {
        'playing': playing,
        'width': width,
        'height': height,
        if (_android) 'frameRate': cadence,
        'orientation': targetOrientation?.name,
        'locked': locked,
        'controlsVisible': controlsVisible,
      });
    } catch (_) {
      _lastUpdate = '';
      if (_ios) _iosOrientation = null;
    }
  }

  Future<void> _syncIosSystemUi({bool force = false}) async {
    if (!_ios || _closed || !identical(_handlerOwner, this)) return;
    final hidden = _video;
    if (!force && _iosUiHidden == hidden) return;
    _iosUiHidden = hidden;
    try {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: hidden ? [] : SystemUiOverlay.values,
      );
    } catch (_) {
      _iosUiHidden = null;
      rethrow;
    }
  }

  @override
  void didChangeMetrics() {
    if (_android) unawaited(_refreshSystemInsets());
    unawaited(_syncIosSystemUi().catchError((Object _) {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_android) unawaited(_refreshSystemInsets());
      unawaited(_syncIosSystemUi(force: true).catchError((Object _) {}));
    }
  }

  @override
  Future<void> setBrightness(double value) async {
    if (_closed || !supportsBrightness) return;
    _brightness = value.clamp(0, 1).toDouble();
    await _invoke<void>('brightness', {'value': _brightness});
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> fullscreen(bool enabled) async {
    if (_closed) return;
    if (_mobile) {
      _fullscreen = enabled;
      if (_ios) {
        await _syncIosSystemUi();
        if (_closed || !identical(_handlerOwner, this)) return;
      }
      await _invoke<void>('fullscreen', {'enabled': enabled});
    } else if (_desktop) {
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
    if (_closed) return;
    if (_windows) {
      await _windowsPip.exit();
    } else {
      return;
    }
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
    if (_mobile) WidgetsBinding.instance.removeObserver(this);
    try {
      if (_android) {
        await _nativeChannel.invokeMethod<void>('cancelExternalPlayer', {
          'session': _session,
        });
      }
      if (_mobile && _started) await _invoke<void>('end');
      if (_ios && identical(_handlerOwner, this)) {
        await SystemChrome.setPreferredOrientations([]);
        if (identical(_handlerOwner, this)) {
          await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        }
      }
      if (_windows) await _windowsPip.exit();
      if (_desktop && _fullscreen) {
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
    if (_macos) return _macosPlayer.open(url);
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
