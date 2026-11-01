import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'support.dart';

const _total = 128 * 1024 * 1024;

class _Clock extends Stopwatch {
  Duration value = Duration.zero;
  @override
  Duration get elapsed => value;
}

class _SlowNative extends FakeNative {
  _SlowNative(this.clock);
  final _Clock clock;
  int downloaded = 1024 * 1024;
  int removals = 0, pauses = 0;
  final offsets = <int>[];
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'snapshot') {
      clock.value += const Duration(seconds: 15);
      downloaded += 128 * 1024;
      return {
        'status': 'running',
        'total': _total,
        'downloaded': downloaded,
        'speed': 128 * 1024,
        'totalConnections': 1,
        'activeConnections': 1,
      };
    }
    if (method == 'begin') {
      expect(writer, isFalse, reason: 'old writer must stop before reconnect');
      offsets.add(downloaded);
    }
    if (method == 'remove') removals++;
    final result = await super.call(method, args);
    if (method == 'pause') pauses++;
    return result;
  }
}

class _Http extends TransferHttp {
  _Http(this.changedIdentity);
  final bool changedIdentity;
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async => Probe(
    RemoteIdentity(
      _total,
      changedIdentity && url.endsWith('/fresh') ? '"changed"' : '"same"',
      null,
    ),
    false,
    rangeSupported: true,
    host: 'fixture.baidupcs.com',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final outcome in [
    'fresh',
    'failed',
    'changed',
    'ordinary',
    'direct',
    'direct-refresh',
  ]) {
    test(
      'slow recovery preserves checkpoint when refresh is $outcome',
      () async {
        final directory = await Directory.systemTemp.createTemp('baidu-slow-');
        final native = _SlowNative(_Clock());
        // The manager and native fixture share the same monotonic timeline.
        final transferClock = native.clock;
        final store = StateStore.memory({
          'settings': {
            'concurrent': 1,
            if (outcome == 'direct-refresh')
              'downloadThreadOverrides': {'baidu_direct': 5},
          },
        });
        final http = _Http(outcome == 'changed');
        final engine = GopeedEngine(
          native,
          store,
          Vault(store),
          Directory(p.join(directory.path, 'native')),
          Directory(p.join(directory.path, 'cache')),
        );
        var refreshes = 0;
        final manager = DownloadManager(
          store: store,
          engine: engine,
          files: FakeFiles(Directory(p.join(directory.path, 'saved'))),
          cleanups: CleanupOutbox(store, FakeHttp()),
          http: http,
          transferClock: () => transferClock,
          refreshSource: (previous) async {
            refreshes++;
            if (outcome == 'failed') {
              throw const AppException('temporary failure');
            }
            return DownloadSpec.fromJson({
              ...previous.toJson(),
              'url': 'https://fixture.baidupcs.com/fresh',
              'profile': switch (outcome) {
                'ordinary' => 'baidu',
                'direct' || 'direct-refresh' => 'baidu_direct',
                _ => 'baidu_preview',
              },
            });
          },
        );
        addTearDown(() async {
          await manager.close();
          manager.dispose();
          http.dio.close(force: true);
          await directory.delete(recursive: true);
        });
        await manager.initialize();
        final origin = DownloadOrigin(
          const BrowseSession(
            platform: CloudPlatform.baidu,
            mode: BrowseMode.personal,
            title: 'fixture',
            rootId: '/',
          ),
          const CloudFile(
            id: '1',
            name: 'fixture.bin',
            size: _total,
            parentId: '/',
          ),
          1,
        );
        final id = await manager.enqueue(
          DownloadSpec(
            url: 'https://fixture.baidupcs.com/original',
            fileName: 'fixture.bin',
            expectedSize: _total,
            source: origin.toJson(),
            profile: outcome == 'direct-refresh'
                ? 'baidu_direct'
                : 'baidu_preview',
          ),
        );
        await until(() => native.begins.length == 3);
        final atThird = native.downloaded;
        await until(() => native.downloaded >= atThird + 10 * 128 * 1024);
        expect(native.begins.length, 3, reason: 'two recoveries maximum');
        expect(refreshes, 1);
        expect(native.pauses, 2);
        expect(
          native.removals,
          1,
          reason: 'only initial empty cache is removed',
        );
        expect(native.offsets[1], greaterThan(native.offsets[0]));
        expect(native.offsets[2], greaterThan(native.offsets[1]));
        expect(
          native.begins.map((b) => b.integer('connections')),
          outcome == 'direct-refresh'
              ? [5, 5, 5]
              : outcome == 'direct'
              ? [8, 8, 3]
              : [8, 8, 8],
        );
        expect(native.begins[1].str('url'), endsWith('/original'));
        expect(
          native.begins[2].str('url'),
          endsWith(
            ['fresh', 'direct', 'direct-refresh'].contains(outcome)
                ? '/fresh'
                : '/original',
          ),
        );
        if (outcome.startsWith('direct')) {
          expect(manager.task(id)!.spec.profile, 'baidu_direct');
        }
        expect(manager.task(id)!.status, DownloadStatus.running);
        await manager.pause(id);
        expect(manager.task(id)!.status, DownloadStatus.paused);
      },
    );
  }
}
