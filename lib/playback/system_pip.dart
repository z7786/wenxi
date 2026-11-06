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
  bool _acceptUpdates = false;
  bool _disposed = false;
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
    if (!response && !accepts(values)) return;
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
    _state = initialState;
    _finished = false;
    _restoreRequested = false;
    _pipId = newId();
    _acceptUpdates = true;
    notifyListeners();
    return await invoke('preparePip', {
          'pipId': _pipId,
          'url': url,
          'title': title,
          'positionMs': initialState.position.inMilliseconds,
          'playing': initialState.playing,
          'rate': initialState.rate,
        }) ==
        true;
  }

  @override
  Future<PlayerState> stop() async {
    _acceptUpdates = false;
    final values = asJson(await invoke('stopPip', {'pipId': _pipId}));
    if (values.str('pipId') == _pipId) update(values, response: true);
    return state;
  }

  @override
  Future<void> play() async {
    await invoke('pipPlay', {'pipId': _pipId});
  }

  @override
  Future<void> pause() async {
    await invoke('pipPause', {'pipId': _pipId});
  }

  @override
  Future<void> seek(Duration position) async {
    await invoke('pipSeek', {
      'pipId': _pipId,
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Future<void> setRate(double value) async {
    await invoke('pipRate', {'pipId': _pipId, 'rate': value});
  }

  @override
  void dispose() {
    _disposed = true;
    _acceptUpdates = false;
    super.dispose();
  }
}
