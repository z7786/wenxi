import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/playback_store.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/domain/playback_source.dart';
import 'package:asterlink/domain/torrent.dart';

PlaybackBookmark mark(int seconds, {int stamp = 1}) => PlaybackBookmark(
  position: Duration(seconds: seconds),
  duration: const Duration(minutes: 10),
  updatedAt: stamp,
  name: 'fixture',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Unchanged progress can still enrich missing torrent replay metadata',
    () async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final history = PlaybackStore(store);
      const file = TorrentFile(0, 'movie.mkv', 1000);
      final hash = List.filled(40, 'a').join();
      PlaybackBookmark torrent({bool rich = false}) => PlaybackBookmark(
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 1),
        updatedAt: 1,
        source: PlaybackSource.torrent(
          hash,
          file,
          torrentData: rich ? 'fixture-metadata' : '',
          torrentFiles: rich ? [file] : [],
        ),
      );
      await history.save('one', torrent());
      await history.save('one', torrent(rich: true));
      expect(store.data['playbackTorrents'][hash]['data'], 'fixture-metadata');
      var changes = 0;
      store.addListener(() => changes++);
      await history.save('one', torrent(rich: true));
      expect(changes, 0);
      await history.clearHistory();
      final rich = history.save('one', torrent(rich: true));
      final restored = history.save('one', torrent());
      await Future.wait([rich, restored]);
      expect(store.data['playbackTorrents'][hash]['data'], 'fixture-metadata');
    },
  );
  test(
    'Repeated idle progress does not rewrite history or bump recency',
    () async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final history = PlaybackStore(store);
      var changes = 0;
      store.addListener(() => changes++);
      await history.save('one', mark(10));
      final before = changes;
      await history.save('one', mark(10, stamp: 500));
      expect(changes, before);
      expect(history.bookmark('one')!.updatedAt, 1);
      await history.save('one', mark(10, stamp: 501), touch: true);
      expect(history.bookmark('one')!.updatedAt, 501);
    },
  );

  test(
    'Concurrent stores publish latest progress immediately and coalesce durable writes',
    () async {
      final store = StateStore.memory();
      addTearDown(store.dispose);
      final a = PlaybackStore(store), b = PlaybackStore(store);
      var changes = 0;
      store.addListener(() => changes++);
      final writes = <Future<void>>[];
      for (var i = 1; i <= 40; i++) {
        writes.add((i.isEven ? a : b).save('one', mark(i, stamp: i)));
      }
      expect(b.bookmark('one')!.position, const Duration(seconds: 40));
      await Future.wait(writes);
      expect(changes, lessThanOrEqualTo(2));
      expect(store.data['playbackHistory']['one']['position'], 40000);
    },
  );

  for (final clear in [false, true]) {
    test(
      '${clear ? 'Clear' : 'Remove'} invalidates pending writes without resurrecting history',
      () async {
        final store = StateStore.memory();
        addTearDown(store.dispose);
        final a = PlaybackStore(store), b = PlaybackStore(store);
        final first = a.save('one', mark(10));
        final second = b.save('one', mark(20));
        final removed = clear ? b.clearHistory() : b.remove('one');
        await Future.wait([first, second, removed]);
        expect(a.bookmark('one'), isNull);
        final old = a.save('one', mark(30));
        final removal = clear ? a.clearHistory() : a.remove('one');
        final fresh = b.save('one', mark(50));
        await Future.wait([old, removal, fresh]);
        expect(a.bookmark('one')!.position, const Duration(seconds: 50));
        expect(store.data['playbackHistory']['one']['position'], 50000);
        final deleted = clear ? a.clearHistory() : a.remove('one');
        expect(b.bookmark('one'), isNull);
        final sameProgress = b.save('one', mark(50));
        await Future.wait([deleted, sameProgress]);
        expect(
          store.data['playbackHistory']['one']['position'],
          50000,
          reason:
              'A new playback after deletion must not be deduplicated against the old entry',
        );
      },
    );
  }

  test(
    'Failed persistence propagates to coalesced callers and permits retry',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'player-store-coalesce-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = await StateStore.open(directory);
      addTearDown(store.dispose);
      final history = PlaybackStore(store);
      final blocked = Directory('${store.file!.path}.tmp');
      await blocked.create();
      final first = history.save('one', mark(10));
      final last = history.save('one', mark(20));
      await Future.wait([
        expectLater(first, throwsA(isA<FileSystemException>())),
        expectLater(last, throwsA(isA<FileSystemException>())),
      ]);
      expect(history.bookmark('one'), isNull);
      await blocked.delete();
      await history.save('one', mark(20));
      final reopened = await StateStore.open(directory);
      addTearDown(reopened.dispose);
      expect(
        PlaybackStore(reopened).bookmark('one')!.position,
        const Duration(seconds: 20),
      );
    },
  );
}
