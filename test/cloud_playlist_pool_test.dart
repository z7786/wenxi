import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/resource_pool_preview.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'package:asterlink/playback/playback_controller.dart';
import 'package:asterlink/playback/playback_sources.dart';
import 'player_support.dart';
import 'resource_search_test.dart' show SearchApiFixture;
import 'support.dart';

const _platform = CloudPlatform.guangya;
final _original = BrowseSession(
  platform: _platform,
  mode: BrowseMode.share,
  title: '连续剧',
  rootId: 'root',
  sourceLink: ParsedLink(
    source: 'fixture',
    url: 'https://www.guangyapan.com/s/original',
    kind: LinkKind.cloudShare,
    platform: _platform,
    shareId: 'original',
  ),
);
const _episodes = [
  CloudFile(id: 'ep1', name: '第01集.mp4', size: 100, parentId: 'owner-parent'),
  CloudFile(id: 'ep2', name: '第02集.mp4', size: 200, parentId: 'owner-parent'),
];

class _PoolCloud extends CloudConnector {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  CloudPlatform get platform => _platform;
  final opened = <String>[];
  final prepared = <(String, String)>[];
  final downloaded = <String>[];
  @override
  Future<DownloadSpec> download(BrowseSession s, CloudFile f, Credential? c) {
    downloaded.add(f.id);
    return playback(s, f, c);
  }

  @override
  Future<BrowseSession> openShare(ParsedLink link, Credential? c) async {
    opened.add(link.shareId!);
    return BrowseSession(
      platform: platform,
      mode: BrowseMode.share,
      title: '单文件转存',
      rootId: 'root',
      sourceLink: link,
    );
  }

  @override
  Future<List<CloudFile>> list(BrowseSession s, String p, Credential? c) async {
    final id = s.sourceLink!.shareId!.replaceFirst('pool-', '');
    final source = _episodes.firstWhere((file) => file.id == id);
    return [
      CloudFile(
        id: 'transferred-$id',
        name: source.name,
        size: source.size,
        parentId: p,
      ),
    ];
  }

  @override
  Future<DownloadSpec> playback(
    BrowseSession s,
    CloudFile f,
    Credential? c,
  ) async {
    prepared.add((s.sourceLink!.shareId!, f.id));
    expect(
      f.parentId,
      s.sourceLink!.shareId == 'original' ? 'shared-folder' : 'root',
    );
    return DownloadSpec(
      url: 'https://media.example/${f.id}',
      fileName: f.name,
      expectedSize: f.size,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late SearchApiFixture api;
  late _PoolCloud cloud;
  late ResourcePoolPreview pool;
  PlaybackController? controller;
  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'asterlink-player-pool-playlist-',
    );
    services = AppServices(
      store: StateStore.memory(),
      dataDirectory: directory,
      cacheDirectory: Directory('${directory.path}/cache'),
      transport: FakeNative(),
      files: FakeFiles(directory),
      http: FakeHttp(),
      platformFeatures: false,
      controlEnabled: false,
    );
    cloud = _PoolCloud();
    services.cloud.connectors[_platform] = cloud;
    api = SearchApiFixture((_, _) => const Stream.empty());
    api.resolve = (hit, _, selection) async =>
        ResourceSearchOpenResult.fromJson(hit, {
          'mode': 'temp_share',
          'transfer_scope': 'file',
          'source_file_id': selection.fileId,
          'url': 'https://www.guangyapan.com/s/pool-${selection.fileId}',
        });
    pool = ResourcePoolPreview(
      source: ResourceSearchHit.fromRaw({
        'url': _original.sourceLink!.url,
        'title': '连续剧',
        'open_ticket': 'fixture-grant',
      }),
      api: api,
      cloud: services.cloud,
    );
  });
  tearDown(() async {
    await controller?.close();
    controller = null;
    await services.close();
    if (directory.existsSync()) {
      final parent = Directory.systemTemp.resolveSymbolicLinksSync();
      final actual = directory.resolveSymbolicLinksSync();
      if (!actual.startsWith(
        '$parent${Platform.pathSeparator}asterlink-player-pool-playlist-',
      )) {
        throw StateError('Unexpected pool fixture directory');
      }
      directory.deleteSync(recursive: true);
    }
  });

  Future<PlaybackController> createPlayer() async {
    final first = await pool.resolve(
      _original,
      _episodes.first,
      ['连续剧'],
      RequestScope(),
      sourceParentId: 'shared-folder',
    );
    return controller = cloudPlayback(
      services,
      _original,
      _episodes.first,
      const [
        ..._episodes,
        CloudFile(id: 'note', name: '说明.txt'),
        CloudFile(id: 'folder', name: '其他.mp4', isDirectory: true),
      ],
      parentFolders: {for (final file in _episodes) file.id: 'shared-folder'},
      poolPreview: pool,
      initialPoolTarget: first,
      sourceFolders: ['连续剧'],
      backendFactory: (entry, _) => FakePlaybackBackend(entry.id, []),
    );
  }

  test(
    'Single-file pool shares retain episodes and original history identities',
    () async {
      final player = await createPlayer();
      expect(player.entries.map((entry) => entry.id), ['ep1', 'ep2']);
      expect(player.prepareAhead, isNull);
      expect(api.openSelections.map((item) => item.fileId), ['ep1']);
      await player.start();
      expect(player.error, isEmpty);
      expect(api.openCalls, hasLength(1));
      expect(cloud.prepared, [('pool-ep1', 'transferred-ep1')]);
      await player.load(1);
      expect(player.error, isEmpty);
      expect(api.openSelections.map((item) => item.fileId), ['ep1', 'ep2']);
      expect(api.openSelections.map((item) => item.parentId), [
        'shared-folder',
        'shared-folder',
      ]);
      expect(cloud.prepared.last, ('pool-ep2', 'transferred-ep2'));
      final origin = player.current.source!.cloud!;
      expect(origin.file.id, 'ep2');
      expect(origin.file.parentId, 'shared-folder');
      expect(origin.session.sourceLink!.shareId, 'original');
      expect(
        (player.backend! as FakePlaybackBackend).openedSource!.url,
        'https://media.example/transferred-ep2',
      );
    },
  );

  test(
    'Refreshing a pool source resolves only the selected original episode again',
    () async {
      final player = await createPlayer();
      await player.start();
      await player.load(1);
      await player.load(1, refreshSource: true);
      expect(player.error, isEmpty);
      expect(api.openSelections.map((item) => item.fileId), [
        'ep1',
        'ep2',
        'ep2',
      ]);
      expect(cloud.prepared.last, ('pool-ep2', 'transferred-ep2'));
      expect(player.entries, hasLength(2));
    },
  );

  test(
    'A pool fallback keeps every episode and uses its share-visible parent',
    () async {
      api.resolve = (hit, _, _) async => ResourceSearchOpenResult(
        hit: hit,
        mode: 'original',
        reason: 'policy_disabled',
      );
      final player = await createPlayer();
      await player.start();
      await player.load(1);
      expect(player.error, isEmpty);
      expect(player.entries, hasLength(2));
      expect(cloud.prepared, [('original', 'ep1'), ('original', 'ep2')]);
    },
  );

  test('Downloading the selected episode retains the pool route', () async {
    final player = await createPlayer();
    await player.start();
    await player.load(1);
    final source = await player.acquireForDownload();
    expect(source.url, 'https://media.example/transferred-ep2');
    expect(api.openSelections.last.fileId, 'ep2');
    expect(api.openSelections.last.parentId, 'shared-folder');
    expect(cloud.downloaded, ['transferred-ep2']);
    await player.release(source);
  });

  test(
    'A cancelled pool resolution never prepares a late transferred source',
    () async {
      final player = await createPlayer();
      await player.start();
      final pending = Completer<ResourceSearchOpenResult>();
      api.resolve = (_, _, _) => pending.future;
      final scope = RequestScope();
      final preparing = player.prepare(player.entries[1], scope);
      await until(() => api.openSelections.length == 2);
      scope.cancel();
      pending.complete(
        ResourceSearchOpenResult.fromJson(pool.source, {
          'mode': 'temp_share',
          'transfer_scope': 'file',
          'source_file_id': 'ep2',
          'url': 'https://www.guangyapan.com/s/pool-ep2',
        }),
      );
      await expectLater(preparing, throwsA(isA<AppException>()));
      expect(cloud.prepared, [('pool-ep1', 'transferred-ep1')]);
    },
  );
}
