import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/download_manager.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/platform/file_access.dart';
import 'package:asterlink/platform/native_engine.dart';
import 'package:asterlink/preview/document_downloads.dart';
import 'support.dart';

DownloadOrigin _origin({
  String account = 'owner',
  String root = 'root',
  String drive = 'space',
  String share = '',
  int size = 20,
  String modified = '',
}) => DownloadOrigin(
  BrowseSession(
    platform: CloudPlatform.quark,
    mode: share.isEmpty ? BrowseMode.personal : BrowseMode.share,
    title: 'fixture',
    rootId: root,
    metadata: {'accountId': account, 'driveId': drive},
    sourceLink: share.isEmpty
        ? null
        : ParsedLink(
            source: 'https://pan.quark.cn/s/$share',
            url: 'https://pan.quark.cn/s/$share',
            kind: LinkKind.cloudShare,
            platform: CloudPlatform.quark,
            shareId: share,
          ),
  ),
  CloudFile(id: 'file', name: 'report.pdf', size: size, modifiedAt: modified),
  1,
);

DownloadTask _task(
  String id,
  DownloadOrigin origin, {
  DownloadStatus status = DownloadStatus.paused,
  String? path,
}) => DownloadTask(
  id: id,
  spec: DownloadSpec(
    url: 'https://download.example/temporary',
    fileName: 'report.pdf',
    source: origin.toJson(),
  ),
  createdAt: 1,
  status: status,
  savedPath: path,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'same owner file identity ignores renewed URLs but isolates drive, share, version and owner',
    () {
      final origin = _origin();
      expect(DocumentDownloads.matches(_task('old', origin), origin), true);
      for (final changed in [
        _origin(account: 'other'),
        _origin(root: 'other'),
        _origin(drive: 'other'),
        _origin(share: 'share'),
        _origin(size: 30),
      ]) {
        expect(DocumentDownloads.matches(_task('old', origin), changed), false);
      }
      expect(
        DocumentDownloads.matches(
          _task('old', _origin(modified: 'before')),
          _origin(modified: 'after'),
        ),
        false,
      );
      expect(
        DocumentDownloads.matches(
          _task('old', _origin(share: 'a')),
          _origin(share: 'b'),
        ),
        false,
      );
      expect(
        DocumentDownloads.matches(
          _task('old', origin, status: DownloadStatus.cancelled),
          origin,
        ),
        false,
      );
    },
  );

  late Directory directory;
  late FakeFiles files;
  late DownloadManager manager;
  late TransferHttp http;
  Future<DocumentDownloads> setup(List<DownloadTask> tasks) async {
    directory = Directory.systemTemp.createTempSync(
      'asterlink-document-downloads-',
    );
    final store = StateStore.memory({
      'tasks': tasks.map((t) => t.toJson()).toList(),
    });
    files = FakeFiles(Directory('${directory.path}/saved'));
    http = TransferHttp();
    manager = DownloadManager(
      store: store,
      engine: GopeedEngine(
        FakeNative(),
        store,
        Vault(store),
        Directory('${directory.path}/native'),
        Directory('${directory.path}/cache'),
      ),
      files: files,
      cleanups: CleanupOutbox(store, FakeHttp()),
      http: http,
      refreshSource: (s) async => s,
    );
    await manager.initialize();
    addTearDown(() async {
      await manager.close();
      http.dio.close(force: true);
      await directory.delete(recursive: true);
    });
    return DocumentDownloads(manager);
  }

  test('lookup of an undownloaded document does not create a task', () async {
    final docs = await setup([]);
    expect(await docs.find(_origin()), null);
    expect(manager.tasks, isEmpty);
  });
  test(
    'read-only lookup leaves failed and paused downloads unchanged',
    () async {
      final docs = await setup([
        _task('failed', _origin(account: 'a'), status: DownloadStatus.failed),
        _task('paused', _origin()),
      ]);
      expect(await docs.find(_origin(account: 'a')), 'failed');
      expect(await docs.find(_origin()), 'paused');
      expect(manager.task('failed')?.status, DownloadStatus.failed);
      expect(manager.task('paused')?.status, DownloadStatus.paused);
    },
  );
  test(
    'saved readable document is reused ahead of unfinished duplicate',
    () async {
      final docs = await setup([
        _task('paused', _origin()),
        _task(
          'done',
          _origin(),
          status: DownloadStatus.completed,
          path: 'saved.pdf',
        ),
      ]);
      final id = await docs.resolve(
        _origin(),
        create: () => throw StateError('Must not download twice'),
      );
      expect(id, 'done');
    },
  );
  test(
    'missing saved file reuses unfinished task or creates exactly one replacement',
    () async {
      final docs = await setup([
        _task(
          'done',
          _origin(),
          status: DownloadStatus.completed,
          path: 'missing.pdf',
        ),
        _task('paused', _origin()),
      ]);
      files.availability['missing.pdf'] = FileAvailability.missing;
      expect(
        await docs.resolve(
          _origin(),
          create: () => throw StateError('Use paused download'),
        ),
        'paused',
      );
    },
  );
  test(
    'concurrent preview taps enqueue once, cancellation releases the pending entry',
    () async {
      final docs = await setup([]);
      final gate = Completer<String?>();
      var created = 0;
      Future<String?> create() {
        created++;
        return gate.future;
      }

      final a = docs.resolve(_origin(), create: create);
      final b = docs.resolve(_origin(), create: create);
      await until(() => created == 1);
      expect(created, 1);
      gate.complete(null);
      expect(await a, null);
      expect(await b, null);
      expect(
        await docs.resolve(
          _origin(),
          create: () async {
            created++;
            return 'fresh';
          },
        ),
        'fresh',
      );
      expect(created, 2);
    },
  );
  test(
    'permission failure does not silently duplicate a completed download',
    () async {
      final docs = await setup([
        _task(
          'done',
          _origin(),
          status: DownloadStatus.completed,
          path: 'protected.pdf',
        ),
      ]);
      files.availability['protected.pdf'] = FileAvailability.inaccessible;
      await expectLater(
        docs.resolve(
          _origin(),
          create: () => throw StateError('Must not duplicate'),
        ),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'concurrent versions of one remote ID are resolved independently',
    () async {
      final docs = await setup([]);
      final older = Completer<String?>(), newer = Completer<String?>();
      final a = docs.resolve(_origin(size: 20), create: () => older.future);
      final b = docs.resolve(_origin(size: 30), create: () => newer.future);
      older.complete('older');
      newer.complete('newer');
      expect(await a, 'older');
      expect(await b, 'newer');
    },
  );

  test('failed creation clears the pending entry for a later retry', () async {
    final docs = await setup([]);
    await expectLater(
      docs.resolve(
        _origin(),
        create: () async => throw const AppException('取消'),
      ),
      throwsA(isA<AppException>()),
    );
    expect(await docs.resolve(_origin(), create: () async => 'retry'), 'retry');
  });
}
