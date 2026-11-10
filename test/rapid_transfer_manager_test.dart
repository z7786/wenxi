import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/rapid_transfer.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/domain/baidu_share_route.dart';
import 'package:asterlink/domain/public_share_route.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/transfer/cross_transfer_relay.dart';
import 'package:asterlink/transfer/rapid_transfer_manager.dart';
import 'package:asterlink/transfer/rapid_transfer_task.dart';
import 'support.dart';

const hash = '900150983cd24fb0d6963f7d28e17f72';
CloudFile file(
  String id,
  String name,
  String parent, {
  bool directory = false,
  bool digest = true,
}) => CloudFile(
  id: id,
  name: name,
  parentId: parent,
  isDirectory: directory,
  size: directory ? 0 : 3,
  hashType: digest && !directory ? 'md5' : null,
  hashValue: digest && !directory ? hash : null,
);
BrowseSession personal(CloudPlatform p) => BrowseSession(
  platform: p,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '0',
);

class Drive extends CloudConnector {
  Drive(this.platform);
  @override
  final CloudPlatform platform;
  final directories = <String, List<CloudFile>>{};
  final calls = <(String, String, String)>[];
  final pages = <(String, String?)>[];
  final miss = <String>{}, fail = <String>{};
  Completer<void>? hold;
  bool paginate = false;
  bool rapidSupported = true;
  bool sourceMd5Supported = true;
  String downloadUrl = '';
  final downloads = <String>[], uploads = <String>[];
  AppException? rapidFailure;
  @override
  bool get providesTransferMd5 => sourceMd5Supported;
  @override
  bool canRapidTransferTo(BrowseSession session) =>
      rapidSupported && session.canManageFiles;
  @override
  Future<BrowseSession> openPersonal(Credential c) async => personal(platform);
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => List.of(directories[parent] ?? []);
  @override
  Future<CloudFilePage> listPage(
    BrowseSession s,
    String parent,
    Credential? c, {
    String? cursor,
  }) async {
    pages.add((parent, cursor));
    final all = directories[parent] ?? [];
    final start = int.tryParse(cursor ?? '') ?? 0;
    if (!paginate) return CloudFilePage(List.of(all));
    return CloudFilePage(
      all.skip(start).take(1).toList(),
      nextCursor: start + 1 < all.length ? '${start + 1}' : null,
    );
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    final f = file('dir-${directories.length}', name, parent, directory: true);
    directories.putIfAbsent(parent, () => []).add(f);
    directories[f.id] = [];
    return f;
  }

  @override
  Future<RapidTransferResult> rapidTransfer(
    BrowseSession s,
    String parent,
    RapidTransferFile source,
    Credential c,
  ) async {
    calls.add((source.name, parent, c.label));
    if (rapidFailure != null) throw rapidFailure!;
    if (hold != null) await RequestScope.cancellable(hold!.future);
    RequestScope.checkpoint();
    if (miss.contains(source.name)) return const RapidTransferResult.missed();
    final result = file('saved-${calls.length}', source.name, parent);
    directories.putIfAbsent(parent, () => []).add(result);
    if (fail.contains(source.name)) {
      throw const HttpRequestFailure('response lost', kind: 'receiveTimeout');
    }
    return RapidTransferResult.reused(result.id);
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    downloads.add(f.name);
    return DownloadSpec(
      url: downloadUrl,
      fileName: f.name,
      expectedSize: f.size,
      headers: {'X-Test-Source': c!.label},
    );
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    final bytes = await source.openRead().fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    expect(utf8.decode(bytes), 'abc');
    uploads.add(source.name);
    onProgress?.call(
      UploadProgress(UploadPhase.uploading, bytes.length, source.size),
    );
    final result = file('uploaded-${uploads.length}', source.name, parent);
    directories.putIfAbsent(parent, () => []).add(result);
    if (fail.contains(source.name)) {
      throw const HttpRequestFailure('response lost', kind: 'receiveTimeout');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late StateStore store;
  late Vault vault;
  late CloudRepository cloud;
  late Drive from, to;
  late RapidTransferManager manager;
  late BrowseSession source, target;
  late Directory cache;
  late HttpServer server;
  late TransferHttp transfer;
  String responseBody = 'abc';
  Completer<void>? responseHold;
  int responseStatus = 200, requests = 0, confirmations = 0;
  setUp(() async {
    store = StateStore.memory();
    vault = Vault(store);
    await vault.putCredential(
      CloudPlatform.tianyi,
      Credential('source', {'primary': 'from'}, updatedAt: 1),
    );
    await vault.putCredential(
      CloudPlatform.pan123,
      Credential('target', {'primary': 'to'}, updatedAt: 2),
    );
    final http = FakeHttp();
    cloud = CloudRepository(http, vault, CleanupOutbox(store, http));
    from = Drive(CloudPlatform.tianyi);
    to = Drive(CloudPlatform.pan123);
    cloud.connectors[from.platform] = from;
    cloud.connectors[to.platform] = to;
    source = cloud.bindSession(personal(from.platform));
    target = cloud.bindSession(personal(to.platform));
    cache = await Directory.systemTemp.createTemp('asterlink-cross-test-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    responseBody = 'abc';
    responseHold = null;
    responseStatus = 200;
    requests = confirmations = 0;
    server.listen((request) async {
      requests++;
      expect(request.headers.value('x-test-source'), 'source');
      request.response.statusCode = responseStatus;
      request.response.contentLength = utf8.encode(responseBody).length;
      request.response.write(responseBody);
      await request.response.flush();
      if (responseHold != null) await responseHold!.future;
      await request.response.close();
    });
    from.downloadUrl = 'http://127.0.0.1:${server.port}/file';
    transfer = TransferHttp();
    manager = RapidTransferManager(
      store: store,
      cloud: cloud,
      relay: CrossTransferRelay(cloud: cloud, http: transfer, cache: cache),
      confirmDownload: () async {
        confirmations++;
      },
    );
    await manager.initialize();
  });
  tearDown(() async {
    if (responseHold?.isCompleted == false) responseHold!.complete();
    await manager.close();
    manager.dispose();
    transfer.dio.close(force: true);
    await server.close(force: true);
    await cache.delete(recursive: true);
  });
  Future<RapidTransferTask> enqueue(List<CloudFile> files) async {
    final id = await manager.enqueue(source, files, target, '0', '全部文件');
    await until(() => !manager.task(id)!.active);
    return manager.task(id)!;
  }

  test(
    'scans all pages, preserves nested and empty folders and deduplicates selection',
    () async {
      final folder = file('a', 'Folder', '0', directory: true),
          empty = file('empty', 'Empty', 'a', directory: true);
      final a = file('f1', 'first.bin', 'a'), b = file('f2', 'second.bin', 'a');
      from.directories['0'] = [folder];
      from.directories['a'] = [a, empty, b];
      from.paginate = true;
      final task = await enqueue([folder, b]);
      expect(task.status, RapidTaskStatus.completed, reason: task.error);
      expect(task.count(RapidEntryStatus.reused), 2);
      expect(to.calls.length, 2);
      expect(from.pages, contains(('a', '2')));
      final dest = to.directories['0']!.single;
      expect(dest.name, 'Folder');
      expect(
        to.directories[dest.id]!.map((f) => f.name),
        containsAll(['Empty', 'first.bin', 'second.bin']),
      );
      expect(to.calls.every((c) => c.$2 == dest.id), true);
    },
  );
  test(
    'missing hash and miss automatically relay while duplicate is skipped',
    () async {
      final a = file('a', 'duplicate.bin', '0'),
          b = file('b', 'unknown.bin', '0', digest: false),
          c = file('c', 'missing.bin', '0');
      from.directories['0'] = [a, b, c];
      to.directories['0'] = [file('old', 'duplicate.bin', '0')];
      to.miss.add('missing.bin');
      final task = await enqueue([a, b, c]);
      expect(task.count(RapidEntryStatus.duplicate), 1);
      expect(task.count(RapidEntryStatus.uploaded), 2);
      expect(from.downloads, ['unknown.bin', 'missing.bin']);
      expect(to.uploads, ['unknown.bin', 'missing.bin']);
      expect(requests, 2);
      expect(confirmations, 1);
      expect(await cache.list().toList(), isEmpty);
      expect(to.calls.map((c) => c.$1), ['missing.bin']);
    },
  );
  test(
    'caller cancellation and switching active account do not redirect the task',
    () async {
      final a = file('a', 'first.bin', '0');
      from.directories['0'] = [a];
      to.hold = Completer<void>();
      final outer = RequestScope();
      final id = await outer.run(
        () => manager.enqueue(source, [a], target, '0', '全部文件'),
      );
      outer.cancel();
      await until(() => to.calls.isNotEmpty);
      final second = await vault.createAccount(CloudPlatform.pan123);
      await vault.withAccount(
        CloudPlatform.pan123,
        second,
        () => vault.putCredential(
          CloudPlatform.pan123,
          Credential('other', {'primary': 'other'}, updatedAt: 3),
        ),
      );
      to.hold!.complete();
      await until(() => !manager.task(id)!.active);
      expect(manager.task(id)!.status, RapidTaskStatus.completed);
      expect(to.calls.single.$3, 'target');
    },
  );

  test(
    'target without rapid API automatically downloads and uploads',
    () async {
      final a = file('a', 'normal.bin', '0');
      from.directories['0'] = [a];
      to.rapidSupported = false;
      final task = await enqueue([a]);
      expect(task.count(RapidEntryStatus.uploaded), 1);
      expect(task.methodLabel, '下载后上传');
      expect(to.calls, isEmpty);
      expect(requests, 1);
    },
  );
  test(
    'source without transfer MD5 capability still supports cross transfer',
    () async {
      final a = file('a', 'no-md5.bin', '0', digest: false);
      from.sourceMd5Supported = false;
      from.directories['0'] = [a];
      final task = await enqueue([a]);
      expect(task.count(RapidEntryStatus.uploaded), 1);
      expect(to.calls, isEmpty);
      expect(to.uploads, [a.name]);
    },
  );
  test('rapid hit never requests payload or download confirmation', () async {
    final a = file('a', 'instant.bin', '0');
    from.directories['0'] = [a];
    final task = await enqueue([a]);
    expect(task.count(RapidEntryStatus.reused), 1);
    expect(task.methodLabel, '秒传');
    expect(requests, 0);
    expect(confirmations, 0);
  });
  test(
    'one batch can mix rapid hits and relay preserving folder structure',
    () async {
      final folder = file('dir', 'Folder', '0', directory: true);
      from.directories['0'] = [folder];
      from.directories['dir'] = [
        file('a', 'hit.bin', 'dir'),
        file('b', 'miss.bin', 'dir'),
      ];
      to.miss.add('miss.bin');
      final task = await enqueue([folder]);
      expect(task.count(RapidEntryStatus.reused), 1);
      expect(task.count(RapidEntryStatus.uploaded), 1);
      expect(task.methodLabel, '秒传 + 下载后上传');
      final dest = to.directories['0']!.single;
      expect(to.directories[dest.id]!.map((f) => f.name), [
        'hit.bin',
        'miss.bin',
      ]);
    },
  );
  test('corrupted payload never uploads and cache is removed', () async {
    final a = file('a', 'damaged.bin', '0');
    from.directories['0'] = [a];
    to.miss.add(a.name);
    responseBody = 'xyz';
    final task = await enqueue([a]);
    expect(task.count(RapidEntryStatus.failed), 1);
    expect(task.entries.single.message, contains('校验失败'));
    expect(to.uploads, isEmpty);
    expect(await cache.list().toList(), isEmpty);
  });
  test(
    'failed relay leaves progress retryable and retry does not repeat a saved upload',
    () async {
      final a = file('a', 'upload.bin', '0', digest: false);
      from.directories['0'] = [a];
      to.fail.add(a.name);
      final task = await enqueue([a]);
      expect(task.count(RapidEntryStatus.failed), 1);
      expect(task.entries.single.md5, hash);
      await manager.retry(task.id);
      await until(() => !task.active);
      expect(task.count(RapidEntryStatus.uploaded), 1);
      expect(to.uploads, [a.name]);
      expect(requests, 1);
    },
  );
  test(
    'rapid rate limit stops without silently starting full download',
    () async {
      final a = file('a', 'limited.bin', '0');
      from.directories['0'] = [a];
      to.rapidFailure = const RapidTransferUnavailable('请求过于频繁');
      final task = await enqueue([a]);
      expect(task.status, RapidTaskStatus.failed);
      expect(requests, 0);
      expect(to.uploads, isEmpty);
      to.rapidFailure = null;
      await manager.retry(task.id);
      await until(() => !task.active);
      expect(task.count(RapidEntryStatus.reused), 1);
    },
  );
  test('mismatched HTTP length fails before upload', () async {
    final a = file('a', 'length.bin', '0');
    from.directories['0'] = [a];
    to.miss.add(a.name);
    responseBody = 'abcd';
    final task = await enqueue([a]);
    expect(task.count(RapidEntryStatus.failed), 1);
    expect(task.entries.single.message, contains('大小不一致'));
    expect(to.uploads, isEmpty);
  });
  test(
    'cancelling download clears cache promptly and retry can complete',
    () async {
      final a = file('a', 'cancel.bin', '0');
      from.directories['0'] = [a];
      to.rapidSupported = false;
      responseHold = Completer<void>();
      // Advertise a valid length but keep the response pending after a partial body.
      responseBody = 'a';
      await server.close(force: true);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = 3;
        request.response.write(responseBody);
        await request.response.flush();
        if (responseHold != null) await responseHold!.future;
        try {
          await request.response.close();
        } catch (_) {}
      });
      from.downloadUrl = 'http://127.0.0.1:${server.port}/file';
      final id = await manager.enqueue(source, [a], target, '0', '全部文件');
      await until(
        () =>
            manager.task(id)!.entries.isNotEmpty &&
            manager.task(id)!.entries.single.downloaded == 1,
      ).catchError(
        (Object e) => throw StateError(
          'Before cancel: ${manager.task(id)!.stage} ${manager.task(id)!.error} ${manager.task(id)!.entries.map((e) => e.message).join()}',
        ),
      );
      await manager.cancel(id).timeout(const Duration(seconds: 2));
      await until(() => cache.listSync().isEmpty).catchError(
        (Object e) => throw StateError('After cancel cache was not cleared'),
      );
      expect(to.uploads, isEmpty);
      expect(manager.task(id)!.status, RapidTaskStatus.cancelled);
      responseHold!.complete();
      responseHold = null;
      responseBody = 'abc';
      await manager.retry(id);
      await until(() => !manager.task(id)!.active);
      expect(manager.task(id)!.count(RapidEntryStatus.uploaded), 1);
    },
  );
  test(
    'insufficient local space does not upload or retain partial cache',
    () async {
      final a = file('a', 'space.bin', '0');
      from.directories['0'] = [a];
      to.rapidSupported = false;
      await manager.close();
      manager.dispose();
      manager = RapidTransferManager(
        store: store,
        cloud: cloud,
        relay: CrossTransferRelay(
          cloud: cloud,
          http: transfer,
          cache: cache,
          availableSpace: (_) async => 2,
        ),
      );
      final task = await enqueue([a]);
      expect(task.count(RapidEntryStatus.failed), 1);
      expect(task.entries.single.message, contains('存储空间不足'));
      expect(to.uploads, isEmpty);
      expect(await cache.list().toList(), isEmpty);
    },
  );
  test(
    'cancel returns promptly and retry preserves already completed files',
    () async {
      final a = file('a', 'first.bin', '0');
      from.directories['0'] = [a];
      to.hold = Completer<void>();
      final id = await manager.enqueue(source, [a], target, '0', '全部文件');
      await until(() => to.calls.isNotEmpty);
      await manager.cancel(id);
      expect(manager.task(id)!.status, RapidTaskStatus.cancelled);
      to.hold!.complete();
      to.hold = null;
      await manager.retry(id);
      await until(() => !manager.task(id)!.active);
      expect(manager.task(id)!.count(RapidEntryStatus.reused), 1);
    },
  );
  test(
    'response lost is verified on retry without repeating the mutation',
    () async {
      final a = file('a', 'first.bin', '0');
      from.directories['0'] = [a];
      to.fail.add(a.name);
      final task = await enqueue([a]);
      expect(task.count(RapidEntryStatus.failed), 1);
      await manager.retry(task.id);
      await until(() => !task.active);
      expect(task.count(RapidEntryStatus.reused), 1);
      expect(to.calls.length, 1);
    },
  );
  test(
    'removing pinned target account interrupts rather than using another',
    () async {
      final a = file('a', 'first.bin', '0');
      from.directories['0'] = [a];
      to.hold = Completer<void>();
      final id = await manager.enqueue(source, [a], target, '0', '全部文件');
      await until(() => to.calls.isNotEmpty);
      await vault.removeAccount(CloudPlatform.pan123, target.accountId!);
      to.hold!.complete();
      await until(() => !manager.task(id)!.active);
      expect(manager.task(id)!.status, RapidTaskStatus.failed);
      expect(to.directories['0'] ?? [], isEmpty);
    },
  );
  test(
    'saved task strips credential metadata and restores interrupted without running',
    () async {
      final a = file('a', 'first.bin', '0');
      from.directories['0'] = [a];
      to.hold = Completer<void>();
      final sensitive = BrowseSession(
        platform: source.platform,
        mode: source.mode,
        title: source.title,
        rootId: source.rootId,
        metadata: {...source.metadata, 'cookie': 'secret', 'token': 'secret'},
      );
      final id = await manager.enqueue(sensitive, [a], target, '0', '全部文件');
      await until(() => to.calls.isNotEmpty);
      await manager.close();
      expect(
        encoded(store.data['rapidTransferTasks']),
        isNot(contains('secret')),
      );
      manager.dispose();
      manager = RapidTransferManager(
        store: store,
        cloud: cloud,
        relay: CrossTransferRelay(cloud: cloud, http: transfer, cache: cache),
      );
      await manager.initialize();
      expect(manager.task(id)!.status, RapidTaskStatus.interrupted);
      expect(to.calls.length, 1);
      to.hold!.complete();
      to.hold = null;
      await manager.retry(id);
      await until(() => !manager.task(id)!.active);
      expect(manager.task(id)!.count(RapidEntryStatus.reused), 1);
    },
  );
  test('persisted source keeps parser route while stripping credentials', () {
    final saved = transferSessionReference(
      const BrowseSession(
        platform: CloudPlatform.baidu,
        mode: BrowseMode.share,
        title: 'share',
        rootId: '/',
        metadata: {
          'accountId': '',
          BaiduShareRoute.metadataKey: 'mf_dg22',
          PublicShareRoute.metadataKey: 'remote',
          'parserSiteId': 'site-1',
          'cookie': 'secret',
          'token': 'secret',
          'parserPasswordGrant': 'secret',
        },
      ),
    );
    expect(BaiduShareRoute.fromSession(saved), BaiduShareRoute.publicParser);
    expect(saved.meta('parserSiteId'), 'site-1');
    expect(encoded(saved.toJson()), isNot(contains('secret')));
  });
}
