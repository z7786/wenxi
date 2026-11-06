import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/playback/system_pip.dart';
import 'player_support.dart';
import 'support.dart' show until;

class _Pip extends SystemPipPlayback {
  PlayerState value = const PlayerState();
  bool supported = true;
  Future<void>? prepareBarrier;
  bool failPrepare = false;
  int stops = 0;
  String url = '';
  @override
  PlayerState get state => value;
  @override
  bool finished = false;
  @override
  bool restoreRequested = false;
  @override
  Widget? buildVideo({required BoxFit fit}) => null;
  @override
  Future<bool> prepare({
    required String url,
    required String title,
    required PlayerState initialState,
  }) async {
    this.url = url;
    value = initialState;
    await prepareBarrier;
    if (failPrepare) throw const AppException('fixture system decoder error');
    notifyListeners();
    return supported;
  }

  @override
  Future<PlayerState> stop() async {
    stops++;
    return state;
  }

  void emit(PlayerState next) {
    value = next;
    notifyListeners();
  }

  @override
  Future<void> play() async => emit(value.copyWith(playing: true));
  @override
  Future<void> pause() async => emit(value.copyWith(playing: false));
  @override
  Future<void> seek(Duration position) async =>
      emit(value.copyWith(position: position));
  @override
  Future<void> setRate(double rate) async => emit(value.copyWith(rate: rate));
}

void main() {
  test(
    'system PiP owns audio and progress; returning resumes the original decoder at its final position',
    () async {
      final fixture = PlaybackFixture(count: 1);
      final controller = fixture.controller, pip = _Pip();
      addTearDown(controller.close);
      await controller.start();
      await controller.seek(const Duration(seconds: 123));
      expect(
        await controller.enterSystemPip(pip, () async {
          expect(fixture.current.state.playing, false);
          expect(fixture.leases.values.single, 2);
          return true;
        }),
        true,
      );
      expect(Uri.parse(pip.url).host, '127.0.0.1');
      expect(pip.url, isNot(contains('fixture-secret')));
      expect(controller.usingSystemPip, true);
      await controller.background(pictureInPicture: true);
      expect(pip.state.playing, true);
      await controller.seek(const Duration(seconds: 245));
      expect(pip.state.position, const Duration(seconds: 245));
      await controller.pause();
      expect(pip.state.playing, false);
      await controller.play();
      expect(fixture.current.state.playing, false);
      pip.emit(pip.state.copyWith(position: const Duration(seconds: 345)));
      await controller.saveProgress();
      expect(
        fixture.history.bookmark(controller.current.key)!.position,
        const Duration(seconds: 345),
      );
      controller.foreground();
      await controller.restoreSystemPip(resume: true);
      expect(controller.usingSystemPip, false);
      expect(controller.state.position, const Duration(seconds: 345));
      expect(controller.state.playing, true);
      expect(pip.stops, 1);
      expect(fixture.leases.values.single, 1);
    },
  );

  for (final originallyPlaying in [true, false]) {
    for (final failure in ['unsupported', 'enter', 'throw']) {
      test(
        'PiP $failure restores playing=$originallyPlaying and releases the handoff',
        () async {
          final fixture = PlaybackFixture(count: 1);
          final controller = fixture.controller;
          final pip = _Pip()
            ..supported = failure != 'unsupported'
            ..failPrepare = failure == 'throw';
          addTearDown(controller.close);
          await controller.start();
          await controller.seek(const Duration(seconds: 121));
          if (!originallyPlaying) await controller.pause();
          final entering = controller.enterSystemPip(pip, () async => false);
          if (failure == 'throw') {
            await expectLater(entering, throwsA(isA<AppException>()));
          } else {
            expect(await entering, false);
          }
          expect(controller.state.playing, originallyPlaying);
          expect(controller.state.position, const Duration(seconds: 121));
          expect(controller.usingSystemPip, false);
          expect(controller.preparingSystemPip, false);
          expect(fixture.leases.values.single, 1);
          expect(pip.stops, 1);
        },
      );
    }
  }

  test(
    'closing PiP saves progress and keeps the ordinary player paused',
    () async {
      final fixture = PlaybackFixture(count: 1);
      final controller = fixture.controller, pip = _Pip();
      addTearDown(controller.close);
      await controller.start();
      await controller.enterSystemPip(pip, () async => true);
      pip.finished = true;
      pip.restoreRequested = false;
      pip.emit(pip.state.copyWith(position: const Duration(seconds: 390)));
      await until(
        () =>
            !controller.usingSystemPip &&
            fixture.current.state.position.inSeconds == 390,
      );
      expect(controller.state.playing, false);
      await controller.saveProgress();
      expect(
        fixture.history.bookmark(controller.current.key)!.position.inSeconds,
        390,
      );
    },
  );

  test(
    'switching videos releases PiP and ignores late events from the old handoff',
    () async {
      final fixture = PlaybackFixture();
      final controller = fixture.controller, pip = _Pip();
      addTearDown(controller.close);
      await controller.start();
      final previous = controller.current.key;
      await controller.enterSystemPip(pip, () async => true);
      pip.emit(pip.state.copyWith(position: const Duration(seconds: 278)));
      await controller.next();
      expect(controller.usingSystemPip, false);
      expect(pip.stops, 1);
      expect(fixture.history.bookmark(previous)!.position.inSeconds, 278);
      pip.emit(pip.state.copyWith(position: const Duration(seconds: 500)));
      expect(controller.state.position, Duration.zero);
      expect(fixture.leases.values.where((value) => value > 0), [1]);
    },
  );

  test(
    'closing while AVKit prepares rejects the late result and releases each lease once',
    () async {
      final fixture = PlaybackFixture(count: 1);
      final controller = fixture.controller;
      final barrier = Completer<void>();
      final pip = _Pip()..prepareBarrier = barrier.future;
      await controller.start();
      final entering = controller.enterSystemPip(pip, () async => true);
      final checked = expectLater(entering, throwsA(isA<AppException>()));
      await until(() => pip.url.isNotEmpty);
      await controller.close();
      barrier.complete();
      await checked;
      expect(pip.stops, 1);
      expect(fixture.leases.values, everyElement(0));
    },
  );

  test(
    'closing PiP in the background saves the bookmark and defers mpv frame rendering until foreground',
    () async {
      final fixture = PlaybackFixture(count: 1);
      final controller = fixture.controller, pip = _Pip();
      addTearDown(controller.close);
      await controller.start();
      await controller.enterSystemPip(pip, () async => true);
      await controller.background(pictureInPicture: true);
      final seeks = fixture.current.seeks.length;
      pip.finished = true;
      pip.emit(pip.state.copyWith(position: const Duration(seconds: 287)));
      await until(
        () => !controller.usingSystemPip && fixture.leases.values.single == 1,
      );
      await controller.saveProgress();
      expect(fixture.current.seeks.length, seeks);
      expect(controller.state.position.inSeconds, 287);
      expect(controller.state.playing, false);
      expect(
        fixture.history.bookmark(controller.current.key)!.position.inSeconds,
        287,
      );
      controller.foreground();
      await until(() => fixture.current.state.position.inSeconds == 287);
      expect(controller.state.playing, false);
      await controller.play();
      expect(controller.state.position.inSeconds, 287);
      expect(controller.state.playing, true);
    },
  );
  test(
    'iOS external playback rejects protected and app-local streams before opening another app',
    () async {
      final fixture = PlaybackFixture(count: 1);
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      var opens = 0;
      await expectLater(
        controller.openExternalPlayer((_, _, _) async {
          opens++;
          return true;
        }, directLink: true),
        throwsA(isA<AppException>()),
      );
      expect(opens, 0);
      expect(controller.state.playing, true);
      expect(fixture.leases.values.single, 1);
    },
  );

  test(
    'iOS external playback opens a signed URL without an app-local proxy',
    () async {
      final factoryCalls = <String>[];
      final fixture = PlaybackFixture(
        count: 1,
        externalStreamFactory: (source) {
          factoryCalls.add(source.url);
          return ExternalPlaybackStream(source);
        },
      );
      final controller = fixture.controller;
      addTearDown(controller.close);
      await controller.start();
      final signed = DownloadSpec(
        url: 'https://cdn.example.invalid/movie.mp4?signature=fixture',
        fileName: controller.current.name,
      );
      // This fixture is deliberately public: no Cookie or Referer is required.
      final independent = PlaybackController(
        entries: fixture.entries,
        initialIndex: 0,
        history: fixture.history,
        prepare: (_, _) async => signed,
        retain: (_) {},
        release: (_) async {},
        backendFactory: (entry, _) => FakePlaybackBackend(entry.name, []),
      );
      addTearDown(independent.close);
      await independent.start();
      await independent.seek(const Duration(seconds: 43));
      expect(
        await independent.openExternalPlayer((url, title, position) async {
          expect(url, signed.url);
          expect(position.inSeconds, 43);
          expect(independent.state.playing, false);
          return true;
        }, directLink: true),
        true,
      );
      expect(independent.playingExternally, true);
      await independent.play();
      expect(independent.playingExternally, false);
    },
  );
}
