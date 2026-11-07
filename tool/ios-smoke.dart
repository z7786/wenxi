// Separate simulator entry point: production builds use lib/main.dart.
// ignore_for_file: file_names
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:asterlink_js/asterlink_js.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/playback_device.dart';
import 'package:asterlink/upload/upload_sources.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/ui/player_page.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/main.dart' as app;

Future<void> main() async {
  app.main(const []);
  final folder = await getApplicationSupportDirectory();
  final report = File('${folder.path}/ios-smoke.json');
  var stage = 'startup';
  try {
    // Verify the ordinary bootstrap before replacing the page with a video.
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    var ready = false;
    while (DateTime.now().isBefore(deadline)) {
      final logs = Directory('${folder.path}/AsterLink/diagnostics');
      if (logs.existsSync()) {
        for (final entry in logs.listSync(recursive: true).whereType<File>()) {
          if (entry.path.endsWith('.jsonl') &&
              entry.readAsStringSync().contains('app.main_frame')) {
            ready = true;
          }
        }
      }
      if (ready) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    require(ready, 'Normal iOS startup did not reach its main frame');
    stage = 'quickjs';
    final bridge = SourceJsBridge();
    try {
      bridge.start({
        'entry': 'main.js',
        'operation': 'resolve',
        'modules': {
          'main.js':
              'export async function resolve(input){return {sum:input.a+input.b};}',
        },
        'input': {'a': 2, 'b': 3},
      });
      Json result = {};
      for (var i = 0; i < 30; i++) {
        result = bridge.poll();
        if (result.str('state') == 'done') break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      require(
        result.str('state') == 'done' &&
            result.obj('value').integer('sum') == 5,
        'Native QuickJS module execution failed: $result',
      );
    } finally {
      bridge.close();
    }
    final transport = IOSGopeedTransport();
    stage = 'download';
    final version = asJson(await transport.call('version'));
    require(
      version.boolean('ed2k') && version.boolean('parserHttp2'),
      'Missing native capabilities',
    );
    final storage = Directory('${folder.path}/ios-smoke-core');
    final cache = Directory('${folder.path}/ios-smoke-cache');
    await storage.create(recursive: true);
    await cache.create(recursive: true);
    final space = asJson(
      await transport.call('freeSpace', {'path': cache.path}),
    );
    require(space.integer('bytes') > 0, 'Free space lookup failed');
    await transport.call('open', {
      'storageDir': storage.path,
      'cacheDir': cache.path,
      'key': '',
    });
    final bytes = List<int>.generate(512 * 1024, (i) => i % 251);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.set('Accept-Ranges', 'bytes');
      final range = RegExp(
        r'bytes=(\d+)-(\d*)',
      ).firstMatch(request.headers.value('Range') ?? '');
      final start = range == null ? 0 : int.parse(range[1]!);
      final end = range == null || range[2]!.isEmpty
          ? bytes.length - 1
          : int.parse(range[2]!);
      if (range != null) {
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/${bytes.length}',
        );
      }
      request.response.contentLength = end - start + 1;
      if (request.method != 'HEAD') {
        request.response.add(bytes.sublist(start, end + 1));
      }
      await request.response.close();
    });
    String? movie;
    try {
      await transport.call('begin', {
        'id': 'ios_smoke',
        'url': 'http://127.0.0.1:${server.port}/file',
        'connections': 4,
        'retries': 1,
        'headers': <String, String>{},
      });
      for (var i = 0; i < 120; i++) {
        final state = asJson(
          await transport.call('snapshot', {'id': 'ios_smoke'}),
        );
        require(
          state.str('status') != 'error',
          'Native HTTP download failed: $state',
        );
        if (state.str('status') == 'done') {
          await transport.call('pause', {'id': 'ios_smoke'});
          final payload = await File(state.str('path')).readAsBytes();
          require(
            payload.length == bytes.length && payload[12345] == bytes[12345],
            'Download contents mismatch',
          );
          final documents = await getApplicationDocumentsDirectory();
          final files = PlatformFileAccess(
            transport,
            Directory('${documents.path}/Downloads'),
          );
          require(
            await files.downloadCacheRoot(documents.path) == null,
            'An incomplete iOS download would be stored in Files',
          );
          final saved = await files.save(
            id: 'ios-save-smoke',
            source: File(state.str('path')),
            name: 'coordinated-download.bin',
            relativePath: 'smoke',
            checkpoint: () {},
          );
          require(
            await files.inspect(saved) == FileAvailability.present,
            'Published iOS document cannot be read',
          );
          require(
            (await File(saved).readAsBytes())[12345] == bytes[12345],
            'Published document bytes differ from the download',
          );
          final duplicate = await files.save(
            id: 'ios-save-smoke-duplicate',
            source: File(state.str('path')),
            name: 'coordinated-download.bin',
            relativePath: 'smoke',
            checkpoint: () {},
          );
          require(
            saved != duplicate && File(saved).existsSync(),
            'Publishing overwrote an existing document',
          );
          stage = 'folderUploadSource';
          final uploadRoot = Directory('${documents.path}/upload-smoke');
          await Directory('${uploadRoot.path}/nested').create(recursive: true);
          await Directory('${uploadRoot.path}/empty').create();
          final uploadBytes = [...bytes, ...bytes.take(32)];
          await File(
            '${uploadRoot.path}/nested/source.bin',
          ).writeAsBytes(uploadBytes);
          try {
            final sources = UploadSources(android: false, ios: true);
            final plan = await sources.scanFolder(uploadRoot.path);
            require(
              plan.files.length == 1 &&
                  plan.files.single.relativePath == 'nested/source.bin' &&
                  plan.directories.contains('empty'),
              'Native folder upload scan lost files or empty directories',
            );
            await sources.validateFolder(plan);
            await sources.validate(plan.files.single);
            final received = await sources
                .read(plan.files.single, 17, uploadBytes.length - 9)
                .expand((chunk) => chunk)
                .toList();
            require(
              received.length == uploadBytes.length - 26 &&
                  Iterable<int>.generate(
                    received.length,
                  ).every((i) => received[i] == uploadBytes[i + 17]),
              'Native folder upload source range bytes differ',
            );
          } finally {
            await uploadRoot.delete(recursive: true);
          }
          await files.delete(saved);
          await files.delete(duplicate);
          movie = '${documents.path}/ios-smoke.mp4';
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      require(
        movie != null && File(movie).existsSync(),
        'Download timed out or playback fixture missing',
      );
    } finally {
      await transport.dispose();
      await server.close(force: true);
    }
    stage = 'playback';
    final player = Player();
    final video = VideoController(player);
    var decodedPosition = 0;
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Video(controller: video)),
        ),
      ),
    );
    try {
      await video.platform.future.timeout(const Duration(seconds: 15));
      await player.open(Media(Uri.file(movie!).toString()));
      await player.stream.position
          .firstWhere((value) => value.inMilliseconds > 1000)
          .timeout(const Duration(seconds: 25));
      require(
        player.state.duration.inSeconds > 2,
        'Video duration was not decoded',
      );
      decodedPosition = player.state.position.inMilliseconds;
    } finally {
      await player.dispose();
    }
    stage = 'playerPage';
    final movieBytes = await File(movie).readAsBytes();
    final mediaServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var authorizedReads = 0;
    mediaServer.listen((request) async {
      try {
        if (request.headers.value('Cookie') != 'smoke-media=fixture') {
          request.response.statusCode = 403;
          return;
        }
        authorizedReads++;
        final range = RegExp(
          r'^bytes=(\d+)-(\d*)$',
        ).firstMatch(request.headers.value('Range') ?? '');
        final start = range == null ? 0 : int.parse(range[1]!);
        final end = range == null || range[2]!.isEmpty
            ? movieBytes.length - 1
            : int.parse(range[2]!).clamp(0, movieBytes.length - 1);
        if (start > end || start >= movieBytes.length) {
          request.response.statusCode = 416;
          return;
        }
        if (range != null) {
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-$end/${movieBytes.length}',
          );
        }
        request.response.headers.set('Content-Type', 'video/mp4');
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.contentLength = end - start + 1;
        if (request.method != 'HEAD') {
          request.response.add(movieBytes.sublist(start, end + 1));
        }
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    final source = DownloadSpec(
      url: 'http://127.0.0.1:${mediaServer.port}/movie.mp4',
      fileName: 'ios-smoke.mp4',
      headers: const {'Cookie': 'smoke-media=fixture'},
    );
    try {
      await verifyPlayerPagePlayback(
        source,
        Directory('${folder.path}/ios-smoke-subtitles'),
      );
      require(authorizedReads > 0, 'Player did not read the authorized stream');
      await report.writeAsString(
        jsonEncode({
          'startup': true,
          'quickjs': true,
          'download': true,
          'coordinatedFileSave': true,
          'folderUploadSource': true,
          'freeSpace': true,
          'playback': true,
          'positionMs': decodedPosition,
          'playerPagePlayback': true,
          'playerPageControls': true,
          'playerPageTexture': true,
          'pipDisabled': true,
          'authorizedMediaReads': authorizedReads,
        }),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
    } finally {
      await mediaServer.close(force: true);
    }
  } catch (error, stack) {
    DiagnosticLog.error('ios.smoke_failed', error, stack);
    await report.writeAsString(
      jsonEncode({'stage': stage, 'error': error.toString()}),
    );
    rethrow;
  }
}

// Exercise ordinary playback through the production page and controller.
Future<void> verifyPlayerPagePlayback(
  DownloadSpec source,
  Directory subtitleDirectory,
) async {
  final controller = PlaybackController(
    entries: const [
      PlaybackEntry(
        id: 'ios-page-smoke',
        key: 'ios-page-smoke',
        name: 'ios-smoke.mp4',
        video: true,
      ),
    ],
    initialIndex: 0,
    history: PlaybackStore(
      StateStore.memory({
        'playbackPreferences': {'autoNext': false},
      }),
    ),
    prepare: (_, _) async => source,
    retain: (_) {},
    release: (_) async {},
    backendFactory: (entry, acceleration) =>
        MediaKitBackend(video: entry.video, hardwareAcceleration: acceleration),
  );
  final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
  runApp(
    MaterialApp(
      home: PlayerPage(
        controller,
        subtitleDirectory: subtitleDirectory,
        device: device,
      ),
    ),
  );
  Future<void> waitFor(bool Function() ready, String message) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!ready() && DateTime.now().isBefore(deadline)) {
      require(
        controller.error.isEmpty,
        'Player page reported a playback error',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    require(ready(), message);
  }

  try {
    await waitFor(
      () =>
          controller.ready &&
          controller.state.playing &&
          controller.state.position.inMilliseconds >= 1000,
      'Production player page did not decode the authenticated stream',
    );
    require(
      !device.supportsPip &&
          !device.supportsIndependentPlayerWindows &&
          device.systemPip == null &&
          !device.inPip &&
          !await device.enterPip() &&
          !await device.queryPip(),
      'iOS unexpectedly exposed picture in picture',
    );
    final backend = controller.backend!;
    final texture = await waitForSmokeElement(
      const Key('player-video-surface'),
    );
    await controller.pause();
    await waitFor(() => !controller.state.playing, 'Player did not pause');
    await controller.seek(const Duration(seconds: 1));
    await waitFor(
      () => (controller.state.position.inMilliseconds - 1000).abs() < 500,
      'Player did not seek',
    );
    await controller.setRate(1.5);
    await waitFor(
      () => (controller.state.rate - 1.5).abs() < .01,
      'Player did not change playback speed',
    );
    await controller.play();
    await waitFor(
      () =>
          controller.state.playing &&
          controller.state.position.inMilliseconds > 1200,
      'Player did not resume after pausing',
    );
    await controller.background(pictureInPicture: false);
    await waitFor(
      () => !controller.state.playing,
      'Backgrounding did not pause ordinary playback',
    );
    controller.foreground();
    await controller.play();
    final resumed = controller.state.position;
    await waitFor(
      () => backend.state.playing && backend.state.position > resumed,
      'Player did not continue after returning to the foreground',
    );
    await WidgetsBinding.instance.endOfFrame;
    require(
      identical(backend, controller.backend) &&
          identical(
            texture,
            findSmokeElement(const Key('player-video-surface')),
          ),
      'Playback controls recreated the decoder or video texture',
    );
    require(
      !controller.usingSystemPip &&
          findSmokeElement(const Key('player-system-pip-surface')) == null,
      'Ordinary iOS playback retained a PiP layer',
    );
  } finally {
    runApp(const MaterialApp(home: SizedBox()));
    await WidgetsBinding.instance.endOfFrame;
    await controller.close();
    await device.finish();
  }
}

Element? findSmokeElement(Key key) {
  Element? found;
  void visit(Element element) {
    if (element.widget.key == key) found = element;
    if (found == null) element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

Future<Element> waitForSmokeElement(Key key) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline)) {
    final element = findSmokeElement(key);
    if (element != null) return element;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('Production player action did not appear: $key');
}
