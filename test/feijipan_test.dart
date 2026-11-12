import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/desktop_browser_ua.dart';
import 'package:asterlink/data/providers/feijipan.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/uploads.dart';
import 'package:asterlink/domain/web_tokens.dart';
import 'support.dart';

const _platform = CloudPlatform.feijipan;
const _token = 'fixture:feijipan:token:123456789';
const _uuid = 'fixture-device-12345678';
const _stamp = 1790200000000;
const _file = CloudFile(
  id: 'f:12',
  name: 'sample.bin',
  parentId: '0',
  size: 1024,
);
Credential _credential() => Credential('test', {
  'primary': _token,
  'accessToken': _token,
  'uuid': _uuid,
  'userId': '123',
  'account': 'fixture123',
  'authType': 'webToken',
});
Future<Vault> _vault([Credential? c]) async {
  final v = Vault(StateStore.memory());
  await v.putCredential(_platform, c ?? _credential());
  return v;
}

HttpResult _ok(Json value) => jsonResponse({'code': 200, ...value});
Json _row(int id, {String name = 'sample.bin'}) => {
  'fileType': 1,
  'fileId': id,
  'fileName': name,
  'fileSize': 1.1,
  'updTime': '2026-10-06 12:00:00',
};
BrowseSession _personal() => const BrowseSession(
  platform: _platform,
  mode: BrowseMode.personal,
  title: 'test',
  rootId: '0',
);
BrowseSession _share() => BrowseSession(
  platform: _platform,
  mode: BrowseMode.share,
  title: 'test',
  rootId: 'share-root',
  metadata: {'uuid': _uuid, 'shareId': 'Share123', 'code': 'a123'},
);

void main() {
  test(
    'Share parse, lists and download keep one matching desktop identity',
    () async {
      final http = FakeHttp((r) {
        final ua = DesktopBrowserUa.builtIn.singleWhere(
          (ua) => ua.value == r.headers['User-Agent'],
        );
        expect(r.uri.queryParameters['devModel'], ua.model);
        expect(r.uri.queryParameters['devVersion'], ua.version);
        if (r.uri.path == '/ws/getUuid') return _ok({'uuid': _uuid});
        if (r.uri.path == '/ws/file/download') {
          return _ok({
            'downloadUrl': FeijipanConnector.encrypt(
              'https://cdn.example.test/sample.bin',
            ),
          });
        }
        return _ok({
          'status': 0,
          'totalPage': 1,
          'list': [_row(12)],
        });
      });
      final connector = FeijipanConnector(
        http,
        Vault(StateStore.memory()),
        random: Random(5),
      );
      final seen = <String>{};
      for (var i = 0; i < 12; i++) {
        http.calls.clear();
        final browse = await connector.openShare(
          LinkParser.parse(
            'https://share.feijipan.com/s/Share123?code=a123',
          ).single,
          null,
        );
        final files = await connector.list(browse, browse.rootId, null);
        final spec = await connector.download(browse, files.single, null);
        final ua = http.calls.first.headers['User-Agent']!;
        seen.add(ua);
        expect(http.calls.map((r) => r.headers['User-Agent']).toSet(), {ua});
        expect(spec.headers['User-Agent'], ua);
      }
      expect(seen, hasLength(12));
    },
  );

  test(
    '403 changes UA and browser metadata without changing token or signature',
    () async {
      final v = await _vault();
      var attempts = 0;
      final http = FakeHttp((r) {
        if (attempts++ == 0) {
          return const HttpResult(403, '<html>Blocked</html>', {
            'content-type': ['text/html'],
            'set-cookie': ['old_identity=old; Path=/; Secure'],
          });
        }
        return const HttpResult(302, '', {
          'location': ['https://cdn.example.test/sample.bin'],
        });
      });
      final spec = await FeijipanConnector(
        http,
        v,
        now: () => _stamp,
        random: Random(2),
      ).download(_personal(), _file, v.credential(_platform));
      expect(http.calls, hasLength(2));
      final first = http.calls.first, last = http.calls.last;
      expect(last.headers['User-Agent'], isNot(first.headers['User-Agent']));
      expect(last.headers['Cookie'], isNull);
      final identity = DesktopBrowserUa.builtIn.singleWhere(
        (ua) => ua.value == last.headers['User-Agent'],
      );
      expect(last.uri.queryParameters['devModel'], identity.model);
      expect(last.uri.queryParameters['devVersion'], identity.version);
      for (final field in [
        'uuid',
        'timestamp',
        'auth',
        'downloadId',
        'appToken',
      ]) {
        expect(
          last.uri.queryParameters[field],
          first.uri.queryParameters[field],
        );
      }
      expect(spec.headers['User-Agent'], last.headers['User-Agent']);
      expect(http.calls.any((r) => r.uri.path == '/ws/login'), isFalse);
    },
  );

  test(
    'Blocked small-plane downloads stop after three different UAs',
    () async {
      final v = await _vault();
      final http = FakeHttp(
        (_) => const HttpResult(403, '<html>Blocked</html>'),
      );
      await expectLater(
        FeijipanConnector(
          http,
          v,
        ).download(_personal(), _file, v.credential(_platform)),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('HTTP 403'),
          ),
        ),
      );
      expect(http.calls, hasLength(3));
      expect(
        http.calls.map((r) => r.headers['User-Agent']).toSet(),
        hasLength(3),
      );
      expect(http.calls.any((r) => r.uri.path == '/ws/login'), isFalse);
    },
  );

  test(
    '403 JSON account expiry follows auth handling without UA retries',
    () async {
      final v = await _vault();
      final http = FakeHttp((_) => jsonResponse({'code': -2}, 403));
      await expectLater(
        FeijipanConnector(
          http,
          v,
        ).list(_personal(), '0', v.credential(_platform)),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(http.calls, hasLength(1));
    },
  );

  test('Rate limiting stops immediately without switching UA', () async {
    final http = FakeHttp(
      (_) => const HttpResult(429, '<html>Rate limited</html>'),
    );
    final connector = FeijipanConnector(http, Vault(StateStore.memory()));
    await expectLater(
      connector.list(_share(), 'share-root', null),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, hasLength(1));
  });

  test('403 on a mutation never replays it with another UA', () async {
    final v = await _vault();
    final http = FakeHttp((_) => const HttpResult(403, '<html>Blocked</html>'));
    await expectLater(
      FeijipanConnector(
        http,
        v,
      ).rename(_personal(), _file, 'next.bin', v.credential(_platform)!),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, hasLength(1));
  });

  test('Cancellation stops before trying a second UA', () async {
    final v = await _vault();
    final scope = RequestScope();
    final http = FakeHttp((_) {
      scope.cancel();
      return const HttpResult(403, '<html>Blocked</html>');
    });
    await expectLater(
      scope.run(
        () => FeijipanConnector(
          http,
          v,
        ).list(_personal(), '0', v.credential(_platform)),
      ),
      throwsA(isA<AppException>()),
    );
    expect(http.calls, hasLength(1));
  });

  test('Concurrent share sessions keep independent identities', () async {
    final http = FakeHttp((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return _ok({
        'status': 0,
        'totalPage': 1,
        'list': [_row(12)],
      });
    });
    final connector = FeijipanConnector(
      http,
      Vault(StateStore.memory()),
      random: Random(9),
    );
    final one = _share(), two = _share();
    await Future.wait([
      connector.list(one, 'share-root', null),
      connector.list(two, 'share-root', null),
    ]);
    final uas = http.calls.map((r) => r.headers['User-Agent']).toList();
    expect(uas.toSet(), hasLength(2));
    await Future.wait([
      connector.list(one, 'share-root', null),
      connector.list(two, 'share-root', null),
    ]);
    expect(http.calls[2].headers['User-Agent'], uas[0]);
    expect(http.calls[3].headers['User-Agent'], uas[1]);
  });

  test(
    'Parallel downloads retain the UA used for their own link response',
    () async {
      final v = await _vault();
      final firstSent = Completer<void>();
      final delayedResponse = Completer<HttpResult>();
      var calls = 0;
      const ready = HttpResult(302, '', {
        'location': ['https://cdn.example.test/sample.bin'],
      });
      final http = FakeHttp((r) {
        if (calls++ == 0) {
          firstSent.complete();
          return delayedResponse.future;
        }
        if (calls == 2) return const HttpResult(403, '<html>Blocked</html>');
        return ready;
      });
      final connector = FeijipanConnector(http, v, random: Random(2));
      final browse = _personal();
      final pending = connector.download(
        browse,
        _file,
        v.credential(_platform),
      );
      await firstSent.future;
      final second = await connector.download(
        browse,
        _file,
        v.credential(_platform),
      );
      delayedResponse.complete(ready);
      final first = await pending;
      expect(
        first.headers['User-Agent'],
        http.calls.first.headers['User-Agent'],
      );
      expect(
        second.headers['User-Agent'],
        http.calls.last.headers['User-Agent'],
      );
      expect(second.headers['User-Agent'], isNot(first.headers['User-Agent']));
    },
  );

  test('Share domains, paths and extraction codes stay distinct', () {
    for (final host in [
      'share.feijipan.com',
      'www.feijipan.com',
      'feijipan.com',
    ]) {
      final link = LinkParser.parse(
        'https://$host/s/Share123?code=a123',
      ).single;
      expect(link.platform, _platform);
      expect(link.passcode, 'a123');
      expect(LinkParser.shareId(_platform, link.url), 'Share123');
    }
    expect(CloudPlatform.fromHost('feijipan.com.evil.test'), isNull);
    expect(
      LinkParser.shareId(_platform, 'https://feijipan.com/console/files/0'),
      isNull,
    );
    expect(_platform.shareRequiresAccount, isFalse);
    expect(_platform.exactFileSize, isFalse);
  });

  test(
    'Vuex and cookie fallback preserve the device without mixing other sites',
    () {
      final fields = WebTokens.fields(
        _platform,
        jsonEncode({
          'common': {'appToken': _token, 'uuid': _uuid},
        }),
      );
      expect(fields['accessToken'], _token);
      expect(fields['uuid'], _uuid);
      final raw = LoginCredentials.fromBrowser(
        _platform,
        storage: jsonEncode({'uuid': _uuid}),
        cookies: ['appToken=${Uri.encodeComponent(_token)}'],
      );
      expect(WebTokens.fields(_platform, raw)['accessToken'], _token);
      expect(WebTokens.fields(_platform, raw)['uuid'], _uuid);
      final target = WebLoginTarget.targets[_platform]!;
      expect(
        target.canReadLocalStorage('https://share.feijipan.com/s/Share123'),
        isTrue,
      );
      expect(
        target.canReadLocalStorage('https://feijipan.com.evil.test'),
        isFalse,
      );
      expect(target.readStorageScript, contains('disk-vuex'));
      expect(target.clearStorageScript, contains('disk-vuex'));
    },
  );

  test(
    'Password login returns verified nickname, capacity and account identity',
    () async {
      final http = FakeHttp((r) {
        switch (r.uri.path) {
          case '/ws/getUuid':
            return _ok({'uuid': _uuid});
          case '/ws/login':
            expect(r.json['loginName'], 'fixture-user');
            expect(r.json['loginPwd'], 'fixture-password');
            return _ok({
              'data': {'appToken': _token},
            });
          case '/app/user/account/map':
            return _ok({
              'map': {
                'userId': 123,
                'account': 'fixture123',
                'usedSize': 2,
                'totalSize': 100,
                'vipSize': 50,
                'rewardSize': 5,
                'contractSize': 3,
              },
            });
          case '/app/user/info/map':
            return _ok({
              'map': {'userId': 123, 'userName': '新的昵称'},
            });
          default:
            throw StateError('Unexpected endpoint');
        }
      });
      final login = await FeijipanConnector(
        http,
        Vault(StateStore.memory()),
        now: () => _stamp,
      ).password('fixture-user', 'fixture-password');
      expect(login.account.nickname, '新的昵称');
      expect(login.account.used, 2048);
      expect(login.account.total, 158 * 1024);
      expect(login.credential.field('userId'), '123');
      expect(login.credential.field('authType'), 'passwordToken');
    },
  );

  test(
    'Pagination retains file dates and rejects an incomplete second page',
    () async {
      var broken = false;
      final http = FakeHttp((r) {
        final page = r.uri.queryParameters['offset'];
        return _ok({
          'totalPage': 2,
          'list': page == '1'
              ? [_row(12)]
              : broken
              ? []
              : [_row(13, name: 'next.bin')],
        });
      });
      final v = await _vault();
      final connector = FeijipanConnector(http, v);
      final files = await connector.list(
        _personal(),
        '0',
        v.credential(_platform),
      );
      expect(files.map((f) => f.id), ['f:12', 'f:13']);
      expect(files.first.size, 1126);
      expect(files.first.modifiedAt, '2026-10-06 12:00:00');
      broken = true;
      await expectLater(
        connector.list(_personal(), '0', v.credential(_platform)),
        throwsA(isA<AppException>()),
      );
    },
  );

  test(
    'Share password validation runs before descending into a folder',
    () async {
      final http = FakeHttp((r) => _ok({'status': 2, 'list': []}));
      final connector = FeijipanConnector(http, Vault(StateStore.memory()));
      await expectLater(
        connector.list(_share(), 'd:99', null),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.single.uri.path, '/ws/recommend/list');
      expect(http.calls.single.uri.queryParameters['code'], 'a123');
    },
  );

  test(
    'Share downloads verify membership, decode URL and leave secrets off CDN headers',
    () async {
      final url = 'https://cdn.example.test/sample.bin?sig=fixture';
      final http = FakeHttp((r) {
        if (r.uri.path == '/ws/recommend/list') {
          return _ok({
            'status': 0,
            'totalPage': 1,
            'list': [
              {
                'fileList': [_row(12)],
              },
            ],
          });
        }
        expect(r.uri.path, '/ws/file/download');
        expect(r.uri.queryParameters['enable'], '1');
        expect(r.uri.queryParameters['shareId'], 'Share123');
        return _ok({'downloadUrl': FeijipanConnector.encrypt(url)});
      });
      final connector = FeijipanConnector(
        http,
        Vault(StateStore.memory()),
        now: () => _stamp,
      );
      final spec = await connector.download(
        _share(),
        const CloudFile(id: 'f:12', name: 'sample.bin', parentId: 'share-root'),
        null,
      );
      expect(spec.url, url);
      expect(spec.fileName, 'sample.bin');
      expect(spec.expectedSize, 0);
      expect(spec.profile, 'feijipan');
      expect(
        spec.headers.keys.map((x) => x.toLowerCase()),
        isNot(
          anyOf(
            contains('cookie'),
            contains('apptoken'),
            contains('authorization'),
          ),
        ),
      );
      http.calls.clear();
      await expectLater(
        connector.download(
          _share(),
          const CloudFile(
            id: 'f:555',
            name: 'other.bin',
            parentId: 'share-root',
          ),
          null,
        ),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.length, 1);
    },
  );

  test('Invalid or non-HTTP encrypted URLs cannot become downloads', () {
    for (final value in [
      '',
      'ab',
      'zz' * 16,
      FeijipanConnector.encrypt('javascript:alert(1)'),
    ]) {
      expect(
        () => FeijipanConnector.decryptDownloadUrl(value),
        throwsA(isA<AppException>()),
      );
    }
  });

  test(
    'An explicit expired token renews once with the remembered password',
    () async {
      final c = Credential('test', {
        ..._credential().fields,
        'username': 'fixture-user',
        'password': 'fixture-password',
        'authType': 'passwordToken',
      });
      final v = await _vault(c);
      var lists = 0;
      final http = FakeHttp((r) {
        if (r.uri.path == '/ws/login') {
          return _ok({
            'data': {'appToken': 'fixture:renewed:token:123456789'},
          });
        }
        if (lists++ == 0) return jsonResponse({'code': -2});
        return _ok({'list': [], 'totalPage': 1});
      });
      await FeijipanConnector(http, v).list(_personal(), '0', c);
      expect(http.calls.where((r) => r.uri.path == '/ws/login').length, 1);
      expect(
        v.credential(_platform)!.field('accessToken'),
        'fixture:renewed:token:123456789',
      );
    },
  );

  test('A rejected mutation is not blindly replayed', () async {
    final v = await _vault(),
        http = FakeHttp((r) => jsonResponse({'code': -1, 'msg': 'rejected'}));
    await expectLater(
      FeijipanConnector(
        http,
        v,
      ).rename(_personal(), _file, 'new.bin', v.credential(_platform)!),
      throwsA(isA<AppException>()),
    );
    expect(http.calls.length, 1);
  });

  test(
    'Upload refuses overwrite before requesting storage credentials',
    () async {
      final v = await _vault(),
          http = FakeHttp(
            (r) => _ok({
              'totalPage': 1,
              'list': [_row(12)],
            }),
          );
      final f = UploadFile(
        name: 'sample.bin',
        size: 4,
        read: (s, e) => Stream.value([1, 2, 3, 4].sublist(s, e)),
      );
      await expectLater(
        FeijipanConnector(
          http,
          v,
        ).upload(_personal(), '0', f, v.credential(_platform)!),
        throwsA(isA<AppException>()),
      );
      expect(http.calls.single.uri.path, '/app/record/file/list');
    },
  );

  test(
    'Multipart upload aborts an unfinished object after a rejected part',
    () async {
      final v = await _vault();
      var aborted = false;
      final http = FakeHttp((r) {
        if (r.uri.path == '/app/record/file/list') {
          return _ok({'list': [], 'totalPage': 1});
        }
        if (r.uri.path == '/app/vod/getUpToken') {
          return _ok({
            'upToken': {
              'accessKeyId': 'fixture-key',
              'secretAccessKey': 'fixture-secret',
              'sessionToken': 'fixture-session',
            },
          });
        }
        expect(r.uri.host, '1500033322.vodpro-upload.com');
        if (r.method == 'DELETE') {
          aborted = true;
          return const HttpResult(204, '');
        }
        if (r.method == 'POST') {
          return const HttpResult(
            200,
            '<InitiateMultipartUploadResult><UploadId>fixture-upload</UploadId></InitiateMultipartUploadResult>',
          );
        }
        return const HttpResult(
          403,
          '<Error><Code>AccessDenied</Code></Error>',
        );
      });
      final bytes = Uint8List(4 * 1024 * 1024 + 1);
      final f = UploadFile(
        name: 'large.bin',
        size: bytes.length,
        read: (s, e) => Stream.value(Uint8List.sublistView(bytes, s, e)),
      );
      await expectLater(
        FeijipanConnector(
          http,
          v,
          now: () => _stamp,
        ).upload(_personal(), '0', f, v.credential(_platform)!),
        throwsA(isA<AppException>()),
      );
      expect(aborted, isTrue);
      expect(http.calls.where((r) => r.uri.path == '/ws/vod/results'), isEmpty);
    },
  );
}
