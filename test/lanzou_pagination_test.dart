import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_favorites.dart';
import 'package:asterlink/data/cloud_search.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'lanzou_folder_support.dart';
import 'lanzou_folder_test.dart' show repository;
import 'lanzou_support.dart';

LanzouFolderFixture pagedFixture({Future<void> Function(Duration)? delay}) {
  final fixture = LanzouFolderFixture(delay: delay)..withChild();
  fixture.pages['321']![1]!['text'] = [
    for (var i = 0; i < 50; i++)
      {'id': 'iFile$i', 'name_all': 'file$i.zip', 'size': '1 M'},
  ];
  fixture.pages['321']![2] = {
    'zt': 1,
    'text': [
      {'id': 'iExample123', 'name_all': '后页目标.zip', 'size': '1.5 M'},
    ],
  };
  return fixture;
}

List<String> rootPages(LanzouFolderFixture fixture) => [
  for (final request in fixture.http.calls.where(
    (r) => r.method == 'POST' && r.uri.path == '/filemoreajax.php',
  ))
    if (Uri.splitQueryString(request.body as String)['fid'] == '321')
      Uri.splitQueryString(request.body as String)['pg']!,
];

void main() {
  for (final shareLink in [false, true]) {
    test(
      'Opening a saved Lanzou ${shareLink ? 'share link' : 'folder'} reads only the first batch',
      () async {
        final fixture = pagedFixture(), repo = repository(fixture);
        final favorites = CloudFavorites((repo.vault as Vault).store, repo);
        final session = await repo.share(fixture.folderLink());
        if (shareLink) {
          await favorites.toggleShare(session);
        } else {
          await favorites.toggle(
            session,
            CloudFile(
              id: session.rootId,
              name: session.title,
              isDirectory: true,
            ),
            [(session.rootId, '全部文件')],
          );
        }
        fixture.http.calls.clear();
        final opened = await favorites.open(favorites.all.single);
        expect(rootPages(fixture), ['1']);
        expect(opened.files, hasLength(51));
        expect(opened.highlight, isNull);
        expect(opened.cursor, isNotNull);
        final next = await repo.listPage(
          opened.session,
          opened.trail.last.$1,
          cursor: opened.cursor,
        );
        expect(next.files.single.name, '后页目标.zip');
        expect(rootPages(fixture), ['1', '2']);
      },
    );
  }

  test(
    'Opening a saved Lanzou child folder preserves its own pagination',
    () async {
      final fixture = pagedFixture(), repo = repository(fixture);
      final favorites = CloudFavorites((repo.vault as Vault).store, repo);
      fixture.pages['322']![2] = {
        'zt': 1,
        'text': [
          {'id': 'iChildLater', 'name_all': 'child-later.zip', 'size': '2 M'},
        ],
      };
      final session = await repo.share(fixture.folderLink());
      final first = await repo.listPage(session, session.rootId);
      await favorites.toggle(session, first.files.first, [
        (session.rootId, '全部文件'),
      ]);
      fixture.http.calls.clear();
      final opened = await favorites.open(favorites.all.single);
      expect(opened.trail.last.$1, lanzouChildUrl);
      expect(opened.files.single.id, 'iNested789');
      expect(opened.cursor, isNotNull);
      final next = await repo.listPage(
        opened.session,
        opened.trail.last.$1,
        cursor: opened.cursor,
      );
      expect(next.files.single.id, 'iChildLater');
    },
  );

  for (final laterPage in [false, true]) {
    test(
      'Opening a saved Lanzou file on the ${laterPage ? 'second' : 'first'} page stops once located',
      () async {
        final fixture = pagedFixture(), repo = repository(fixture);
        final favorites = CloudFavorites((repo.vault as Vault).store, repo);
        final session = await repo.share(fixture.folderLink());
        final target = CloudFile(
          id: laterPage ? 'iExample123' : 'iFile0',
          name: laterPage ? '后页目标.zip' : 'file0.zip',
        );
        await favorites.toggle(session, target, [(session.rootId, '全部文件')]);
        fixture.http.calls.clear();
        final opened = await favorites.open(favorites.all.single);
        expect(rootPages(fixture), laterPage ? ['1', '2'] : ['1']);
        expect(opened.files, hasLength(laterPage ? 52 : 51));
        expect(opened.files.any((file) => file.id == target.id), isTrue);
        expect(opened.highlight, target.id);
        expect(opened.cursor, isNotNull);
        final next = await repo.listPage(
          opened.session,
          opened.trail.last.$1,
          cursor: opened.cursor,
        );
        if (laterPage) {
          expect(next.files, isEmpty);
          expect(next.hasMore, isFalse);
          expect(rootPages(fixture), ['1', '2', '3']);
        } else {
          expect(next.files.single.id, 'iExample123');
          expect(rootPages(fixture), ['1', '2']);
        }
      },
    );
  }

  test(
    'A missing saved Lanzou file is checked across all batches before failing',
    () async {
      final fixture = pagedFixture(), repo = repository(fixture);
      final favorites = CloudFavorites((repo.vault as Vault).store, repo);
      final session = await repo.share(fixture.folderLink());
      await favorites.toggle(
        session,
        const CloudFile(id: 'iRemoved', name: 'removed.zip'),
        [(session.rootId, '全部文件')],
      );
      fixture.http.calls.clear();
      await expectLater(
        favorites.open(favorites.all.single),
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            '收藏的文件已移动、删除或分享已失效',
          ),
        ),
      );
      expect(rootPages(fixture), ['1', '2', '3']);
      expect(favorites.all.single.lastOpenedAt, 0);
    },
  );

  test(
    'Opening a folder reads only its first batch, including nested folders',
    () async {
      final fixture = pagedFixture(), repo = repository(fixture);
      final session = await repo.share(fixture.folderLink());
      expect(rootPages(fixture), ['1']);
      final first = await repo.listPage(session, session.rootId);
      expect(first.files, hasLength(51));
      expect(first.hasMore, isTrue);
      expect(first.files.first.isDirectory, isTrue);
      expect(rootPages(fixture), ['1']);
      final second = await repo.listPage(
        session,
        session.rootId,
        cursor: first.nextCursor,
      );
      expect(second.files.single.name, '后页目标.zip');
      final done = await repo.listPage(
        session,
        session.rootId,
        cursor: second.nextCursor,
      );
      expect(done.hasMore, isFalse);
      expect(done.files, isEmpty);
      expect(rootPages(fixture), ['1', '2', '3']);
      final replay = await repo.listPage(
        session,
        session.rootId,
        cursor: first.nextCursor,
      );
      expect(replay.files.single.id, second.files.single.id);
      expect(rootPages(fixture), ['1', '2', '3']);
    },
  );

  test(
    'Search reads later pages and nested folders after a partial browser list',
    () async {
      final fixture = pagedFixture(), repo = repository(fixture);
      final session = await repo.share(fixture.folderLink());
      final first = await repo.listPage(session, session.rootId);
      expect(first.hasMore, isTrue);
      final search = CloudDirectorySearch(
        read: repo.list,
        directoryId: repo.directoryId,
        validate: (_) {},
      );
      try {
        await search.start(session, [(session.rootId, '全部文件')], '后页目标');
        expect(search.phase, CloudSearchPhase.completed);
        expect(search.hits.single.file.id, 'iExample123');
        expect(search.scannedEntries, 53);
        await repo.listPage(session, session.rootId);
        final download = await fixture.connector.download(
          session,
          search.hits.single.file,
          null,
        );
        expect(download.url, lanzouTestFinal);
      } finally {
        search.dispose();
      }
      final second = await repo.listPage(
        session,
        session.rootId,
        cursor: first.nextCursor,
      );
      expect(second.files.single.id, 'iExample123');
    },
  );

  test(
    'Folder download collection retains all pages after incremental browsing',
    () async {
      final fixture = pagedFixture(), repo = repository(fixture);
      fixture.pages['322']![2] = {
        'zt': 1,
        'text': [
          {'id': 'iOther456', 'name_all': 'another.zip', 'size': '2 M'},
        ],
      };
      final session = await repo.share(fixture.folderLink());
      final first = await repo.listPage(session, session.rootId);
      final collected = await repo.collect(session, [first.files.first]);
      expect(collected.map((item) => (item.$1.id, item.$2)), [
        ('iNested789', '子目录'),
        ('iOther456', '子目录'),
      ]);
    },
  );

  test(
    'Failed or cancelled later pages retain the cursor and previous files',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var wait = false;
      final fixture = pagedFixture(
            delay: (_) async {
              if (wait) {
                entered.complete();
                await release.future;
              }
            },
          ),
          repo = repository(fixture);
      final session = await repo.share(fixture.folderLink());
      final first = await repo.listPage(session, session.rootId);
      fixture.pages['321']![2] = {'zt': 1, 'text': 'invalid'};
      await expectLater(
        repo.listPage(session, session.rootId, cursor: first.nextCursor),
        throwsA(isA<AppException>()),
      );
      fixture.pages['321']![2] = {
        'zt': 1,
        'text': [
          {'id': 'iExample123', 'name_all': '后页目标.zip', 'size': '1.5 M'},
        ],
      };
      wait = true;
      final scope = RequestScope();
      final operation = scope.run(
        () => repo.listPage(session, session.rootId, cursor: first.nextCursor),
      );
      final cancelled = expectLater(operation, throwsA(isA<AppException>()));
      await entered.future;
      scope.cancel();
      await cancelled;
      wait = false;
      release.complete();
      final next = await repo.listPage(
        session,
        session.rootId,
        cursor: first.nextCursor,
      );
      expect(next.files.single.id, 'iExample123');
      expect(first.files, hasLength(51));
    },
  );

  test(
    'Concurrent calls using the same cursor reuse one page request',
    () async {
      final fixture = pagedFixture(), repo = repository(fixture);
      final session = await repo.share(fixture.folderLink());
      final first = await repo.listPage(session, session.rootId);
      final result = await Future.wait([
        repo.listPage(session, session.rootId, cursor: first.nextCursor),
        repo.listPage(session, session.rootId, cursor: first.nextCursor),
      ]);
      expect(
        result.map((page) => page.files.single.id),
        everyElement('iExample123'),
      );
      expect(rootPages(fixture), ['1', '2']);
      await expectLater(
        repo.listPage(session, lanzouChildUrl, cursor: first.nextCursor),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'A frequency retry stays on the requested page and deduplicates overlaps',
    () async {
      final fixture = pagedFixture(), repo = repository(fixture);
      fixture.pages['321']![2]!['text'] = [
        {'id': 'iFile49', 'name_all': 'file49.zip', 'size': '1 M'},
        {'id': 'iExample123', 'name_all': '后页目标.zip', 'size': '1.5 M'},
      ];
      var limited = false;
      fixture.folderOverride = (request) {
        if (request.method == 'POST' &&
            request.uri.path == '/filemoreajax.php' &&
            Uri.splitQueryString(request.body as String)['pg'] == '2' &&
            !limited) {
          limited = true;
          return HttpResult(200, jsonEncode({'zt': 4}));
        }
        return null;
      };
      final session = await repo.share(fixture.folderLink());
      final first = await repo.listPage(session, session.rootId);
      final next = await repo.listPage(
        session,
        session.rootId,
        cursor: first.nextCursor,
      );
      expect(rootPages(fixture), ['1', '2', '2']);
      final merged = {
        for (final file in [...first.files, ...next.files]) file.id: file,
      };
      expect(merged, hasLength(52));
    },
  );
}
