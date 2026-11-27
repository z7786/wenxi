import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/github_update_service.dart';
import 'package:asterlink/data/remote_control_http.dart';
import 'package:asterlink/domain/github_update.dart';
import 'package:asterlink/domain/remote_control.dart';
import 'github_update_support.dart';
import 'remote_control_support.dart';

void main() {
  test('Public builds have no default update repository', () async {
    final fetcher = FakeControlFetcher();
    final source = GitHubUpdateService(
      platform: 'android',
      architecture: 'arm64',
      fetcher: fetcher,
    );
    addTearDown(source.close);
    expect(source.configured, isFalse);
    await expectLater(source.check(), throwsStateError);
    expect(fetcher.calls, isEmpty);
  });

  RemoteUpdate? parse(
    Json data, {
    String platform = 'android',
    String architecture = 'arm64',
  }) => GitHubReleaseParser.parse(
    jsonEncode(data),
    repository: githubRepository,
    platform: platform,
    architecture: architecture,
  );

  test(
    'Release fields become an ordinary update with an independent identity',
    () {
      final update = parse(githubRelease()..['force'] = true)!;
      expect(update.version, '0.6.0');
      expect(update.build, 54);
      expect(update.notes, '更新说明\n修复已知问题');
      expect(update.force, isFalse);
      expect(update.releaseKey, contains('github:z7786/wenxi:android:arm64:'));
      expect(
        update.downloadUrl.pathSegments.last,
        endsWith('android-arm64.apk'),
      );
    },
  );

  for (final entry in {
    'arm64': 'arm64-v8a',
    'arm': 'armeabi-v7a',
    'x64': 'x86_64',
    'x86': 'x86',
  }.entries) {
    test('Android selects its own ABI: ${entry.key}', () {
      final data = githubRelease(
        files: [
          'wenxi-windows-x64.exe',
          'wenxi-universal.apk',
          'wenxi-armeabi-v7a.apk',
          'wenxi-arm64-v8a.apk',
          'wenxi-x86_64.apk',
          'wenxi-x86.apk',
        ],
      );
      expect(
        parse(data, architecture: entry.key)!.downloadUrl.pathSegments.last,
        'wenxi-${entry.value}.apk',
      );
    });
  }

  test('Windows chooses a compatible installer before the same-ABI ZIP', () {
    final data = githubRelease(
      files: [
        'wenxi-windows-arm64-setup.exe',
        'wenxi-windows-x64.zip',
        'wenxi-windows-x64-setup.exe',
        'wenxi-arm64.apk',
      ],
    );
    expect(
      parse(
        data,
        platform: 'windows',
        architecture: 'x64',
      )!.downloadUrl.pathSegments.last,
      'wenxi-windows-x64-setup.exe',
    );
  });

  test(
    'Generic packages are fallbacks; explicit incompatible ABIs are rejected',
    () {
      expect(parse(githubRelease(files: ['app-release.apk']))?.build, 54);
      expect(parse(githubRelease(files: ['app-x86_64.apk'])), isNull);
      expect(
        parse(
          githubRelease(files: ['source.zip', 'linux-x64.tar.gz']),
          platform: 'windows',
          architecture: 'x64',
        ),
        isNull,
      );
      expect(
        parse(
          githubRelease(files: ['wenxi-win64.exe']),
          platform: 'windows',
          architecture: 'arm64',
        ),
        isNull,
      );
    },
  );

  test(
    'A plain version tag reads a matching build number from the selected asset',
    () {
      final update = parse(githubRelease(tag: 'v0.6.0'))!;
      expect(update.build, 54);
      expect(parse(githubRelease(tag: 'v0.6.0+55')), isNull);
      expect(parse(githubRelease(tag: 'v0.7.0')), isNull);
      expect(
        parse(
          githubRelease(
            tag: 'v0.6.0',
            files: ['wenxi-0.6.0+54-arm64.apk', 'wenxi-0.6.0+55-arm64.apk'],
          ),
        )!.build,
        55,
      );
    },
  );

  test('A tag without build metadata does not invent a build number', () {
    final update = parse(githubRelease(tag: 'v0.6.0', files: ['app.apk']))!;
    expect(update.build, 0);
    expect(GitHubReleaseParser.newerThan(update, '0.5.0+53', 53), isTrue);
    expect(GitHubReleaseParser.newerThan(update, '0.6.0+54', 54), isFalse);
  });

  for (final (version, build, current, currentBuild, expected) in [
    ('0.5.10', 54, '0.5.9+53', 53, true),
    ('0.5.0', 54, '0.5.0+53', 53, true),
    ('0.5.0', 53, '0.5.0+53', 53, false),
    ('0.4.9', 99, '0.5.0+53', 53, false),
    ('0.6.0', 52, '0.5.0+53', 53, false),
    ('0.6.0', 0, '0.5.0+53', 53, true),
  ]) {
    test('Update ordering $version+$build against $current', () {
      expect(
        GitHubReleaseParser.newerThan(
          RemoteUpdate(version, build, Uri.https('github.com'), ''),
          current,
          currentBuild,
        ),
        expected,
      );
    });
  }

  test('Drafts, prereleases and non-version tags cannot trigger an update', () {
    for (final flag in ['draft', 'prerelease']) {
      expect(parse(githubRelease()..[flag] = true), isNull);
    }
    for (final tag in ['latest', 'v0.6.0-beta', 'v0.6.0+0']) {
      expect(parse(githubRelease(tag: tag, files: ['app.apk'])), isNull);
    }
    expect(() => parse({'message': 'API unavailable'}), throwsFormatException);
  });

  test(
    'Only an asset URL belonging to this repository, release and file is accepted',
    () {
      for (final url in [
        'http://github.com/z7786/wenxi/releases/download/v0.6.0+54/app.apk',
        'https://github.com.evil.test/z7786/wenxi/releases/download/v0.6.0+54/app.apk',
        'https://github.com/another/repo/releases/download/v0.6.0+54/app.apk',
        'https://github.com/z7786/wenxi/releases/download/v0.5.0/app.apk',
        'https://github.com/z7786/wenxi/releases/download/v0.6.0+54/different.apk',
      ]) {
        final data = githubRelease(files: ['app.apk']);
        (data['assets'] as List).first['browser_download_url'] = url;
        expect(parse(data), isNull, reason: url);
      }
    },
  );

  test(
    'Successful checks are cached between automatic primary retries',
    () async {
      var now = controlNow;
      final http = FakeControlFetcher(githubRelease());
      final source = GitHubUpdateService(
        repository: githubRepository,

        platform: 'android',
        architecture: 'arm64',
        fetcher: http,
        clock: () => now,
      );
      addTearDown(source.close);
      expect(http.calls, isEmpty);
      await source.check();
      await source.check();
      expect(
        http.calls.single.toString(),
        'https://api.github.com/repos/z7786/wenxi/releases/latest',
      );
      now = now.add(GitHubUpdateService.refreshInterval);
      await source.check();
      expect(http.calls, hasLength(2));
      await source.check(force: true);
      expect(http.calls, hasLength(3));
    },
  );

  test(
    '404 means no published release; rate limiting remains a failed check',
    () async {
      var now = controlNow;
      final http = FakeControlFetcher()
        ..respond = (_) =>
            throw const ControlAccessException('Not found', statusCode: 404);
      final source = GitHubUpdateService(
        repository: githubRepository,

        platform: 'android',
        architecture: 'arm64',
        fetcher: http,
        clock: () => now,
      );
      addTearDown(source.close);
      expect(await source.check(), isNull);
      http.respond = (_) =>
          throw const ControlAccessException('Rate limited', statusCode: 403);
      await expectLater(source.check(force: true), throwsFormatException);
      await expectLater(source.check(), throwsFormatException);
      expect(http.calls, hasLength(2));
      now = now.add(GitHubUpdateService.failureInterval);
      await expectLater(source.check(), throwsFormatException);
      expect(http.calls, hasLength(3));
    },
  );

  test(
    'Concurrent checks share a request and a close discards late results',
    () async {
      final waiting = Completer<String>();
      final http = FakeControlFetcher()..respond = (_) => waiting.future;
      final source = GitHubUpdateService(
        repository: githubRepository,

        platform: 'android',
        architecture: 'arm64',
        fetcher: http,
      );
      final first = source.check();
      final second = source.check(force: true);
      expect(identical(first, second), isTrue);
      final checked = expectLater(first, throwsStateError);
      source.close();
      waiting.complete(jsonEncode(githubRelease()));
      await checked;
      expect(http.calls, hasLength(1));
      expect(http.closed, isTrue);
    },
  );

  const digest =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const installer = 'asterlink-0.6.0+54-windows-x64-setup.exe';

  test('GitHub asset digest and byte size describe the selected package', () {
    final release =
        jsonDecode(jsonEncode(githubRelease(files: [installer]))) as Json;
    (release['assets'] as List).single['digest'] =
        'sha256:${digest.toUpperCase()}';
    final update = parse(release, platform: 'windows', architecture: 'x64')!;
    expect(update.packageSha256, digest);
    expect(update.packageSize, 123456);
    for (final invalid in ['sha256:short', 'md5:$digest', null, 123]) {
      (release['assets'] as List).single['digest'] = invalid;
      expect(
        parse(release, platform: 'windows', architecture: 'x64')!.packageSha256,
        isEmpty,
      );
    }
  });

  test('Checksum manifests match the complete exact file name', () {
    expect(
      GitHubReleaseParser.checksumFor(
        '$digest  $installer.old\n${digest.toUpperCase()} *$installer\r\n'
        '$digest  $installer\n',
        installer,
      ),
      digest,
    );
    for (final name in [
      'prefix-$installer',
      installer.toUpperCase(),
      './$installer',
    ]) {
      expect(
        GitHubReleaseParser.checksumFor('$digest  $name\n', installer),
        isEmpty,
      );
    }
    expect(
      () => GitHubReleaseParser.checksumFor(
        '$digest  $installer\n${'a' * 64}  $installer\n',
        installer,
      ),
      throwsFormatException,
    );
  });

  test(
    'Only the checksum asset from the selected release is fetched',
    () async {
      final release = githubRelease(files: [installer, 'SHA256SUMS.txt']);
      final package = parse(release, platform: 'windows', architecture: 'x64')!;
      final expected = package.downloadUrl.replace(
        pathSegments: [
          ...package.downloadUrl.pathSegments.take(5),
          'SHA256SUMS.txt',
        ],
      );
      expect(
        GitHubReleaseParser.checksumUrl(
          jsonEncode(release),
          package.downloadUrl,
        ),
        expected,
      );
      final manifest = (release['assets'] as List).last as Map;
      for (final invalid in [
        expected.replace(host: 'images.example.test').toString(),
        expected.toString().replaceFirst('v0.6.0+54', 'v0.5.0+53'),
        '${expected.toString()}?token=wrong',
      ]) {
        manifest['browser_download_url'] = invalid;
        expect(
          GitHubReleaseParser.checksumUrl(
            jsonEncode(release),
            package.downloadUrl,
          ),
          isNull,
        );
      }
      manifest['browser_download_url'] = expected.toString();
      final http = FakeControlFetcher()
        ..respond = (uri) =>
            uri == expected ? '$digest  $installer\n' : jsonEncode(release);
      final source = GitHubUpdateService(
        repository: githubRepository,
        platform: 'windows',
        architecture: 'x64',
        fetcher: http,
      );
      addTearDown(source.close);
      final checked = (await source.check())!;
      expect(checked.packageSha256, digest);
      expect(checked.packageSize, package.packageSize);
      expect(http.calls.last, expected);
      await source.check();
      expect(http.calls, hasLength(2));
    },
  );

  test('An asset digest needs no additional manifest request', () async {
    final release = githubRelease(files: [installer, 'SHA256SUMS.txt']);
    (release['assets'] as List).first['digest'] = 'sha256:$digest';
    final http = FakeControlFetcher(release);
    final source = GitHubUpdateService(
      repository: githubRepository,
      platform: 'windows',
      architecture: 'x64',
      fetcher: http,
    );
    addTearDown(source.close);
    expect((await source.check())!.packageSha256, digest);
    expect(http.calls, hasLength(1));
  });

  test(
    'A failed checksum fetch cannot return a partially checked update',
    () async {
      final release = githubRelease(files: [installer, 'SHA256SUMS.txt']);
      final http = FakeControlFetcher()
        ..respond = (uri) {
          if (uri.path.endsWith('SHA256SUMS.txt')) {
            throw const ControlAccessException(
              'Checksum unavailable',
              statusCode: 503,
            );
          }
          return jsonEncode(release);
        };
      final source = GitHubUpdateService(
        repository: githubRepository,
        platform: 'windows',
        architecture: 'x64',
        fetcher: http,
      );
      addTearDown(source.close);
      await expectLater(source.check(), throwsFormatException);
      await expectLater(source.check(), throwsFormatException);
      expect(http.calls, hasLength(2));
      http.respond = (uri) => uri.path.endsWith('SHA256SUMS.txt')
          ? '$digest  $installer\n'
          : jsonEncode(release);
      expect((await source.check(force: true))!.packageSha256, digest);
    },
  );

  test('Closing during checksum download discards its late response', () async {
    final release = githubRelease(files: [installer, 'SHA256SUMS.txt']);
    final manifest = Completer<String>();
    final http = FakeControlFetcher()
      ..respond = (uri) => uri.path.endsWith('SHA256SUMS.txt')
          ? manifest.future
          : jsonEncode(release);
    final source = GitHubUpdateService(
      repository: githubRepository,
      platform: 'windows',
      architecture: 'x64',
      fetcher: http,
    );
    final pending = source.check();
    final failed = expectLater(pending, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(http.calls, hasLength(2));
    source.close();
    manifest.complete('$digest  $installer\n');
    await failed;
    expect(http.closed, isTrue);
  });
}
