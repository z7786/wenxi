import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'support.dart';

class _RealHttp extends HttpOverrides {}

class _QuietBackend extends MediaKitBackend {
  _QuietBackend() : super(video: false, hardwareAcceleration: false);
  Duration? openedStart;
  @override
  Future<void> open(DownloadSpec source, Duration start) async {
    openedStart = start;
    final native = player.platform as NativePlayer;
    await native.setProperty('ao', 'null');
    await native.setProperty('vo', 'null');
    await native.setProperty('vid', 'auto');
    await super.open(source, start);
  }
}

class _VideoOrigin {
  _VideoOrigin(this.bytes);
  final Uint8List bytes;
  late HttpServer server;
  Completer<void>? tail;
  int requests = 0;
  final pending = <Future<void>>[];
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) => pending.add(_serve(request)));
  }

  DownloadSpec source({
    bool truncated = false,
    bool knownSize = true,
  }) => DownloadSpec(
    url: 'http://127.0.0.1:${server.port}/${truncated ? 'short' : 'full'}.mkv',
    fileName: 'original-test-fixture.mkv',
    expectedSize: knownSize ? bytes.length : 0,
  );

  Future<void> _serve(HttpRequest request) async {
    requests++;
    try {
      request.response.headers.set('Content-Type', 'video/x-matroska');
      request.response.bufferOutput = false;
      if (request.uri.path == '/short.mkv') {
        request.response.contentLength = bytes.length ~/ 4;
        request.response.add(bytes.sublist(0, bytes.length ~/ 4));
      } else {
        final range = RegExp(
          r'bytes=(\d+)-(\d*)',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = int.tryParse(range?[1] ?? '') ?? 0;
        final end = math.min(
          bytes.length - 1,
          int.tryParse(range?[2] ?? '') ?? bytes.length - 1,
        );
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/${bytes.length}',
        );
        request.response.headers.set('ETag', '"same-fixture"');
        request.response.contentLength = end - start + 1;
        final firstEnd = tail == null
            ? end + 1
            : math.min(end + 1, math.max(start, bytes.length ~/ 2));
        request.response.add(bytes.sublist(start, firstEnd));
        await request.response.flush();
        if (firstEnd < end + 1) {
          await tail!.future;
          request.response.add(bytes.sublist(firstEnd, end + 1));
        }
      }
      await request.response.close();
    } catch (_) {
      // Native seeks, probe cancellation and teardown may abandon a response.
    }
  }

  Future<void> close() async {
    if (tail != null && !tail!.isCompleted) tail!.complete();
    await server.close(force: true);
    await Future.wait(pending);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
    'build/windows/x64/runner/Release/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;

  group(
    'Native HTTP playback continuity',
    () {
      late _VideoOrigin origin;
      late DiagnosticLog log;
      setUpAll(() => MediaKit.ensureInitialized(libmpv: library));
      setUp(() async {
        origin = _VideoOrigin(
          await File('test/fixtures/player-sample.mkv').readAsBytes(),
        );
        await origin.start();
        log = DiagnosticLog.open(null);
        DiagnosticLog.active = log;
      });
      tearDown(() async {
        await origin.close();
        DiagnosticLog.active = null;
        log.close();
      });

      test(
        'A truncated VOD is a source interruption, not a completed episode',
        () async {
          final backend = _QuietBackend();
          try {
            await HttpOverrides.runWithHttpOverrides(() async {
              await backend.open(origin.source(truncated: true), Duration.zero);
              await backend.play();
              await until(() => backend.failure != null);
              expect(backend.failure!.kind, PlaybackFailureKind.network);
              expect(backend.state.completed, isFalse);
              expect(
                backend.state.position.inMilliseconds,
                inInclusiveRange(1000, 3000),
              );
              expect(backend.canRetryWithSoftware, isFalse);
              final event = log.entries().singleWhere(
                (entry) => entry.event == 'player.terminal_failure',
              );
              expect((event.data['fields'] as Map)['origin'], 'premature_eof');
            }, _RealHttp());
          } finally {
            await backend.close();
          }
        },
      );

      test(
        'A real underrun grows the native buffer reserve and scales it with playback speed',
        () async {
          final backend = _QuietBackend();
          final transitions = <Object>[];
          Object? previous;
          backend.addListener(() {
            final state = backend.state;
            final key = (
              state.buffering,
              state.completed,
              backend.diagnosticFields['rebufferCount'],
            );
            if (key != previous) {
              previous = key;
              transitions.add([
                state.position.inMilliseconds,
                state.buffer.inMilliseconds,
                key,
              ]);
            }
          });
          origin.tail = Completer<void>();
          try {
            await HttpOverrides.runWithHttpOverrides(() async {
              await backend.open(origin.source(), Duration.zero);
              // This short fixture must begin before its held tail arrives;
              // the production startup reserve exceeds the fixture duration.
              final native = backend.player.platform as NativePlayer;
              await native.setProperty('cache-pause-initial', 'no');
              await native.setProperty('cache-pause-wait', '1');
              await backend.play();
              await until(
                () => (backend.diagnosticFields['rebufferCount'] as int) > 0,
              );
              await until(
                () => backend.diagnosticFields['resumeBufferSeconds'] == 8,
              );
              expect(
                double.parse(await native.getProperty('cache-pause-wait')),
                8,
              );
              expect(backend.state.buffering, isTrue);
              expect(backend.failure, isNull);
              await backend.setRate(2);
              await until(
                () => backend.diagnosticFields['resumeBufferSeconds'] == 16,
              );
              expect(
                double.parse(await native.getProperty('cache-pause-wait')),
                16,
              );
              origin.tail!.complete();
              await until(() => backend.state.completed);
              expect(backend.failure, isNull);
              expect(
                backend.diagnosticFields['rebufferCount'],
                1,
                reason: '$transitions',
              );
              expect(origin.requests, 2);
            }, _RealHttp());
          } finally {
            if (!origin.tail!.isCompleted) origin.tail!.complete();
            await backend.close();
          }
        },
      );

      for (final repeated in [false, true]) {
        test(
          repeated
              ? 'Repeated native short reads stop after one automatic refresh'
              : 'Native HTTP recovery resumes the same episode and preserves its bookmark',
          () async {
            final store = StateStore.memory();
            final history = PlaybackStore(store);
            var preparations = 0;
            final backends = <_QuietBackend>[];
            final controller = PlaybackController(
              entries: List.generate(
                2,
                (index) => PlaybackEntry(
                  id: '$index',
                  key: 'native-recovery-$index',
                  name: 'fixture.mkv',
                  video: true,
                  platform: CloudPlatform.tianyi,
                ),
              ),
              initialIndex: 0,
              history: history,
              prepare: (_, _) async {
                preparations++;
                return origin.source(truncated: true);
              },
              refresh: (_, _) async {
                preparations++;
                return origin.source(truncated: repeated);
              },
              retain: (_) {},
              release: (_) async {},
              backendFactory: (_, _) {
                final backend = _QuietBackend();
                backends.add(backend);
                return backend;
              },
            );
            try {
              await HttpOverrides.runWithHttpOverrides(() async {
                await controller.start();
                await until(
                  () => repeated
                      ? controller.error.isNotEmpty
                      : preparations == 2 &&
                            controller.ready &&
                            controller.state.position >=
                                const Duration(seconds: 4),
                );
                expect(preparations, 2);
                expect(backends, hasLength(2));
                expect(controller.index, 0);
                expect(
                  backends.last.openedStart!.inMilliseconds,
                  inInclusiveRange(1000, 3000),
                );
                expect(
                  history.bookmark('native-recovery-0')?.completed,
                  isFalse,
                );
                if (repeated) {
                  expect(controller.loading, isFalse);
                  expect(controller.state.playing, isFalse);
                  expect(controller.state.completed, isFalse);
                } else {
                  expect(controller.error, isEmpty);
                  expect(controller.state.playing, isTrue);
                }
              }, _RealHttp());
            } finally {
              await controller.close();
              store.dispose();
            }
          },
        );
      }

      for (final paused in [false, true]) {
        test(
          'A cached ${paused ? 'paused' : 'playing'} seek keeps its HTTP response and plays beyond the old buffer',
          () async {
            final backend = _QuietBackend();
            origin.tail = Completer<void>();
            try {
              await HttpOverrides.runWithHttpOverrides(() async {
                await backend.open(origin.source(), Duration.zero);
                await backend.play();
                await until(
                  () => backend.state.buffer >= const Duration(seconds: 3),
                );
                if (paused) await backend.pause();
                await backend.seek(const Duration(seconds: 1));
                await Future<void>.delayed(const Duration(milliseconds: 100));
                expect(
                  (backend.diagnosticFields['proxy'] as Map)['activeRequests'],
                  1,
                );
                expect(origin.requests, 2);
                if (paused) expect(backend.state.playing, isFalse);
                origin.tail!.complete();
                if (paused) await backend.play();
                await until(
                  () => backend.state.position >= const Duration(seconds: 6),
                );
                expect(backend.failure, isNull);
                expect(backend.state.completed, isFalse);
                expect(origin.requests, 2);
                expect(
                  await (backend.player.platform as NativePlayer).getProperty(
                    'cache-on-disk',
                  ),
                  'no',
                );
              }, _RealHttp());
            } finally {
              await backend.close();
            }
          },
        );
      }

      test(
        'Seeking to the end of a healthy HTTP video retains normal completion',
        () async {
          final backend = _QuietBackend();
          try {
            await HttpOverrides.runWithHttpOverrides(() async {
              await backend.open(origin.source(), Duration.zero);
              await until(
                () => backend.state.duration == const Duration(seconds: 9),
              );
              await backend.seek(const Duration(seconds: 8));
              await backend.play();
              await until(() => backend.state.completed);
              expect(backend.failure, isNull);
            }, _RealHttp());
          } finally {
            await backend.close();
          }
        },
      );
    },
    skip: !Platform.isWindows
        ? 'Native media tests currently require Windows.'
        : library == null
        ? 'A local libmpv test runtime is required.'
        : false,
  );
}
