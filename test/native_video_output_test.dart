import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
// Exercise the vendored Android controller on the real Windows mpv handle;
// platform Surface operations are mocked, never claimed as device rendering.
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/real.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'support.dart';

class _RecordingNative extends NativePlayer {
  _RecordingNative({this.platformOnly = false})
    : super(configuration: const PlayerConfiguration(libass: true, vo: 'null'));
  final bool platformOnly;
  final properties = <(String, String)>[];
  int seeks = 0;
  void emitVideoParams(VideoParams value) => videoParamsController.add(value);
  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    properties.add((property, value));
    if (!platformOnly) {
      await super.setProperty(
        property,
        value,
        waitForInitialization: waitForInitialization,
      );
    }
  }

  @override
  Future<void> seek(Duration position, {bool synchronized = true}) async {
    seeks++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library =
      Platform.environment['ASTERLINK_MPV_LIBRARY'] ??
      '.local/player-test/libmpv/libmpv-2.dll';
  group(
    'Vendored output and native property traffic',
    () {
      setUpAll(() => MediaKit.ensureInitialized(libmpv: library));
      const channel = MethodChannel('com.alexmercerind/media_kit_video');
      tearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      for (final emulator in [false, true]) {
        test(
          'Android resize retains seek and playback state, emulator=$emulator',
          () async {
            final sizes = <(int, int)>[];
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, (call) async {
                  if (call.method == 'Utils.IsEmulator') return emulator;
                  if (call.method == 'VideoOutputManager.SetSurfaceSize') {
                    final args = call.arguments as Map;
                    sizes.add((
                      int.parse(args['width']),
                      int.parse(args['height']),
                    ));
                  }
                  return null;
                });
            final native = _RecordingNative(platformOnly: true);
            final player = Player(platformPlayer: native);
            try {
              final output =
                  await AndroidVideoController.create(
                        player,
                        const VideoControllerConfiguration(),
                      )
                      as AndroidVideoController;
              expect(
                output.configuration.hwdec,
                emulator ? 'no' : 'mediacodec,mediacodec-copy',
              );
              output.wid.value = 123;
              native.emitVideoParams(
                const VideoParams(dw: 3840, dh: 2160, rotate: 0),
              );
              await until(() => sizes.isNotEmpty);
              await output.setSize(width: 1920, height: 1080);
              expect(sizes.last, (1920, 1080));
              final count = sizes.length;
              await output.setSize(width: 1920, height: 1080);
              expect(sizes.length, count);
              native.properties.clear();
              await output.setSize(width: 960, height: 540);
              expect(
                native.properties,
                containsAllInOrder([
                  ('vo', 'null'),
                  ('android-surface-size', '960x540'),
                  ('wid', '123'),
                  ('vo', 'gpu'),
                ]),
              );
              output.wid.value = 0;
              await output.widListener();
              expect(native.properties.last, ('vo', 'null'));
              output.wid.value = 456;
              await output.widListener();
              expect(native.properties.last, ('vo', 'gpu'));
              expect(native.seeks, 0);
              expect(player.state.playing, isFalse);
              await output.setSize();
              expect(sizes.last, (3840, 2160));
            } finally {
              await player.dispose();
            }
          },
        );
      }
      test(
        'Changing subtitle position only writes sub-pos after initial styling',
        () async {
          final native = _RecordingNative();
          final backend = MediaKitBackend(
            video: false,
            player: Player(platformPlayer: native),
          );
          try {
            await native.setProperty('ao', 'null');
            native.properties.clear();
            await backend.setSubtitlePresentation(
              size: 22,
              height: 1080,
              bottom: .1,
            );
            expect(native.properties, hasLength(9));
            native.properties.clear();
            await backend.setSubtitlePresentation(
              size: 22,
              height: 1080,
              bottom: .2,
            );
            expect(native.properties, [('sub-pos', '80')]);
            native.properties.clear();
            await backend.setSubtitlePresentation(
              size: 22,
              height: 1080,
              bottom: .2,
            );
            expect(native.properties, isEmpty);
          } finally {
            await backend.close();
          }
        },
      );
    },
    skip: !Platform.isWindows || !File(library).existsSync(),
  );
}
