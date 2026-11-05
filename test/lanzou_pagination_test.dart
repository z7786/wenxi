import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cloud_search.dart';
import 'package:asterlink/data/http.dart';
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
