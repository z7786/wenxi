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
import 'package:asterlink/platform/playback_device.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/external_stream.dart';
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
          final payload = await File(state.str('path')).readAsBytes();
          require(
            payload.length == bytes.length && payload[12345] == bytes[12345],
            'Download contents mismatch',
          );
          final documents = await getApplicationDocumentsDirectory();
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
    stage = 'systemPip';
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
    final media = ExternalPlaybackStream(
      DownloadSpec(
        url: 'http://127.0.0.1:${mediaServer.port}/movie.mp4',
        fileName: 'ios-smoke.mp4',
        headers: const {'Cookie': 'smoke-media=fixture'},
      ),
    );
    final device = NativePlaybackDevice(targetPlatform: TargetPlatform.iOS);
    try {
      await device.start(video: true);
      final pip = device.systemPip!;
      await media.start();
      final preparation = pip.prepare(
        url: media.url,
        title: 'ios-smoke.mp4',
        initialState: const PlayerState(playing: false),
      );
      runApp(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: pip,
              builder: (_, _) =>
                  pip.buildVideo(fit: BoxFit.contain) ?? const SizedBox(),
            ),
          ),
        ),
      );
      require(
        await preparation,
        'AVKit could not prepare the authorized stream',
      );
      await pip.play();
      final playbackDeadline = DateTime.now().add(const Duration(seconds: 15));
      while (pip.state.position.inMilliseconds < 1000 &&
          DateTime.now().isBefore(playbackDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      require(
        pip.state.position.inMilliseconds >= 1000,
        'AVKit playback did not advance',
      );
      await pip.pause();
      await pip.seek(const Duration(milliseconds: 500));
      require(
        (pip.state.position.inMilliseconds - 500).abs() < 250,
        'AVKit seek did not update progress',
      );
      require(!pip.state.playing, 'AVKit pause did not stop audio');
      require(
        authorizedReads > 0,
        'AVKit did not read the authorized local transport',
      );
      final stopped = await pip.stop();
      require(
        stopped.position.inMilliseconds > 0 && !device.inPip,
        'AVKit stop did not return its bookmark',
      );
      await report.writeAsString(
        jsonEncode({
          'startup': true,
          'quickjs': true,
          'download': true,
          'freeSpace': true,
          'playback': true,
          'positionMs': decodedPosition,
          'systemPipTransport': true,
          'systemPipPlayback': true,
          'systemPipSeek': true,
          'systemPipSupported': device.supportsPip,
          'authorizedMediaReads': authorizedReads,
        }),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
    } finally {
      await device.finish();
      await media.close();
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
