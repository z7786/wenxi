import 'package:flutter/widgets.dart';
import 'playback_state.dart';

/// A system PiP session can own playback without recreating the ordinary decoder.
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
