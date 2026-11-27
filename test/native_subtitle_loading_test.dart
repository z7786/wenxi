import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/playback/media_backend.dart';
import 'package:asterlink/playback/subtitle_files.dart';
import 'player_support.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = [
    Platform.environment['ASTERLINK_MPV_LIBRARY'],
    '.local/player-test/libmpv/libmpv-2.dll',
  ].whereType<String>().where((path) => File(path).existsSync()).firstOrNull;

  group(
    'Real libmpv subtitle loading',
    () {
      late Directory root;
      late Player player;
      late MediaKitBackend backend;
      setUpAll(() => MediaKit.ensureInitialized(libmpv: library));
      setUp(() async {
        root = await Directory.systemTemp.createTemp(
          'asterlink-player-native-subtitle-',
        );
        player = Player(configuration: const PlayerConfiguration(vo: 'null'));
        await (player.platform as NativePlayer).setProperty('ao', 'null');
        backend = MediaKitBackend(video: false, player: player);
        await backend.open(
          DownloadSpec(
            url: File('test/fixtures/player-sample.mkv').absolute.path,
            fileName: 'sample.mkv',
          ),
          Duration.zero,
        );
        await until(() => player.state.duration.inSeconds >= 8);
      });
      tearDown(() async {
        await backend.close();
        await removePlayerFixture(root);
      });

      for (final gbk in [false, true]) {
        test(
          'A ${gbk ? 'GBK' : 'UTF-8'} subtitle in a Chinese path with spaces and percent signs really loads',
          () async {
            final file =
                await SubtitleFiles(Directory('${root.path}/中文字幕 100%')).stage(
                  '01.srt',
                  Stream.value(
                    gbk
                        ? [
                            ...ascii.encode(
                              '1\n00:00:00,000 --> 00:00:08,000\n',
                            ),
                            0xd6,
                            0xd0,
                            0xce,
                            0xc4,
                            0xd7,
                            0xd6,
                            0xc4,
                            0xbb,
                            10,
                          ]
                        : utf8.encode(
                            '1\n00:00:00,000 --> 00:00:08,000\n中文字幕\n',
                          ),
                  ),
                );
            await backend.setSubtitleTrack(
              SubtitleTrack.uri(file.uri.toString(), title: '网盘字幕'),
            );
            await backend.play();
            await backend.seek(const Duration(seconds: 1));
            await until(() => player.state.subtitle.join().contains('中文字幕'));
            expect(player.state.subtitle.join(), isNot(contains('\ufffd')));
            expect(backend.failure, isNull);
          },
        );
      }

      test(
        'A native subtitle load failure cannot publish a successful selection and permits retry',
        () async {
          await backend.setSubtitleTrack(SubtitleTrack.no());
          await backend.play();
          final missing = File('${root.path}/missing.srt');
          final track = SubtitleTrack.uri(
            missing.uri.toString(),
            title: 'missing',
          );
          await expectLater(backend.setSubtitleTrack(track), throwsStateError);
          expect(player.state.track.subtitle.id, 'no');
          expect(
            await (player.platform as NativePlayer).getProperty('sid'),
            'no',
          );
          expect(backend.failure, isNull);
          expect(player.state.playing, isTrue);
          await missing.writeAsString(
            '1\n00:00:00,000 --> 00:00:08,000\n重试成功\n',
          );
          await backend.setSubtitleTrack(track);
          await backend.seek(const Duration(seconds: 1));
          await until(() => player.state.subtitle.join().contains('重试成功'));
          expect(backend.failure, isNull);
        },
      );
    },
    skip: library == null
        ? 'Requires the pinned Windows libmpv runtime.'
        : false,
  );
}
