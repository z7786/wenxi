import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/backup_targets.dart';
import 'package:asterlink/data/classified_backup.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/upload/upload_manager.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'support.dart';

class MemoryTarget extends BackupTarget {
  final files = <String, Uint8List>{};
  final writes = <String>[];
  bool failMarker = false, corruptRead = false;
  @override
  Future<List<BackupRemoteFile>> list() async => [
    for (final entry in files.entries)
      BackupRemoteFile(entry.key, entry.value.length),
  ];
  @override
  Future<Uint8List> read(
    BackupRemoteFile file, {
    int limit = backupSizeLimit,
  }) async {
    final bytes = files[file.name]!;
    require(bytes.length <= limit, 'too large');
    return corruptRead ? Uint8List.fromList([...bytes]..[0] ^= 1) : bytes;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    if (failMarker && name.endsWith('.complete')) {
      throw const AppException('marker interrupted');
    }
    expect(
      files.containsKey(name),
      isFalse,
      reason: 'must not overwrite existing snapshots',
    );
    files[name] = bytes;
    writes.add(name);
  }
}

class BackupConnector extends CloudConnector {
  @override
  final platform = CloudPlatform.quark;
  final content = <String, Uint8List>{};
  Completer<void>? hold;
  bool fail = false;
  int started = 0;
  final pages = <String?>[];
  @override
  Future<BrowseSession> openPersonal(Credential credential) async =>
      const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'Drive',
        rootId: '0',
      );
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => [
    for (final entry in content.entries)
      CloudFile(
        id: entry.key,
        name: entry.key,
        size: entry.value.length,
        parentId: parent,
      ),
  ];
  @override
  Future<CloudFilePage> listPage(
    BrowseSession s,
    String parent,
    Credential? c, {
    String? cursor,
  }) async {
    pages.add(cursor);
    final files = await list(s, parent, c),
        start = int.tryParse(cursor ?? '0') ?? 0;
    return CloudFilePage(
      files.skip(start).take(1).toList(),
      nextCursor: start + 1 < files.length ? '${start + 1}' : null,
    );
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile file,
    Credential? c,
  ) async => DownloadSpec(
    url: 'https://fixture.invalid/${file.name}',
    fileName: file.name,
    expectedSize: file.size,
  );
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    started++;
    if (hold != null) await RequestScope.cancellable(hold!.future);
    if (fail) throw const AppException('simulated upload failure');
    final bytes = BytesBuilder();
    await for (final chunk in source.openRead()) {
      bytes.add(chunk);
    }
    content[source.name] = bytes.takeBytes();
    return CloudFile(
      id: source.name,
      name: source.name,
      size: source.size,
      parentId: parent,
    );
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class BackupDownloadHttp extends TransferHttp {
  BackupDownloadHttp(this.connector);
  final BackupConnector connector;
  @override
  Future<Uint8List> limited(
    String url,
    Map<String, String> headers,
    int limit,
  ) async {
    final bytes = connector.content[Uri.parse(url).pathSegments.last]!;
    require(bytes.length <= limit, 'too large');
    return bytes;
  }
}

void main() {
  // HTTP tests intentionally use a real loopback server, outside testWidgets.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('backup-targets-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'cloud backup publishes and restores complete snapshot through queue and paged directory',
    () async {
      final store = StateStore.memory(), vault = Vault(store);
      await vault.putCredential(
        CloudPlatform.quark,
        Credential('owner', {'primary': 'token'}),
      );
      final http = FakeHttp(), cleanups = CleanupOutbox(store, FakeHttp());
      final cloud = CloudRepository(http, vault, cleanups),
          connector = BackupConnector();
      cloud.connectors[CloudPlatform.quark] = connector;
      final uploads = UploadManager(store: store, cloud: cloud),
          download = BackupDownloadHttp(connector);
      final target = CloudBackupTarget(
        cloud: cloud,
        uploads: uploads,
        http: download,
        cleanups: cleanups,
        directory: root,
        session: await cloud.personal(CloudPlatform.quark),
        parent: '0',
      );
      addTearDown(() async {
        await uploads.close();
        uploads.dispose();
        download.dio.close(force: true);
      });
      final transfers = BackupTransfers(store, root),
          bytes = await ClassifiedBackupRepository(
            store,
          ).create(categories: {BackupCategory.accounts});
      final job = await transfers.stage(bytes, {'kind': 'cloud'});
      await transfers.send(job, target);
      expect(transfers.pending, isEmpty);
      expect(
        uploads.tasks.every((task) => task.status == UploadStatus.completed),
        isTrue,
      );
      expect(uploads.tasks, hasLength(2));
      expect(connector.pages, contains('1'));
      final versions = await transfers.versions(target);
      expect(versions, hasLength(1));
      expect(await transfers.download(target, versions.single), bytes);
      expect(cleanups.pendingCount, 0);
    },
  );

  test(
    'completion marker follows readback; restart retries original bytes and name',
    () async {
      final store = StateStore.memory(),
          target = MemoryTarget(),
          transfers = BackupTransfers(store, root);
      final payload = await ClassifiedBackupRepository(store).create(
        categories: {BackupCategory.settings},
        password: 'test-password',
      );
      final job = await transfers.stage(payload, {'kind': 'cloud'});
      target.failMarker = true;
      await expectLater(
        transfers.send(job, target),
        throwsA(isA<AppException>()),
      );
      expect(await transfers.versions(target), isEmpty);
      expect(transfers.pending, hasLength(1));
      final restarted = BackupTransfers(StateStore.memory(store.data), root);
      target.failMarker = false;
      await restarted.send(restarted.pending.single, target);
      expect(target.writes.where((n) => n.endsWith('.json')), hasLength(1));
      expect(restarted.pending, isEmpty);
      expect(await File('${root.path}/${job.str('name')}').exists(), isFalse);
      final versions = await restarted.versions(target);
      expect(versions, hasLength(1));
      expect(await restarted.download(target, versions.single), payload);
    },
  );

  test(
    'corrupt readback leaves old successful backups intact and staging available',
    () async {
      final store = StateStore.memory(),
          target = MemoryTarget(),
          transfers = BackupTransfers(store, root);
      final bytes = Uint8List.fromList(utf8.encode('payload'));
      final first = await transfers.stage(bytes, {});
      await transfers.send(first, target);
      final oldNames = target.files.keys.toSet();
      target.corruptRead = true;
      final next = await transfers.stage(bytes, {});
      await expectLater(
        transfers.send(next, target),
        throwsA(isA<AppException>()),
      );
      expect(target.files.keys.toSet().containsAll(oldNames), isTrue);
      expect(target.files.containsKey('${next.str('name')}.complete'), isFalse);
      expect(await File('${root.path}/${next.str('name')}').exists(), isTrue);
    },
  );

  test(
    'cloud adapter waits actual upload completion and cancellation retains retryable payload',
    () async {
      final store = StateStore.memory();
      // Use the same store for credentials and the durable upload queue.
      final owner = Vault(store);
      await owner.putCredential(
        CloudPlatform.quark,
        Credential('owner', {'primary': 'token'}),
      );
      final http = FakeHttp(), cleanups = CleanupOutbox(store, FakeHttp());
      final cloud = CloudRepository(http, owner, cleanups),
          connector = BackupConnector()..hold = Completer<void>();
      cloud.connectors[CloudPlatform.quark] = connector;
      final uploads = UploadManager(store: store, cloud: cloud, concurrent: 1);
      final target = CloudBackupTarget(
        cloud: cloud,
        uploads: uploads,
        http: TransferHttp(),
        cleanups: cleanups,
        directory: root,
        session: cloud.bindSession(
          await connector.openPersonal(Credential('', {})),
        ),
        parent: '0',
      );
      addTearDown(() async {
        await uploads.close();
        uploads.dispose();
        target.http.dio.close(force: true);
      });
      final scope = RequestScope();
      var completed = false;
      final writing = scope
          .run(
            () => target.write(
              'asterlink-backup-test.json',
              Uint8List.fromList([1, 2, 3]),
            ),
          )
          .then((_) => completed = true);
      Object? writeError;
      final watched = writing.catchError((Object error) {
        writeError = error;
        return false;
      });
      await until(
        () =>
            connector.started == 1 ||
            writeError != null ||
            uploads.tasks.any((t) => !t.active),
      );
      expect(
        connector.started,
        1,
        reason: '$writeError ${uploads.tasks.map((t) => t.error).join('; ')}',
      );
      expect(completed, isFalse);
      scope.cancel();
      await watched;
      expect(writeError, isA<AppException>());
      expect(uploads.tasks.single.status, UploadStatus.cancelled);
      expect(
        await File('${root.path}/asterlink-backup-test.json').exists(),
        isTrue,
      );
      connector.hold = null;
      await target.write(
        'asterlink-backup-test.json',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(uploads.tasks, hasLength(1));
      expect(uploads.tasks.single.status, UploadStatus.completed);
      expect(connector.content.values.single, [1, 2, 3]);
    },
  );

  test(
    'WebDAV tests actual read/write/delete; namespace XML and encoded names work',
    () async {
      final files = <String, List<int>>{}, methods = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        methods.add(request.method);
        if (request.headers.value('authorization') !=
            'Basic ${base64Encode(utf8.encode('user:secret'))}') {
          request.response.statusCode = 401;
          await request.response.close();
          return;
        }
        final name = request.uri.pathSegments.last;
        switch (request.method) {
          case 'PROPFIND':
            await request.drain<void>();
            request.response.statusCode = 207;
            request.response.write(
              '<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>${files.entries.map((e) => '<d:response><d:href>/dav/${Uri.encodeComponent(e.key)}</d:href><d:propstat><d:prop><d:getcontentlength>${e.value.length}</d:getcontentlength></d:prop></d:propstat></d:response>').join()}</d:multistatus>',
            );
          case 'PUT':
            files[name] = await request.fold<List<int>>(
              [],
              (previous, chunk) => previous..addAll(chunk),
            );
            request.response.statusCode = 201;
          case 'GET':
            request.response.add(files[name] ?? []);
          case 'DELETE':
            files.remove(name);
            request.response.statusCode = 204;
        }
        await request.response.close();
      });
      final target = WebDavBackupTarget(
        url: 'http://127.0.0.1:${server.port}/dav/',
        username: 'user',
        password: 'secret',
        client: Dio(),
      );
      addTearDown(target.close);
      await target.test();
      expect(methods, ['PROPFIND', 'PUT', 'GET', 'DELETE']);
      expect(files, isEmpty);
      files['旧备份.json'] = [1, 2, 3];
      final list = await target.list();
      expect(list.single.name, '旧备份.json');
      expect(await target.read(list.single), [1, 2, 3]);
      expect(
        () => target.read(list.single, limit: 2),
        throwsA(isA<AppException>()),
      );
      files['asterlink-backup-incomplete.json'] = [1];
      await target.repairIncomplete(
        'asterlink-backup-incomplete.json',
        Uint8List.fromList([1, 2, 3]),
      );
      expect(files['asterlink-backup-incomplete.json'], [1, 2, 3]);
      files['asterlink-backup-incomplete.json.complete'] = [0];
      await expectLater(
        target.repairIncomplete(
          'asterlink-backup-incomplete.json',
          Uint8List.fromList([4]),
        ),
        throwsA(isA<AppException>()),
      );
      expect(files['asterlink-backup-incomplete.json'], [1, 2, 3]);
    },
  );

  test(
    'WebDAV refuses redirects without leaking authentication and bounds streamed reads',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var second = 0;
      server.listen((request) async {
        if (request.uri.path == '/dav/redirect.json') {
          request.response.statusCode = 302;
          request.response.headers.set('location', '/other');
        } else if (request.uri.path == '/other') {
          second++;
        } else {
          request.response.add(List.filled(100, 65));
        }
        await request.response.close();
      });
      final target = WebDavBackupTarget(
        url: 'http://127.0.0.1:${server.port}/dav/',
        username: 'user',
        password: 'secret',
        client: Dio(),
      );
      addTearDown(target.close);
      await expectLater(
        target.read(const BackupRemoteFile('redirect.json', 0)),
        throwsA(isA<AppException>()),
      );
      expect(second, 0);
      await expectLater(
        target.read(const BackupRemoteFile('large.json', 0), limit: 10),
        throwsA(isA<AppException>()),
      );
      expect(
        () => target.read(const BackupRemoteFile('../outside.json', 0)),
        throwsA(isA<AppException>()),
      );
    },
  );
}
