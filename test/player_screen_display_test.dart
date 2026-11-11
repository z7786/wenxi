import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_screen_display.dart';
import 'package:asterlink/playback/playback_screen_info.dart';
import 'package:asterlink/playback/playback_state.dart';
import 'package:asterlink/ui/player_screen_display.dart';
import 'player_support.dart';

void main() {
  var fixtureFont = false;
  setUpAll(() async {
    final file = File('C:/Windows/Fonts/msyh.ttc');
    if (await file.exists()) {
      await (FontLoader('FixtureUI')..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          ))
          .load();
      fixtureFont = true;
    }
  });

  for (final (size, television) in [
    (const Size(792, 360), false),
    (const Size(320, 700), false),
    (const Size(1920, 1080), true),
  ]) {
    testWidgets('All screen data stays in separate video corners at $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = PlaybackFixture(
        suppliedEntries: const [
          PlaybackEntry(
            id: 'lecture',
            key: 'lecture',
            name: '17-9_1713.mp4',
            video: true,
          ),
        ],
        data: {
          'playbackPreferences': {
            'screenDisplay': {
              'enabled': true,
              'items': [
                for (final item in PlaybackScreenItem.values) item.name,
              ],
            },
          },
        },
      );
      await fixture.controller.start();
      fixture.current.screenInfo = const PlaybackScreenInfo(
        transport: 'direct',
        bytesPerSecond: 2048,
        hardwareDecoder: 'mediacodec-copy',
        bufferSeconds: 90,
        decoderDroppedFrames: 0,
        outputDroppedFrames: 0,
      );
      fixture.current.emit(
        fixture.current.state.copyWith(
          width: 1280,
          height: 720,
          position: const Duration(seconds: 1),
          duration: const Duration(minutes: 2, seconds: 8),
          tracks: const Tracks(
            video: [VideoTrack('1', null, null, codec: 'h264', fps: 25)],
            audio: [
              AudioTrack(
                '1',
                null,
                null,
                codec: 'aac',
                samplerate: 44100,
                channelscount: 1,
                bitrate: 68410,
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: fixtureFont ? 'FixtureUI' : null),
          home: Scaffold(
            body: RepaintBoundary(
              key: const Key('screen-fixture-capture'),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(painter: _BrightVideoFixture()),
                  PlayerScreenDisplay(
                    controller: fixture.controller,
                    television: television,
                    now: () => DateTime(2026, 11, 11, 20, 20, 22),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final video = tester.getRect(
        find.byKey(const Key('player-screen-video-bounds')),
      );
      final regions = <String, Rect>{};
      for (final id in [
        'top-left',
        'top-right',
        'bottom-left',
        'bottom-right',
      ]) {
        final region = tester.getRect(
          find.byKey(Key('player-screen-region-$id')),
        );
        expect(region.left, greaterThanOrEqualTo(video.left));
        expect(region.right, lessThanOrEqualTo(video.right));
        expect(region.top, greaterThanOrEqualTo(video.top));
        expect(region.bottom, lessThanOrEqualTo(video.bottom));
        regions[id] = region;
      }
      for (final a in regions.keys) {
        for (final b in regions.keys.where((b) => b != a)) {
          expect(
            regions[a]!.overlaps(regions[b]!),
            isFalse,
            reason: '$a overlaps $b',
          );
        }
      }
      expect(find.textContaining('mediacodec-copy'), findsOneWidget);
      expect(find.text('解码丢帧 0 · 输出丢帧 0'), findsOneWidget);
      final parameters = tester.getRect(
        find.byKey(const Key('player-screen-line-parameters')),
      );
      expect(parameters.width, lessThanOrEqualTo(video.width / 2));
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const Key('screen-fixture-capture')),
        matchesGoldenFile(
          'goldens/player-screen-bright-${size.width.toInt()}.png',
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.controller.close();
      fixture.store.dispose();
    });
  }

  for (final (fit, aspect, scale, x, expected) in [
    (PlaybackFit.contain, 0.0, 1.0, 0.0, const Rect.fromLTRB(76, 0, 716, 360)),
    (PlaybackFit.cover, 0.0, 1.0, 0.0, const Rect.fromLTRB(40, 0, 772, 350)),
    (PlaybackFit.stretch, 0.0, 1.0, 0.0, const Rect.fromLTRB(40, 0, 772, 350)),
    (PlaybackFit.contain, 1.0, 1.0, 0.0, const Rect.fromLTRB(216, 0, 576, 350)),
    (
      PlaybackFit.contain,
      0.0,
      .5,
      .2,
      const Rect.fromLTRB(315.2, 90, 635.2, 270),
    ),
  ]) {
    testWidgets(
      'Screen follows video fit=$fit aspect=$aspect scale=$scale offset=$x',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(792, 360);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = PlaybackFixture(
          data: {
            'playbackPreferences': {
              'fit': fit.name,
              'aspectRatio': aspect,
              'videoScale': scale,
              'videoOffsetX': x,
              'screenDisplay': {'enabled': true},
            },
          },
        );
        await fixture.controller.start();
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerScreenDisplay(
              controller: fixture.controller,
              insets: const EdgeInsets.fromLTRB(40, 0, 20, 10),
            ),
          ),
        );
        final actual = tester.getRect(
          find.byKey(const Key('player-screen-video-bounds')),
        );
        // For contain, the safe area intersects the picture, rather than adding
        // its insets to black letterboxing around it a second time.
        final safeExpected = expected.intersect(
          const Rect.fromLTRB(40, 0, 772, 350),
        );
        expect(actual.left, closeTo(safeExpected.left, .01));
        expect(actual.top, closeTo(safeExpected.top, .01));
        expect(actual.right, closeTo(safeExpected.right, .01));
        expect(actual.bottom, closeTo(safeExpected.bottom, .01));
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.controller.close();
        fixture.store.dispose();
      },
    );
  }

  testWidgets(
    'Clock and progress update independently and suspend in the background',
    (tester) async {
      final fixture = PlaybackFixture(
        data: {
          'playbackPreferences': {
            'screenDisplay': {
              'enabled': true,
              'items': ['time', 'network', 'progress'],
            },
          },
        },
      );
      await fixture.controller.start();
      final backend = fixture.current;
      backend.screenInfo = const PlaybackScreenInfo(
        transport: 'direct',
        bytesPerSecond: 2048,
      );
      var now = DateTime(2026, 11, 11, 14, 25, 59);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 844,
            height: 390,
            child: PlayerScreenDisplay(
              controller: fixture.controller,
              now: () => now,
            ),
          ),
        ),
      );
      expect(find.text('时间 14:25:59'), findsOneWidget);
      expect(backend.screenMonitoring, isTrue);
      now = DateTime(2026, 11, 11, 14, 26);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('时间 14:26:00'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(backend.screenMonitoring, isFalse);
      now = DateTime(2026, 11, 11, 14, 30);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('时间 14:26:00'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('时间 14:30:00'), findsOneWidget);
      expect(backend.screenMonitoring, isTrue);
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(
          screenDisplay: fixture.controller.preferences.screenDisplay.withItem(
            PlaybackScreenItem.network,
            false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(backend.screenMonitoring, isFalse);
      expect(find.textContaining('网速'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.controller.close();
      fixture.store.dispose();
    },
  );
}

class _BrightVideoFixture extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final fitted = applyBoxFit(
      BoxFit.contain,
      const Size(16, 9),
      size,
    ).destination;
    final video = Alignment.center.inscribe(fitted, Offset.zero & size);
    canvas.drawRect(video, Paint()..color = const Color(0xfffafafa));
    canvas.drawRect(
      Rect.fromLTWH(video.left, video.top, video.width, fitted.height * .06),
      Paint()..color = const Color(0xffa0ccca),
    );
    final stroke = Paint()
      ..color = const Color(0xffdedede)
      ..strokeWidth = 1;
    for (var i = 1; i < 6; i++) {
      final y = video.top + fitted.height * i / 6;
      canvas.drawLine(
        Offset(video.left + fitted.width * .08, y),
        Offset(video.right - fitted.width * .08, y),
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_BrightVideoFixture oldDelegate) => false;
}
