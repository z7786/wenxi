import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/playback/torrent_playback.dart';
import 'support.dart';
import 'player_support.dart';
import 'torrent_test.dart' show testTorrent;

class _StreamingNative extends FakeNative {
  final starts = <Json>[], stopped = <String>[];
  Completer<void>? startBarrier;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'torrentStreamStart') {
      starts.add(args);
      await startBarrier?.future;
      return {
        'id': args.str('id'),
        'url': 'http://127.0.0.1:9988/${args.str('id')}/media.mp4',
        'size': 4,
      };
    }
    if (method == 'torrentStreamStop') {
      stopped.add(args.str('id'));
      return {};
    }
    return super.call(method, args);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppServices services;
  late _StreamingNative native;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('wenxi-bt-playback-');
    native = _StreamingNative();
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory(),
      dataDirectory: root,
      cacheDirectory: Directory('${root.path}/cache'),
      transport: native,
      files: FakeFiles(Directory('${root.path}/saved')),
      http: FakeHttp(),
      platformFeatures: false,
    );
  });
  tearDown(() async {
    await services.close();
    await root.delete(recursive: true);
  });

  test(
    'BT playlist releases the previous stream and keeps URLs out of history',
    () async {
      final backends = <FakePlaybackBackend>[];
      final controller = torrentPlayback(
        services,
        testTorrent,
        testTorrent.files.first,
        backendFactory: (entry, hardware) {
          final backend = FakePlaybackBackend(entry.id, []);
          backends.add(backend);
          return backend;
        },
      );
      try {
        await controller.start();
        expect(controller.error, isEmpty);
        expect(controller.current.torrent, isTrue);
        expect(native.starts.single.integer('torrentIndex'), 0);
        expect(backends.single.openedSource!.isTorrent, isTrue);
        await controller.seek(const Duration(seconds: 75));
        await controller.saveProgress();
        await controller.next();
        expect(
          native.starts.map((request) => request.integer('torrentIndex')),
          [0, 1],
        );
        expect(native.stopped, [native.starts.first.str('id')]);
        expect(
          services.store.data.toString(),
          isNot(contains('127.0.0.1:9988')),
        );
        expect(services.store.data.toString(), isNot(contains('streamId')));
      } finally {
        await controller.close();
      }
      expect(
        native.stopped.toSet(),
        native.starts.map((request) => request.str('id')).toSet(),
      );
      expect(backends.every((backend) => backend.closed), isTrue);
    },
  );

  test(
    'BT hardware fallback retains the same stream until the final decoder closes',
    () async {
      final backends = <FakePlaybackBackend>[];
      final controller = torrentPlayback(
        services,
        testTorrent,
        testTorrent.files.first,
        backendFactory: (entry, hardware) {
          final backend = FakePlaybackBackend(entry.id, [])
            ..hardwareAcceleration = hardware
            ..describeVideo()
            ..failHardwareOpen = true;
          backends.add(backend);
          return backend;
        },
      );
      try {
        await controller.start();
        expect(controller.error, isEmpty);
        expect(controller.usingSoftwareDecoder, isTrue);
        await controller.background(pictureInPicture: false);
        expect(backends.last.videoMonitoring, isFalse);
        controller.foreground();
        expect(backends.last.videoMonitoring, isTrue);

        expect(backends, hasLength(2));
        expect(native.starts, hasLength(1));
        expect(native.stopped, isEmpty);
        expect(
          backends.first.openedSource!.url,
          backends.last.openedSource!.url,
        );
      } finally {
        await controller.close();
      }
      expect(native.stopped, [native.starts.single.str('id')]);
    },
  );

  test('Closing during BT preparation stops the late native stream', () async {
    native.startBarrier = Completer<void>();
    final controller = torrentPlayback(
      services,
      testTorrent,
      testTorrent.files.first,
      backendFactory: (entry, hardware) => FakePlaybackBackend(entry.id, []),
    );
    final starting = controller.start();
    await until(() => native.starts.isNotEmpty);
    final closing = controller.close();
    native.startBarrier!.complete();
    await starting;
    await closing;
    expect(native.stopped, [native.starts.single.str('id')]);
    expect(controller.backend, isNull);
  });

  test(
    'Adding a BT download while watching releases the stream and resumes the queue on exit',
    () async {
      native.finish = false;
      await services.downloads.initialize();
      final controller = torrentPlayback(
        services,
        testTorrent,
        testTorrent.files.first,
        backendFactory: (entry, hardware) => FakePlaybackBackend(entry.id, []),
      );
      try {
        await controller.start();
        await expectLater(
          controller.enqueueDownload((_) async {
            throw StateError('Download queue is unavailable');
          }),
          throwsStateError,
        );
        expect(native.stopped, isEmpty);
        await controller.enqueueDownload((source) async {
          await services.downloads.enqueueTorrent(testTorrent, [
            source.torrent!.integer('index'),
          ]);
        });
        expect(services.downloads.tasks, hasLength(1));
        expect(native.begins, isEmpty);
        expect(services.store.data.toString(), isNot(contains('streamId')));
        expect(
          services.store.data.toString(),
          isNot(contains('127.0.0.1:9988')),
        );
        await controller.close();
        await until(() => native.begins.isNotEmpty);
        expect(native.stopped, [native.starts.single.str('id')]);
        expect(native.begins, hasLength(1));
      } finally {
        await controller.close();
      }
    },
  );

  test(
    'BT playback yields background bandwidth and preserves explicit pauses',
    () async {
      native.finish = false;
      await services.downloads.initialize();
      final ids = await services.downloads.enqueueTorrent(testTorrent, [0]);
      await until(() => native.begins.isNotEmpty);
      final release = await services.downloads.prioritizeTorrentPlayback();
      expect(
        services.downloads.task(ids.single)!.status,
        DownloadStatus.pending,
      );
      expect(services.downloads.activeCount, 0);
      release();
      await until(() => native.begins.length == 2);
      final releaseAgain = await services.downloads.prioritizeTorrentPlayback();
      await services.downloads.pause(ids.single);
      releaseAgain();
      releaseAgain();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        services.downloads.task(ids.single)!.status,
        DownloadStatus.paused,
      );
      expect(native.begins, hasLength(2));
    },
  );
}
