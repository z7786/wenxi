import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/downloads.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/download/transfer_http.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'package:asterlink/playback/playback_failure.dart';
import 'player_support.dart';
import 'remote_control_support.dart';
import 'support.dart';

const _file = CloudFile(id: 'first', name: '第一集.mp4', parentId: '0', size: 4);
const _second = CloudFile(
  id: 'second',
  name: '第二集.mp4',
  parentId: '0',
  size: 4,
);

class _Connector extends CloudConnector {
  _Connector(this.platform);
  @override
  final CloudPlatform platform;
  final calls = <String>[];
  Future<void>? barrier;
  DownloadCleanup? cleanup;
  BrowseSession get session => BrowseSession(
    platform: platform,
    mode: BrowseMode.personal,
    rootId: '0',
    title: '测试网盘',
  );
  @override
  Future<CloudAccount> account(Credential c) async {
    calls.add('account');
    return const CloudAccount('fixture');
  }

  @override
  Future<BrowseSession> openPersonal(Credential c) async {
    calls.add('personal');
    await barrier;
    return session;
  }

  @override
  Future<BrowseSession> openShare(ParsedLink l, Credential? c) async {
    calls.add('share');
    return session;
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession s,
    String parentId,
    Credential? c,
  ) async {
    calls.add('list');
    return [_file, _second];
  }

  @override
  Future<DownloadSpec> download(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    calls.add('download:${f.id}');
    await barrier;
    return DownloadSpec(
      url: 'https://download.example.test/${f.id}',
      fileName: f.name,
      expectedSize: 4,
      cleanup: cleanup,
    );
  }

  @override
  Future<DownloadSpec> playback(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    calls.add('play:${f.id}');
    return DownloadSpec(
      url: 'https://video.example.test/${f.id}',
      fileName: f.name,
      expectedSize: 4,
    );
  }

  @override
  Future<void> delete(
    BrowseSession s,
    List<CloudFile> files,
    Credential c,
  ) async {
    calls.add('delete:${files.single.id}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Probe extends TransferHttp {
  @override
  Future<Probe> probe(String url, Map<String, String> headers) async =>
      const Probe(RemoteIdentity(4, '"fixture"', null), false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppServices services;
  late Directory root;
  late FakeControlFetcher fetcher;
  late FakeNative native;
  late _Connector connector;
  int revision = 0;
  Future<void> disable([List<String> names = const ['quark']]) async {
    fetcher.text = jsonEncode(
      controlJson(revision: ++revision, disabled: names),
    );
    await services.control.refresh(force: true);
  }

  setUp(() async {
    revision = 0;
    root = await Directory.systemTemp.createTemp('aster-control-');
    final store = StateStore.memory({
      'credentials': {
        for (final p in [CloudPlatform.quark, CloudPlatform.tianyi])
          p.key: Credential('fixture', {
            'primary': '__pus=fixture; __puus=fixture',
          }, updatedAt: 1).toJson(),
      },
    });
    fetcher = FakeControlFetcher();
    native = FakeNative();
    services = AppServices(
      store: store,
      dataDirectory: root,
      cacheDirectory: Directory('${root.path}/cache'),
      transport: native,
      files: FakeFiles(Directory('${root.path}/saved')),
      http: FakeHttp(),
      transferHttp: _Probe(),
      platformFeatures: false,
      controlUrl: controlEndpoint,
      controlEnabled: true,
      controlFetcher: fetcher,
      clock: () => controlNow,
    );
    connector = _Connector(CloudPlatform.quark);
    services.cloud.connectors[CloudPlatform.quark] = connector;
  });
  tearDown(() async {
    await services.close();
    await root.delete(recursive: true);
  });

  test(
    'All eight switches reject new personal entry before account or connector access',
    () async {
      await disable(CloudPlatform.values.map((p) => p.name).toList());
      for (final p in CloudPlatform.values) {
        await expectLater(
          services.cloud.personal(p),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'reason',
              contains('维护'),
            ),
          ),
        );
      }
      expect(connector.calls, isEmpty);
    },
  );

  test(
    'Blocked provider rejects parse, list, family, collection, playback, history and cached new downloads',
    () async {
      await disable();
      final cloud = services.cloud;
      final session = connector.session;
      final origin = DownloadOrigin(session, _file, 1);
      final actions = <Future<Object?> Function()>[
        () => cloud.share(
          ParsedLink(
            source: '',
            url: 'https://pan.quark.cn/s/fixture',
            kind: LinkKind.cloudShare,
            platform: CloudPlatform.quark,
            shareId: 'fixture',
          ),
        ),
        () => cloud.list(session, '0'),
        () => cloud.familySpaces(CloudPlatform.quark),
        () => cloud.family(CloudPlatform.quark, 'family'),
        () => cloud.collect(session, [_file]),
        () => cloud.prepare(session, _file),
        () => cloud.preparePlayback(session, _file),
        () => cloud.restoreOrigin(origin),
        () => services.downloads.enqueue(
          DownloadSpec(
            url: 'https://download.example.test/file',
            fileName: _file.name,
            source: origin.toJson(),
          ),
        ),
      ];
      for (final action in actions) {
        await expectLater(
          action(),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'reason',
              contains('维护'),
            ),
          ),
        );
      }
      expect(services.downloads.tasks, isEmpty);
      expect(connector.calls, isEmpty);
    },
  );

  test(
    'New login is rejected, in-flight login cannot commit, and logout remains available',
    () async {
      final response = Completer<LoginResult>();
      final login = services.login.submit(
        CloudPlatform.quark,
        (_) => response.future,
      );
      final cancelledLogin = expectLater(login, throwsA(isA<AppException>()));
      await disable();
      response.complete(
        LoginResult(
          Credential('new', {'primary': 'new'}),
          const CloudAccount('new'),
        ),
      );
      await cancelledLogin;
      expect(services.vault.credential(CloudPlatform.quark)!.updatedAt, 1);
      var entered = false;
      await expectLater(
        services.login.submit(CloudPlatform.quark, (_) async {
          entered = true;
          return response.future;
        }),
        throwsA(isA<AppException>()),
      );
      expect(entered, isFalse);
      await services.login.remove(CloudPlatform.quark);
      expect(services.vault.credential(CloudPlatform.quark), isNull);
    },
  );

  test(
    'Closing a provider during source preparation releases its staged temporary file',
    () async {
      final barrier = Completer<void>();
      connector.barrier = barrier.future;
      final cleanup = connector.cleanup = const DownloadCleanup(
        url: 'https://cleanup.example.test/file',
      );
      await services.cleanups.stage(cleanup);
      final source = services.cloud.prepare(connector.session, _file);
      await disable();
      barrier.complete();
      await expectLater(source, throwsA(isA<AppException>()));
      await services.cleanups.drain();
      expect(services.cleanups.pendingCount, 0);
    },
  );

  test(
    'Existing download refresh bypass is private to that operation and still validates identity',
    () async {
      final original = await services.cloud.prepare(connector.session, _file);
      await disable();
      final barrier = Completer<void>();
      connector.barrier = barrier.future;
      final refreshing = services.cloud.refresh(original);
      await expectLater(
        services.cloud.personal(CloudPlatform.quark),
        throwsA(isA<AppException>()),
      );
      barrier.complete();
      final refreshed = await refreshing;
      expect(refreshed.source!['accountRevision'], 1);
      expect(refreshed.fileName, original.fileName);
      await expectLater(
        services.cloud.prepare(connector.session, _file),
        throwsA(isA<AppException>()),
      );
      await services.vault.removeCredential(CloudPlatform.quark);
      await expectLater(
        services.cloud.refresh(original),
        throwsA(isA<AccountLoginRequired>()),
      );
    },
  );

  test(
    'An existing paused download can resume and finish while new tasks are disabled',
    () async {
      final spec = await services.cloud.prepare(connector.session, _file);
      await services.store.put('tasks', [
        DownloadTask(
          id: 'existing',
          spec: spec,
          createdAt: 1,
          status: DownloadStatus.paused,
        ).toJson(),
      ]);
      await services.downloads.initialize();
      await disable();
      await services.downloads.resume('existing');
      await until(
        () =>
            services.downloads.task('existing')?.status ==
                DownloadStatus.completed &&
            services.downloads.activeCount == 0,
      );
      final path = services.downloads.task('existing')!.savedPath!;
      expect(await File(path).readAsBytes(), native.content);
      await expectLater(
        services.downloads.enqueue(spec),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Personal-folder automatic cleanup still executes for a disabled provider',
    () async {
      final tianyi = _Connector(CloudPlatform.tianyi);
      services.cloud.connectors[CloudPlatform.tianyi] = tianyi;
      await disable(['tianyi']);
      const cleanup = DownloadCleanup(
        url: '',
        action: {
          'platform': 'Tianyi',
          'kind': 'temporary-folder',
          'accountRevision': 1,
          'folderId': 'temporary',
          'name': 'AsterLink临时转存_12345678-1234-1234-1234-123456789012',
        },
      );
      await services.cleanups.stage(cleanup);
      await services.cleanups.ready(cleanup);
      await services.cleanups.drain();
      expect(tianyi.calls, ['personal', 'delete:temporary']);
      expect(services.cleanups.pendingCount, 0);
    },
  );

  test(
    'Active playback can refresh and change decoding, while next episode and retry cannot bypass a switch',
    () async {
      final backends = <FakePlaybackBackend>[];
      final player = cloudPlayback(
        services,
        connector.session,
        _file,
        [_file, _second],
        backendFactory: (_, _) {
          final backend = FakePlaybackBackend('fixture', []);
          backends.add(backend);
          return backend;
        },
      );
      addTearDown(player.close);
      await player.start();
      expect(player.ready, isTrue);
      await disable();
      backends.last
        ..failure = PlaybackFailure.http(403)
        ..fail();
      await until(() => backends.length == 2 && player.ready);
      await player.setHardwareAcceleration(false);
      expect(player.ready, isTrue);
      final calls = connector.calls.length;
      await expectLater(
        player.acquireForDownload(),
        throwsA(isA<AppException>()),
      );
      expect(connector.calls.length, calls);
      await player.next();
      expect(player.error, contains('维护'));
      expect(connector.calls.length, calls);
      await player.retry();
      expect(player.error, contains('维护'));
      expect(connector.calls.length, calls);
    },
  );

  test(
    'A newly opened player cannot use the retry button to bypass a disabled provider',
    () async {
      await disable();
      final player = cloudPlayback(
        services,
        connector.session,
        _file,
        [_file],
        backendFactory: (_, _) => FakePlaybackBackend('fixture', []),
      );
      addTearDown(player.close);
      await player.start();
      expect(player.error, contains('维护'));
      await player.retry();
      expect(player.error, contains('维护'));
      expect(connector.calls, isEmpty);
    },
  );
}
