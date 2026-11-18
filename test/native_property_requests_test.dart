import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
// Exercise the fallback used on platforms that restrict executable memory.
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/initializer_isolate.dart';
// ignore: implementation_imports
import 'package:media_kit/src/player/native/core/native_disposal.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = File(
    Platform.environment['ASTERLINK_MPV_LIBRARY'] ??
        '.local/player-test/libmpv/libmpv-2.dll',
  );
  group('Native property replies', () {
    late Player player;
    late NativePlayer native;
    setUpAll(() => MediaKit.ensureInitialized(libmpv: library.path));
    setUp(() async {
      player = Player(configuration: const PlayerConfiguration(vo: 'null'));
      native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
    });
    tearDown(() async {
      if (!native.disposed) await player.dispose();
    });

    test(
      'Concurrent reads retain their matching reply and missing values',
      () async {
        await native.setProperty('speed', '1.5');
        await native.setProperty('volume', '37');
        final values = await Future.wait([
          native.getProperty('speed'),
          native.getProperty('volume'),
          native.getProperty('not-a-real-optional-property'),
          native.getProperty('pause'),
        ]);
        expect(double.parse(values[0]), 1.5);
        expect(double.parse(values[1]), 37);
        expect(values[2], '');
        expect(values[3], 'yes');
      },
    );

    test(
      'Observation callbacks can await property replies while playback advances',
      () async {
        final replies = <(String, String)>[];
        await native.observeProperty('speed', (value) async {
          replies.add((value, await native.getProperty('volume')));
        });
        await until(() => replies.isNotEmpty);
        await native.setProperty('speed', '1.75');
        await until(() => replies.any((entry) => entry.$1 == '1.750000'));
        expect(replies.every((entry) => entry.$2.isNotEmpty), isTrue);
        await native.unobserveProperty('speed');
        await player.open(
          Media(File('test/fixtures/player-sample.mkv').absolute.path),
        );
        await until(() => player.state.position.inMilliseconds >= 200);
        await native.setProperty('not-a-real-optional-property', '1');
        await expectLater(
          native.setProperty('speed', 'not-a-number'),
          throwsA(isA<StateError>()),
        );
        expect(native.pendingNativeRequests, 0);
        await native.setProperty('speed', '2');
        expect(double.parse(await native.getProperty('speed')), 2);
      },
    );

    test(
      'A held native event cannot freeze timers; late replies remain safe',
      () async {
        // Hold a real mpv on_load event. Replies queue behind the event
        // handler, without blocking Dart's timers or input processing.
        await native.setProperty('vid', 'auto');
        final entered = Completer<void>();
        final release = Completer<void>();
        Future<void> hook() async {
          entered.complete();
          await release.future;
        }

        native.onLoadHooks.add(hook);
        final loading = native.command([
          'loadfile',
          File('test/fixtures/player-sample.mkv').absolute.path,
          'replace',
        ]);
        try {
          await entered.future.timeout(const Duration(seconds: 3));
          final delayed = native.getProperty(
            'video-format',
            timeout: const Duration(milliseconds: 80),
          );
          await expectLater(delayed, throwsA(isA<TimeoutException>()));
          var ticks = 0;
          final timer = Timer.periodic(
            const Duration(milliseconds: 10),
            (_) => ticks++,
          );
          try {
            // The request timed out, but its native reply still arrives later.
            await Future<void>.delayed(const Duration(milliseconds: 150));
            expect(ticks, greaterThanOrEqualTo(5));
          } finally {
            timer.cancel();
          }
          var writeCompleted = false;
          final writing = native.setProperty('volume', '46').then((_) {
            writeCompleted = true;
          });
          await Future<void>.delayed(const Duration(milliseconds: 40));
          expect(writeCompleted, isFalse);
          release.complete();
          await loading;
          await writing;
          await until(() => player.state.duration > Duration.zero);
          expect(await native.getProperty('path'), isNotEmpty);
          expect(await native.getProperty('video-format'), isNotEmpty);
          expect(double.parse(await native.getProperty('volume')), 46);
        } finally {
          if (!release.isCompleted) release.complete();
          native.onLoadHooks.remove(hook);
          await loading;
        }
      },
    );

    test(
      'Timed-out writes and commands clean up, and late replies cannot corrupt the next request',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        Future<void> hook() async {
          entered.complete();
          await release.future;
        }

        native.onLoadHooks.add(hook);
        final loading = native.command([
          'loadfile',
          File('test/fixtures/player-sample.mkv').absolute.path,
          'replace',
        ]);
        try {
          await entered.future.timeout(const Duration(seconds: 3));
          final pending = native.pendingNativeRequests;
          await expectLater(
            native.setProperty(
              'volume',
              '41',
              timeout: const Duration(milliseconds: 60),
            ),
            throwsA(isA<TimeoutException>()),
          );
          await expectLater(
            native.command([
              'set',
              'speed',
              '1.25',
            ], timeout: const Duration(milliseconds: 60)),
            throwsA(isA<TimeoutException>()),
          );
          expect(native.pendingNativeRequests, pending);
          release.complete();
          await loading;
          await native.setProperty('volume', '63');
          await native.command(['set', 'speed', '1.75']);
          expect(double.parse(await native.getProperty('volume')), 63);
          expect(double.parse(await native.getProperty('speed')), 1.75);
          expect(native.pendingNativeRequests, 0);
          for (var i = 0; i < 20; i++) {
            await native.command(['not-a-real-command']);
          }
          expect(native.pendingNativeRequests, 0);
          await native.command(['set', 'speed', '1']);
          expect(double.parse(await native.getProperty('speed')), 1);
        } finally {
          if (!release.isCompleted) release.complete();
          native.onLoadHooks.remove(hook);
          await loading;
        }
      },
    );

    test(
      'Native destruction waits off the UI isolate for other clients',
      () async {
        final name = 'teardown-test'.toNativeUtf8();
        final client = native.mpv.mpv_create_client(native.ctx, name.cast());
        calloc.free(name);
        expect(client, isNot(nullptr));
        var destroyed = false;
        var clientReleased = false;
        try {
          await player.dispose();
          unawaited(native.nativeDisposed.then((_) => destroyed = true));
          // The extra client keeps terminate_destroy blocked until we release it.
          await until(
            () =>
                native.mpv.mpv_wait_event(client, 0).ref.event_id ==
                generated.mpv_event_id.MPV_EVENT_SHUTDOWN,
            timeout: const Duration(seconds: 10),
          );
          var ticks = 0;
          final timer = Timer.periodic(
            const Duration(milliseconds: 10),
            (_) => ticks++,
          );
          await Future<void>.delayed(const Duration(milliseconds: 120));
          timer.cancel();
          expect(ticks, greaterThanOrEqualTo(5));
          expect(destroyed, isFalse);
          native.mpv.mpv_destroy(client);
          clientReleased = true;
          await native.nativeDisposed.timeout(const Duration(seconds: 5));
          expect(destroyed, isTrue);
        } finally {
          if (!clientReleased) native.mpv.mpv_destroy(client);
        }
      },
    );

    test(
      'Isolate event pump waits for an in-flight callback before detaching',
      () async {
        final initializer = InitializerIsolate();
        final entered = Completer<void>(), release = Completer<void>();
        final ctx = await initializer.create((event) async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
            // This event is still owned by the worker while the callback awaits.
            expect(
              event.ref.event_id,
              isNot(generated.mpv_event_id.MPV_EVENT_NONE),
            );
          }
        }, options: const {'vo': 'null', 'ao': 'null', 'idle': 'yes'});
        var detached = false;
        Future<void>? stopping;
        try {
          await entered.future.timeout(const Duration(seconds: 3));
          stopping = initializer
              .dispose(native.mpv, ctx)
              .then((_) => detached = true);
          await Future<void>.delayed(const Duration(milliseconds: 120));
          expect(detached, isFalse);
          release.complete();
          await stopping.timeout(const Duration(seconds: 3));
          expect(detached, isTrue);
        } finally {
          if (!release.isCompleted) release.complete();
          await (stopping ?? initializer.dispose(native.mpv, ctx));
          await destroyNativePlayer(library.path, ctx.address);
        }
      },
    );

    test(
      'A delayed stop retains the output until its real reply arrives',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        Future<void> hook() async {
          entered.complete();
          await release.future;
        }

        native.onLoadHooks.add(hook);
        var outputReleased = false;
        native.release.add(() async => outputReleased = true);
        final loading = native
            .command([
              'loadfile',
              File('test/fixtures/player-sample.mkv').absolute.path,
              'replace',
            ])
            .catchError((Object error) {
              if (error is! TimeoutException) throw error;
            });
        try {
          await entered.future.timeout(const Duration(seconds: 3));
          await expectLater(player.dispose(), throwsA(isA<TimeoutException>()));
          expect(outputReleased, isFalse);
          expect(native.disposed, isFalse);
          release.complete();
          await loading;
          // The original cleanup continues rather than freeing the active output
          // at its deadline or starting a second stop/dispose operation.
          await player.dispose();
          expect(outputReleased, isTrue);
          expect(native.pendingNativeRequests, 0);
          await native.nativeDisposed.timeout(const Duration(seconds: 8));
        } finally {
          if (!release.isCompleted) release.complete();
          native.onLoadHooks.remove(hook);
          await loading;
        }
      },
    );

    test(
      'Reads racing disposal complete and disposed handles reject new reads',
      () async {
        final requests = List.generate(32, (_) => native.getProperty('volume'));
        final closing = player.dispose();
        final values = await Future.wait(requests);
        await closing;
        expect(values, hasLength(32));
        await expectLater(
          native.getProperty('volume'),
          throwsA(isA<AssertionError>()),
        );
      },
    );
  }, skip: !Platform.isWindows || !library.existsSync());
}
