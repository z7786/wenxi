import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/playback/download_playback.dart';
import 'package:asterlink/playback/recent_playback.dart';
import 'support.dart';
import 'player_support.dart';

class _Probe extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"fixture"', null), false);
}

class _Native extends FakeNative {
  _Native() {
    finish = false;
  }
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    final value = await super.call(method, args);
    if (method == 'snapshot') {
      return {
        ...asJson(value),
        'downloaded': finish ? 4 : 2,
        'readableRanges': finish
            ? [
                [0, 4],
              ]
            : [
                [0, 2],
              ],
      };
    }
    return value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppServices services;
  late _Native native;
  const identity = RemoteIdentity(4, '"fixture"', null);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('wenxi-download-play-');
    native = _Native();
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'tasks': [
          DownloadTask(
            id: 'movie',
            spec: const DownloadSpec(
              url: 'https://example.invalid/video.mp4',
              fileName: 'video.mp4',
            ),
            createdAt: 1,
            status: DownloadStatus.paused,
          ).toJson(),
        ],
      }),
      dataDirectory: root,
      cacheDirectory: Directory('${root.path}/cache'),
      transport: native,
      files: FakeFiles(Directory('${root.path}/saved')),
      http: FakeHttp(),
      transferHttp: _Probe(),
      platformFeatures: false,
    );
    await services.downloads.initialize();
  });
  tearDown(() async {
    await services.close();
    await root.delete(recursive: true);
  });

  test(
    'Readers use written ranges, reject holes and mismatched identities',
    () async {
      final cache = await services.downloads.acquirePlayback('movie');
      try {
        await until(() => services.downloads.task('movie')!.downloaded == 2);
        expect(await cache.read(0, 1, identity), [1, 2]);
        expect((await cache.snapshot())!.identity.canResume(identity), isTrue);
        expect(await cache.readAvailable(0, 3, identity), [1, 2]);
        expect(await cache.readAvailable(2, 3, identity), isNull);
        expect(
          await cache.readAvailable(
            0,
            3,
            const RemoteIdentity(4, '"changed"', null),
          ),
          isNull,
        );
        expect(await cache.read(2, 3, identity), isNull);
        expect(
          await cache.read(0, 1, const RemoteIdentity(4, '"changed"', null)),
          isNull,
        );
        expect(
          await cache.read(0, 1, const RemoteIdentity(4, null, null)),
          isNull,
        );
        await expectLater(
          services.downloads.delete('movie'),
          throwsA(isA<AppException>()),
        );
        expect(native.removedWhileWriting, isFalse);
      } finally {
        await cache.release();
      }
      expect(services.downloads.task('movie')!.active, isTrue);
      await services.downloads.pause('movie');
      await services.downloads.delete('movie');
      expect(services.downloads.task('movie'), isNull);
    },
  );

  test('Completed download keeps cache until its last reader closes', () async {
    final first = await services.downloads.acquirePlayback('movie');
    final second = await services.downloads.acquirePlayback('movie');
    await until(() => services.downloads.task('movie')!.downloaded == 2);
    final file = File(
      '${services.engine.taskDirectory('movie').path}/payload.gopeed',
    );
    native.finish = true;
    await until(
      () =>
          services.downloads.task('movie')!.status ==
              DownloadStatus.completed &&
          services.downloads.activeCount == 0,
    );
    expect(await file.exists(), isTrue);
    expect(await first.read(0, 3, identity), [1, 2, 3, 4]);
    await first.release();
    expect(await file.exists(), isTrue);
    expect(await second.read(0, 3, identity), [1, 2, 3, 4]);
    await second.release();
    expect(await file.exists(), isFalse);
    expect(services.store.data['completedCacheRemovals'], isEmpty);
    final saved = File(services.downloads.task('movie')!.savedPath!);
    expect(await saved.readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'Explicit download pause keeps readable bytes but prevents new network reads',
    () async {
      final cache = await services.downloads.acquirePlayback('movie');
      try {
        await until(() => services.downloads.task('movie')!.downloaded == 2);
        await services.downloads.pause('movie');
        expect(await cache.read(0, 1, identity), [1, 2]);
        await expectLater(
          cache.read(2, 3, identity),
          throwsA(isA<AppException>()),
        );
        expect(services.downloads.task('movie')!.status, DownloadStatus.paused);
      } finally {
        await cache.release();
      }
    },
  );

  test(
    'Hardware retry retains one cache hold and close leaves download running',
    () async {
      final backends = <FakePlaybackBackend>[];
      final controller = downloadPlayback(
        services,
        services.downloads.task('movie')!,
        backendFactory: (entry, hardware) {
          final backend = FakePlaybackBackend(entry.id, [])
            ..hardwareAcceleration = hardware
            ..failHardwareOpen = true;
          backends.add(backend);
          return backend;
        },
      );
      await controller.start();
      expect(controller.error, isEmpty);
      expect(backends, hasLength(2));
      expect(controller.usingSoftwareDecoder, isTrue);
      await controller.seek(const Duration(seconds: 40));
      await controller.saveProgress();
      final history = services.store.data.toString();
      expect(history, contains('downloadId'));
      expect(controller.current.source!.kind, PlaybackSourceKind.download);
      await expectLater(
        services.downloads.delete('movie'),
        throwsA(isA<AppException>()),
      );
      await controller.close();
      expect(services.downloads.task('movie')!.active, isTrue);
      await services.downloads.pause('movie');
      await services.downloads.delete('movie');
    },
  );

  for (final complete in [false, true]) {
    test(
      'Recent download resumes before and after completion ($complete)',
      () async {
        final current = downloadPlayback(
          services,
          services.downloads.task('movie')!,
          backendFactory: (entry, _) => FakePlaybackBackend(entry.id, []),
        );
        await current.start();
        await current.seek(const Duration(seconds: 35));
        await current.saveProgress();
        await current.close();
        await until(() => services.downloads.task('movie')!.downloaded == 2);
        if (complete) {
          native.finish = true;
          await until(
            () =>
                services.downloads.task('movie')!.status ==
                    DownloadStatus.completed &&
                services.downloads.activeCount == 0,
          );
        } else {
          await services.downloads.pause('movie');
        }
        final record = PlaybackStore(services.store).recent.single;
        final restored = await restoreRecentPlayback(
          services,
          record,
          backendFactory: (entry, _) => FakePlaybackBackend(entry.id, []),
        );
        try {
          await restored.start();
          expect(restored.error, isEmpty);
          final backend = restored.backend! as FakePlaybackBackend;
          expect(backend.openedStart, const Duration(seconds: 35));
          expect(
            restored.current.source!.kind,
            complete ? PlaybackSourceKind.local : PlaybackSourceKind.download,
          );
          if (complete) {
            expect(
              backend.openedSource!.url,
              services.downloads.task('movie')!.savedPath,
            );
          } else {
            expect(services.downloads.task('movie')!.active, isTrue);
          }
        } finally {
          await restored.close();
        }
      },
    );
  }

  test('Download history stores stable ID and rejects malformed identity', () {
    final source = PlaybackSource.download('movie', size: 4);
    final restored = PlaybackSource.tryFromJson(source.toJson());
    expect(restored!.downloadId, 'movie');
    expect(restored.label, '边下边播');
    expect(source.toJson().toString(), isNot(contains('https://')));
    expect(
      PlaybackSource.tryFromJson({
        'version': 1,
        'kind': 'download',
        'downloadId': '../movie',
      }),
      isNull,
    );
  });
}
