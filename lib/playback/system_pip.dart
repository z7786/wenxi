import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import '../core/json.dart';
import '../domain/models.dart' show newId;
import 'playback_state.dart';

/// The ordinary decoder remains available while an Apple system PiP session
/// owns the video. Only that session sends playback commands to AVKit.
abstract class SystemPipPlayback extends ChangeNotifier {
  PlayerState get state;
  bool get finished;
  bool get restoreRequested;
  String get failureMessage => '';
  Object get surfaceKey => this;
  Widget? buildVideo({required BoxFit fit});
  Future<bool> prepare({
    required String url,
    required String title,
    required PlayerState initialState,
  });
  Future<PlayerState> stop();
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double value);
}

class IOSSystemPipPlayback extends SystemPipPlayback {
  IOSSystemPipPlayback(this.session, this.invoke);
  final String session;
  final Future<Object?> Function(String method, Json arguments) invoke;
  PlayerState _state = const PlayerState();
  bool _finished = false, _restoreRequested = false;
  String _pipId = '';
  String _failureCode = '';
  bool _acceptUpdates = false;
  bool _disposed = false;
  bool _surfaceAttached = false,
      _readyForDisplay = false,
      _statusBarHidden = false;
  int _revision = 0;
  Future<PlayerState>? _stopping;
  String get pipId => _pipId;
  bool get surfaceAttached => _surfaceAttached;
  bool get readyForDisplay => _readyForDisplay;
  bool get statusBarHidden => _statusBarHidden;
  @override
  String get failureMessage => switch (_failureCode) {
    'item_failed' => '系统画中画无法读取此视频，已恢复内置播放',
    'prepare_timeout' => '系统画中画未能准备好视频，已恢复内置播放',
    'enter_timeout' || 'enter_failed' => '系统画中画未能启动，已恢复内置播放',
    _ => '',
  };
  @override
  PlayerState get state => _state;
  @override
  bool get finished => _finished;
  @override
  bool get restoreRequested => _restoreRequested;
  @override
  Object get surfaceKey => _pipId;

  bool accepts(Json values) =>
      _acceptUpdates && _pipId.isNotEmpty && values.str('pipId') == _pipId;

  void update(Json values, {bool response = false}) {
    if (_disposed) return;
    if (values.str('pipId') != _pipId) return;
    if (!response && !accepts(values)) return;
    _surfaceAttached = values.boolean('surfaceAttached', _surfaceAttached);
    _readyForDisplay = values.boolean('readyForDisplay', _readyForDisplay);
    _statusBarHidden = values.boolean('statusBarHidden', _statusBarHidden);
    _failureCode = values.str('failureCode', _failureCode);
    final position = values.number(
      'positionMs',
      _state.position.inMilliseconds.toDouble(),
    );
    final duration = values.number(
      'durationMs',
      _state.duration.inMilliseconds.toDouble(),
    );
    final rate = values.number('rate', _state.rate);
    _state = _state.copyWith(
      position: position.isFinite
          ? Duration(milliseconds: position.clamp(0, 1e12).round())
          : _state.position,
      duration: duration.isFinite && duration > 0
          ? Duration(milliseconds: duration.clamp(0, 1e12).round())
          : _state.duration,
      playing: values.boolean('playing'),
      buffering: values.boolean('buffering'),
      completed: values.boolean('completed'),
      rate: rate.isFinite && rate > 0 ? rate.clamp(.25, 5) : _state.rate,
    );
    _finished = values.boolean('finished');
    _restoreRequested = values.boolean('restore');
    notifyListeners();
  }

  @override
  Widget? buildVideo({required BoxFit fit}) => !_acceptUpdates
      ? null
      : UiKitView(
          key: ValueKey('ios-system-pip-$session-$_pipId'),
          viewType: 'com.asterlink.app/pip_video',
          creationParams: {'session': session, 'pipId': _pipId},
          creationParamsCodec: const StandardMessageCodec(),
          layoutDirection: TextDirection.ltr,
        );

  @override
  Future<bool> prepare({
    required String url,
    required String title,
    required PlayerState initialState,
  }) async {
    if (_disposed) return false;
    final revision = ++_revision;
    await _stopping;
    if (_disposed || revision != _revision) return false;
    _stopping = null;
    _state = initialState;
    _finished = false;
    _restoreRequested = false;
    _surfaceAttached = false;
    _readyForDisplay = false;
    _statusBarHidden = false;
    _failureCode = '';
    _pipId = newId();
    _acceptUpdates = true;
    notifyListeners();
    final prepared = await invoke('preparePip', {
      'pipId': _pipId,
      'url': url,
      'title': title,
      'positionMs': initialState.position.inMilliseconds,
      'playing': initialState.playing,
      'rate': initialState.rate,
    });
    return prepared == true && !_disposed && revision == _revision;
  }

  @override
  Future<PlayerState> stop() => _stopping ??= () async {
    _revision++;
    final id = _pipId;
    try {
      final values = asJson(await invoke('stopPip', {'pipId': id}));
      if (id == _pipId) update(values, response: true);
      return state;
    } finally {
      if (id == _pipId) {
        _acceptUpdates = false;
        if (!_disposed) notifyListeners();
      }
    }
  }();

  @override
  Future<void> play() => _command('pipPlay');

  @override
  Future<void> pause() => _command('pipPause');

  @override
  Future<void> seek(Duration position) =>
      _command('pipSeek', {'positionMs': position.inMilliseconds});

  @override
  Future<void> setRate(double value) => _command('pipRate', {'rate': value});

  Future<void> _command(String method, [Json arguments = const {}]) async {
    if (_disposed || _stopping != null) return;
    final id = _pipId;
    final values = asJson(await invoke(method, {'pipId': id, ...arguments}));
    if (_acceptUpdates && id == _pipId) update(values, response: true);
  }

  @override
  void dispose() {
    _disposed = true;
    _acceptUpdates = false;
    super.dispose();
  }
}
