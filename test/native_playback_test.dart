import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'support.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final libraries = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
    'build/windows/x64/runner/Release/libmpv-2.dll',
  ];
  final library = libraries
      .whereType<String>()
      .where((path) => File(path).existsSync())
      .firstOrNull;
  group(
    'Real libmpv playback',
    () {
      late Player player;
      late MediaKitBackend backend;
      late DiagnosticLog log;
      final sample = File('test/fixtures/player-sample.mkv').absolute;
      setUpAll(() {
        MediaKit.ensureInitialized(libmpv: library);
      });
      setUp(() async {
        log = DiagnosticLog.open(null);
        DiagnosticLog.active = log;
        player = Player(
          configuration: const PlayerConfiguration(
            title: 'AsterLink media test',
          ),
        );
        await (player.platform as NativePlayer).setProperty('ao', 'null');
        backend = MediaKitBackend(video: false, player: player);
      });
      tearDown(() async {
        await backend.close();
        DiagnosticLog.active = null;
        log.close();
      });
      Future<void> open() async {
        await backend.open(
          DownloadSpec(url: sample.path, fileName: 'sample.mkv'),
          Duration.zero,
        );
        await until(
          () =>
              player.state.duration.inSeconds >= 8 &&
              player.state.tracks.audio.length >= 4,
        );
      }

      test(
        'Actual decoding reports codec, frame rate and software mode without leaking the previous file metrics',
        () async {
          final native = player.platform as NativePlayer;
          await native.setProperty('vo', 'null');
          await native.setProperty('vid', 'auto');
          await native.setProperty('hwdec', 'no');
          for (final (path, codec, fps, width) in [
            ('test/fixtures/player-hls/segment0.ts', 'h264', 25, 96),
            (sample.path, 'mjpeg', 10, 320),
          ]) {
            await backend.open(
              DownloadSpec(url: File(path).absolute.path, fileName: 'video'),
              Duration.zero,
            );
            expect(backend.diagnosticFields, isNot(contains('videoCodec')));
            expect(backend.hardwareDecodingActive, isNull);
            await backend.play();
            await until(
              () =>
                  backend.diagnosticFields['videoCodec'] == codec &&
                  player.state.position > const Duration(milliseconds: 100),
            );
            expect(backend.hardwareDecodingActive, isFalse);
            expect(backend.diagnosticFields['videoFps'], fps);
            expect(backend.diagnosticFields['videoPixelFormat'], isNotEmpty);
            expect(backend.diagnosticFields['decoderDroppedFrames'], 0);
            expect(player.state.width, width);
            expect(backend.failure, isNull);
          }
        },
      );

      test(
        'Reads real container dimensions while decoding and playback are disabled',
        () async {
          await (player.platform as NativePlayer).setProperty('vid', 'no');
          await backend.open(
            DownloadSpec(url: sample.path, fileName: 'sample.mkv'),
            Duration.zero,
          );
          await until(() => backend.videoGeometry != null);
          expect(backend.videoGeometry, const VideoGeometry(320, 180));
          expect(player.state.playing, isFalse);
          expect(player.state.width, isNull);
          expect(player.state.height, isNull);
          expect(player.state.position, Duration.zero);
        },
      );
      test(
        'Reads QuickTime rotation matrices and pixel aspect ratios before video decoding',
        () async {
          await (player.platform as NativePlayer).setProperty('vid', 'no');
          for (final (file, geometry) in [
            ('player-rotated.mov', const VideoGeometry(180, 320)),
            ('player-anamorphic.mov', const VideoGeometry(640, 180)),
          ]) {
            final metadata = player.stream.tracks.firstWhere(
              (tracks) => tracks.video.any((track) => track.w != null),
            );
            await backend.open(
              DownloadSpec(
                url: File('test/fixtures/$file').absolute.path,
                fileName: file,
              ),
              Duration.zero,
            );
            final tracks = await metadata.timeout(const Duration(seconds: 10));
            expect(
              backend.videoGeometry,
              geometry,
              reason: '$file: ${tracks.video}',
            );
            expect(player.state.playing, isFalse);
            expect(player.state.width, isNull);
            expect(player.state.height, isNull);
          }
        },
      );
      test(
        'Demuxes the generated video, switches audio and really seeks, pauses and changes speed',
        () async {
          await open();
          final audios = player.state.tracks.audio
              .where((track) => track.id != 'auto' && track.id != 'no')
              .toList();
          expect(audios.length, 2);
          expect(
            player.state.tracks.subtitle.where(
              (track) => track.id != 'auto' && track.id != 'no',
            ),
            isNotEmpty,
          );
          await backend.setAudioTrack(audios.last);
          await until(() => player.state.track.audio.id == audios.last.id);
          await backend.setRate(1.5);
          await backend.setVolume(65);
          await backend.play();
          await until(
            () => player.state.position > const Duration(milliseconds: 100),
          );
          await backend.seek(const Duration(seconds: 4));
          await until(() => player.state.position.inMilliseconds >= 3500);
          await backend.pause();
          await until(() => !player.state.playing);
          expect(player.state.rate, 1.5);
          expect(player.state.volume, 65);
          expect(player.state.position.inSeconds, lessThan(8));
        },
      );
      test(
        'Loads external UTF-8 captions, applies sync offsets and disables subtitles',
        () async {
          await open();
          final subtitle = File('test/fixtures/player-external.srt').absolute;
          await backend.setSubtitleTrack(
            SubtitleTrack.uri(subtitle.uri.toString(), title: '外挂测试'),
          );
          await backend.setSubtitleDelay(.75);
          await backend.setAudioDelay(-.25);
          await backend.play();
          await backend.seek(const Duration(seconds: 2));
          await until(
            () => player.state.subtitle.join().contains('External subtitle'),
          );
          expect(player.state.subtitle.join(), contains('外挂字幕'));
          expect(
            double.parse(
              await (player.platform as NativePlayer).getProperty('sub-delay'),
            ),
            closeTo(.75, .01),
          );
          expect(
            double.parse(
              await (player.platform as NativePlayer).getProperty(
                'audio-delay',
              ),
            ),
            closeTo(-.25, .01),
          );
          await backend.setSubtitleTrack(SubtitleTrack.no());
          await until(
            () =>
                player.state.track.subtitle.id == 'no' &&
                player.state.subtitle.join().trim().isEmpty,
          );
        },
      );
      test(
        'Rapid sync adjustments complete in order without false verification failures',
        () async {
          await open();
          await Future.wait([
            for (var i = 0; i <= 20; i++) ...[
              backend.setSubtitleDelay(i / 10),
              backend.setAudioDelay(-i / 20),
            ],
          ]);
          final native = player.platform as NativePlayer;
          expect(double.parse(await native.getProperty('sub-delay')), 2);
          expect(double.parse(await native.getProperty('audio-delay')), -1);
        },
      );
      test(
        'Opening Aliyun HLS from the beginning does not seek past its first segment',
        () async {
          final root = Directory('test/fixtures/player-hls').absolute;
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            try {
              final file = File(
                '${root.path}/${request.uri.pathSegments.last}',
              );
              request.response.headers.set(
                'Content-Type',
                request.uri.path.endsWith('.m3u8')
                    ? 'application/vnd.apple.mpegurl'
                    : 'video/mp2t',
              );
              request.response.add(await file.readAsBytes());
              await request.response.close();
            } catch (_) {
              // Opening another source and teardown can cancel media reads.
            }
          });
          final native = player.platform as NativePlayer;
          await native.setProperty('vo', 'null');
          await native.setProperty('vid', 'auto');
          final source = DownloadSpec(
            url: 'http://127.0.0.1:${server.port}/video.m3u8',
            fileName: 'hls-video.mp4',
            profile: 'aliyun',
          );
          // A preceding resume must not leak its start option into a fresh open.
          for (final start in [
            Duration.zero,
            const Duration(seconds: 10),
            Duration.zero,
          ]) {
            await HttpOverrides.runWithHttpOverrides(
              () => backend.open(source, start),
              _RealHttp(),
            );
            await until(() => (player.state.width ?? 0) > 0);
            expect(player.state.playing, isFalse);
            expect(backend.failure, isNull);
            expect(
              player.state.position.inMilliseconds,
              closeTo(start.inMilliseconds, 250),
              reason:
                  'The requested start must not advance to the next HLS segment.',
            );
            await backend.play();
            await until(
              () =>
                  player.state.position >=
                  start + const Duration(milliseconds: 300),
            );
            await backend.pause();
            expect(
              player.state.position,
              lessThan(start + const Duration(seconds: 2)),
            );
          }
        },
      );
      test(
        'Native network playback sends the required cookie and supports Range seeking',
        () async {
          final bytes = await sample.readAsBytes(),
              requests = <Map<String, String>>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            final response = request.response;
            try {
              requests.add({
                'cookie': request.headers.value('cookie') ?? '',
                'range': request.headers.value('range') ?? '',
              });
              if (request.headers.value('cookie') !=
                  'player-fixture=only-tests') {
                response.statusCode = 403;
                return;
              }
              response.headers.set('Content-Type', 'video/x-matroska');
              response.headers.set('Accept-Ranges', 'bytes');
              final match = RegExp(
                r'bytes=(\d+)-(\d*)',
              ).firstMatch(request.headers.value('range') ?? '');
              final start = match == null ? 0 : int.parse(match.group(1)!);
              final end = match == null || match.group(2)!.isEmpty
                  ? bytes.length - 1
                  : int.parse(match.group(2)!).clamp(0, bytes.length - 1);
              if (start >= bytes.length || start > end) {
                response.statusCode = 416;
                return;
              }
              if (match != null) {
                response.statusCode = 206;
                response.headers.set(
                  'Content-Range',
                  'bytes $start-$end/${bytes.length}',
                );
              }
              response.contentLength = end - start + 1;
              if (request.method != 'HEAD') {
                response.add(bytes.sublist(start, end + 1));
              }
            } finally {
              await response.close();
            }
          });
          // Use real Dart HTTP for the Range adapter as well as native mpv.
          // The widget binding otherwise replaces it with a 400-only client.
          await HttpOverrides.runWithHttpOverrides(
            () => backend.open(
              DownloadSpec(
                url: 'http://127.0.0.1:${server.port}/video.mkv',
                fileName: 'video.mkv',
                headers: const {'Cookie': 'player-fixture=only-tests'},
              ),
              const Duration(seconds: 2),
            ),
            _RealHttp(),
          );
          expect(backend.streamingDescription, startsWith('最多 12 个连接'));
          final native = player.platform as NativePlayer;
          expect(double.parse(await native.getProperty('cache-secs')), 90);
          expect(await native.getProperty('cache-pause-initial'), 'yes');
          expect(double.parse(await native.getProperty('cache-pause-wait')), 6);
          expect(
            int.parse(await native.getProperty('demuxer-max-bytes')),
            16 * 1024 * 1024,
          );
          expect(
            int.parse(await native.getProperty('demuxer-max-back-bytes')),
            4 * 1024 * 1024,
          );
          await backend.play();
          await until(
            () => player.state.position >= const Duration(seconds: 2),
          );
          await backend.seek(const Duration(seconds: 6));
          await until(
            () => player.state.position >= const Duration(seconds: 5),
          );
          expect(requests, isNotEmpty);
          expect(
            requests.every(
              (request) => request['cookie'] == 'player-fixture=only-tests',
            ),
            isTrue,
          );
          expect(
            requests.any((request) => request['range']!.startsWith('bytes=')),
            isTrue,
          );
        },
      );
      for (final (ranged, cancel) in [
        (true, false),
        (false, false),
        (true, true),
        (false, true),
      ]) {
        test(
          cancel
              ? 'Closing ${ranged ? 'segmented' : 'direct'} playback interrupts a pending first response promptly'
              : 'Slow ${ranged ? 'segmented' : 'direct'} playback survives a first response beyond five seconds',
          () async {
            final bytes = await sample.readAsBytes();
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final pending = <Future<void>>[];
            var probes = 0, mediaReads = 0;
            Future<void> serve(HttpRequest request) async {
              final response = request.response;
              try {
                final value = request.headers.value('range') ?? '';
                final probe = value == 'bytes=0-1023';
                if (probe) {
                  probes++;
                } else {
                  mediaReads++;
                  // The probe succeeds quickly, but the first verified media
                  // segment arrives after media_kit's default 5-second timeout.
                  await Future<void>.delayed(const Duration(seconds: 7));
                }
                final match = ranged
                    ? RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(value)
                    : null;
                final start = match == null ? 0 : int.parse(match[1]!);
                final end = match == null || match[2]!.isEmpty
                    ? bytes.length - 1
                    : int.parse(match[2]!).clamp(0, bytes.length - 1);
                if (start > end) {
                  response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
                  response.contentLength = 0;
                  return;
                }
                response.headers.set('Content-Type', 'video/x-matroska');
                if (match != null) {
                  response.statusCode = HttpStatus.partialContent;
                  response.headers.set('Accept-Ranges', 'bytes');
                  response.headers.set(
                    'Content-Range',
                    'bytes $start-$end/${bytes.length}',
                  );
                }
                response.contentLength = end - start + 1;
                response.add(bytes.sublist(start, end + 1));
              } catch (_) {
                // A failing regression closes the player before the response.
              } finally {
                try {
                  await response.close();
                } catch (_) {}
              }
            }

            server.listen((request) => pending.add(serve(request)));
            addTearDown(() async {
              await server.close(force: true);
              await Future.wait(pending);
            });
            await HttpOverrides.runWithHttpOverrides(
              () => backend.open(
                DownloadSpec(
                  url: 'http://127.0.0.1:${server.port}/slow.mkv',
                  fileName: 'slow.mkv',
                ),
                Duration.zero,
              ),
              _RealHttp(),
            );
            if (cancel) {
              await until(() => mediaReads > 0);
              await backend.close().timeout(const Duration(seconds: 2));
              expect(backend.failure, isNull);
              expect(
                log.entries().where(
                  (e) => e.event == 'player.terminal_failure',
                ),
                isEmpty,
              );
              return;
            }
            await until(
              () =>
                  backend.errorRevision > 0 ||
                  player.state.duration.inSeconds >= 8,
            );
            expect(
              backend.errorRevision,
              0,
              reason:
                  'A healthy slow source must not be abandoned before it responds: ${backend.failure}',
            );
            expect(player.state.duration.inSeconds, greaterThanOrEqualTo(8));
            expect(probes, 1);
            expect(mediaReads, greaterThan(0));
            expect(
              log.entries().where((e) => e.event == 'player.transport_waiting'),
              isNotEmpty,
            );
            final transport =
                log
                        .entries()
                        .singleWhere((e) => e.event == 'player.transport')
                        .data['fields']
                    as Map;
            expect(transport['transport'], ranged ? 'segmented' : 'direct');
            expect(transport['networkTimeoutSeconds'], ranged ? 90 : 30);
            expect(
              (transport['proxy'] as Map)['probeResult'],
              ranged ? 'ready' : 'range_not_supported',
            );
            await backend.play();
            await until(() => player.state.position.inMilliseconds >= 100);
            expect(backend.failure, isNull);
          },
        );
      }
      test(
        'Real mpv starts from streamed packets while the remainder of its first segment is held',
        () async {
          final bytes = await sample.readAsBytes();
          final tail = Completer<void>();
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final pending = <Future<void>>[];
          var held = 0;
          Future<void> serve(HttpRequest request) async {
            final response = request.response;
            try {
              response.bufferOutput = false;
              final match = RegExp(
                r'^bytes=(\d+)-(\d*)$',
              ).firstMatch(request.headers.value('range') ?? '');
              final start = match == null ? 0 : int.parse(match[1]!);
              final end = match == null || match[2]!.isEmpty
                  ? bytes.length - 1
                  : int.parse(match[2]!).clamp(0, bytes.length - 1);
              response.statusCode = 206;
              response.headers.set(
                'Content-Range',
                'bytes $start-$end/${bytes.length}',
              );
              response.headers.set('Content-Type', 'video/x-matroska');
              response.headers.set('ETag', '"streamed-fixture"');
              response.contentLength = end - start + 1;
              // The startup reserve is now six seconds; keep enough real
              // packets for it while holding the remainder of the range.
              const prefix = 512 * 1024;
              if (end - start + 1 > prefix) {
                response.add(bytes.sublist(start, start + prefix));
                await response.flush();
                held++;
                await tail.future;
                response.add(bytes.sublist(start + prefix, end + 1));
              } else {
                response.add(bytes.sublist(start, end + 1));
              }
            } catch (_) {
              // The player may cancel a header read when it seeks to the tail.
            } finally {
              try {
                await response.close();
              } catch (_) {}
            }
          }

          server.listen((request) => pending.add(serve(request)));
          addTearDown(() async {
            if (!tail.isCompleted) tail.complete();
            await server.close(force: true);
            await Future.wait(pending);
          });
          await HttpOverrides.runWithHttpOverrides(
            () => backend.open(
              DownloadSpec(
                url: 'http://127.0.0.1:${server.port}/progressive.mkv',
                fileName: 'progressive.mkv',
              ),
              Duration.zero,
            ),
            _RealHttp(),
          );
          await until(
            () => backend.state.duration.inSeconds >= 8,
            timeout: const Duration(seconds: 4),
          );
          await backend.play();
          await until(
            () => backend.state.position.inMilliseconds >= 100,
            timeout: const Duration(seconds: 4),
          );
          expect(held, greaterThan(0));
          expect(tail.isCompleted, isFalse);
          expect(backend.failure, isNull);
          final stats = backend.diagnosticFields['proxy'] as Map;
          expect(stats['receivedBytes'], greaterThan(0));
          expect(stats['servedBytes'], greaterThan(0));
          await backend.close().timeout(const Duration(seconds: 2));
          final closed =
              log
                      .entries()
                      .singleWhere((e) => e.event == 'player.transport_closed')
                      .data['fields']
                  as Map;
          expect(closed['positionMs'], greaterThan(0));
          expect((closed['proxy'] as Map)['servedBytes'], greaterThan(0));
        },
      );
      test(
        'Real HTTP authorization failure is not classified as a decoder failure',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            request.response.statusCode = HttpStatus.forbidden;
            request.response.contentLength = 0;
            await request.response.close();
          });
          await expectLater(
            HttpOverrides.runWithHttpOverrides(
              () => backend.open(
                DownloadSpec(
                  url: 'http://127.0.0.1:${server.port}/denied.mkv',
                  fileName: 'denied.mkv',
                ),
                Duration.zero,
              ),
              _RealHttp(),
            ),
            throwsA(
              isA<PlaybackFailure>().having((e) => e.status, 'status', 403),
            ),
          );
          await until(() => backend.errorRevision > 0);
          expect(backend.canRetryWithSoftware, isFalse);
          expect(backend.state.playing, isFalse);
          final error = log
              .entries(errorsOnly: true)
              .singleWhere((e) => e.event == 'player.terminal_failure');
          expect((error.data['fields'] as Map)['status'], 403);
          expect((error.data['fields'] as Map)['origin'], 'proxy');
        },
      );
      test(
        'Recoverable native TCP and decoder log messages do not stop valid playback',
        () async {
          await open();
          await backend.play();
          await until(() => player.state.position.inMilliseconds >= 100);
          final position = player.state.position;
          final native = player.platform as NativePlayer;
          for (final (prefix, message) in [
            ('ffmpeg/tcp', 'Connection reset by peer'),
            ('vd', 'Error decoding frame; continuing with the next frame'),
          ]) {
            // Inject log traffic while the real native decoder keeps running.
            // ignore: invalid_use_of_protected_member
            native.logController.add(
              PlayerLog(prefix: prefix, level: 'error', text: message),
            );
            // ignore: invalid_use_of_protected_member
            native.errorController.add(message);
          }
          await until(
            () =>
                player.state.position >
                position + const Duration(milliseconds: 200),
          );
          expect(backend.errorRevision, 0);
          expect(backend.failure, isNull);
          expect(player.state.playing, isTrue);
          expect(
            log.entries().where((e) => e.event == 'player.terminal_failure'),
            isEmpty,
          );
        },
      );
      test(
        'A real native loading failure emits a terminal error; stop and normal EOF do not',
        () async {
          final native = player.platform as NativePlayer;
          final failures = <int>[];
          final subscription = native.playbackFailures.listen(failures.add);
          addTearDown(subscription.cancel);
          await open();
          await backend.seek(const Duration(seconds: 7));
          await backend.play();
          await until(() => player.state.completed);
          expect(failures, isEmpty);
          await player.stop();
          expect(failures, isEmpty);
          await backend.open(
            DownloadSpec(
              url: '${sample.path}.does-not-exist',
              fileName: 'missing.mkv',
            ),
            Duration.zero,
          );
          await until(() => backend.errorRevision > 0);
          expect(failures, hasLength(1));
          expect(backend.failure, isNotNull);
          expect(backend.state.completed, isFalse);
          final error = log
              .entries(errorsOnly: true)
              .singleWhere((e) => e.event == 'player.terminal_failure');
          expect((error.data['fields'] as Map)['origin'], 'native');
          expect((error.data['fields'] as Map)['nativeCode'], lessThan(0));
        },
      );
    },
    skip: !Platform.isWindows
        ? 'Native media tests currently require Windows.'
        : library == null
        ? 'Run tool/prepare-player-test.ps1 or set ASTERLINK_MPV_LIBRARY to libmpv-2.dll.'
        : false,
  );
}
