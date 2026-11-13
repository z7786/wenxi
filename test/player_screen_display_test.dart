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
    testWidgets('All screen data stays in separate screen corners at $size', (
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
      final viewport = tester.getRect(
        find.byKey(const Key('player-screen-viewport-bounds')),
      );
      expect(viewport, Offset.zero & size);
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
        expect(region.left, greaterThanOrEqualTo(viewport.left));
        expect(region.right, lessThanOrEqualTo(viewport.right));
        expect(region.top, greaterThanOrEqualTo(viewport.top));
        expect(region.bottom, lessThanOrEqualTo(viewport.bottom));
        regions[id] = region;
      }
      expect(regions['top-left']!.left, closeTo(television ? 48 : 12, .1));
      expect(regions['top-left']!.top, closeTo(television ? 27 : 12, .1));
      expect(
        regions['top-right']!.right,
        closeTo(size.width - (television ? 48 : 12), .1),
      );
      expect(
        regions['bottom-left']!.bottom,
        closeTo(size.height - (television ? 27 : 12), .1),
      );
      expect(
        regions['bottom-right']!.right,
        closeTo(size.width - (television ? 48 : 12), .1),
      );
      for (final (corner, line) in [
        ('top-left', 'resolution'),
        ('top-right', 'time'),
        ('bottom-left', 'progress'),
        ('bottom-right', 'network'),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(Key('player-screen-region-$corner')),
            matching: find.byKey(Key('player-screen-line-$line')),
          ),
          findsOneWidget,
        );
      }
      for (final id in [
        'title',
        'resolution',
        'time',
        'network',
        'progress',
        'video',
        'audio',
        'parameters',
        'buffer',
        'dropped',
      ]) {
        final outline = tester.getRect(
          find.byKey(Key('player-screen-outline-$id')),
        );
        final fill = tester.getRect(find.byKey(Key('player-screen-line-$id')));
        expect(
          outline,
          fill,
          reason: '$id outline and text must share wrapping',
        );
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
      expect(find.text('20:20:22'), findsOneWidget);
      expect(find.text('2.0 KB/s'), findsOneWidget);
      expect(find.text('1280 × 720'), findsOneWidget);
      expect(find.text('00:01 / 02:08 · 0.8%'), findsOneWidget);
      expect(find.text('1× · mediacodec-copy'), findsOneWidget);
      expect(find.text('90.0 s'), findsOneWidget);
      expect(find.text('0 / 0 帧'), findsOneWidget);
      expect(find.text('H264 · 25 fps'), findsOneWidget);
      expect(find.text('AAC · 44.1 kHz · 1 声道 · 68.41 kbps'), findsOneWidget);
      expect(
        find.textContaining(
          RegExp(r'^(时间|网速|分辨率|进度|播放 |视频 |音频 |缓冲 |解码丢帧|输出丢帧)'),
        ),
        findsNothing,
      );
      final parameters = tester.getRect(
        find.byKey(const Key('player-screen-line-parameters')),
      );
      expect(parameters.width, lessThanOrEqualTo(viewport.width / 2));
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

  for (final (fit, aspect, scale, x) in [
    (PlaybackFit.contain, 0.0, 1.0, 0.0),
    (PlaybackFit.cover, 0.0, 1.0, 0.0),
    (PlaybackFit.stretch, 0.0, 1.0, 0.0),
    (PlaybackFit.contain, 1.0, 1.0, 0.0),
    (PlaybackFit.contain, 0.0, .5, .2),
    (PlaybackFit.cover, 0.0, 3.0, 1.0),
  ]) {
    testWidgets(
      'Screen corners ignore video fit=$fit aspect=$aspect scale=$scale offset=$x',
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
          find.byKey(const Key('player-screen-viewport-bounds')),
        );
        const safeExpected = Rect.fromLTRB(40, 0, 772, 350);
        expect(actual.left, closeTo(safeExpected.left, .01));
        expect(actual.top, closeTo(safeExpected.top, .01));
        expect(actual.right, closeTo(safeExpected.right, .01));
        expect(actual.bottom, closeTo(safeExpected.bottom, .01));
        expect(
          tester
              .getRect(find.byKey(const Key('player-screen-region-top-left')))
              .topLeft,
          const Offset(52, 12),
        );
        expect(
          tester
              .getRect(
                find.byKey(const Key('player-screen-region-bottom-right')),
              )
              .bottomRight,
          const Offset(760, 338),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await fixture.controller.close();
        fixture.store.dispose();
      },
    );
  }

  testWidgets(
    'Screen text switches between aligned black outlines and background',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = PlaybackFixture(
        suppliedEntries: const [
          PlaybackEntry(
            id: 'long-title',
            key: 'long-title',
            name: '西游记修复版 · 一段需要在窄屏换行的中文标题.mp4',
            video: true,
          ),
        ],
        data: {
          'playbackPreferences': {
            'screenDisplay': {'enabled': true},
          },
        },
      );
      await fixture.controller.start();
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: fixtureFont ? 'FixtureUI' : null),
          home: PlayerScreenDisplay(controller: fixture.controller),
        ),
      );
      await render();
      final title = find.byKey(const Key('player-screen-line-title'));
      final outline = find.byKey(const Key('player-screen-outline-title'));
      final region = find.byKey(const Key('player-screen-region-top-left'));
      expect(outline, findsOneWidget);
      expect(tester.widget<Container>(region).decoration, isNull);
      final stroke = tester.widget<RichText>(outline);
      expect(stroke.text.style!.foreground!.color, Colors.black);
      expect(stroke.text.style!.foreground!.style, PaintingStyle.stroke);
      expect(tester.getRect(outline), tester.getRect(title));
      final semantics = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(fixture.controller.current.name),
        findsOneWidget,
      );
      semantics.dispose();
      final before = fixture.current;
      await fixture.controller.updatePreferences(
        fixture.controller.preferences.copyWith(
          screenDisplay: fixture.controller.preferences.screenDisplay.copyWith(
            style: PlaybackScreenStyle.background,
          ),
        ),
      );
      await render();
      expect(outline, findsNothing);
      expect(
        (tester.widget<Container>(region).decoration as BoxDecoration).color,
        const Color(0x99000000),
      );
      expect(fixture.current, same(before));
      expect(
        fixture.history.preferences.screenDisplay.style,
        PlaybackScreenStyle.background,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.controller.close();
      fixture.store.dispose();
    },
  );

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
      expect(find.text('14:25:59'), findsOneWidget);
      expect(backend.screenMonitoring, isTrue);
      now = DateTime(2026, 11, 11, 14, 26);
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('14:26:00'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(backend.screenMonitoring, isFalse);
      now = DateTime(2026, 11, 11, 14, 30);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('14:26:00'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('14:30:00'), findsOneWidget);
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
      expect(find.byKey(const Key('player-screen-line-network')), findsNothing);
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
