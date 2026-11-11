import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/subtitle_fonts.dart';
import 'player_support.dart';
import 'support.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;

  test(
    'Windows runtime decodes and renders embedded PGS bitmap subtitles',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final player = Player(
        configuration: const PlayerConfiguration(libass: true, vo: 'null'),
      );
      final backend = MediaKitBackend(video: false, player: player);
      addTearDown(backend.close);
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('vid', 'auto');
      await native.setProperty('hwdec', 'no');
      final errors = <String>[];
      final subscription = player.stream.log.listen((line) {
        if ({'error', 'fatal'}.contains(line.level)) errors.add(line.text);
      });
      addTearDown(subscription.cancel);
      await backend.open(
        DownloadSpec(
          url: File('test/fixtures/player-pgs.mkv').absolute.path,
          fileName: 'player-pgs.mkv',
        ),
        Duration.zero,
      );
      await backend.play();
      await until(() => player.state.position.inMilliseconds >= 800);
      await backend.pause();
      final track = player.state.tracks.subtitle.firstWhere(
        (track) => track.codec == 'hdmv_pgs_subtitle',
      );
      expect(player.state.track.subtitle.id, isNot('no'));
      Future<int> greenPixels() async {
        final png = await backend.screenshot(includeSubtitles: true);
        expect(png, isNotNull);
        final codec = await ui.instantiateImageCodec(png!);
        final frame = (await codec.getNextFrame()).image;
        final pixels = (await frame.toByteData())!.buffer.asUint8List();
        var green = 0;
        for (var i = 0; i < pixels.length; i += 4) {
          if (pixels[i + 1] > pixels[i] + 60 &&
              pixels[i + 1] > pixels[i + 2] + 60) {
            green++;
          }
        }
        frame.dispose();
        codec.dispose();
        return green;
      }

      expect(await greenPixels(), greaterThan(2000));
      await backend.setSubtitleTrack(SubtitleTrack.no());
      expect(await greenPixels(), 0);
      await backend.setSubtitleTrack(track);
      // Selecting a bitmap track while paused may need the next decoded
      // packet before the PGS display set is restored.
      await backend.play();
      await until(() => player.state.position.inMilliseconds >= 1400);
      await backend.pause();
      expect(await greenPixels(), greaterThan(2000));
      expect(
        errors.where(
          (line) => line.contains('Could not find subtitle decoder'),
        ),
        isEmpty,
      );
      expect(backend.failure, isNull);
    },
    skip: library == null
        ? 'Requires the pinned Windows libmpv runtime.'
        : false,
  );

  for (final source in ['system', 'cache', 'late-download']) {
    test(
      'Native libass renders Chinese ASS from $source without implicit system fonts or a Flutter overlay',
      () async {
        MediaKit.ensureInitialized(libmpv: library);
        final directory = await Directory.systemTemp.createTemp(
          'asterlink-player-libass-',
        );
        addTearDown(() => removePlayerFixture(directory));
        final fontCache = Directory('${directory.path}/fonts');
        final releaseFont = Completer<void>();
        final urls = <Uri>[];
        if (source == 'cache') {
          final cached = File(
            '${fontCache.path}/${SubtitleFontStore.fontSha256}/NotoSansSC-Regular.otf',
          );
          await cached.parent.create(recursive: true);
          await File('assets/fonts/NotoSansSC-Regular.otf').copy(cached.path);
        } else if (source == 'late-download') {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          addTearDown(() {
            if (!releaseFont.isCompleted) releaseFont.complete();
          });
          server.listen((request) async {
            try {
              await releaseFont.future;
              request.response.contentLength = SubtitleFontStore.fontBytes;
              await request.response.addStream(
                File('assets/fonts/NotoSansSC-Regular.otf').openRead(),
              );
              await request.response.close();
            } on IOException {
              // The player may close before the shared download finishes.
            }
          });
          urls.add(Uri.parse('http://127.0.0.1:${server.port}/font'));
        }
        final fonts = SubtitleFontStore(
          directory: () async => fontCache,
          systemFiles: source == 'system' ? null : () async => [],
          clientFactory: () => _RealHttp().createHttpClient(null),
          downloadUrls: urls,
        );
        final subtitle = await File('${directory.path}/styled.ass')
            .writeAsString(r'''
[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Noto Sans SC,22,&H0000FF00,&H0000FF00,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,0,0,7,0,0,0,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:08.00,Default,,0,0,0,,{\an7\pos(16,20)}原生中文字幕
''');
        final player = Player(
          configuration: const PlayerConfiguration(libass: true, vo: 'null'),
        );
        final backend = MediaKitBackend(
          video: false,
          player: player,
          subtitleFonts: fonts,
        );
        addTearDown(backend.close);
        final native = player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await native.setProperty('vid', 'auto');
        await native.setProperty('hwdec', 'no');
        // Model Android's libass build: no implicit DirectWrite/fontconfig fonts.
        await native.setProperty('sub-font-provider', 'none');
        await backend.open(
          DownloadSpec(
            url: File('test/fixtures/player-sample.mkv').absolute.path,
            fileName: 'sample.mkv',
          ),
          Duration.zero,
        );
        await backend.setSubtitleTrack(
          SubtitleTrack.uri(subtitle.uri.toString()),
        );
        await backend.setSubtitlePresentation(
          size: 22,
          height: 180,
          bottom: .25,
        );
        await backend.play();
        await until(
          () =>
              player.state.position.inMilliseconds >= 1100 &&
              (player.state.width ?? 0) > 1,
        );
        await backend.pause();
        if (source == 'late-download') {
          expect(backend.subtitleFontLoading, isTrue);
          expect(backend.failure, isNull);
          final position = player.state.position;
          releaseFont.complete();
          await until(() => !backend.subtitleFontLoading);
          expect(backend.subtitleFontMessage, isEmpty);
          expect(player.state.playing, isFalse);
          expect(player.state.position, position);
          expect(player.state.track.subtitle.uri, isTrue);
        }
        expect(
          backend.diagnosticFields['subtitleFontSource'],
          source == 'late-download' ? 'download' : source,
        );
        expect(backend.supportsScreenshot, isTrue);
        final clean = await backend.screenshot();
        final styled = await backend.screenshot(includeSubtitles: true);
        expect(clean, isNotNull);
        expect(styled, isNotNull);
        final cleanCodec = await ui.instantiateImageCodec(clean!);
        final styledCodec = await ui.instantiateImageCodec(styled!);
        final cleanFrame = (await cleanCodec.getNextFrame()).image;
        final styledFrame = (await styledCodec.getNextFrame()).image;
        final a = (await cleanFrame.toByteData())!.buffer.asUint8List();
        final b = (await styledFrame.toByteData())!.buffer.asUint8List();
        var green = 0, top = styledFrame.height, bottom = 0;
        for (var i = 0; i + 3 < b.length; i += 4) {
          if (a[i] == b[i] && a[i + 1] == b[i + 1] && a[i + 2] == b[i + 2]) {
            continue;
          }
          if (b[i + 1] > b[i] + 30 && b[i + 1] > b[i + 2] + 30) {
            green++;
            final y = (i ~/ 4) ~/ styledFrame.width;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
          }
        }
        expect(green, greaterThan(40));
        expect(top, lessThan(45));
        expect(bottom, lessThan(90));
        expect(backend.rendersSubtitlesNatively, isTrue);
        cleanFrame.dispose();
        styledFrame.dispose();
        cleanCodec.dispose();
        styledCodec.dispose();
      },
      skip: library == null
          ? 'Requires the pinned Windows libmpv runtime.'
          : false,
    );
  }

  test(
    'Native plain text minimum removes the implicit libass bottom margin',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final player = Player(
        configuration: const PlayerConfiguration(libass: true, vo: 'null'),
      );
      final backend = MediaKitBackend(video: false, player: player);
      addTearDown(backend.close);
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('vid', 'auto');
      await backend.open(
        DownloadSpec(
          url: File('test/fixtures/player-sample.mkv').absolute.path,
          fileName: 'sample.mkv',
        ),
        Duration.zero,
      );
      await backend.setSubtitleTrack(
        SubtitleTrack.uri(
          File('test/fixtures/player-external.srt').absolute.uri.toString(),
        ),
      );
      await native.setProperty('sub-font-size', '88');
      await native.setProperty('sub-scale', '1');
      await native.setProperty('sub-pos', '100');
      await native.setProperty('sub-margin-y', '34');
      await backend.play();
      await until(
        () =>
            player.state.position.inMilliseconds >= 1100 &&
            (player.state.width ?? 0) > 1,
      );
      await backend.pause();

      Future<int> subtitleBottom() async {
        final clean = (await player.screenshot(format: 'image/png'))!;
        final styled = (await player.screenshot(
          format: 'image/png',
          includeLibassSubtitles: true,
        ))!;
        final cleanCodec = await ui.instantiateImageCodec(clean);
        final styledCodec = await ui.instantiateImageCodec(styled);
        final a = (await cleanCodec.getNextFrame()).image;
        final b = (await styledCodec.getNextFrame()).image;
        try {
          final before = (await a.toByteData())!.buffer.asUint8List();
          final after = (await b.toByteData())!.buffer.asUint8List();
          var bottom = -1;
          for (var i = 0; i + 3 < after.length; i += 4) {
            if (before[i] != after[i] ||
                before[i + 1] != after[i + 1] ||
                before[i + 2] != after[i + 2]) {
              bottom = (i ~/ 4) ~/ b.width;
            }
          }
          return bottom;
        } finally {
          a.dispose();
          b.dispose();
          cleanCodec.dispose();
          styledCodec.dispose();
        }
      }

      final previous = await subtitleBottom();
      expect(previous, greaterThan(0));
      await backend.setSubtitlePresentation(size: 22, height: 180, bottom: 0);
      final lowest = await subtitleBottom();
      expect(lowest, greaterThan(previous + 4));
      expect(await native.getProperty('sub-margin-y'), '0');
      expect(double.parse(await native.getProperty('sub-pos')), 100);
    },
    skip: library == null
        ? 'Requires the pinned Windows libmpv runtime.'
        : false,
  );

  test(
    'Native subtitle background updates color and alpha without moving text',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final player = Player(
        configuration: const PlayerConfiguration(libass: true, vo: 'null'),
      );
      final backend = MediaKitBackend(video: false, player: player);
      addTearDown(backend.close);
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await native.setProperty('vid', 'auto');
      // Measure box opacity in RGB instead of clipping saturated colors
      // through the video's limited-range YUV planes.
      await native.setProperty('vf', 'format=fmt=rgb24');
      await backend.open(
        DownloadSpec(
          url: File('test/fixtures/player-sample.mkv').absolute.path,
          fileName: 'sample.mkv',
        ),
        Duration.zero,
      );
      await backend.setSubtitleTrack(
        SubtitleTrack.uri(
          File('test/fixtures/player-external.srt').absolute.uri.toString(),
        ),
      );
      await backend.setSubtitlePresentation(size: 22, height: 180, bottom: .1);
      await backend.play();
      await until(
        () =>
            player.state.position.inMilliseconds >= 1100 &&
            (player.state.width ?? 0) > 1,
      );
      await backend.pause();

      Future<List<int>> pixels(String label) async {
        final png = (await player.screenshot(
          format: 'image/png',
          includeLibassSubtitles: true,
        ))!;
        final output = Platform.environment['ASTERLINK_SUBTITLE_SCREENSHOTS'];
        if (output != null) {
          await Directory(output).create(recursive: true);
          await File('$output/$label.png').writeAsBytes(png);
        }
        final codec = await ui.instantiateImageCodec(png);
        final frame = (await codec.getNextFrame()).image;
        try {
          return List<int>.of((await frame.toByteData())!.buffer.asUint8List());
        } finally {
          frame.dispose();
          codec.dispose();
        }
      }

      final none = await pixels('no-background');
      // Compare box opacity against the video itself. The no-background
      // subtitle image also contains text outlines underneath the box.
      final cleanPng = (await backend.screenshot())!;
      final cleanCodec = await ui.instantiateImageCodec(cleanPng);
      final cleanFrame = (await cleanCodec.getNextFrame()).image;
      final clean = List<int>.of(
        (await cleanFrame.toByteData())!.buffer.asUint8List(),
      );
      cleanFrame.dispose();
      cleanCodec.dispose();
      expect(double.parse(await native.getProperty('sub-shadow-offset')), 0);
      expect(double.parse(await native.getProperty('sub-border-size')), 4);
      await backend.setSubtitlePresentation(
        size: 22,
        height: 180,
        bottom: .1,
        backgroundColor: 0xffff0000,
      );
      final opaque = await pixels('red-opaque');
      await backend.setSubtitlePresentation(
        size: 22,
        height: 180,
        bottom: .1,
        backgroundColor: 0x80ff0000,
      );
      final half = await pixels('red-half');
      await backend.setSubtitlePresentation(
        size: 22,
        height: 180,
        bottom: .1,
        backgroundColor: 0xff0000ff,
      );
      final blue = await pixels('blue-opaque');
      var backgroundPixels = 0;
      var opacityError = 0.0;
      for (var i = 0; i + 3 < opaque.length; i += 4) {
        if (opaque[i] < 250 ||
            opaque[i + 1] > 5 ||
            opaque[i + 2] > 5 ||
            blue[i] > 5 ||
            blue[i + 1] > 5 ||
            blue[i + 2] < 250) {
          continue;
        }
        backgroundPixels++;
        for (var c = 0; c < 3; c++) {
          final expected = (opaque[i + c] + clean[i + c]) / 2;
          opacityError += (half[i + c] - expected).abs();
        }
      }
      expect(backgroundPixels, greaterThan(100));
      expect(opacityError / (backgroundPixels * 3), lessThan(3));
      await backend.setSubtitlePresentation(size: 22, height: 180, bottom: .1);
      expect(await pixels('cleared-background'), none);
    },
    skip: library == null
        ? 'Requires the pinned Windows libmpv runtime.'
        : false,
  );

  test(
    'Closing a player does not wait for its font download or attach a late result',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-player-font-close-',
      );
      addTearDown(() => removePlayerFixture(directory));
      final release = Completer<void>(), started = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      server.listen((request) async {
        try {
          started.complete();
          await release.future;
          request.response.contentLength = SubtitleFontStore.fontBytes;
          await request.response.addStream(
            File('assets/fonts/NotoSansSC-Regular.otf').openRead(),
          );
          await request.response.close();
        } on IOException {
          // The test deliberately closes the native player first.
        }
      });
      final fonts = SubtitleFontStore(
        directory: () async => directory,
        systemFiles: () async => [],
        clientFactory: () => _RealHttp().createHttpClient(null),
        downloadUrls: [Uri.parse('http://127.0.0.1:${server.port}/font')],
      );
      final player = Player(
        configuration: const PlayerConfiguration(libass: true),
      );
      final backend = MediaKitBackend(
        video: false,
        player: player,
        subtitleFonts: fonts,
      );
      addTearDown(backend.close);
      await backend.initialize();
      await started.future;
      await backend.close().timeout(const Duration(seconds: 2));
      release.complete();
      final ready = await fonts.ensureAvailable();
      expect(await File(ready.path).exists(), isTrue);
      expect(backend.diagnosticFields['subtitleFontSource'], isNull);
    },
    skip: library == null
        ? 'Requires the pinned Windows libmpv runtime.'
        : false,
  );
}
