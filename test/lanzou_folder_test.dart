import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/core/operation_progress.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/lanzou_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/links.dart';
import 'lanzou_folder_support.dart';
import 'lanzou_support.dart';

Matcher fails(String message) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(message)),
);

CloudRepository repository(LanzouFolderFixture fixture) {
  final store = StateStore.memory();
  return CloudRepository(
    fixture.http,
    Vault(store),
    CleanupOutbox(store, fixture.http),
  )..connectors[CloudPlatform.lanzou] = fixture.connector;
}

void main() {
  const paginationScript = '''
function loaded(msg) {
  var data = msg.text;
  if(data.length<50){
    document.getElementById("filemore").style.display="none";
  }
}''';

  test('Only a recognized folder pagination template ends on a short page', () {
    expect(LanzouPage(lanzouFolderPage()).folderPageSize, isNull);
    expect(
      LanzouPage(
        lanzouFolderPage(paginationScript: paginationScript),
      ).folderPageSize,
      50,
    );
    expect(
      LanzouPage(
        lanzouFolderPage(paginationScript: '/* $paginationScript */'),
      ).folderPageSize,
      isNull,
    );
    expect(
      LanzouPage(
        lanzouFolderPage(
          paginationScript: paginationScript.replaceAll('filemore', 'advert'),
        ),
      ).folderPageSize,
      isNull,
    );
  });

  test(
    'A short final folder page completes without an extra list request',
    () async {
      final fixture = LanzouFolderFixture();
      fixture.folders['/bFolder123'] = lanzouFolderPage(
        paginationScript: paginationScript,
      );
      fixture.pages['321']![1]!['text'] = [
        for (var i = 0; i < 50; i++)
          {'id': 'iFile$i', 'name_all': 'file$i.zip', 'size': '1 M'},
      ];
      fixture.pages['321']![2] = {
        'zt': 1,
        'text': [
          {'id': 'iLastFile', 'name_all': 'last.zip', 'size': '1 M'},
        ],
      };
      final session = await fixture.openFolder();
      final files = await fixture.connector.list(session, session.rootId, null);
      expect(files, hasLength(51));
      expect(files.last.id, 'iLastFile');
      expect(fixture.http.calls.where((r) => r.method == 'POST'), hasLength(2));
    },
  );

  test(
    'Folder parsing reports file counts and rate-limit waiting as files are read',
    () async {
      final fixture = LanzouFolderFixture();
      fixture.folders['/bFolder123'] = lanzouFolderPage(
        paginationScript: paginationScript,
      );
      fixture.pages['321']![1]!['text'] = [
        for (var i = 0; i < 50; i++)
          {'id': 'iFile$i', 'name_all': 'file$i.zip', 'size': '1 M'},
      ];
      fixture.pages['321']![2] = {
        'zt': 1,
        'text': [
          {'id': 'iLastFile', 'name_all': 'last.zip', 'size': '1 M'},
        ],
      };
      var limited = false;
      fixture.folderOverride = (request) {
        if (request.method == 'POST' &&
            Uri.splitQueryString(request.body as String)['pg'] == '2' &&
            !limited) {
          limited = true;
          return HttpResult(200, jsonEncode({'zt': 4}));
        }
        return null;
      };
      final progress = OperationProgress();
      final readings = <OperationStep>[];
      progress.addListener(() {
        final reading = progress.value
            .where((step) => step.stage == OperationStage.readFiles)
            .lastOrNull;
        if (reading != null) readings.add(reading);
      });
      final repo = repository(fixture);
      try {
        await progress.run(() async {
          final session = await repo.share(fixture.folderLink());
          expect(await repo.list(session, session.rootId), hasLength(51));
        });
        expect(
          readings.map((step) => step.itemsRead),
          containsAll([0, 50, 51]),
        );
        expect(
          readings.any((step) => step.itemsRead == 50 && step.waitingForRetry),
          isTrue,
        );
        expect(
          progress.value.every(
            (step) => step.status == OperationStepStatus.completed,
          ),
          isTrue,
        );
        expect(
          fixture.http.calls.where((r) => r.method == 'POST'),
          hasLength(3),
        );
      } finally {
        progress.dispose();
      }
    },
  );

  test(
    'MoePal aliases work for folder roots, cross-domain children and file downloads',
    () async {
      final fixture = LanzouFolderFixture();
      const root = 'https://author.lanzou123.net/bFolder123';
      const child = 'https://other.lansou.cn/bNested456';
      fixture.folders['/bFolder123'] = lanzouFolderPage(
        children:
            '<div class="mbxfolder"><a href="$child"><div class="filename">子目录</div></a></div>',
      );
      final repo = repository(fixture);
      final session = await repo.share(
        LinkParser.parse('$root 提取码：Ab12').single,
      );
      expect(session.rootId, root);
      final rootFiles = await repo.list(session, session.rootId);
      expect(rootFiles.singleWhere((file) => file.isDirectory).id, child);
      final children = await repo.list(session, child);
      expect(children.single.token, 'https://other.lansou.cn/iNested789');
      final download = await fixture.connector.download(
        session,
        children.single,
        null,
      );
      expect(download.url, lanzouTestFinal);
      expect(download.headers['Referer'], 'https://other.lansou.cn/');
      final folderPosts = fixture.http.calls.where(
        (request) => request.uri.path == '/filemoreajax.php',
      );
      expect(folderPosts.map((request) => request.uri.host).toSet(), {
        'author.lanzou123.net',
        'other.lansou.cn',
      });
      expect(
        folderPosts.every(
          (request) =>
              Uri.splitQueryString(request.body as String)['pwd'] == 'Ab12',
        ),
        isTrue,
      );
    },
  );
  test(
    'Folder parameters use the actual data fields and DOM password marker',
    () {
      final page = LanzouPage(lanzouFolderPage());
      expect(page.folderParameters(), {
        'lx': '2',
        'fid': '321',
        't': '1789000100',
        'k': 'real-folder-sign',
        'pwd': '',
      });
      expect(page.folderPasswordRequired, isFalse);
      expect(page.folderName, '示例文件夹');
      final scriptTitle = LanzouPage(r'''<script>var title_name='工具合集';
document.title=title_name + ' - 蓝奏云';</script>''');
      expect(scriptTitle.folderName, '工具合集');
      expect(LanzouPage.sizeFromLabel('1.5 M'), 1572864);
      expect(LanzouPage.sizeFromLabel('10.2 MB'), (10.2 * 1024 * 1024).round());
      expect(LanzouPage.sizeFromLabel('unknown'), 0);
    },
  );

  test(
    'Folder listing paginates, deduplicates overlaps and resolves no file links',
    () async {
      final pauses = <Duration>[];
      final fixture = LanzouFolderFixture(
        delay: (duration) async => pauses.add(duration),
      );
      fixture.pages['321']![1]!['text'] = [
        {
          'id': 'iExample123',
          'name_all': 'Example & 1.zip',
          'size': '1.5 M',
          'time': '2026-09-14',
        },
        {'id': 'iSecond456', 'name_all': '第二个.txt', 'size': '2 KB'},
      ];
      fixture.pages['321']![2] = {
        'zt': 1,
        'text': [
          {'id': 'iSecond456', 'name_all': '第二个.txt', 'size': '2 KB'},
          {'id': 'iThird789', 'name_all': '第三个.zip', 'size': '40 M'},
        ],
      };
      final session = await fixture.openFolder('a&+');
      final calls = fixture.http.calls.length;
      final files = await fixture.connector.list(session, session.rootId, null);
      expect(session.rootId, lanzouFolderUrl);
      expect(session.title, '示例文件夹');
      expect(files.map((f) => f.id), [
        'iExample123',
        'iSecond456',
        'iThird789',
      ]);
      expect(files.map((f) => f.parentId), everyElement(lanzouFolderUrl));
      expect(files.first.size, 1572864);
      expect(files.first.token, lanzouTestUrl);
      expect(fixture.http.calls.length, calls);
      final requests = fixture.http.calls
          .where((r) => r.method == 'POST')
          .toList();
      expect(
        requests.map((r) => Uri.splitQueryString(r.body as String)['pg']),
        ['1', '2', '3'],
      );
      for (final request in requests) {
        expect(request.uri.path, '/filemoreajax.php');
        expect(request.headers['Referer'], lanzouFolderUrl);
        expect(request.headers['Cookie'], contains('folder_session=anonymous'));
        expect(Uri.splitQueryString(request.body as String)['pwd'], 'a&+');
      }
      expect(pauses, [
        const Duration(milliseconds: 600),
        const Duration(milliseconds: 600),
      ]);
      expect(fixture.http.peeks, isEmpty);
    },
  );

  test(
    'Missing and wrong folder passwords, deleted folders fail without leaking response text',
    () async {
      final fixture = LanzouFolderFixture();
      fixture.folders['/bFolder123'] = lanzouFolderPage(password: true);
      await expectLater(fixture.openFolder(), fails('需要提取码'));
      expect(fixture.http.calls.where((r) => r.method == 'POST'), isEmpty);
      fixture.pages['321']![1] = {'zt': 3, 'info': 'secret server details'};
      await expectLater(fixture.openFolder('bad'), fails('提取码错误'));
      fixture.folders['/bFolder123'] = '<div>文件夹已取消分享</div>';
      await expectLater(fixture.openFolder(), fails('取消分享'));
    },
  );

  test('An empty folder is a successful empty list', () async {
    final fixture = LanzouFolderFixture();
    fixture.pages['321']!.clear();
    final session = await fixture.openFolder();
    expect(
      await fixture.connector.list(session, session.rootId, null),
      isEmpty,
    );
    expect(fixture.http.calls.where((r) => r.method == 'POST'), hasLength(1));
  });

  test(
    'Nested folder navigation and recursive collection preserve paths without eager file parsing',
    () async {
      final fixture = LanzouFolderFixture()..withChild();
      final repo = repository(fixture);
      final session = await repo.share(fixture.folderLink('code'));
      final rootFiles = await repo.list(session, session.rootId);
      final child = rootFiles.singleWhere((f) => f.isDirectory);
      expect(child.name, '子目录');
      expect(child.id, lanzouChildUrl);
      final collected = await repo.collect(session, rootFiles);
      expect(collected.map((f) => (f.$1.id, f.$2)), [
        ('iNested789', '子目录'),
        ('iExample123', ''),
      ]);
      expect(collected.first.$1.parentId, lanzouChildUrl);
      expect(
        fixture.http.calls.where((r) => r.uri.path == '/ajaxm.php'),
        isEmpty,
      );
      expect(fixture.http.calls.where((r) => r.method == 'HEAD'), isEmpty);
      expect(
        fixture.http.calls
            .where((r) => r.uri.path == '/filemoreajax.php')
            .map((r) => Uri.splitQueryString(r.body as String)['pwd']),
        everyElement('code'),
      );
    },
  );

  test(
    'Selecting a file uses its own share and final exact length instead of rounded folder size',
    () async {
      final fixture = LanzouFolderFixture();
      fixture.pages['321']![1]!['text'] = [
        {'id': 'iExample123', 'name_all': 'Example & 1.zip', 'size': '1.49 MB'},
      ];
      final session = await fixture.openFolder();
      final file = (await fixture.connector.list(
        session,
        session.rootId,
        null,
      )).single;
      final before = fixture.http.calls.length;
      final spec = await fixture.connector.download(session, file, null);
      expect(spec.url, lanzouTestFinal);
      expect(spec.expectedSize, 1234567);
      expect(spec.cleanup, isNull);
      expect(
        fixture.http.calls
            .skip(before)
            .where((r) => r.uri.path == '/filemoreajax.php'),
        isEmpty,
      );
      expect(
        fixture.http.calls.skip(before).any((r) => r.url == lanzouTestUrl),
        isTrue,
      );
      expect(spec.headers['Cookie'], isNull);
    },
  );

  test(
    'Folder file query parameters survive resolution without becoming the file identity',
    () async {
      final fixture = LanzouFolderFixture();
      const reference = 'iExample123?webpage=preview_a%2Bb_c&key=one&key=two';
      fixture.pages['321']![1]!['text'] = [
        {'id': reference, 'name_all': 'Example & 1.zip', 'size': '1.5 M'},
      ];
      final session = await fixture.openFolder('Ab12');
      final file = (await fixture.connector.list(
        session,
        session.rootId,
        null,
      )).single;
      expect(file.id, 'iExample123');
      expect(file.token, 'https://author.lanzouu.com/$reference');
      final spec = await fixture.connector.download(session, file, null);
      expect(spec.url, lanzouTestFinal);
      expect(spec.expectedSize, fixture.exactSize);
      expect(
        fixture.http.calls
            .where((r) => r.uri.path == '/iExample123')
            .single
            .url,
        'https://author.lanzouu.com/$reference',
      );
    },
  );

  test(
    'A saved folder download uses renewed webpage parameters after restart',
    () async {
      final fixture = LanzouFolderFixture();
      fixture.pages['321']![1]!['text'] = [
        {
          'id': 'iExample123?webpage=before',
          'name_all': 'Example & 1.zip',
          'size': '1.5 M',
        },
      ];
      final repo = repository(fixture);
      final session = await repo.share(fixture.folderLink());
      final file = (await repo.list(session, session.rootId)).single;
      final saved = DownloadSpec.fromJson(
        asJson(
          jsonDecode(encoded((await repo.prepare(session, file)).toJson())),
        ),
      );
      final restarted = LanzouFolderFixture();
      restarted.pages['321']![1]!['text'] = [
        {
          'id': 'iExample123?webpage=renewed',
          'name_all': 'Example & 1.zip',
          'size': '1.5 M',
        },
      ];
      final refreshed = await repository(restarted).refresh(saved);
      expect(refreshed.url, lanzouTestFinal);
      expect(
        restarted.http.calls
            .where((r) => r.uri.path == '/iExample123')
            .single
            .url,
        '$lanzouTestUrl?webpage=renewed',
      );
    },
  );

  test(
    'Folder pagination deduplicates a file whose webpage parameter changes',
    () async {
      final fixture = LanzouFolderFixture();
      fixture.pages['321']![1]!['text'] = [
        {
          'id': 'iExample123?webpage=first',
          'name_all': 'Example & 1.zip',
          'size': '1.5 M',
        },
      ];
      fixture.pages['321']![2] = {
        'zt': 1,
        'text': [
          {
            'id': 'iExample123?webpage=second',
            'name_all': 'Example & 1.zip',
            'size': '1.5 M',
          },
          {'id': 'iSecond456', 'name_all': 'second.txt', 'size': '2 KB'},
        ],
      };
      final session = await fixture.openFolder();
      final files = await fixture.connector.list(session, session.rootId, null);
      expect(files.map((file) => file.id), ['iExample123', 'iSecond456']);
      expect(files.first.token, '$lanzouTestUrl?webpage=second');
    },
  );

  test(
    'Folder file references reject invalid paths, fragments and malformed escapes',
    () async {
      for (final reference in [
        'https://evil.test/iExample123?webpage=value',
        '//evil.test/iExample123?webpage=value',
        '../iExample123?webpage=value',
        'iExample123/other?webpage=value',
        'iExample123#?webpage=value',
        'iExample123?webpage=bad value',
        'iExample123?webpage=%GG',
      ]) {
        final fixture = LanzouFolderFixture();
        fixture.pages['321']![1]!['text'] = [
          {'id': reference, 'name_all': 'Example & 1.zip', 'size': '1.5 M'},
        ];
        await expectLater(
          fixture.openFolder(),
          fails('文件分享标识无效'),
          reason: reference,
        );
        expect(
          fixture.http.calls.where((r) => r.uri.path.startsWith('/i')),
          isEmpty,
        );
      }
    },
  );

  test(
    'Persisted nested downloads refresh after restart without in-memory folder state',
    () async {
      final fixture = LanzouFolderFixture()..withChild();
      final repo = repository(fixture);
      final session = await repo.share(fixture.folderLink('code'));
      final child = (await repo.list(
        session,
        session.rootId,
      )).firstWhere((f) => f.isDirectory);
      final file = (await repo.list(session, child.id)).single;
      final saved = (await repo.prepare(
        session,
        file,
      )).copyWith(fileName: '保留名称.zip', relativePath: '子目录');
      final serialized = encoded(saved.toJson());
      expect(serialized, isNot(contains('folder_session')));
      expect(serialized, isNot(contains('share_session')));
      final restarted = LanzouFolderFixture()..withChild();
      final next = repository(restarted);
      final refreshed = await next.refresh(
        DownloadSpec.fromJson(asJson(jsonDecode(serialized))),
      );
      expect(refreshed.url, lanzouTestFinal);
      expect(refreshed.fileName, '保留名称.zip');
      expect(refreshed.relativePath, '子目录');
      expect(
        restarted.http.calls.any((r) => r.uri.path == '/bNested456'),
        isTrue,
      );
      expect(
        restarted.http.calls.any((r) => r.uri.path == '/iNested789'),
        isTrue,
      );
      expect(next.vault.credential(CloudPlatform.lanzou), isNull);
    },
  );

  test(
    'Refreshing a folder invalidates old lists and removed files cannot become downloads',
    () async {
      final fixture = LanzouFolderFixture();
      final session = await fixture.openFolder();
      final original = (await fixture.connector.list(
        session,
        session.rootId,
        null,
      )).single;
      fixture.pages['321']!.clear();
      expect(
        await fixture.connector.list(session, session.rootId, null),
        isEmpty,
      );
      await expectLater(
        fixture.connector.download(session, original, null),
        fails('已移动或失效'),
      );
      expect(
        fixture.http.calls.where((r) => r.uri.path == '/ajaxm.php'),
        isEmpty,
      );
    },
  );

  test(
    'A repeated non-empty page fails and never publishes an incomplete cached list',
    () async {
      final fixture = LanzouFolderFixture();
      fixture.pages['321']![2] = fixture.pages['321']![1]!;
      await expectLater(fixture.openFolder(), fails('分页重复'));
      fixture.pages['321']!.remove(2);
      final session = await fixture.openFolder();
      expect(
        await fixture.connector.list(session, session.rootId, null),
        hasLength(1),
      );
    },
  );

  test(
    'Unknown or malformed list responses never silently drop entries',
    () async {
      for (final response in <Json>[
        {'zt': 5},
        {'zt': 1, 'text': 'not a list'},
        {
          'zt': 1,
          'text': [
            {'id': 'https://evil.test/file', 'name_all': 'bad'},
          ],
        },
        {
          'zt': 1,
          'text': [
            {'id': 'iBad123'},
          ],
        },
      ]) {
        final fixture = LanzouFolderFixture();
        fixture.pages['321']![1] = response;
        await expectLater(fixture.openFolder(), throwsA(isA<AppException>()));
        expect(
          fixture.http.calls.any((r) => r.uri.host == 'evil.test'),
          isFalse,
        );
      }
    },
  );

  test(
    'Transient folder busy responses retry the same page with a finite budget',
    () async {
      final pauses = <Duration>[];
      final fixture = LanzouFolderFixture(
        delay: (duration) async => pauses.add(duration),
      );
      fixture.pages['321']![1] = {'zt': 4};
      await expectLater(fixture.openFolder(), fails('过于频繁'));
      final requests = fixture.http.calls.where((r) => r.method == 'POST');
      expect(requests, hasLength(3));
      expect(
        requests.map((r) => Uri.splitQueryString(r.body as String)['pg']),
        everyElement('1'),
      );
      expect(pauses.length, 2);
    },
  );

  test(
    'Cancelling a pagination wait stops requests and does not cache partial results',
    () async {
      final waiting = Completer<void>(), entered = Completer<void>();
      final fixture = LanzouFolderFixture(
        delay: (_) {
          if (!entered.isCompleted) entered.complete();
          return waiting.future;
        },
      );
      final scope = RequestScope();
      final operation = scope.run(fixture.openFolder);
      final expected = expectLater(operation, fails('取消'));
      await entered.future;
      scope.cancel();
      await expected;
      expect(fixture.http.calls.where((r) => r.method == 'POST'), hasLength(1));
      waiting.complete();
      fixture.pages['321']!.clear();
      final session = await fixture.openFolder();
      expect(
        await fixture.connector.list(session, session.rootId, null),
        isEmpty,
      );
    },
  );

  test('Nested external links are rejected before fetching them', () async {
    final fixture = LanzouFolderFixture();
    fixture.folders['/bFolder123'] = lanzouFolderPage(
      children:
          '<div class="mbxfolder"><a href="https://evil.test/bFolder"><span class="filename">bad</span></a></div>',
    );
    await expectLater(fixture.openFolder(), fails('蓝奏'));
    expect(fixture.http.calls, hasLength(1));
    expect(fixture.http.calls.any((r) => r.uri.host == 'evil.test'), isFalse);
  });
}
