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

class _Clock extends Stopwatch {
  Duration value = Duration.zero;
  @override
  Duration get elapsed => value;
}

class _Native extends FakeNative {
  _Native(this.clock, this.mode);
  final _Clock clock;
  final String mode;
  int snapshots = 0, removals = 0;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method == 'remove') removals++;
    if (method != 'snapshot') return super.call(method, args);
    snapshots++;
    clock.value += const Duration(seconds: 15);
    final expired = mode.startsWith('refresh') && begins.length == 1;
    final done =
        mode == 'done' || mode.startsWith('refresh') && begins.length > 1;
    if (done) writer = false;
    return {
      'status': expired
          ? 'error'
          : done
          ? 'done'
          : 'running',
      'total': 4,
      'downloaded': done ? 4 : 2,
      'speed': 0,
      'totalConnections': 8,
      'activeConnections': mode == 'wait' || mode == 'queued' ? 0 : 1,
      'aliyun': {
        'limit': begins.last.integer('connections').clamp(1, 4),
        'waitMs': mode == 'wait' ? 60000 : 0,
        'queued': mode == 'queued',
      },
      if (expired) ...{
        'httpCode': 403,
        'retryExhausted': true,
        'errorKind': 'http',
      },
      'path': p.join(cache!, args.str('id'), 'payload.gopeed'),
    };
  }
}

class _Http extends TransferHttp {
  _Http(this.mode);
  final String mode;
  bool forceChanged = false;
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async => Probe(
    RemoteIdentity(
      4,
      forceChanged || mode == 'refreshChanged' && url.endsWith('/fresh')
          ? '"changed"'
          : '"same"',
      null,
    ),
    false,
    rangeSupported: true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late StateStore store;
  late _Native native;
  late _Http http;
  late DownloadManager manager;
  var refreshes = 0;

  Future<void> open(String mode) async {
    root = await Directory.systemTemp.createTemp('aliyun-recovery-');
    store = StateStore.memory({
      'settings': {
        'concurrent': 1,
        'downloadThreadOverrides': {'aliyun': 64},
      },
    });
    native = _Native(_Clock(), mode);
    http = _Http(mode);
    refreshes = 0;
    manager = DownloadManager(
      store: store,
      engine: GopeedEngine(
        native,
        store,
        Vault(store),
        Directory(p.join(root.path, 'native')),
        Directory(p.join(root.path, 'cache')),
      ),
      files: FakeFiles(Directory(p.join(root.path, 'saved'))),
      cleanups: CleanupOutbox(store, FakeHttp()),
      http: http,
      transferClock: () => native.clock,
      refreshSource: (previous) async {
        refreshes++;
        return DownloadSpec.fromJson({
          ...previous.toJson(),
          'url': 'https://fixture.invalid/fresh',
        });
      },
    );
    addTearDown(() async {
      await manager.close();
      manager.dispose();
      http.dio.close(force: true);
      await root.delete(recursive: true);
    });
    await manager.initialize();
  }

  DownloadSpec spec({
    CloudPlatform platform = CloudPlatform.aliyun,
    String account = 'fixture-account-a',
  }) => DownloadSpec(
    url: 'https://fixture.invalid/original',
    fileName: 'fixture.bin',
    expectedSize: 4,
    source: DownloadOrigin(
      BrowseSession(
        platform: platform,
        mode: BrowseMode.personal,
        title: 'fixture',
        rootId: 'root',
        metadata: {'accountId': account},
      ),
      const CloudFile(
        id: 'file',
        name: 'fixture.bin',
        size: 4,
        parentId: 'root',
      ),
      1,
    ).toJson(),
    profile: platform == CloudPlatform.aliyun ? 'aliyun' : platform.key,
  );

  test(
    'Aliyun stalled transfer lowers actual begin limits and retains progress',
    () async {
      await open('stall');
      final id = await manager.enqueue(spec());
      await until(
        () => native.begins.length == 3,
        timeout: const Duration(seconds: 25),
      );
      final atThird = native.snapshots;
      await until(() => native.snapshots >= atThird + 5);
      expect(native.begins.map((b) => b.integer('connections')), [8, 2, 1]);
      expect(native.begins.length, 3);
      expect(native.removals, 1, reason: 'only initial empty cache is removed');
      expect(manager.task(id)!.downloaded, 2);
      expect(manager.task(id)!.status, DownloadStatus.running);
      expect(
        refreshes,
        0,
        reason: 'stalled sockets do not unnecessarily refresh credentials',
      );
      final group = native.begins.first.str('aliyunGroup');
      expect(group, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(native.begins.every((b) => b.str('aliyunGroup') == group), isTrue);
      expect(group, isNot(contains('fixture-account')));
      await manager.pause(id);
    },
  );

  for (final mode in ['wait', 'queued']) {
    test('Aliyun $mode does not cause a false reconnect', () async {
      await open(mode);
      final id = await manager.enqueue(spec());
      await until(() => native.snapshots >= 7);
      expect(native.begins.length, 1);
      expect(
        manager.task(id)!.phase,
        mode == 'wait' ? contains('秒后重试') : contains('等待阿里下载连接'),
      );
      await manager.pause(id);
    });
  }

  for (final platform in [
    CloudPlatform.xunlei,
    CloudPlatform.quark,
    CloudPlatform.uc,
  ]) {
    test(
      '${platform.name} is unaffected by the Aliyun recovery policy',
      () async {
        await open('stall');
        final id = await manager.enqueue(spec(platform: platform));
        await until(() => native.snapshots >= 7);
        expect(native.begins.length, 1);
        expect(native.begins.single.containsKey('aliyunGroup'), isFalse);
        expect(
          native.begins.single.integer('connections'),
          platform == CloudPlatform.xunlei ? equals(8) : greaterThan(8),
        );
        expect(manager.task(id)!.phase, isEmpty);
        await manager.pause(id);
      },
    );
  }

  for (final mode in ['refreshSame', 'refreshChanged']) {
    test(
      'Aliyun expired URL with $mode keeps the existing checkpoint safe',
      () async {
        await open(mode);
        final id = await manager.enqueue(spec());
        await until(
          () => !manager.task(id)!.active && manager.activeCount == 0,
        );
        expect(refreshes, 1);
        expect(native.removedWhileWriting, isFalse);
        if (mode == 'refreshChanged') {
          expect(native.begins.length, 1);
          expect(native.removals, 1);
          expect(manager.task(id)!.downloaded, 2);
          expect(manager.task(id)!.status, DownloadStatus.failed);
          expect(manager.task(id)!.spec.url, endsWith('/original'));
          expect(
            await File(p.join(native.cache!, id, 'payload.gopeed')).exists(),
            isTrue,
          );
        } else {
          expect(native.begins.length, 2);
          expect(native.begins.last.str('url'), endsWith('/fresh'));
          expect(manager.task(id)!.status, DownloadStatus.completed);
          expect(
            await File(manager.task(id)!.savedPath!).readAsBytes(),
            native.content,
          );
        }
      },
    );
  }

  test(
    'Aliyun resume with changed remote identity does not discard bytes',
    () async {
      await open('stall');
      final id = await manager.enqueue(spec());
      await until(() => manager.task(id)!.downloaded == 2);
      await manager.pause(id);
      http.forceChanged = true;
      await manager.resume(id);
      await until(
        () =>
            manager.task(id)!.status == DownloadStatus.failed &&
            manager.activeCount == 0,
      );
      expect(native.begins.length, 1);
      expect(native.removals, 1);
      expect(manager.task(id)!.downloaded, 2);
      expect(
        await File(p.join(native.cache!, id, 'payload.gopeed')).exists(),
        isTrue,
      );
    },
  );

  test(
    'Aliyun account groups are stable across files and isolated between accounts',
    () async {
      await open('done');
      for (final account in ['account-one', 'account-one', 'account-two']) {
        final id = await manager.enqueue(spec(account: account));
        await until(
          () =>
              manager.task(id)!.status == DownloadStatus.completed &&
              manager.activeCount == 0,
        );
      }
      final groups = native.begins.map((b) => b.str('aliyunGroup')).toList();
      expect(groups[0], groups[1]);
      expect(groups[0], isNot(groups[2]));
    },
  );
}
