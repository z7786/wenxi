import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/guangya.dart';
import 'package:asterlink/domain/cloud_file_time.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';
import 'token_cloud_support.dart';

const p = CloudPlatform.guangya;

void main() {
  test('File times retain compact dates and Unix timestamp precision', () {
    final instant = DateTime(2026, 10, 4, 7, 8, 9, 123, 456);
    final times = <Object, DateTime>{
      '20261004': DateTime(2026, 10, 4),
      20261004: DateTime(2026, 10, 4),
      '20261004070809': DateTime(2026, 10, 4, 7, 8, 9),
      instant.millisecondsSinceEpoch ~/ 1000: DateTime(2026, 10, 4, 7, 8, 9),
      '${instant.millisecondsSinceEpoch ~/ 1000}.123456': instant,
      '${instant.millisecondsSinceEpoch}.456': instant,
      instant.microsecondsSinceEpoch: instant,
    };
    for (final entry in times.entries) {
      final file = GuangyaConnector.file({
        'fileId': 'time-file',
        'fileName': 'time.txt',
        'updatedAt': entry.key,
      }, 'root');
      expect(
        cloudFileDate(file.modifiedAt),
        entry.value,
        reason: '${entry.key}',
      );
    }
  });

  test(
    'An empty account omits zero usage and an empty directory omits its list',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp(
        (r) => switch (r.uri.path) {
          '/v1/user/me' => jsonResponse({'sub': 'user-1', 'name': 'fixture'}),
          '/assets/v1/get_assets' => guangyaResponse({
            'totalSpaceSize': 2199023255552,
          }),
          '/userres/v1/file/get_file_list' => guangyaResponse({}),
          _ => throw StateError('Unexpected endpoint'),
        },
      );
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      final account = await connector.account(vault.credential(p)!);
      expect(account.total, 2199023255552);
      expect(account.used, 0);
      expect(
        await connector.list(
          tokenPersonal(p),
          'empty-folder',
          vault.credential(p),
        ),
        isEmpty,
      );
    },
  );
  test(
    'personal files use zero-based pages and retain thumbnail and known checksum',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) {
        expect(r.uri.path, '/userres/v1/file/get_file_list');
        expect(r.json['parentId'], '');
        expect(r.headers['Authorization'], 'Bearer $accessToken');
        expect(r.headers['did'], 'device-1');
        final page = r.json.integer('page');
        return guangyaResponse({
          'total': 101,
          'list': [
            if (page == 0)
              for (var i = 0; i < 100; i++)
                {
                  'fileId': 'f$i',
                  'fileName': 'file$i.mp4',
                  'resType': 1,
                  'dirType': 1,
                  'fileSize': 4,
                  'thumbnailUrl': 'https://thumb.example/f$i',
                  'md5': '0123456789abcdef0123456789abcdef',
                }
            else
              {'fileId': 'folder', 'fileName': '旅行', 'resType': 2},
          ],
        });
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      final files = await connector.list(
        tokenPersonal(p),
        'root',
        vault.credential(p),
      );
      expect(files, hasLength(101));
      expect(files.first.isDirectory, isFalse);
      expect(files.last.isDirectory, isTrue);
      expect(files.first.thumbnailUrl, 'https://thumb.example/f0');
      expect(files.first.hashType, 'md5');
      expect(http.calls.map((r) => r.json.integer('page')), [0, 1]);
    },
  );

  test(
    'directory mapping respects resType and does not treat opaque gcid as SHA1',
    () {
      final file = GuangyaConnector.file({
        'fileId': 'x',
        'fileName': 'README',
        'resType': 1,
        'dirType': 1,
        'gcid': 'a' * 40,
        'contentHash': 'base64-hash',
      }, 'root');
      expect(file.isDirectory, isFalse);
      expect(file.hashValue, isNull);
      expect(
        GuangyaConnector.file({
          'fileId': 'y',
          'dirName': 'folder',
        }, 'root').isDirectory,
        isTrue,
      );
    },
  );

  test(
    'share listing follows current cursor pagination without an account',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) {
        expect(r.headers.containsKey('Authorization'), isFalse);
        switch (r.uri.path) {
          case '/userres/v1/get_share_summary':
            return guangyaResponse({'title': '旅行影像'});
          case '/userres/v1/get_share_access_token':
            expect(r.json, {'shareId': 'Share123', 'code': 'a123'});
            return guangyaResponse({'accessToken': 'share-access'});
          case '/userres/v1/get_share_page_files_list':
            expect(r.json['accessToken'], 'share-access');
            expect(r.json.containsKey('page'), isFalse);
            final second = r.json.str('cursor') == 'next';
            return guangyaResponse({
              'hasMore': !second,
              'cursor': second ? '' : 'next',
              'list': [
                {
                  'fileId': second ? 'b' : 'a',
                  'fileName': 'movie.mp4',
                  'resType': 1,
                },
              ],
            });
          default:
            throw StateError(r.url);
        }
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      final session = await connector.openShare(
        tokenShare(p).sourceLink!,
        null,
      );
      expect(session.title, '旅行影像');
      final files = await connector.list(session, 'root', null);
      expect(files.map((f) => f.id), ['a', 'b']);
    },
  );

  for (final scenario in ['repeated-cursor', 'repeated-page', 'missing-list']) {
    test('invalid pagination fails explicitly: $scenario', () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('get_share_access_token')) {
          return guangyaResponse({'accessToken': 'share-token'});
        }
        return guangyaResponse(
          scenario == 'missing-list'
              ? {'total': 1}
              : {
                  'total': 101,
                  'hasMore': true,
                  'cursor': 'same',
                  'list': [
                    {'fileId': 'same', 'fileName': 'movie.mp4'},
                  ],
                },
        );
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock);
      await expectLater(
        connector.list(
          scenario == 'repeated-cursor' ? tokenShare(p) : tokenPersonal(p),
          'root',
          vault.credential(p),
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.length, lessThanOrEqualTo(3));
    });
  }

  for (final share in [false, true]) {
    test(
      '${share ? 'share' : 'personal'} download sends no bearer token to the file server',
      () async {
        final vault = await tokenVault(p);
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('get_share_access_token')) {
            return guangyaResponse({'accessToken': 'share-token'});
          }
          expect(
            r.uri.path,
            '/userres/v1/${share ? 'get_share_download_url' : 'get_res_download_url'}',
          );
          expect(r.json['fileId'], tokenFile.id);
          if (share) expect(r.json['accessToken'], 'share-token');
          return guangyaResponse({
            share ? 'downloadUrl' : 'signedURL':
                'https://cdn.guangyapan.com/file?sign=x%2B%2F',
            'size': 4,
          });
        });
        final result =
            await GuangyaConnector(http, vault, now: () => tokenClock).download(
              share ? tokenShare(p) : tokenPersonal(p),
              tokenFile,
              vault.credential(p),
            );
        expect(result.url, endsWith('sign=x%2B%2F'));
        expect(result.expectedSize, 4);
        expect(result.profile, 'guangya');
        expect(result.headers.keys, isNot(contains('Authorization')));
        expect(result.headers.keys, isNot(contains('Cookie')));
      },
    );
  }

  test(
    'paid or restricted share is never reported as a successful download',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('get_share_access_token')
            ? guangyaResponse({'accessToken': 'share-token'})
            : guangyaResponse({}, code: 205),
      );
      await expectLater(
        GuangyaConnector(
          http,
          vault,
          now: () => tokenClock,
        ).download(tokenShare(p), tokenFile, null),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('下载受限'),
          ),
        ),
      );
      expect(http.calls, hasLength(2));
    },
  );

  for (final action in ['move', 'delete', 'save']) {
    test(
      '$action waits for asynchronous task completion and submits once',
      () async {
        final vault = await tokenVault(p);
        var submissions = 0, polls = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('get_share_access_token')) {
            return guangyaResponse({'accessToken': 'share-token'});
          }
          if (r.uri.path.endsWith('get_task_status')) {
            polls++;
            return guangyaResponse({
              'status': polls < 2 ? 1 : 2,
              'detail': {'code': 0},
            });
          }
          submissions++;
          expect(r.json['fileIds'], ['file-1']);
          if (action != 'delete') expect(r.json['parentId'], '');
          return guangyaResponse({'taskId': 'task'});
        });
        final connector = GuangyaConnector(
          http,
          vault,
          taskDelay: Duration.zero,
          now: () => tokenClock,
        );
        final c = vault.credential(p)!;
        switch (action) {
          case 'move':
            await connector.move(tokenPersonal(p), [tokenFile], 'root', c);
          case 'delete':
            await connector.delete(tokenPersonal(p), [tokenFile], c);
          case 'save':
            await connector.saveShare(tokenShare(p), [tokenFile], 'root', c);
        }
        expect(polls, 2);
        expect(submissions, 1);
      },
    );
  }

  for (final state in [3, 2]) {
    test('task failure is retained even when state is $state', () async {
      final vault = await tokenVault(p);
      final http = FakeHttp(
        (r) => guangyaResponse(
          r.uri.path.endsWith('get_task_status')
              ? {
                  'status': state,
                  'detail': {'code': 157, 'msg': '空间不足'},
                }
              : {'taskId': 'task'},
        ),
      );
      await expectLater(
        GuangyaConnector(
          http,
          vault,
          taskDelay: Duration.zero,
          now: () => tokenClock,
        ).move(tokenPersonal(p), [tokenFile], 'target', vault.credential(p)!),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('空间不足'),
          ),
        ),
      );
      expect(http.calls, hasLength(2));
    });
  }

  test(
    'cancellation during task polling cannot resubmit the mutation',
    () async {
      final vault = await tokenVault(p), scope = RequestScope();
      final http = FakeHttp((r) {
        scope.cancel();
        return guangyaResponse({'taskId': 'task'});
      });
      final connector = GuangyaConnector(
        http,
        vault,
        taskDelay: Duration.zero,
        now: () => tokenClock,
      );
      await expectLater(
        scope.run(
          () => connector.delete(tokenPersonal(p), [
            tokenFile,
          ], vault.credential(p)!),
        ),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('取消'),
          ),
        ),
      );
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'folder, rename and share preserve names, extraction code and expiry',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) {
        switch (r.uri.path) {
          case '/userres/v1/file/create_dir':
            expect(r.json, {
              'parentId': '',
              'dirName': '旅行',
              'failIfNameExist': true,
            });
            return guangyaResponse({'fileId': 'new-folder', 'resType': 2});
          case '/userres/v1/file/rename':
            expect(r.json, {'fileId': 'file-1', 'newName': '新的名字.mp4'});
            return guangyaResponse({});
          case '/userres/v1/share_file':
            expect(r.json['validateDuration'], 7);
            expect(r.json['code'], 'a123');
            return guangyaResponse({
              'shareUrl': 'https://www.guangyapan.com/s/New123',
              'code': 'a123',
            });
          default:
            throw StateError(r.url);
        }
      });
      final connector = GuangyaConnector(http, vault, now: () => tokenClock),
          c = vault.credential(p)!;
      final folder = await connector.createFolder(
        tokenPersonal(p),
        'root',
        '旅行',
        c,
      );
      expect(folder.isDirectory, isTrue);
      await connector.rename(tokenPersonal(p), tokenFile, '新的名字.mp4', c);
      final share = await connector.createShare(
        tokenPersonal(p),
        [tokenFile],
        const ShareOptions('旅行', expiryDays: 7, passcode: 'a123'),
        c,
      );
      expect(share.passcode, 'a123');
      expect(share.url, contains('New123'));
    },
  );

  test(
    'wrong passcode and successful HTTP business errors cannot appear as empty lists',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp((r) => guangyaResponse({}, code: 209));
      await expectLater(
        GuangyaConnector(
          http,
          vault,
          now: () => tokenClock,
        ).list(tokenShare(p), 'root', null),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('提取码'),
          ),
        ),
      );
    },
  );

  test('quota validates the account token through the account host', () async {
    final vault = await tokenVault(p);
    final http = FakeHttp((r) {
      if (r.uri.path == '/assets/v1/get_assets') {
        expect(r.uri.host, 'api.guangyapan.com');
        expect(r.method, 'POST');
        expect(r.headers['Authorization'], 'Bearer $accessToken');
        return guangyaAssetsResponse();
      }
      expect(r.uri.host, 'account.guangyapan.com');
      expect(r.uri.path, '/v1/user/me');
      expect(r.method, 'GET');
      expect(r.headers['X-Client-Id'], GuangyaConnector.clientId);
      return jsonResponse({
        'sub': 'user-1',
        'nickname': '光鸭测试',
        'used_size': 250,
        'total_size': 1000,
      });
    });
    final result = await GuangyaConnector(
      http,
      vault,
      now: () => tokenClock,
    ).account(vault.credential(p)!);
    expect(result.nickname, '光鸭测试');
    expect(result.used, 564090134);
    expect(result.total, 2199023255552);
  });

  test(
    'an early empty page cannot silently truncate the personal directory',
    () async {
      final vault = await tokenVault(p);
      final http = FakeHttp(
        (r) => guangyaResponse({
          'total': 2,
          'list': r.json.integer('page') == 0
              ? [
                  {'fileId': 'first', 'fileName': 'first.mp4'},
                ]
              : [],
        }),
      );
      await expectLater(
        GuangyaConnector(
          http,
          vault,
          now: () => tokenClock,
        ).list(tokenPersonal(p), 'root', vault.credential(p)),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('分页不完整'),
          ),
        ),
      );
      expect(http.calls, hasLength(2));
    },
  );

  test(
    'an empty successful HTTP account response is not a valid login',
    () async {
      final vault = await tokenVault(p);
      await expectLater(
        GuangyaConnector(
          FakeHttp(),
          vault,
          now: () => tokenClock,
        ).authenticate(vault.credential(p)!),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'reason',
            contains('账号信息'),
          ),
        ),
      );
    },
  );
}
