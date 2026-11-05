import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'player_support.dart';
import 'support.dart';

void main() {
  late PlaybackFixture fixture;
  setUp(() => fixture = PlaybackFixture(renewable: true));
  tearDown(() => fixture.controller.close());

  test(
    'An explicitly paused download never auto-refreshes its playback source',
    () async {
      await fixture.controller.start();
      fixture.current
        ..failure = const PlaybackFailure('下载已暂停', PlaybackFailureKind.paused)
        ..fail();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(fixture.preparations, 1);
      expect(fixture.controller.loading, isFalse);
      expect(fixture.controller.error, contains('暂停'));
      expect(fixture.current.state.playing, isFalse);
    },
  );

  test(
    'An expired initial URL refreshes once and retains the saved position',
    () async {
      await fixture.history.save(
        fixture.entries.first.key,
        PlaybackBookmark(
          name: fixture.entries.first.name,
          position: const Duration(seconds: 83),
          duration: const Duration(minutes: 10),
          updatedAt: 1,
        ),
      );
      fixture.configureBackend = (backend) {
        if (fixture.backends.isEmpty) {
          backend
            ..failure = PlaybackFailure.http(403)
            ..failOpen = true;
        }
      };
      await fixture.controller.start();
      expect(fixture.controller.error, isEmpty);
      expect(fixture.preparations, 2);
      expect(fixture.backends, hasLength(2));
      expect(fixture.current.openedStart, const Duration(seconds: 83));
      expect(fixture.current.state.playing, isTrue);
      expect(fixture.backends.first.closed, isTrue);
      expect(fixture.leases[fixture.backends.first.openedSource!.url], 0);
      expect(
        fixture.events.indexOf('closed:0:0'),
        lessThan(fixture.events.indexOf('prepare:0:2')),
      );
    },
  );

  test(
    'A terminal network error refreshes once; a second error waits for manual retry',
    () async {
      await fixture.controller.start();
      fixture.current.emit(
        fixture.current.state.copyWith(position: const Duration(seconds: 95)),
      );
      fixture.current
        ..failure = PlaybackFailure.http(503)
        ..fail();
      await until(() => fixture.preparations == 2 && fixture.controller.ready);
      expect(fixture.current.openedStart, const Duration(seconds: 95));
      expect(fixture.controller.error, isEmpty);
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(fixture.preparations, 2);
      expect(fixture.controller.loading, isFalse);
      expect(fixture.controller.error, contains('失效'));
      expect(fixture.current.state.playing, isFalse);
      await fixture.controller.retry();
      expect(fixture.preparations, 3);
      expect(fixture.controller.error, isEmpty);
      expect(fixture.current.openedStart, const Duration(seconds: 95));
    },
  );

  test(
    'Repeated initialization failures do not loop or attempt software decoding',
    () async {
      fixture.configureBackend = (backend) => backend
        ..failure = PlaybackFailure.http(403)
        ..failOpen = true;
      await fixture.controller.start();
      expect(fixture.preparations, 2);
      expect(fixture.backends, hasLength(2));
      expect(
        fixture.backends.every((backend) => backend.hardwareAcceleration),
        isTrue,
      );
      expect(fixture.controller.loading, isFalse);
      expect(fixture.controller.error, contains('失效'));
    },
  );

  for (final background in [false, true]) {
    test(
      'Recovery respects ${background ? 'background' : 'manual pause'} state',
      () async {
        await fixture.controller.start();
        if (background) {
          await fixture.controller.background(pictureInPicture: false);
        } else {
          await fixture.controller.pause();
        }
        fixture.current
          ..failure = PlaybackFailure.http(503)
          ..fail();
        await until(
          () => fixture.preparations == 2 && fixture.controller.ready,
        );
        expect(fixture.current.plays, 0);
        expect(fixture.current.state.playing, isFalse);
        if (background) fixture.controller.foreground();
        await fixture.controller.play();
        expect(fixture.current.state.playing, isTrue);
      },
    );
  }

  test(
    'Switching episodes during refresh retires the late source without reopening it',
    () async {
      await fixture.controller.start();
      final gate = Completer<void>();
      fixture.prepareBarrier = (_, number) =>
          number == 2 ? gate.future : Future.value();
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      await until(() => fixture.preparations == 2);
      await fixture.controller.next();
      expect(fixture.controller.current.id, '1');
      gate.complete();
      await until(
        () => fixture.leases.values.where((count) => count == 0).length == 2,
      );
      expect(fixture.backends, hasLength(3));
      expect(fixture.backends[1].closed, isTrue);
      expect(fixture.backends[1].openedSource, isNull);
      expect(fixture.current.name, '1:2');
      expect(fixture.controller.current.id, '1');
      expect(fixture.leases.values.where((count) => count == 1), hasLength(1));
    },
  );

  test(
    'Closing during refresh releases its late lease and closes the unused warm backend',
    () async {
      await fixture.controller.start();
      final gate = Completer<void>();
      fixture.prepareBarrier = (_, _) => gate.future;
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      await until(() => fixture.preparations == 2);
      final closing = fixture.controller.close();
      gate.complete();
      await closing;
      expect(fixture.backends, hasLength(2));
      expect(fixture.backends.last.closed, isTrue);
      expect(fixture.backends.last.openedSource, isNull);
      expect(fixture.leases.values, everyElement(0));
    },
  );

  test(
    'A pause requested while the new URL is resolving prevents recovery autoplay',
    () async {
      await fixture.controller.start();
      final gate = Completer<void>();
      fixture.prepareBarrier = (_, _) => gate.future;
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      await until(() => fixture.preparations == 2);
      await fixture.controller.pause();
      gate.complete();
      await until(() => fixture.controller.ready);
      expect(fixture.current.plays, 0);
      expect(fixture.current.state.playing, isFalse);
    },
  );

  test(
    'Adding a download after a source failure reacquires a usable URL',
    () async {
      await fixture.controller.start();
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      await until(() => fixture.preparations == 2 && fixture.controller.ready);
      final failed = fixture.current.openedSource!;
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      final download = await fixture.controller.acquireForDownload();
      expect(fixture.preparations, 3);
      expect(download.url, isNot(failed.url));
      expect(fixture.leases[failed.url], 1);
      await fixture.controller.release(download);
      expect(fixture.leases[download.url], 0);
    },
  );

  test(
    'Changing accounts while refreshing rejects the new source and releases its lease',
    () async {
      await fixture.controller.start();
      final gate = Completer<void>();
      fixture.prepareBarrier = (_, _) => gate.future;
      fixture.current
        ..failure = PlaybackFailure.http(403)
        ..fail();
      await until(() => fixture.preparations == 2);
      fixture.accountValid = false;
      gate.complete();
      await until(() => !fixture.controller.loading);
      expect(fixture.controller.error, contains('账号已变化'));
      expect(fixture.backends, hasLength(2));
      await until(() => fixture.backends.last.closed);
      expect(fixture.backends.last.openedSource, isNull);
      expect(fixture.leases.values, everyElement(0));
    },
  );

  for (final failure in [
    PlaybackFailure.http(404)!,
    const PlaybackFailure('视频内容已变化', PlaybackFailureKind.changed),
    const PlaybackFailure('视频解码失败', PlaybackFailureKind.decoder),
  ]) {
    test(
      '${failure.kind.name} during playback does not trigger a network refresh',
      () async {
        await fixture.controller.start();
        fixture.current
          ..failure = failure
          ..fail();
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(fixture.preparations, 1);
        expect(fixture.controller.error, failure.message);
        expect(fixture.current.state.playing, isFalse);
      },
    );
  }

  test(
    'A released decoder saves its last progress and waits for an explicit decoder choice',
    () async {
      await fixture.controller.start();
      final backend = fixture.current;
      const position = Duration(seconds: 395);
      backend.emit(backend.state.copyWith(position: position));
      backend
        ..failure = PlaybackFailure.fromLog(
          'hevc_mediacodec: Failed to dequeue output buffer (status=-542398533)',
        )
        ..fail();
      await until(
        () =>
            fixture.history.bookmark(fixture.entries.first.key)?.position ==
            position,
      );
      expect(fixture.preparations, 1);
      expect(backend.state.playing, isFalse);
      expect(fixture.controller.error, contains('硬件解码器'));
      expect(fixture.controller.preferences.hardwareAcceleration, isTrue);
      expect(fixture.leases[backend.openedSource!.url], 1);
      await fixture.controller.setHardwareAcceleration(false);
      expect(backend.closed, isTrue);
      expect(fixture.current.hardwareAcceleration, isFalse);
      expect(fixture.current.openedStart, position);
      expect(fixture.controller.error, isEmpty);
      expect(fixture.leases[backend.openedSource!.url], 0);
    },
  );
}
