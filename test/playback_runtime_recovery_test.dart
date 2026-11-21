import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:asterlink/domain/playback.dart';
import 'package:asterlink/playback/external_stream.dart';
import 'package:asterlink/playback/playback_runtime.dart';

import 'player_support.dart';

class _ExternalStream extends ExternalPlaybackStream {
  _ExternalStream(super.source);
  @override
  Future<void> start() async {}
  @override
  String get url => 'http://127.0.0.1:12345/video';
  @override
  Future<void> close() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'runtime failure requests no source or decoder and preserves progress for retry',
    () async {
      var starts = 0;
      final runtime = PlaybackRuntime(
        initialize: () {
          if (++starts == 1) throw TypeError();
          return Future.value();
        },
      );
      final fixture = PlaybackFixture(
        renewable: true,
        initializePlayback: runtime.ensureInitialized,
      );
      addTearDown(fixture.controller.close);
      await fixture.history.save(
        fixture.entries.first.key,
        const PlaybackBookmark(
          position: Duration(minutes: 2),
          duration: Duration(minutes: 10),
          updatedAt: 1,
        ),
      );
      await fixture.controller.start();
      expect(fixture.controller.playbackRuntimeFailed, isTrue);
      expect(fixture.controller.loading, isFalse);
      expect(fixture.controller.sourceError, isNull);
      expect(fixture.controller.error, contains('解析和下载不受影响'));
      expect(fixture.backends, isEmpty);
      expect(fixture.preparations, 0);
      expect(
        fixture.history.bookmark(fixture.entries.first.key)!.position,
        const Duration(minutes: 2),
      );
      await fixture.controller.retry();
      expect(starts, 2);
      expect(fixture.preparations, 1);
      expect(fixture.backends, hasLength(1));
      expect(fixture.controller.ready, isTrue);
      expect(fixture.controller.playbackRuntimeFailed, isFalse);
      expect(fixture.current.openedStart, const Duration(minutes: 2));
    },
  );

  test(
    'an unavailable player still offers a download source and external playback',
    () async {
      final runtime = PlaybackRuntime(
        initialize: () async => throw StateError('missing library'),
      );
      final fixture = PlaybackFixture(
        initializePlayback: runtime.ensureInitialized,
        externalStreamFactory: _ExternalStream.new,
      );
      addTearDown(fixture.controller.close);
      await fixture.controller.start();
      final download = await fixture.controller.acquireForDownload();
      expect(download.fileName, fixture.entries.first.name);
      await fixture.controller.release(download);
      final launched = await fixture.controller.openExternalPlayer((
        url,
        title,
        position,
      ) async {
        expect(url, 'http://127.0.0.1:12345/video');
        expect(title, fixture.entries.first.name);
        return true;
      });
      expect(launched, isTrue);
      expect(fixture.controller.playingExternally, isTrue);
      expect(fixture.backends, isEmpty);
      await fixture.controller.close();
      expect(fixture.leases.values.every((count) => count == 0), isTrue);
    },
  );

  test(
    'leaving during runtime loading does not later prepare or start a decoder',
    () async {
      final pending = Completer<void>();
      final runtime = PlaybackRuntime(initialize: () => pending.future);
      final fixture = PlaybackFixture(
        initializePlayback: runtime.ensureInitialized,
      );
      final starting = fixture.controller.start();
      await Future<void>.delayed(Duration.zero);
      try {
        await fixture.controller.close().timeout(const Duration(seconds: 1));
        await starting;
        expect(runtime.ready, isFalse);
        expect(fixture.backends, isEmpty);
        expect(fixture.preparations, 0);
        pending.complete();
        await runtime.ensureInitialized();
        expect(runtime.ready, isTrue);
        expect(fixture.backends, isEmpty);
        expect(fixture.preparations, 0);
      } finally {
        if (!pending.isCompleted) pending.complete();
        await fixture.controller.close();
      }
    },
  );
}
