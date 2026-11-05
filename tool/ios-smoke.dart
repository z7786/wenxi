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
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/main.dart' as app;

Future<void> main() async {
  app.main(const []);
  final folder = await getApplicationSupportDirectory();
  final report = File('${folder.path}/ios-smoke.json');
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
          movie = Platform.environment['ASTERLINK_IOS_SMOKE_MOVIE'];
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
    final player = Player();
    final video = VideoController(player);
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
      await report.writeAsString(
        jsonEncode({
          'startup': true,
          'quickjs': true,
          'download': true,
          'freeSpace': true,
          'playback': true,
          'positionMs': player.state.position.inMilliseconds,
        }),
      );
    } finally {
      await player.dispose();
    }
  } catch (error, stack) {
    DiagnosticLog.error('ios.smoke_failed', error, stack);
    await report.writeAsString(jsonEncode({'error': error.toString()}));
    rethrow;
  }
}
