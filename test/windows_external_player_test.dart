import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/playback_device.dart';
import 'package:asterlink/platform/windows_external_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows launcher passes an authenticated proxy URL as one argument',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'external-player-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final executable = File(p.join(directory.path, 'Player with spaces.exe'));
      await executable.writeAsString('fixture');
      final calls = <(String, List<String>)>[];
      final launcher = WindowsExternalPlayer(
        start: (program, arguments) async {
          calls.add((program, arguments));
        },
      )..executable = executable.path;
      final device = NativePlaybackDevice(
        targetPlatform: TargetPlatform.windows,
        windowsExternalPlayer: launcher,
      );
      expect(device.supportsExternalPlayer, isTrue);
      expect(
        await device.openExternalPlayer(
          url: 'http://127.0.0.1:1234/video?name=a&b=2',
          title: 'movie',
          position: Duration.zero,
        ),
        isTrue,
      );
      expect(calls.single.$1, executable.path);
      expect(calls.single.$2, ['http://127.0.0.1:1234/video?name=a&b=2']);
      await launcher.open(
        Uri.file(p.join(directory.path, 'movie with spaces.mkv')).toString(),
      );
      expect(calls.last.$2, [p.join(directory.path, 'movie with spaces.mkv')]);
    },
  );

  test('Missing and invalid programs fail before launch', () async {
    var started = false;
    final launcher = WindowsExternalPlayer(
      start: (_, _) async {
        started = true;
      },
    );
    await expectLater(
      launcher.open('http://127.0.0.1/video'),
      throwsA(isA<AppException>()),
    );
    launcher.executable = 'relative.exe';
    await expectLater(
      launcher.open('http://127.0.0.1/video'),
      throwsA(isA<AppException>()),
    );
    launcher.executable = p.join(
      Directory.systemTemp.path,
      'asterlink-missing.exe',
    );
    await expectLater(
      launcher.open('http://127.0.0.1/video'),
      throwsA(isA<AppException>()),
    );
    expect(started, isFalse);
  });
}
