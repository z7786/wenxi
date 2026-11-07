import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/platform/desktop_platform.dart';
import 'package:asterlink/platform/app_update_installer.dart';
import 'package:asterlink/platform/windows_actions.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'package:asterlink/domain/github_update.dart';
import 'package:asterlink/data/external_player_history.dart';
import 'package:asterlink/data/state_store.dart';
import 'github_update_support.dart';

void main() {
  test(
    'macOS selects the correct DMG and excludes Windows and test builds',
    () {
      RemoteUpdate? parse(List<String> files, String architecture) =>
          GitHubReleaseParser.parse(
            jsonEncode(githubRelease(files: files)),
            repository: githubRepository,
            platform: 'macos',
            architecture: architecture,
          );
      expect(
        parse([
          'asterlink-macos-arm64-test.dmg',
          'asterlink-windows-arm64-setup.exe',
          'asterlink-macos-x64.dmg',
          'asterlink-macos-arm64.zip',
          'asterlink-macos-arm64.dmg',
        ], 'arm64')!.downloadUrl.pathSegments.last,
        'asterlink-macos-arm64.dmg',
      );
      expect(parse(['asterlink-macos-arm64-test.dmg'], 'arm64'), isNull);
      expect(parse(['asterlink-macos-arm64.dmg'], 'x64'), isNull);
    },
  );

  test('macOS external player history preserves Windows settings', () async {
    final store = StateStore.memory({
      'windowsExternalPlayer': r'C:\Players\vlc.exe',
    });
    addTearDown(store.dispose);
    final history = ExternalPlayerHistory(store);
    await history.used('/Applications/VLC.app', platform: 'macos');
    await history.used('/Applications/IINA.app', platform: 'macos');
    await history.used('/Applications/VLC.app', platform: 'macos');
    expect(history.macos, ['/Applications/VLC.app', '/Applications/IINA.app']);
    expect(history.windows, [r'C:\Players\vlc.exe']);
    await expectLater(
      history.used('relative.app', platform: 'macos'),
      throwsA(isA<AppException>()),
    );
  });

  test(
    'macOS helper resolves inside the app bundle without Windows suffix',
    () {
      expect(
        desktopDownloadExecutable(
          '/Applications/文析助手.app/Contents/MacOS/文析助手',
          'macos',
        ),
        '/Applications/文析助手.app/Contents/MacOS/asterlink_gopeed',
      );
      expect(
        () => desktopDownloadExecutable('/app/program', 'linux'),
        throwsA(isA<AppException>()),
      );
      expect(
        desktopDownloadExecutable(r'C:\Apps\AsterLink\app.exe', 'windows'),
        r'C:\Apps\AsterLink\asterlink_gopeed.exe',
      );
    },
  );

  test(
    'macOS update rejects renamed HTML and truncated DMG before opening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'macos-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final installer = AppUpdateInstaller(
        platform: 'macos',
        windows: WindowsActions(supported: false),
      );
      final update = RemoteUpdate(
        '2.2.0',
        220,
        Uri.parse('https://example.test/app.dmg'),
        '',
      );
      Future<DownloadTask> task(String name, List<int> bytes) async {
        final file = File('${directory.path}/$name');
        await file.writeAsBytes(bytes);
        return DownloadTask(
          id: 'macos-update',
          createdAt: 1,
          status: DownloadStatus.completed,
          spec: DownloadSpec(url: 'https://example.test/$name', fileName: name),
          savedPath: file.path,
        );
      }

      expect(
        () async => installer.prepare(
          await task('html.dmg', '<html>error</html>'.codeUnits),
          update,
        ),
        throwsA(isA<AppException>()),
      );
      expect(
        () async => installer.prepare(
          await task('truncated.dmg', 'koly'.codeUnits),
          update,
        ),
        throwsA(isA<AppException>()),
      );
      final image = Uint8List(1024)..setRange(512, 516, 'koly'.codeUnits);
      final valid = await task('app.dmg', image);
      expect(await installer.prepare(valid, update), valid.savedPath);
      expect(AppUpdateInstaller.supportsName('app.exe', 'macos'), isFalse);
      expect(AppUpdateInstaller.supportsName('app.dmg', 'windows'), isFalse);
    },
  );
}
