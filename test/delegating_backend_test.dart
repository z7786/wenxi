import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/playback/delegating_backend.dart';
import 'player_support.dart';

class _VideoMonitoringBackend extends FakePlaybackBackend {
  _VideoMonitoringBackend(super.name, super.events);
  final videoMonitoringCalls = <bool>[];
  @override
  void setVideoMonitoringEnabled(bool enabled) {
    videoMonitoringCalls.add(enabled);
  }
}

void main() {
  test(
    'DelegatingPlaybackBackend forwards setVideoMonitoringEnabled to delegate',
    () async {
      final delegate = _VideoMonitoringBackend('inner', []);
      final wrapper = DelegatingPlaybackBackend(delegate);
      wrapper.setVideoMonitoringEnabled(false);
      wrapper.setVideoMonitoringEnabled(true);
      expect(delegate.videoMonitoringCalls, [false, true]);
      await wrapper.close();
    },
  );
}
