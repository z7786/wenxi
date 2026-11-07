import 'dart:async';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/upload/upload_folder.dart';
import 'package:asterlink/upload/upload_manager.dart';
import 'package:asterlink/upload/upload_sources.dart';
import 'package:asterlink/upload/upload_task.dart';
import 'support.dart';

class _FolderConnector extends CloudConnector {
  _FolderConnector([this.platform = CloudPlatform.quark]);
  @override
  final CloudPlatform platform;
  final files = <CloudFile>[];
  final started = <(String, String)>[], created = <(String, String)>[];
  final owners = <String>[];
  final payloads = <String, List<int>>{};
  String failName = '', holdName = '';
  bool foldersAllowed = true;
  Completer<void>? hold;
  Future<void> Function()? afterFolder;
  int sequence = 0;

  BrowseSession get session => BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    title: '网盘',
    rootId: platform == CloudPlatform.baidu ? '/' : '0',
  );
  @override
  Future<BrowseSession> openPersonal(Credential c) async => session;
  @override
  bool canCreateFolderIn(BrowseSession s, String parent) => foldersAllowed;
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => files.where((f) => f.parentId == parent).toList();
  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    RequestScope.checkpoint();
    final folder = CloudFile(
      id: 'dir-${sequence++}',
      name: name,
      isDirectory: true,
      parentId: parent,
      token: platform == CloudPlatform.baidu
          ? '${parent.replaceFirst(RegExp(r'/+$'), '')}/$name'
          : '',
    );
    files.add(folder);
    created.add((parent, name));
    owners.add(c.label);
    await afterFolder?.call();
    return folder;
  }

  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    started.add((parent, source.name));
    owners.add(c.label);
    onProgress?.call(UploadProgress(UploadPhase.uploading, 0, source.size));
    if (source.name == holdName && hold != null) {
      await RequestScope.cancellable(hold!.future);
    }
    if (source.name == failName) throw const AppException('网络中断');
    final bytes = await source.openRead().expand((b) => b).toList();
    onProgress?.call(
      UploadProgress(UploadPhase.uploading, bytes.length, source.size),
    );
    onProgress?.call(
      UploadProgress(UploadPhase.finishing, bytes.length, source.size),
    );
    RequestScope.checkpoint();
    final file = CloudFile(
      id: 'file-${sequence++}',
      name: source.name,
      parentId: parent,
      size: source.size,
    );
    files.add(file);
    payloads[file.id] = bytes;
    return file;
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory workspace, folder;
  late StateStore store;
  late Vault vault;
  late CloudRepository cloud;
  late _FolderConnector provider;
  late UploadManager manager;
  late UploadSources sources;

  Future<void> local(
    String relative, [
    List<int> bytes = const [1, 2, 3],
  ]) async {
    final file = File(p.joinAll([folder.path, ...relative.split('/')]));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  Future<String> enqueue() async => (await manager.enqueue(
    cloud.bindSession(provider.session),
    provider.session.rootId,
    '全部文件',
    [],
    folders: [await sources.scanFolder(folder.path)],
  )).single;
  Future<void> settled(String id) => until(() => !manager.task(id)!.active);
  CloudFile remote(String name, [String? parent]) => provider.files.singleWhere(
    (f) => f.name == name && (parent == null || f.parentId == parent),
  );

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('folder-upload-');
    folder = await Directory(p.join(workspace.path, '资料')).create();
    store = StateStore.memory();
    vault = Vault(store);
    await vault.putCredential(
      CloudPlatform.quark,
      Credential('original', {'primary': 'test'}, updatedAt: 1),
    );
    final http = FakeHttp();
    cloud = CloudRepository(http, vault, CleanupOutbox(store, http));
    provider = _FolderConnector();
    cloud.connectors[provider.platform] = provider;
    sources = UploadSources(android: false, ios: false);
    manager = UploadManager(store: store, cloud: cloud, sources: sources);
    await manager.initialize();
  });
  tearDown(() async {
    await manager.close();
    manager.dispose();
    await workspace.delete(recursive: true);
  });

  test(
    'one folder task preserves nested names, empty folders and exact bytes',
    () async {
      await local('说明.txt');
      await local('甲/同名.txt', [4, 5]);
      await local('乙/同名.txt', [6, 7, 8, 9]);
      await local('甲/更深/视频.mp4', [10]);
      await Directory(p.join(folder.path, '空目录')).create();
      final id = await enqueue();
      await settled(id);
      final task = manager.task(id)!;
      expect(task.status, UploadStatus.completed, reason: task.error);
      expect(manager.tasks, hasLength(1));
      expect(task.folder!.completedFiles, 4);
      expect(task.size, 10);
      expect(task.sent, 10);
      final root = remote('资料');
      final a = remote('甲', root.id), b = remote('乙', root.id);
      expect(remote('空目录', root.id).isDirectory, isTrue);
      expect(remote('更深', a.id).isDirectory, isTrue);
      expect(provider.payloads[remote('同名.txt', a.id).id], [4, 5]);
      expect(provider.payloads[remote('同名.txt', b.id).id], [6, 7, 8, 9]);
      expect(task.fileId, root.id);
    },
  );

  test(
    'an empty folder completes without uploading a placeholder file',
    () async {
      final id = await enqueue();
      await settled(id);
      expect(manager.task(id)!.status, UploadStatus.completed);
      expect(provider.created, [('0', '资料')]);
      expect(provider.started, isEmpty);
    },
  );

  test(
    'existing directories merge, while existing files are never overwritten',
    () async {
      provider.files.add(
        const CloudFile(
          id: 'existing',
          parentId: '0',
          name: '资料',
          isDirectory: true,
        ),
      );
      provider.files.add(
        const CloudFile(
          id: 'keep',
          parentId: 'existing',
          name: '说明.txt',
          size: 99,
        ),
      );
      await local('说明.txt');
      final id = await enqueue();
      await settled(id);
      expect(manager.task(id)!.status, UploadStatus.failed);
      expect(manager.task(id)!.error, contains('同名'));
      expect(provider.started, isEmpty);
      expect(provider.created, isEmpty);
      expect(remote('说明.txt').size, 99);
    },
  );

  test(
    'retry after restart uploads only unfinished files into the same directories',
    () async {
      await local('01.txt');
      await local('sub/02.txt');
      provider.failName = '02.txt';
      final id = await enqueue();
      await settled(id);
      expect(manager.task(id)!.status, UploadStatus.failed);
      expect(manager.task(id)!.folder!.completedFiles, 1);
      final directories = List.of(provider.created);
      await manager.close();
      manager.dispose();
      manager = UploadManager(store: store, cloud: cloud, sources: sources);
      await manager.initialize();
      expect(manager.task(id)!.folder!.completedFiles, 1);
      provider.failName = '';
      await manager.retry(id);
      await settled(id);
      expect(
        manager.task(id)!.status,
        UploadStatus.completed,
        reason: manager.task(id)!.error,
      );
      expect(provider.started.map((f) => f.$2), ['01.txt', '02.txt', '02.txt']);
      expect(provider.created, directories);
      expect(provider.files.where((f) => !f.isDirectory), hasLength(2));
    },
  );

  test(
    'a replaced remote directory blocks retry before uploading another file',
    () async {
      await local('01.txt');
      await local('sub/02.txt');
      provider.failName = '02.txt';
      final id = await enqueue();
      await settled(id);
      final root = remote('资料');
      provider.files.remove(root);
      provider.files.add(
        const CloudFile(
          id: 'replacement',
          name: '资料',
          parentId: '0',
          isDirectory: true,
        ),
      );
      provider.failName = '';
      await manager.retry(id);
      await settled(id);
      expect(manager.task(id)!.status, UploadStatus.failed);
      expect(manager.task(id)!.error, contains('文件夹已变化'));
      expect(provider.started, hasLength(2));
    },
  );

  test(
    'cancel stops remaining files and lets a later standalone upload run',
    () async {
      await local('01.txt');
      await local('02.txt');
      await local('03.txt');
      provider.holdName = '02.txt';
      provider.hold = Completer<void>();
      final id = await enqueue();
      await until(() => provider.started.length == 2);
      await manager.cancel(id);
      final extra = File(p.join(workspace.path, 'extra.txt'));
      await extra.writeAsBytes([9]);
      final other = (await manager.enqueue(
        cloud.bindSession(provider.session),
        '0',
        '全部文件',
        [XFile(extra.path)],
      )).single;
      await settled(other);
      expect(manager.task(id)!.status, UploadStatus.cancelled);
      expect(manager.task(id)!.folder!.completedFiles, 1);
      expect(provider.started.map((f) => f.$2), [
        '01.txt',
        '02.txt',
        'extra.txt',
      ]);
      expect(manager.task(other)!.status, UploadStatus.completed);
      provider.hold = null;
      await manager.retry(id);
      await settled(id);
      expect(
        manager.task(id)!.status,
        UploadStatus.completed,
        reason: manager.task(id)!.error,
      );
      expect(provider.started.map((f) => f.$2), [
        '01.txt',
        '02.txt',
        'extra.txt',
        '02.txt',
        '03.txt',
      ]);
    },
  );

  test(
    'credential changes during directory preparation stop subsequent writes',
    () async {
      await local('说明.txt');
      provider.afterFolder = () => vault.putCredential(
        provider.platform,
        Credential('updated', {'primary': 'new'}, updatedAt: 2),
      );
      final id = await enqueue();
      await settled(id);
      expect(manager.task(id)!.status, UploadStatus.failed);
      expect(manager.task(id)!.error, contains('账号已变化'));
      expect(provider.started, isEmpty);
      expect(provider.owners, ['original']);
    },
  );

  test(
    'baidu children use path tokens rather than numeric folder ids',
    () async {
      provider = _FolderConnector(CloudPlatform.baidu);
      cloud.connectors[provider.platform] = provider;
      await vault.putCredential(
        provider.platform,
        Credential('original', {'primary': 'test'}, updatedAt: 1),
      );
      await local('sub/说明.txt');
      final id = await enqueue();
      await settled(id);
      expect(
        manager.task(id)!.status,
        UploadStatus.completed,
        reason: manager.task(id)!.error,
      );
      expect(provider.created, [('/', '资料'), ('/资料', 'sub')]);
      expect(provider.started, [('/资料/sub', '说明.txt')]);
    },
  );

  test(
    'baidu rejects a recreated same-path directory using its numeric file identity',
    () async {
      provider = _FolderConnector(CloudPlatform.baidu);
      cloud.connectors[provider.platform] = provider;
      await vault.putCredential(
        provider.platform,
        Credential('original', {'primary': 'test'}, updatedAt: 1),
      );
      await local('说明.txt');
      provider.failName = '说明.txt';
      final id = await enqueue();
      await settled(id);
      final root = remote('资料');
      provider.files.remove(root);
      provider.files.add(
        CloudFile(
          id: 'replacement',
          name: root.name,
          parentId: root.parentId,
          token: root.token,
          isDirectory: true,
        ),
      );
      provider.failName = '';
      await manager.retry(id);
      await settled(id);
      expect(manager.task(id)!.status, UploadStatus.failed);
      expect(manager.task(id)!.error, contains('文件夹已变化'));
      expect(provider.started, hasLength(1));
    },
  );

  test(
    'folder enqueue capability and same-name batches fail atomically',
    () async {
      provider.foldersAllowed = false;
      final plan = await sources.scanFolder(folder.path);
      await expectLater(
        manager.enqueue(
          cloud.bindSession(provider.session),
          '0',
          '全部文件',
          [],
          folders: [plan],
        ),
        throwsA(isA<AppException>()),
      );
      expect(manager.tasks, isEmpty);
      provider.foldersAllowed = true;
      await expectLater(
        manager.enqueue(
          cloud.bindSession(provider.session),
          '0',
          '全部文件',
          [],
          folders: [plan, plan],
        ),
        throwsA(isA<AppException>()),
      );
      expect(manager.tasks, isEmpty);
      expect(provider.created, isEmpty);
    },
  );

  test('local changes fail before reading any file bytes', () async {
    await local('01.txt');
    final plan = await sources.scanFolder(folder.path);
    await local('01.txt', [9, 8, 7, 6]);
    final id = (await manager.enqueue(
      cloud.bindSession(provider.session),
      '0',
      '全部文件',
      [],
      folders: [plan],
    )).single;
    await settled(id);
    expect(manager.task(id)!.error, contains('文件已变化'));
    expect(provider.started, isEmpty);
  });

  test('unsafe paths, duplicate names and too many items are rejected', () {
    for (final invalid in ['../a', '/a', 'a//b', 'a/./b', r'a\b']) {
      expect(() => uploadRelativePath(invalid), throwsA(isA<AppException>()));
    }
    UploadFolderFile file(String path) => UploadFolderFile(
      location: 'local',
      relativePath: path,
      size: 1,
      modifiedAt: 0,
    );
    expect(
      () => UploadFolder(
        location: 'local',
        name: '资料',
        files: [file('A.txt'), file('a.txt')],
      ),
      throwsA(isA<AppException>()),
    );
    expect(
      () => UploadFolder(
        location: 'local',
        name: '资料',
        files: [file('a'), file('a/b')],
      ),
      throwsA(isA<AppException>()),
    );
    expect(
      () => UploadFolder(
        location: 'local',
        name: '资料',
        files: [],
        directories: [for (var i = 0; i < 10000; i++) 'dir-$i'],
      ),
      throwsA(isA<AppException>()),
    );
  });

  test('old file task records still load without a folder plan', () {
    final record = UploadTask(
      id: 'old',
      session: provider.session.withAccount('original'),
      parent: '0',
      folderName: '全部文件',
      accountName: 'original',
      path: 'file.txt',
      name: 'file.txt',
      size: 1,
      modifiedAt: 1,
      createdAt: 1,
    ).toJson();
    expect(record.containsKey('folder'), isFalse);
    expect(UploadTask.fromJson(record).isFolder, isFalse);
  });
}
