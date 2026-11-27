import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/pikpak.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/domain/web_tokens.dart';
import 'support.dart';

const platform = CloudPlatform.pikpak;
const access = 'fixture-access-token-123456';
const refresh = 'fixture-refresh-token-123456';
const personal = BrowseSession(
  platform: platform,
  mode: BrowseMode.personal,
  title: 'PikPak',
  rootId: '',
);
const file = CloudFile(id: 'file-id', name: 'sample.bin', size: 3);
Credential credential({int expires = 0}) => Credential('PikPak', {
  'primary': access,
  'accessToken': access,
  'refreshToken': refresh,
  'userId': 'user-id',
  'deviceId': 'fixture-device',
  'expiresAt': '$expires',
}, updatedAt: 12345);
Future<Vault> vault([Credential? c]) async {
  final result = Vault(StateStore.memory());
  await result.putCredential(platform, c ?? credential());
  return result;
}

Json row({
  String id = 'file-id',
  String name = 'sample.bin',
  bool folder = false,
  String phase = 'PHASE_TYPE_COMPLETE',
}) => {
  'id': id,
  'name': name,
  'size': '3',
  'parent_id': '',
  'kind': folder ? 'drive#folder' : 'drive#file',
  'phase': phase,
  'modified_time': '2026-10-08T12:00:00Z',
  'hash': '0123456789012345678901234567890123456789',
};

void main() {
  test('PikPak net aliases preserve share IDs and six-character passcodes', () {
    const id = 'Share_123AbC-XyZ9876543210';
    const url = 'https://mypikpak.net/s/$id';
    for (final (text, normalized) in [
      ('$url 访问密码：abc123', url),
      ('mypikpak.net/s/$id 访问密码：abc123', url),
      (
        r'https\://mypikpak.net/s/'
            '$id 访问密码：abc123',
        url,
      ),
      (
        'HTTP://WWW.MYPIKPAK.NET/s/$id?pass_code=abc123',
        'http://www.mypikpak.net/s/$id?pass_code=abc123',
      ),
      ('$url#/list?pwd=abc123', '$url#/list?pwd=abc123'),
    ]) {
      final link = LinkParser.parse(text).single;
      expect(link.kind, LinkKind.cloudShare, reason: text);
      expect(link.platform, platform, reason: text);
      expect(link.url, normalized, reason: text);
      expect(link.shareId, id, reason: text);
      expect(link.passcode, 'abc123', reason: text);
    }
    expect(
      LinkParser.normalize(
        r'https\://mypikpak.net/s/'
        '$id',
      ),
      url,
    );
    expect(
      LinkParser.normalize(
        r'HTTPS\://MYPIKPAK.NET/s/'
        '$id?b=2&a=%2b+%20#frag',
      ),
      '$url?b=2&a=%2b+%20#frag',
    );
  });

  test('PikPak copied Markdown and adjacent password labels stay usable', () {
    for (final host in ['mypikpak.com', 'mypikpak.net']) {
      final url = 'https://$host/s/Share_123-Xyz';
      for (final text in ['[$url]($url) 访问密码：abc123', '$url（访问密码：abc123）']) {
        final link = LinkParser.parse(text).single;
        expect(link.url, url, reason: text);
        expect(link.kind, LinkKind.cloudShare, reason: text);
        expect(link.shareId, 'Share_123-Xyz', reason: text);
        expect(link.passcode, 'abc123', reason: text);
      }
    }
  });

  test('Long PikPak passcodes stay intact and unrelated paths are ignored', () {
    expect(
      LinkParser.parse(
        'https://mypikpak.com/s/abc?pass_code=abcdefghij',
      ).single.passcode,
      'abcdefghij',
    );
    expect(
      LinkParser.parse(
        'https://mypikpak.com/s/abc 密码：abc12345',
      ).single.passcode,
      'abc12345',
    );
    expect(
      LinkParser.parse(
        'https://mypikpak.com/s/abc?pwd=12345678901',
      ).single.passcode,
      isNull,
    );
    expect(
      LinkParser.shareId(platform, 'https://mypikpak.com/help/s/abc'),
      isNull,
    );
  });

  test(
    'Root share children never inherit the owner personal parent id',
    () async {
      final v = await vault();
      final http = FakeHttp(
        (_) => jsonResponse({
          'share_status': 'OK',
          'files': [
            {...row(), 'parent_id': 'owner-folder'},
          ],
        }),
      );
      final files = await PikPakConnector(http, v).list(
        const BrowseSession(
          platform: platform,
          mode: BrowseMode.share,
          title: 'Share',
          rootId: '',
          metadata: {'shareId': 's', 'passCodeToken': 't', 'deviceId': 'd'},
        ),
        '',
        null,
      );
      expect(files.single.parentId, isEmpty);
    },
  );

  test(
    'Cancelled refresh cannot write a late token or retry its file request',
    () async {
      final v = await vault(credential(expires: 1));
      final gate = Completer<HttpResult>();
      final http = FakeHttp((_) => gate.future);
      final scope = RequestScope();
      final request = scope.run(
        () => PikPakConnector(
          http,
          v,
        ).list(personal, '', v.credential(platform)!),
      );
      await until(() => http.calls.isNotEmpty);
      scope.cancel();
      await expectLater(request, throwsA(isA<AppException>()));
      gate.complete(
        jsonResponse({
          'access_token': 'late-access-token-123456',
          'refresh_token': 'late-refresh-token-12345',
          'sub': 'user-id',
          'expires_in': 3600,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(v.credential(platform)!.field('accessToken'), access);
      expect(http.calls.length, 1);
    },
  );

  test(
    'Cancelled multipart upload aborts parts and deletes only its pending node',
    () async {
      final v = await vault();
      final scope = RequestScope();
      final http = FakeHttp((r) {
        if (r.uri.host == 'api-drive.mypikpak.com') {
          if (r.method == 'POST') {
            return jsonResponse({
              'file': row(phase: 'PHASE_TYPE_PENDING'),
              'resumable': {
                'params': {
                  'bucket': 'bucket',
                  'endpoint': 'uploads.example.test',
                  'key': 'path/file',
                  'access_key_id': 'key',
                  'access_key_secret': 'secret',
                },
              },
            });
          }
          if (r.method == 'GET') {
            return jsonResponse(row(phase: 'PHASE_TYPE_PENDING'));
          }
          return jsonResponse({});
        }
        if (r.method == 'POST') {
          return const HttpResult(200, '<UploadId>upload</UploadId>');
        }
        if (r.method == 'PUT') {
          scope.cancel();
          throw const AppException('cancelled');
        }
        return const HttpResult(204, '');
      });
      await expectLater(
        scope.run(
          () => PikPakConnector(http, v).upload(
            personal,
            '',
            UploadFile(
              name: 'sample.bin',
              size: 3,
              read: (s, e) => Stream.value([1, 2, 3].sublist(s, e)),
            ),
            v.credential(platform)!,
          ),
        ),
        throwsA(isA<AppException>()),
      );
      expect(
        http.calls.where((r) => r.method == 'DELETE').map((r) => r.uri.host),
        ['uploads.example.test', 'api-drive.mypikpak.com'],
      );
    },
  );

  test('PikPak share links reject landing pages and unrelated hosts', () {
    final parsed = LinkParser.parse(
      'https://www.mypikpak.com/s/Share_123 提取码：k123',
    ).single;
    expect(parsed.platform, platform);
    expect(parsed.passcode, 'k123');
    expect(LinkParser.shareId(platform, parsed.url), 'Share_123');
    for (final host in ['mypikpak.com', 'mypikpak.net']) {
      for (final url in [
        'https://$host/',
        'https://$host/drive/all',
        'https://$host/help/s/abc',
        'https://$host.evil.test/s/abc',
        'https://not$host/s/abc',
        'https://$host@evil.test/s/abc',
        'https://example.test/?url=https://$host/s/abc',
      ]) {
        expect(LinkParser.shareId(platform, url), isNull, reason: url);
        expect(
          LinkParser.parse(url).where((link) => link.isCloudShare),
          isEmpty,
          reason: url,
        );
      }
    }
    expect(platform.shareRequiresAccount, isFalse);
  });

  test('Manual token login preserves refresh, identity and device', () {
    final c = LoginCredentials.candidate(
      platform,
      jsonEncode({
        'access_token': access,
        'refresh_token': refresh,
        'sub': 'user-id',
        'device_id': 'fixture-device',
      }),
      null,
    );
    expect(c.field('refreshToken'), refresh);
    expect(c.field('deviceId'), 'fixture-device');
    expect(WebTokens.supports(platform), isTrue);
    expect(LoginCredentials.savedCookie(platform, c), isNull);
    expect(WebLoginTarget.targets[platform]!.desktopMode, isTrue);
  });

  test(
    'Password authentication returns current nickname, quota and reusable session',
    () async {
      final v = await vault();
      final http = FakeHttp((r) {
        switch (r.uri.path) {
          case '/v1/shield/captcha/init':
            expect(r.json.obj('meta')['username'], 'person@example.test');
            expect(r.headers.containsKey('Authorization'), isFalse);
            return jsonResponse({
              'captcha_token': 'fixture-captcha-token-12345',
            });
          case '/v1/auth/signin':
            expect(r.json['password'], 'test-password');
            expect(r.json['grant_type'], 'password');
            return jsonResponse({
              'access_token': access,
              'refresh_token': refresh,
              'sub': 'new-user',
              'expires_in': 3600,
            });
          case '/v1/user/me':
            return jsonResponse({'sub': 'new-user', 'name': '当前账号'});
          case '/drive/v1/about':
            return jsonResponse({
              'quota': {'usage': '1024', 'limit': '2048'},
            });
        }
        throw StateError(r.url);
      });
      final result = await PikPakConnector(
        http,
        v,
      ).password('person@example.test', 'test-password');
      expect(result.account.nickname, '当前账号');
      expect(result.account.used, 1024);
      expect(result.account.total, 2048);
      expect(result.credential.field('userId'), 'new-user');
      expect(result.credential.field('password'), isEmpty);
      expect(v.credential(platform)!.field('userId'), 'user-id');
      expect(http.calls.map((r) => r.headers['X-Device-Id']).toSet().length, 1);
    },
  );

  test(
    'Expired session rotates once for simultaneous reads without changing account revision',
    () async {
      final v = await vault(credential(expires: 1));
      final http = FakeHttp((r) async {
        if (r.uri.path == '/v1/auth/token') {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return jsonResponse({
            'access_token': 'new-access-token-1234567',
            'refresh_token': 'new-refresh-token-123456',
            'sub': 'user-id',
            'expires_in': 3600,
          });
        }
        expect(r.headers['Authorization'], 'Bearer new-access-token-1234567');
        return jsonResponse({
          'files': [row()],
        });
      });
      final connector = PikPakConnector(http, v);
      final c = v.credential(platform)!;
      await Future.wait([
        connector.list(personal, '', c),
        connector.list(personal, '', c),
      ]);
      expect(http.calls.where((r) => r.uri.path == '/v1/auth/token').length, 1);
      expect(v.credential(platform)!.updatedAt, c.updatedAt);
      expect(
        v.credential(platform)!.field('refreshToken'),
        'new-refresh-token-123456',
      );
    },
  );

  test(
    '401 refreshes once and a changed server identity never replaces account',
    () async {
      final v = await vault();
      final http = FakeHttp(
        (r) => r.uri.path == '/v1/auth/token'
            ? jsonResponse({
                'access_token': 'new-access-token-1234567',
                'sub': 'wrong-user',
              })
            : jsonResponse({'error': 'unauthenticated'}, 401),
      );
      await expectLater(
        PikPakConnector(http, v).list(personal, '', v.credential(platform)!),
        throwsA(isA<AppException>()),
      );
      expect(v.credential(platform)!.field('userId'), 'user-id');
      expect(v.credential(platform)!.field('accessToken'), access);
      expect(http.calls.length, 2);
    },
  );

  test(
    'Captcha rejection retries once, unrelated code 9 errors are not retried',
    () async {
      final v = await vault();
      var reads = 0;
      final http = FakeHttp((r) {
        if (r.uri.path == '/v1/shield/captcha/init') {
          expect(r.json['action'], 'GET:/drive/v1/files');
          expect(r.json.obj('meta').str('captcha_sign'), startsWith('1.'));
          return jsonResponse({'captcha_token': 'new-captcha-token-123456'});
        }
        if (reads++ == 0) {
          return jsonResponse({
            'error_code': 9,
            'error': 'captcha_invalid',
          }, 400);
        }
        expect(r.headers['X-Captcha-Token'], 'new-captcha-token-123456');
        return jsonResponse({
          'error_code': 9,
          'error': 'file_restore_own',
        }, 400);
      });
      await expectLater(
        PikPakConnector(http, v).list(personal, '', v.credential(platform)!),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.length, 3);
    },
  );

  test(
    'Pagination preserves dates and does not treat GCID as file SHA1',
    () async {
      final v = await vault();
      final http = FakeHttp((r) {
        expect(jsonDecode(r.uri.queryParameters['filters']!), {
          'trashed': {'eq': false},
        });
        return jsonResponse({
          'files': [row()],
          'next_page_token': r.uri.queryParameters['page_token'] == ''
              ? 'page2'
              : '',
        });
      });
      final files = await PikPakConnector(
        http,
        v,
      ).list(personal, '', v.credential(platform)!);
      expect(files.length, 2);
      expect(files.first.modifiedAt, '2026-10-08T12:00:00Z');
      expect(files.first.hashType, isNull);
    },
  );

  test('Repeated page token terminates instead of hanging', () async {
    final v = await vault();
    final http = FakeHttp(
      (_) => jsonResponse({'files': [], 'next_page_token': 'same'}),
    );
    await expectLater(
      PikPakConnector(http, v).list(personal, '', v.credential(platform)!),
      throwsA(isA<AppException>()),
    );
    expect(http.calls.length, 2);
  });

  test(
    'Anonymous share read carries client id, passcode and folder ancestry',
    () async {
      final v = await vault();
      final http = FakeHttp((r) {
        expect(r.headers['X-Client-Id'], PikPakConnector.clientId);
        expect(r.headers.containsKey('Authorization'), isFalse);
        if (r.uri.path == '/drive/v1/share') {
          expect(r.uri.queryParameters['pass_code'], 'k123');
          return jsonResponse({
            'files': [],
            'share_status': 'OK',
            'pass_code_token': 'share-token',
          });
        }
        expect(r.uri.queryParameters['pass_code_token'], 'share-token');
        return jsonResponse({
          'share_status': 'OK',
          'files': [row(id: 'folder2', folder: true)],
        });
      });
      final connector = PikPakConnector(http, v);
      final session = await connector.openShare(
        LinkParser.parse('https://mypikpak.com/s/abc?pwd=k123').single,
        null,
      );
      final files = await connector.list(session, 'folder1', null);
      expect(files.single.id, 'folder1/folder2');
      expect(jsonDecode(files.single.token), ['folder1']);
      await expectLater(
        connector.download(session, file, null),
        throwsA(isA<AccountLoginRequired>()),
      );
    },
  );

  test(
    'Invalid share passcode is not shown as empty successful share',
    () async {
      final v = await vault();
      final http = FakeHttp(
        (_) => jsonResponse({'share_status': 'PASS_CODE_ERROR', 'files': []}),
      );
      await expectLater(
        PikPakConnector(http, v).openShare(
          LinkParser.parse('https://mypikpak.com/s/abc').single,
          null,
        ),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Downloads prefer original bytes, carry no account tokens and validate size',
    () async {
      final v = await vault();
      final http = FakeHttp(
        (_) => jsonResponse({
          ...row(),
          'web_content_link': 'https://web.example.test/wrong',
          'links': {
            'application/octet-stream': {
              'url': 'https://cdn.example.test/original',
            },
          },
          'medias': [
            {
              'link': {'url': 'https://cdn.example.test/transcode'},
            },
          ],
        }),
      );
      final result = await PikPakConnector(
        http,
        v,
      ).download(personal, file, v.credential(platform)!);
      expect(result.url, 'https://cdn.example.test/original');
      expect(result.headers.keys, ['User-Agent']);
      expect(result.expectedSize, 3);
      expect(result.profile, 'pikpak');
      expect(result.checksumType, isNull);
    },
  );

  test(
    'File operations use selected ids, parent and recoverable deletion',
    () async {
      final v = await vault();
      final http = FakeHttp((r) {
        if (r.uri.path == '/drive/v1/files' && r.method == 'POST') {
          return jsonResponse({
            'file': row(
              id: 'new-folder',
              name: r.json.str('name'),
              folder: true,
            ),
          });
        }
        if (r.uri.path == '/drive/v1/share') {
          return jsonResponse({
            'share_url': 'https://mypikpak.com/s/created',
            'pass_code': 'a123',
          });
        }
        return jsonResponse({});
      });
      final connector = PikPakConnector(http, v), c = v.credential(platform)!;
      await connector.createFolder(personal, 'dest', '文件夹', c);
      await connector.rename(personal, file, 'renamed.bin', c);
      await connector.move(personal, [file], 'dest', c);
      await connector.delete(personal, [file], c);
      await connector.createShare(
        personal,
        [file],
        const ShareOptions('分享', passcode: 'a123', expiryDays: 7),
        c,
      );
      expect(http.calls[0].json['parent_id'], 'dest');
      expect(http.calls[1].method, 'PATCH');
      expect(http.calls[2].json.obj('to')['parent_id'], 'dest');
      expect(http.calls[3].uri.path, '/drive/v1/files:batchTrash');
      expect(http.calls[4].json['custom_pass_code'], 'a123');
    },
  );

  test(
    'Share download restores nested file and schedules owner-bound cleanup',
    () async {
      final v = await vault();
      final cleanups = <DownloadCleanup>[];
      final http = FakeHttp((r) {
        if (r.uri.path == '/drive/v1/files' && r.method == 'POST') {
          return jsonResponse({
            'file': row(id: 'temp-dir', name: r.json.str('name'), folder: true),
          });
        }
        if (r.uri.path == '/drive/v1/share/restore') {
          expect(r.json['ancestor_ids'], ['dir1', 'dir2']);
          expect(r.json['file_ids'], ['shared-file']);
          expect(r.json['parent_id'], 'temp-dir');
          return jsonResponse({'restore_task_id': 'restore-task'});
        }
        if (r.uri.path == '/drive/v1/tasks/restore-task') {
          return jsonResponse({'phase': 'PHASE_TYPE_COMPLETE'});
        }
        if (r.uri.path == '/drive/v1/files') {
          return jsonResponse({
            'files': [row(id: 'copied-file')],
          });
        }
        if (r.uri.path == '/drive/v1/files/copied-file') {
          return jsonResponse({
            ...row(),
            'web_content_link': 'https://cdn.example.test/file',
          });
        }
        throw StateError(r.url);
      });
      final connector = PikPakConnector(
        http,
        v,
        stageCleanup: (c) async => cleanups.add(c),
      );
      final result = await connector.download(
        const BrowseSession(
          platform: platform,
          mode: BrowseMode.share,
          title: 'Share',
          rootId: '',
          metadata: {'shareId': 'share', 'passCodeToken': 'token'},
        ),
        const CloudFile(
          id: 'shared-file',
          name: 'sample.bin',
          size: 3,
          token: '["dir1","dir2"]',
        ),
        v.credential(platform)!,
      );
      expect(result.url, 'https://cdn.example.test/file');
      expect(result.cleanup, cleanups.single);
      expect(
        cleanups.single.action!['accountRevision'],
        v.credential(platform)!.updatedAt,
      );
    },
  );

  test(
    'Instant upload uses GCID and verifies server completion and exact size',
    () async {
      final v = await vault();
      final bytes = [1, 2, 3];
      final http = FakeHttp((r) {
        if (r.method == 'POST') {
          expect(
            r.json['hash'],
            sha1.convert(sha1.convert(bytes).bytes).toString().toUpperCase(),
          );
          expect(r.json['upload_type'], 'UPLOAD_TYPE_RESUMABLE');
          return jsonResponse({'file': row()});
        }
        return jsonResponse(row());
      });
      final progress = <UploadProgress>[];
      final source = UploadFile(
        name: 'sample.bin',
        size: bytes.length,
        read: (start, end) => Stream.value(bytes.sublist(start, end)),
      );
      final result = await PikPakConnector(http, v).upload(
        personal,
        '',
        source,
        v.credential(platform)!,
        onProgress: progress.add,
      );
      expect(result.id, 'file-id');
      expect(progress.last.phase, UploadPhase.finishing);
      expect(http.calls.length, 2);
    },
  );

  test(
    'OSS upload sends temporary credentials only to the supplied upload host',
    () async {
      final v = await vault();
      final http = FakeHttp((r) async {
        if (r.uri.host == 'api-drive.mypikpak.com') {
          if (r.method == 'POST') {
            return jsonResponse({
              'file': row(phase: 'PHASE_TYPE_PENDING'),
              'resumable': {
                'params': {
                  'bucket': 'bucket',
                  'endpoint': 'bucket.oss.example.test',
                  'key': 'path/sample.bin',
                  'access_key_id': 'temp-key',
                  'access_key_secret': 'temp-secret',
                  'security_token': 'temp-sts',
                },
              },
            });
          }
          return jsonResponse(row());
        }
        expect(r.uri.host, 'bucket.oss.example.test');
        expect(r.headers['Authorization'], startsWith('OSS temp-key:'));
        expect(r.headers.containsKey('X-Captcha-Token'), isFalse);
        if (r.method == 'POST' &&
            r.uri.queryParameters.containsKey('uploads')) {
          return const HttpResult(200, '<UploadId>upload-1</UploadId>');
        }
        if (r.method == 'PUT') {
          final body = r.body as HttpUpload;
          expect(await body.open().expand((v) => v).toList(), [1, 2, 3]);
          return const HttpResult(200, '', {
            'etag': ['"part-etag"'],
          });
        }
        expect(r.body.toString(), contains('<CompleteMultipartUpload>'));
        return const HttpResult(200, '<CompleteMultipartUploadResult/>');
      });
      final result = await PikPakConnector(http, v).upload(
        personal,
        '',
        UploadFile(
          name: 'sample.bin',
          size: 3,
          read: (s, e) => Stream.value([1, 2, 3].sublist(s, e)),
        ),
        v.credential(platform)!,
      );
      expect(result.size, 3);
      expect(http.calls.length, 5);
    },
  );
}
