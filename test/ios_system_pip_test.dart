import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/playback/system_pip.dart';
import 'support.dart' show until;

void main() {
  test(
    'stop retains its surface and final updates until native PiP finishes, then permits another handoff',
    () async {
      final stopping = Completer<Object?>();
      final calls = <(String, Json)>[];
      final pip = IOSSystemPipPlayback('player-session', (method, args) async {
        calls.add((method, args));
        if (method == 'preparePip') return true;
        if (method == 'stopPip') return stopping.future;
        return null;
      });
      addTearDown(pip.dispose);
      await pip.prepare(
        url: 'file:///fixture.mp4',
        title: 'fixture',
        initialState: const PlayerState(playing: true),
      );
      final id = pip.pipId;
      final stop = pip.stop();
      expect(identical(stop, pip.stop()), isTrue);
      expect(pip.buildVideo(fit: BoxFit.contain), isNotNull);
      pip.update({'pipId': id, 'positionMs': 42000, 'playing': false});
      expect(pip.state.position.inSeconds, 42);
      final preparing = pip.prepare(
        url: 'file:///next.mp4',
        title: 'next',
        initialState: const PlayerState(),
      );
      expect(calls.where((call) => call.$1 == 'preparePip').length, 1);
      stopping.complete({'pipId': id, 'positionMs': 43000, 'playing': false});
      expect((await stop).position.inSeconds, 43);
      expect(await preparing, true);
      expect(pip.pipId, isNot(id));
      expect(pip.buildVideo(fit: BoxFit.contain), isNotNull);
      pip.update({
        'pipId': id,
        'finished': true,
        'playing': true,
        'positionMs': 99000,
      });
      expect(pip.state.position, Duration.zero);
      expect(pip.finished, isFalse);
      expect(calls.where((call) => call.$1 == 'stopPip').length, 1);
    },
  );
  test(
    'native controls update pause, play, seek and speed before returning to the caller',
    () async {
      final pip = IOSSystemPipPlayback('player-session', (method, args) async {
        if (method == 'preparePip') return true;
        return {
          'pipId': args.str('pipId'),
          'playing': method != 'pipPause',
          'positionMs': method == 'pipSeek' ? args.integer('positionMs') : 1000,
          'rate': args.number('rate', 1),
        };
      });
      addTearDown(pip.dispose);
      await pip.prepare(
        url: 'file:///fixture.mp4',
        title: 'fixture',
        initialState: const PlayerState(playing: true),
      );
      await pip.pause();
      expect(pip.state.playing, isFalse);
      await pip.play();
      expect(pip.state.playing, isTrue);
      await pip.seek(const Duration(seconds: 42));
      expect(pip.state.position.inSeconds, 42);
      await pip.setRate(1.5);
      expect(pip.state.rate, 1.5);
    },
  );
  test(
    'late preparation and control replies cannot update a new handoff',
    () async {
      final preparing = Completer<Object?>(), control = Completer<Object?>();
      Json previous = {};
      var prepares = 0;
      final pip = IOSSystemPipPlayback('player-session', (method, args) async {
        if (method == 'preparePip') {
          prepares++;
          return prepares == 1 ? preparing.future : true;
        }
        if (method == 'pipPause') {
          previous = args;
          return control.future;
        }
        return null;
      });
      addTearDown(pip.dispose);
      final first = pip.prepare(
        url: 'file:///one.mp4',
        title: 'one',
        initialState: const PlayerState(),
      );
      await until(() => prepares == 1);
      final previousId = pip.pipId;
      final pausing = pip.pause();
      await pip.stop();
      expect(pip.buildVideo(fit: BoxFit.contain), isNull);
      expect(
        await pip.prepare(
          url: 'file:///two.mp4',
          title: 'two',
          initialState: const PlayerState(playing: true),
        ),
        true,
      );
      preparing.complete(true);
      control.complete({
        'pipId': previous.str('pipId'),
        'playing': false,
        'finished': true,
      });
      expect(await first, isFalse);
      await pausing;
      expect(pip.pipId, isNot(previousId));
      expect(pip.state.playing, isTrue);
      expect(pip.finished, isFalse);
    },
  );
}
