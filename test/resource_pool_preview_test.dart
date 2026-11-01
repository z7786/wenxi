import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/resource_pool_preview.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/baidu_share_route.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/resource_search.dart';
import 'resource_search_test.dart' show SearchApiFixture;
import 'support.dart';

const original = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.share,
  title: 'Python',
  rootId: 'oldroot',
);
const originalFile = CloudFile(
  id: 'oldfile',
  name: 'README.txt',
  size: 123,
  parentId: 'oldroot',
);

class _PoolConnector extends CloudConnector {
  @override
  CloudPlatform get platform => CloudPlatform.quark;
  final opened = <ParsedLink>[];
  final listed = <String>[];
  final directories = <String, List<CloudFile>>{
    'newroot': [
      const CloudFile(
        id: 'newfile',
        name: 'README.txt',
        size: 123,
        parentId: 'newroot',
      ),
    ],
  };
  @override
  Future<BrowseSession> openShare(
    ParsedLink link,
    Credential? credential,
  ) async {
    opened.add(link);
    return const BrowseSession(
      platform: CloudPlatform.quark,
      mode: BrowseMode.share,
      title: 'Python',
      rootId: 'newroot',
    );
  }

  @override
  Future<List<CloudFile>> list(
    BrowseSession session,
    String parentId,
    Credential? credential,
  ) async {
    listed.add(parentId);
    return directories[parentId] ?? [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late AppServices services;
  late Directory directory;
  late SearchApiFixture api;
  late _PoolConnector connector;
  late ResourcePoolPreview pool;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('asterlink-pool-preview-');
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
    connector = _PoolConnector();
    services.cloud.connectors[CloudPlatform.quark] = connector;
    api = SearchApiFixture((_, _) => const Stream.empty());
    api.resolve = (hit, _, selection) async =>
        ResourceSearchOpenResult.fromJson(hit, {
          'mode': 'temp_share',
          'url': 'https://pan.quark.cn/s/newshare',
          'password': 'nEw2',
          'transfer_scope': 'file',
          'source_file_id': selection.fileId,
        });
    pool = ResourcePoolPreview(
      source: ResourceSearchHit.fromRaw({
        'title': 'Python',
        'url': 'https://pan.quark.cn/s/original',
        'password': 'old1',
        'open_ticket': 'grant',
      }),
      api: api,
      cloud: services.cloud,
    );
  });
  tearDown(() async {
    await services.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'construction and browsing do not transfer; preview maps to the new file ID and password',
    () async {
      expect(api.openCalls, isEmpty);
      final result = await pool.resolve(
        original,
        originalFile,
        [],
        RequestScope(),
      );
      expect(api.openCalls, hasLength(1));
      expect(api.openSelections.single.toJson(), {
        'file_id': 'oldfile',
        'parent_id': 'oldroot',
        'name': 'README.txt',
        'size': 123,
      });
      expect(connector.opened.single.shareId, 'newshare');
      expect(connector.opened.single.passcode, 'nEw2');
      expect(result.file.id, 'newfile');
      expect(result.parentId, 'newroot');
      expect(result.session.sourceLink!.shareId, 'newshare');
    },
  );

  test(
    'nested files request their source parent and map to a single file at the new root',
    () async {
      connector.directories['newroot'] = [
        const CloudFile(
          id: 'newchild',
          name: 'README.txt',
          size: 123,
          parentId: 'newroot',
        ),
      ];
      final result = await pool.resolve(
        original,
        const CloudFile(
          id: 'nestedfile',
          name: 'README.txt',
          size: 123,
          parentId: 'olddocs',
        ),
        ['docs'],
        RequestScope(),
      );
      expect(result.file.id, 'newchild');
      expect(result.parentId, 'newroot');
      expect(connector.listed, ['newroot']);
      expect(api.openSelections.single.fileId, 'nestedfile');
      expect(api.openSelections.single.parentId, 'olddocs');
      expect(result.siblings, hasLength(1));
    },
  );

  test(
    'another preview reuses the transferred share and fresh file IDs',
    () async {
      await pool.resolve(original, originalFile, [], RequestScope());
      final result = await pool.resolve(
        original,
        originalFile,
        [],
        RequestScope(),
      );
      expect(result.file.id, 'newfile');
      expect(api.openCalls, hasLength(2));
      expect(connector.opened, hasLength(1));
    },
  );

  for (final reason in [
    'policy_disabled',
    'policy_probability',
    'backend_unavailable',
    'insufficient_space',
    'no_account',
  ]) {
    test(
      '$reason immediately uses the original file even after a cached transfer',
      () async {
        await pool.resolve(original, originalFile, [], RequestScope());
        api.resolve = (hit, _, _) async => ResourceSearchOpenResult(
          hit: hit,
          mode: 'original',
          reason: reason,
        );
        final result = await pool.resolve(
          original,
          originalFile,
          [],
          RequestScope(),
        );
        expect(result.session, same(original));
        expect(result.file, same(originalFile));
        expect(result.parentId, original.rootId);
        expect(result.siblings, [originalFile]);
        expect(api.openCalls, hasLength(2));
        expect(connector.opened, hasLength(1));
      },
    );
  }

  test(
    'a wrong-size response fails without caching and a retry can resolve the file',
    () async {
      connector.directories['newroot'] = [
        const CloudFile(id: 'wrong-size', name: 'README.txt', size: 456),
      ];
      await expectLater(
        pool.resolve(original, originalFile, [], RequestScope()),
        throwsA(isA<AppException>()),
      );
      connector.directories['newroot'] = [
        const CloudFile(id: 'right-size', name: 'README.txt', size: 123),
      ];
      final result = await pool.resolve(
        original,
        originalFile,
        [],
        RequestScope(),
      );
      expect(result.file.id, 'right-size');
      expect(api.openCalls, hasLength(2));
    },
  );

  test(
    'a share with extra files or a directory is rejected and never cached',
    () async {
      connector.directories['newroot']!.add(
        const CloudFile(id: 'duplicate', name: 'README.txt', size: 123),
      );
      await expectLater(
        pool.resolve(original, originalFile, [], RequestScope()),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('单文件'),
          ),
        ),
      );
      connector.directories['newroot'] = [
        const CloudFile(id: 'folder', name: 'docs', isDirectory: true),
      ];
      await expectLater(
        pool.resolve(original, originalFile, ['missing'], RequestScope()),
        throwsA(isA<AppException>()),
      );
      expect(api.openCalls, hasLength(2));
    },
  );

  test(
    'space fallback preserves nested parent and the chosen Baidu parse route',
    () async {
      for (final route in BaiduShareRoute.values) {
        final session = BrowseSession(
          platform: CloudPlatform.baidu,
          mode: BrowseMode.share,
          title: 'Python',
          rootId: '/',
          metadata: {
            BaiduShareRoute.metadataKey: route.key,
            'parserSiteId': 'chosen-site',
            'parserPasswordGrant': 'existing-grant',
          },
        );
        const nested = CloudFile(
          id: 'baidu-file',
          name: 'lesson.mp4',
          size: 123,
          parentId: '/owner-private-path',
        );
        api.resolve = (hit, _, _) async => ResourceSearchOpenResult(
          hit: hit,
          mode: 'original',
          reason: 'insufficient_space',
        );
        final target = await pool.resolve(
          session,
          nested,
          ['docs'],
          RequestScope(),
          sourceParentId: '/docs',
        );
        expect(target.session, same(session));
        expect(BaiduShareRoute.fromSession(target.session), route);
        expect(target.session.meta('parserSiteId'), 'chosen-site');
        expect(target.session.meta('parserPasswordGrant'), 'existing-grant');
        expect(target.file, same(nested));
        expect(target.parentId, '/docs');
        expect(api.openSelections.last.parentId, '/docs');
        expect(connector.opened, isEmpty);
      }
    },
  );

  test(
    'general transfer failure stays explicit and never opens a new share',
    () async {
      api.resolve = (hit, _, _) async => ResourceSearchOpenResult(
        hit: hit,
        mode: 'original',
        reason: 'transfer_failed',
        message: '暂时未能生成新的分享链接',
      );
      await expectLater(
        pool.resolve(original, originalFile, [], RequestScope()),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('新的分享链接'),
          ),
        ),
      );
      expect(connector.opened, isEmpty);
    },
  );

  test(
    'different files in one share redeem separate grants; revisiting one reuses only its own target',
    () async {
      final first = await pool.resolve(
        original,
        originalFile,
        [],
        RequestScope(),
      );
      connector.directories['newroot'] = [
        const CloudFile(id: 'new-second', name: 'second.txt', size: 456),
      ];
      final second = await pool.resolve(
        original,
        const CloudFile(
          id: 'old-second',
          name: 'second.txt',
          size: 456,
          parentId: 'oldroot',
        ),
        [],
        RequestScope(),
      );
      final firstAgain = await pool.resolve(
        original,
        originalFile,
        [],
        RequestScope(),
      );
      expect(first.file.id, 'newfile');
      expect(second.file.id, 'new-second');
      expect(firstAgain.file.id, 'newfile');
      expect(api.openCalls, hasLength(3));
      expect(api.openSelections.map((s) => s.fileId), [
        'oldfile',
        'old-second',
        'oldfile',
      ]);
      expect(connector.opened, hasLength(2));
    },
  );

  test(
    'the browser parent wins over owner-only metadata and root uses the share root',
    () async {
      const fileWithPrivateParent = CloudFile(
        id: 'oldfile',
        name: 'README.txt',
        size: 123,
        parentId: 'owner-private-parent',
      );
      await pool.resolve(original, fileWithPrivateParent, [], RequestScope());
      expect(api.openSelections.last.parentId, original.rootId);
      await pool.resolve(
        original,
        fileWithPrivateParent,
        ['docs'],
        RequestScope(),
        sourceParentId: 'actual-shared-folder',
      );
      expect(api.openSelections.last.parentId, 'actual-shared-folder');
    },
  );

  test('expired per-file entries request a fresh single-file share', () async {
    var now = DateTime(2026, 10, 22);
    pool = ResourcePoolPreview(
      source: pool.source,
      api: api,
      cloud: services.cloud,
      clock: () => now,
    );
    await pool.resolve(original, originalFile, [], RequestScope());
    now = now.add(const Duration(minutes: 10));
    await pool.resolve(original, originalFile, [], RequestScope());
    expect(api.openCalls, hasLength(2));
  });

  test(
    'whole-share and mismatched source acknowledgements never open a new share',
    () async {
      for (final data in [
        {'mode': 'temp_share', 'url': 'https://pan.quark.cn/s/unsafe'},
        {
          'mode': 'temp_share',
          'url': 'https://pan.quark.cn/s/unsafe',
          'transfer_scope': 'file',
          'source_file_id': 'different-file',
        },
      ]) {
        api.resolve = (hit, _, _) async =>
            ResourceSearchOpenResult.fromJson(hit, data);
        await expectLater(
          pool.resolve(original, originalFile, [], RequestScope()),
          throwsA(isA<AppException>()),
        );
      }
      expect(connector.opened, isEmpty);
    },
  );

  test(
    'a single renamed new file remains mapped using validated scope and size',
    () async {
      connector.directories['newroot'] = [
        const CloudFile(id: 'renamed', name: 'README(1).txt', size: 123),
      ];
      final target = await pool.resolve(
        original,
        originalFile,
        [],
        RequestScope(),
      );
      expect(target.file.id, 'renamed');
    },
  );

  test(
    'directories and missing nested-parent metadata never send a transfer',
    () async {
      await expectLater(
        pool.resolve(
          original,
          const CloudFile(id: 'folder', name: 'docs', isDirectory: true),
          [],
          RequestScope(),
        ),
        throwsA(isA<AppException>()),
      );
      await expectLater(
        pool.resolve(
          original,
          const CloudFile(id: 'file', name: 'lesson.mp4'),
          ['docs'],
          RequestScope(),
        ),
        throwsA(isA<AppException>()),
      );
      expect(api.openCalls, isEmpty);
    },
  );

  test(
    'leaving preview cancels the grant request and ignores late completion',
    () async {
      final waiting = Completer<ResourceSearchOpenResult>();
      api.resolve = (_, _, _) => waiting.future;
      final scope = RequestScope();
      final checked = expectLater(
        pool.resolve(original, originalFile, [], scope),
        throwsA(isA<AppException>()),
      );
      await Future<void>.delayed(Duration.zero);
      scope.cancel();
      await checked;
      waiting.complete(
        ResourceSearchOpenResult.fromJson(api.openCalls.single, {
          'mode': 'temp_share',
          'url': 'https://pan.quark.cn/s/late',
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(connector.opened, isEmpty);
      expect(api.openCancellations.single.isCancelled, isTrue);
    },
  );
}
