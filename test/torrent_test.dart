import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/http.dart' show RequestScope;
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/torrent.dart';
import 'package:asterlink/download/torrent_session.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'support.dart';

const _hash = '0123456789012345678901234567890123456789';
const _data = '${torrentDataPrefix}Zml4dHVyZQ==';
const testTorrent = TorrentInfo(_hash, '合集', _data, [
  TorrentFile(0, '合集/第一集.mp4', 4),
  TorrentFile(1, '合集/第二集.mp4', 4),
], pieceLength: 16384);
final testTorrentJson = <String, dynamic>{
  'hash': _hash,
  'name': '合集',
  'data': _data,
  'pieceLength': 16384,
  'files': [
    {'index': 0, 'path': '合集/第一集.mp4', 'size': 4},
    {'index': 1, 'path': '合集/第二集.mp4', 'size': 4},
  ],
};

class TorrentTestNative extends FakeNative {
  String metadataStatus = 'ready';
  Json? resolvedRequest;
  @override
  Future<Object?> call(String method, [Json args = const {}]) async {
    if (method.startsWith('torrent')) {
      calls.add(method);
      if (method == 'torrentResolve') resolvedRequest = args;
      if (method == 'torrentMetadata') {
        return {
          'status': metadataStatus,
          'info': testTorrentJson,
          'error': metadataStatus == 'error' ? '没有找到可用做种者' : '',
        };
      }
      return null;
    }
    return super.call(method, args);
  }
}

class TorrentTestHttp extends TransferHttp {
  int probes = 0;
  List<Uint8List>? chunks;
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async {
    probes++;
    throw StateError('BT must not use the HTTP probe');
  }

  @override
  Future<Response<ResponseBody>> stream(
    String url,
    Map<String, String> h, {
    CancelToken? cancel,
  }) async => Response(
    requestOptions: RequestOptions(path: url),
    statusCode: 200,
    data: ResponseBody(
      Stream.fromIterable(
        chunks ?? [Uint8List.fromList(utf8.encode('fixture'))],
      ),
      200,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppServices services;
  late TorrentTestNative native;
  late TorrentTestHttp http;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('aster-bt-');
    native = TorrentTestNative();
    http = TorrentTestHttp();
    services = AppServices(
      controlEnabled: false,
      store: StateStore.memory({
        'settings': {'concurrent': 3},
      }),
      dataDirectory: root,
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      transport: native,
      files: FakeFiles(Directory(p.join(root.path, 'saved'))),
      transferHttp: http,
      http: FakeHttp(),
      platformFeatures: false,
    );
    await services.downloads.initialize();
  });
  tearDown(() async {
    await services.close();
    await root.delete(recursive: true);
  });
  for (final count in [1001, maxTorrentFiles]) {
    test('All $count BT files can be queued from one selection', () async {
      final release = await services.downloads.prioritizeTorrentPlayback();
      final info = TorrentInfo(
        _hash,
        '大合集',
        _data,
        List.generate(count, (i) => TorrentFile(i, '大合集/$i.mp4', 4)),
        pieceLength: 16384,
      );
      try {
        final ids = await services.downloads.enqueueTorrent(
          info,
          List.generate(count, (i) => count - 1 - i),
        );
        expect(ids.toSet(), hasLength(count));
        expect(services.downloads.tasks, hasLength(count));
        expect(
          ids.map(
            (id) => services.downloads.task(id)!.spec.torrent!.integer('index'),
          ),
          List.generate(count, (i) => i),
        );
        expect(services.store.data.list('tasks'), hasLength(count));
        expect(services.store.data.obj('torrents').keys, [_hash]);
        expect(native.begins, isEmpty);
        expect(http.probes, 0);
        await services.downloads.pauseAll();
      } finally {
        release();
      }
    });
  }

  test(
    'Cancelling a large BT selection does not leave partial queue entries',
    () async {
      final scope = RequestScope();
      var checkpoints = 0;
      final info = TorrentInfo(
        _hash,
        '大合集',
        _data,
        List.generate(1001, (i) => TorrentFile(i, '大合集/$i.mp4', 4)),
        pieceLength: 16384,
      );
      await expectLater(
        scope.run(
          () => RequestScope.guarded(
            () => services.downloads.enqueueTorrent(
              info,
              List.generate(1001, (i) => i),
            ),
            () {
              if (++checkpoints == 3) scope.cancel();
            },
          ),
        ),
        throwsA(isA<AppException>()),
      );
      expect(checkpoints, greaterThanOrEqualTo(3));
      expect(services.downloads.tasks, isEmpty);
      expect(services.store.data.list('tasks'), isEmpty);
      expect(services.store.data.obj('torrents'), isEmpty);
      expect(native.begins, isEmpty);
    },
  );

  test(
    'Selected BT files keep one shared metadata record and export serially without HTTP probes',
    () async {
      final ids = await services.downloads.enqueueTorrent(testTorrent, [1, 0]);
      expect(ids, hasLength(2));
      await until(
        () =>
            services.downloads.tasks.every(
              (t) => t.status == DownloadStatus.completed,
            ) &&
            services.downloads.activeCount == 0,
      );
      expect(http.probes, 0);
      expect(native.begins.map((b) => b['torrentIndex']), [0, 1]);
      expect(native.begins.every((b) => b['torrentData'] == _data), isTrue);
      expect(services.store.data.obj('torrents').keys, [_hash]);
      expect(
        services.store.data
            .list('tasks')
            .every((t) => !encoded(t).contains(_data)),
        isTrue,
      );
      for (final task in services.downloads.tasks) {
        expect(await File(task.savedPath!).readAsBytes(), native.content);
        expect(task.spec.relativePath, '合集');
      }
      final second = services.downloads.task(ids.last)!.savedPath!;
      await services.downloads.delete(ids.first, deleteFile: true);
      expect(await File(second).exists(), isTrue);
      expect(services.store.data.obj('torrents'), isNotEmpty);
      await services.downloads.delete(ids.last, deleteFile: true);
      expect(services.store.data.obj('torrents'), isEmpty);
    },
  );

  test(
    'BT pause and resume preserve selection; deletion stops the writer',
    () async {
      native.finish = false;
      final id = (await services.downloads.enqueueTorrent(testTorrent, [
        1,
      ])).single;
      await until(() => native.begins.isNotEmpty);
      await services.downloads.pause(id);
      expect(services.downloads.task(id)!.status, DownloadStatus.paused);
      expect(services.store.data.obj('torrents'), isNotEmpty);
      native.finish = true;
      await services.downloads.resume(id);
      await until(
        () =>
            services.downloads.task(id)!.status == DownloadStatus.completed &&
            services.downloads.activeCount == 0,
      );
      expect(
        native.begins.every((b) => b.integer('torrentIndex') == 1),
        isTrue,
      );
      await services.downloads.delete(id, deleteFile: true);
      expect(native.removedWhileWriting, isFalse);
    },
  );

  test(
    'Duplicate unfinished BT file is rejected without losing shared metadata',
    () async {
      native.finish = false;
      final id = (await services.downloads.enqueueTorrent(testTorrent, [
        0,
      ])).single;
      await until(() => native.begins.isNotEmpty);
      await services.downloads.pause(id);
      await expectLater(
        services.downloads.enqueueTorrent(testTorrent, [0]),
        throwsA(isA<AppException>()),
      );
      expect(services.downloads.tasks, hasLength(1));
      expect(services.store.data.obj('torrents').obj(_hash).str('data'), _data);
      await services.downloads.delete(id);
      expect(native.removedWhileWriting, isFalse);
    },
  );

  test('No selection and invalid file index cannot create tasks', () async {
    for (final selection in <List<int>>[
      [],
      [-1],
      [2],
    ]) {
      await expectLater(
        services.downloads.enqueueTorrent(testTorrent, selection),
        throwsA(isA<AppException>()),
      );
    }
    expect(services.downloads.tasks, isEmpty);
    expect(native.openCount, 0);
  });

  test(
    'Cancelling magnet metadata releases it without starting a payload',
    () async {
      native.metadataStatus = 'resolving';
      final session = TorrentSession(services.engine, http);
      final future = session.resolve(testTorrent.magnet);
      await until(() => native.calls.contains('torrentMetadata'));
      session.dispose();
      await future;
      expect(native.calls, contains('torrentCancel'));
      expect(native.begins, isEmpty);
      expect(session.info, isNull);
    },
  );

  test(
    'HTTP torrent file becomes metadata and failure stays recoverable',
    () async {
      final session = TorrentSession(services.engine, http);
      await session.resolve('https://example.com/files.torrent');
      expect(native.resolvedRequest!.str('url'), _data);
      expect(session.info!.files, hasLength(2));
      expect(native.begins, isEmpty);
      session.dispose();
      native.metadataStatus = 'error';
      final failed = TorrentSession(services.engine, http);
      await failed.resolve(testTorrent.magnet);
      expect(failed.error, '没有找到可用做种者');
      expect(failed.info, isNull);
      failed.dispose();
    },
  );

  test(
    'Oversized HTTP torrent stops before invoking the native resolver',
    () async {
      http.chunks = [Uint8List(maxTorrentBytes), Uint8List(1)];
      final session = TorrentSession(services.engine, http);
      await session.resolve('https://example.com/oversized.torrent');
      expect(session.error, contains('4 MiB'));
      expect(native.calls, isNot(contains('torrentResolve')));
      session.dispose();
    },
  );
}
