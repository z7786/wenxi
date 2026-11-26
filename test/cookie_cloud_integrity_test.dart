import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/auth.dart';
import 'support.dart';

const _now = 1700000000000;
const _digest = '0123456789abcdef0123456789abcdef';
const _file = CloudFile(id: 'file', name: 'sample.mp4', size: 4);
const _session = BrowseSession(
  platform: CloudPlatform.uc,
  mode: BrowseMode.personal,
  title: 'UC',
  rootId: '0',
);
Credential credential() => Credential('fixture', {
  'primary': '__pus=account; __puus=session',
  'ucSessionRefreshedAt': '$_now',
  'quarkSessionRefreshedAt': '$_now',
});
HttpResult ok(Object data) =>
    jsonResponse({'status': 200, 'code': 0, 'data': data});
HttpResult download({
  String fid = 'file',
  String md5 = _digest,
  int size = 4,
}) => ok([
  {
    'fid': fid,
    'file_name': 'sample.mp4',
    'size': size,
    'md5': md5,
    'download_url': 'https://cdn.example/original?sign=a%2Bb&part=1&part=2',
  },
]);

void main() {
  test(
    'UC verifies the original object length with a one-byte probe and retains MD5',
    () async {
      final c = credential();
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/download')) return download();
        expect(r.headers['Range'], 'bytes=0-0');
        expect(r.headers['Cookie'], c.primary);
        expect(r.headers['User-Agent'], UcConnector.webUa);
        expect(r.headers['Referer'], 'https://drive.uc.cn/');
        expect(r.url, 'https://cdn.example/original?sign=a%2Bb&part=1&part=2');
        return const HttpResult(206, 'x', {
          'content-range': ['bytes 0-0/4'],
          'content-length': ['1'],
        });
      });
      final spec = await UcConnector(
        http,
        now: () => _now,
      ).download(_session, _file, c);
      expect(spec.expectedSize, 4);
      expect(spec.checksumType, 'md5');
      expect(spec.checksumValue, _digest);
      expect(spec.headers['Cookie'], c.primary);
      expect(http.calls, hasLength(2));
    },
  );

  test(
    'UC Base64-encoded download digests are normalized to whole-file hex MD5',
    () async {
      // Real capture: a share-transferred APK whose file/download md5 field is
      // a 24-char Base64 string of the 16 digest bytes. Decoding it yields the
      // MD5 of the complete file (verified against the downloaded bytes).
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/download')) {
          return download(md5: 'pT9a5AC0wYhxEiHKcWjOPw==');
        }
        expect(r.headers['Range'], 'bytes=0-0');
        return const HttpResult(206, 'x', {
          'content-range': ['bytes 0-0/4'],
          'content-length': ['1'],
        });
      });
      final spec = await UcConnector(
        http,
        now: () => _now,
      ).download(_session, _file, credential());
      expect(spec.checksumType, 'md5');
      expect(spec.checksumValue, 'a53f5ae400b4c188711221ca7168ce3f');
      expect(spec.expectedSize, 4);
    },
  );

  test(
    'UC accepts a full-response length when a server ignores Range',
    () async {
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/download')
            ? download()
            : const HttpResult(200, 'x', {
                'content-length': ['4'],
              }),
      );
      final spec = await UcConnector(
        http,
        now: () => _now,
      ).download(_session, _file, credential());
      expect(spec.expectedSize, 4);
      expect(spec.checksumValue, _digest);
    },
  );

  test(
    'UC rejects replacement original downloads and never falls back from TV to a notice video',
    () async {
      for (final playback in [false, true]) {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/download')
              ? download()
              : const HttpResult(206, 'x', {
                  'content-range': ['bytes 0-0/16'],
                  'content-length': ['1'],
                }),
        );
        final connector = UcConnector(http, now: () => _now);
        if (playback) {
          await expectLater(
            connector.playback(_session, _file, credential()),
            throwsA(isA<UcTvAuthorizationRequired>()),
          );
          expect(http.calls, isEmpty);
          continue;
        }
        await expectLater(
          connector.download(_session, _file, credential()),
          throwsA(
            isA<AppException>().having(
              (e) => e.message,
              'message',
              contains('外部播放或会员限制'),
            ),
          ),
        );
        expect(http.calls, hasLength(2));
      }
    },
  );

  test(
    'UC rejects encoded, malformed and unsuccessful length probes',
    () async {
      for (final response in [
        const HttpResult(206, 'x', {
          'content-range': ['bytes 1-1/16'],
        }),
        const HttpResult(206, 'x', {
          'content-range': ['bytes 0-0/16'],
          'content-length': ['2'],
        }),
        const HttpResult(206, 'x', {
          'content-range': ['bytes 0-0/16'],
          'content-encoding': ['gzip'],
        }),
        const HttpResult(200, 'x'),
        const HttpResult(403, 'denied'),
      ]) {
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/download') ? download() : response,
        );
        await expectLater(
          UcConnector(
            http,
            now: () => _now,
          ).download(_session, _file, credential()),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(2));
      }
    },
  );

  test('UC does not change length without a valid checksum', () async {
    final http = FakeHttp((r) => download(md5: '', size: 16));
    await expectLater(
      UcConnector(
        http,
        now: () => _now,
      ).download(_session, _file, credential()),
      throwsA(
        isA<AppException>().having((e) => e.message, 'message', contains('大小')),
      ),
    );
    expect(http.calls, hasLength(1));
  });

  test(
    'UC cancellation during the size probe cannot return a source',
    () async {
      final scope = RequestScope();
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/download')) return download();
        scope.cancel();
        return const HttpResult(206, 'x', {
          'content-range': ['bytes 0-0/16'],
        });
      });
      await expectLater(
        scope.run(
          () => UcConnector(
            http,
            now: () => _now,
          ).download(_session, _file, credential()),
        ),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
    },
  );

  for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
    final session = BrowseSession(
      platform: platform,
      mode: BrowseMode.personal,
      title: 'fixture',
      rootId: '0',
    );
    CloudConnector connector(FakeHttp http) => platform == CloudPlatform.quark
        ? QuarkConnector(http, now: () => _now)
        : UcConnector(http, now: () => _now);

    test(
      '${platform.key} maps only verified whole-file checksum fields',
      () async {
        final http = FakeHttp(
          (r) => ok({
            'list': [
              {
                'fid': 'file',
                'file_name': 'sample.mp4',
                'md5': _digest.toUpperCase(),
              },
              {'fid': 'other', 'file_name': 'sample.zip', 'md5': 'invalid'},
            ],
          }),
        );
        final files = await connector(http).list(session, '0', credential());
        expect(
          files.first.hashType,
          platform == CloudPlatform.uc ? 'md5' : null,
        );
        expect(
          files.first.hashValue,
          platform == CloudPlatform.uc ? _digest : null,
        );
        expect(files.last.hashType, isNull);
      },
    );

    test(
      '${platform.key} rejects foreign file IDs and changed or invalid checksums before CDN access',
      () async {
        for (final response in [
          download(fid: 'different-file'),
          if (platform == CloudPlatform.uc) download(md5: 'invalid'),
          if (platform == CloudPlatform.uc)
            download(md5: 'ffffffffffffffffffffffffffffffff'),
        ]) {
          final http = FakeHttp((_) => response);
          await expectLater(
            connector(http).download(
              session,
              const CloudFile(
                id: 'file',
                name: 'sample.mp4',
                size: 4,
                hashType: 'md5',
                hashValue: _digest,
              ),
              credential(),
            ),
            throwsA(isA<AppException>()),
          );
          expect(http.calls, hasLength(1));
        }
      },
    );
  }

  test(
    'Quark selects the requested file without treating its API digest as a full-file MD5',
    () async {
      final other =
          jsonDecode(download(fid: 'other').body) as Map<String, dynamic>;
      final wanted = jsonDecode(download().body) as Map<String, dynamic>;
      final http = FakeHttp(
        (r) => ok([...(other['data'] as List), ...(wanted['data'] as List)]),
      );
      final spec = await QuarkConnector(http, now: () => _now).download(
        const BrowseSession(
          platform: CloudPlatform.quark,
          mode: BrowseMode.personal,
          title: 'fixture',
          rootId: '0',
        ),
        _file,
        credential(),
      );
      expect(spec.expectedSize, 4);
      expect(spec.checksumType, isNull);
      expect(spec.checksumValue, isNull);
      expect(http.calls, hasLength(1));
    },
  );

  test('Quark retains an independently supplied checksum', () async {
    final http = FakeHttp(
      (_) => download(md5: 'ffffffffffffffffffffffffffffffff'),
    );
    final spec = await QuarkConnector(http, now: () => _now).download(
      const BrowseSession(
        platform: CloudPlatform.quark,
        mode: BrowseMode.personal,
        title: 'fixture',
        rootId: '0',
      ),
      const CloudFile(
        id: 'file',
        name: 'sample.mp4',
        size: 4,
        hashType: 'md5',
        hashValue: _digest,
      ),
      credential(),
    );
    expect(spec.checksumType, 'md5');
    expect(spec.checksumValue, _digest);
  });

  test('Concurrent UC cookie refreshes share a single refresh gate', () async {
    final store = StateStore.memory();
    final vault = Vault(store);
    final initial = Credential('uc', {
      'primary': '__pus=keep; __puus=expired',
      'ucSessionRefreshedAt': '$_now',
    }, updatedAt: 7);
    await vault.putCredential(CloudPlatform.uc, initial);
    final refreshEntered = Completer<void>();
    final refreshRelease = Completer<void>();
    var refreshCalls = 0;
    final http = FakeHttp((r) async {
      if (r.uri.path.endsWith('/config')) {
        refreshCalls++;
        if (!refreshEntered.isCompleted) refreshEntered.complete();
        await refreshRelease.future;
        return HttpResult(200, '{"status":200,"code":0,"data":{}}', {
          'set-cookie': ['__puus=fresh; Path=/'],
        });
      }
      if ((r.headers['Cookie'] ?? '').contains('__puus=expired')) {
        return const HttpResult(401, '{"status":401,"code":31001}');
      }
      return ok({'list': []});
    });
    final uc = UcConnector(http, store: vault, now: () => _now);
    final pending = Future.wait([
      uc.list(_session, '0', initial),
      uc.list(_session, '0', initial),
    ]);
    await refreshEntered.future;
    refreshRelease.complete();
    await pending;
    expect(refreshCalls, 1);
    expect(vault.credential(CloudPlatform.uc)!.primary, contains('__puus=fresh'));
  });
}
