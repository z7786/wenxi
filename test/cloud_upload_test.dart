import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'support.dart';

class _Connector extends CloudConnector {
  @override
  CloudPlatform get platform => CloudPlatform.quark;
  final files = <CloudFile>[];
  int commits = 0, folders = 0;
  Future<void> Function()? onChunk;
  Future<CloudFile> Function(UploadFile)? uploadOverride;
  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parent,
    Credential? c,
  ) async => files;
  @override
  Future<CloudFile> upload(
    BrowseSession s,
    String parent,
    UploadFile source,
    Credential c, {
    UploadProgressCallback? onProgress,
  }) async {
    if (uploadOverride case final upload?) return upload(source);
    await for (final _ in source.openRead()) {
      await onChunk?.call();
    }
    commits++;
    return CloudFile(
      id: 'new',
      name: source.name,
      size: source.size,
      parentId: parent,
    );
  }

  @override
  Future<CloudFile> createFolder(
    BrowseSession s,
    String parent,
    String name,
    Credential c,
  ) async {
    folders++;
    return CloudFile(
      id: 'new-folder',
      name: name,
      isDirectory: true,
      parentId: parent,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _session = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.personal,
  title: 'files',
  rootId: '0',
);
Credential _credential(int revision) =>
    Credential('fixture', {'primary': 'fixture'}, updatedAt: revision);
UploadFile _source([String name = 'sample.txt']) => UploadFile(
  name: name,
  size: 4,
  read: (start, end) async* {
    for (var i = start; i < end; i++) {
      yield [i];
    }
  },
);
Future<(CloudRepository, Vault, _Connector)> _fixture({
  void Function(CloudPlatform)? checkAccess,
}) async {
  final store = StateStore.memory(), http = FakeHttp();
  final vault = Vault(store);
  await vault.putCredential(CloudPlatform.quark, _credential(1));
  final repository = CloudRepository(
    http,
    vault,
    CleanupOutbox(store, http),
    checkAccess: checkAccess,
  );
  final connector = _Connector();
  repository.connectors[CloudPlatform.quark] = connector;
  return (repository, vault, connector);
}

void main() {
  test(
    'same destination writes serialize and recheck a saved file before a second upload',
    () async {
      final (repository, _, connector) = await _fixture();
      final started = Completer<void>(), release = Completer<void>();
      var commits = 0;
      connector.uploadOverride = (file) async {
        commits++;
        if (!started.isCompleted) started.complete();
        await release.future;
        final saved = CloudFile(
          id: 'saved',
          name: file.name,
          size: file.size,
          parentId: '0',
        );
        connector.files.add(saved);
        return saved;
      };
      final first = repository.withWriteTarget(
        _session,
        '0',
        'sample.txt',
        () => repository.upload(_session, '0', _source()),
      );
      await started.future;
      final next = repository.upload(_session, '0', _source());
      final checked = expectLater(next, throwsA(isA<AppException>()));
      expect(commits, 1);
      release.complete();
      expect((await first).id, 'saved');
      await checked;
      expect(commits, 1);
    },
  );

  test(
    'a cancelled destination waiter leaves other names and the first write running',
    () async {
      final (repository, _, connector) = await _fixture();
      final release = Completer<void>(), started = Completer<void>();
      final sent = <String>[];
      connector.uploadOverride = (file) async {
        sent.add(file.name);
        if (file.name == 'sample.txt') {
          if (!started.isCompleted) started.complete();
          await release.future;
        }
        return CloudFile(id: file.name, name: file.name, size: file.size);
      };
      final first = repository.upload(_session, '0', _source());
      await started.future;
      final scope = RequestScope();
      final next = scope.run(() => repository.upload(_session, '0', _source()));
      scope.cancel();
      await expectLater(next, throwsA(isA<AppException>()));
      expect(
        (await repository.upload(_session, '0', _source('other.txt'))).name,
        'other.txt',
      );
      expect(sent, ['sample.txt', 'other.txt']);
      release.complete();
      await first;
      expect(sent, ['sample.txt', 'other.txt']);
    },
  );
  test(
    'Write marker is saved after preflight and receipt before cancellation',
    () async {
      final (repository, _, connector) = await _fixture();
      final scope = RequestScope(), events = <String>[];
      connector.uploadOverride = (file) async {
        events.add('write');
        scope.cancel();
        return CloudFile(id: 'saved', name: file.name, size: file.size);
      };
      await expectLater(
        scope.run(
          () => repository.upload(
            _session,
            '0',
            _source(),
            beforeWrite: () async => events.add('marked'),
            onSaved: (file) async => events.add('receipt:${file.id}'),
          ),
        ),
        throwsA(isA<AppException>()),
      );
      expect(events, ['marked', 'write', 'receipt:saved']);
    },
  );
  test(
    'Local preflight failure clears the marker without any mutation',
    () async {
      final (repository, _, connector) = await _fixture();
      var pending = false;
      connector.uploadOverride = (_) async =>
          throw const AppException('local file missing');
      await expectLater(
        repository.upload(
          _session,
          '0',
          _source(),
          beforeWrite: () async => pending = true,
          onNotSubmitted: () async => pending = false,
        ),
        throwsA(isA<AppException>()),
      );
      expect(pending, isFalse);
      connector.files.add(const CloudFile(id: 'other', name: 'sample.txt'));
      var marks = 0;
      await expectLater(
        repository.upload(
          _session,
          '0',
          _source(),
          beforeWrite: () async => marks++,
        ),
        throwsA(isA<AppException>()),
      );
      expect(marks, 0);
    },
  );
  test(
    'All personal providers expose upload and folder creation capabilities',
    () {
      expect(
        CloudPlatform.values.every(
          (p) => p.requiresAccount && p.canCreateFolder,
        ),
        isTrue,
      );
    },
  );
  test(
    'Duplicate names and invalid folder names never make write requests',
    () async {
      final (repository, _, connector) = await _fixture();
      connector.files.add(
        const CloudFile(id: 'old', name: 'SAMPLE.TXT', size: 4),
      );
      await expectLater(
        repository.upload(_session, '0', _source()),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        repository.createFolder(_session, '0', 'sample.txt'),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        repository.createFolder(_session, '0', '../outside'),
        throwsA(isA<AppException>()),
      );
      expect(connector.commits, 0);
      expect(connector.folders, 0);
      expect(connector.files.single.id, 'old');
      expect(
        (await repository.createFolder(_session, '0', 'new folder')).parentId,
        '0',
      );
      expect(connector.folders, 1);
    },
  );
  test('Replacing credentials during a source read prevents commit', () async {
    final (repository, vault, connector) = await _fixture();
    connector.onChunk = () =>
        vault.putCredential(CloudPlatform.quark, _credential(2));
    await expectLater(
      repository.upload(_session, '0', _source()),
      throwsA(isA<AppException>()),
    );
    expect(connector.commits, 0);
  });
  test(
    'Cancellation or disabling the cloud stops subsequent bytes and commit',
    () async {
      for (final cancel in [true, false]) {
        var enabled = true;
        final scope = RequestScope();
        final (repository, _, connector) = await _fixture(
          checkAccess: (_) => require(enabled, '网盘已停用'),
        );
        connector.onChunk = () async {
          if (cancel) {
            scope.cancel();
          } else {
            enabled = false;
          }
        };
        await expectLater(
          scope.run(() => repository.upload(_session, '0', _source())),
          throwsA(isA<AppException>()),
        );
        expect(connector.commits, 0);
      }
    },
  );
  test('Share and read-only family sessions refuse writes', () async {
    final (repository, _, connector) = await _fixture();
    for (final session in [
      const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.share,
        title: 'share',
        rootId: '0',
      ),
      const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'family',
        rootId: '0',
        metadata: {'familyId': 'family'},
      ),
    ]) {
      await expectLater(
        repository.upload(session, '0', _source()),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        repository.createFolder(session, '0', 'folder'),
        throwsA(isA<AppException>()),
      );
    }
    expect(connector.commits + connector.folders, 0);
  });
  test(
    'GET upload mutation endpoints are never automatically replayed',
    () async {
      final delegate = FakeHttp((r) => const HttpResult(503, 'unavailable'));
      final http = RetryingJsonHttp(delegate);
      final scope = ReadRetryScope(
        retries: 3,
        checkpoint: RequestScope.checkpoint,
        wait: (_) async {},
      );
      final result = await scope.run(
        () => http.mutationRequest(
          'GET',
          'https://upload.example/person/commitMultiUploadFile',
        ),
      );
      expect(result.status, 503);
      expect(delegate.calls, hasLength(1));
    },
  );
}
