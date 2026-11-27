import 'dart:async';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/data/cloud_browser_ua.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/desktop_browser_ua.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/data/providers/ctfile.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/providers/uc_tv_protocol.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const blocked = HttpResult(
  403,
  '<!doctype html><html>ESA Request blocked: browser rejected</html>',
);
const browserHeaders = {'User-Agent': WebLoginTarget.desktopUserAgent};

void main() {
  late Vault vault;
  late CloudBrowserUa identities;
  setUp(() {
    vault = Vault(StateStore.memory());
    identities = CloudBrowserUa(
      vault,
      pool: DesktopBrowserUaPool(random: Random(4)),
    );
  });

  test(
    'ordinary browser profiles join the pool; client identities stay exact',
    () async {
      final http = FakeHttp();
      for (final platform in CloudPlatform.values) {
        final client = BrowserUaJsonHttp(http, identities, platform);
        await client.get('https://example.test/list', browserHeaders);
        final ua = http.calls.last.headers['User-Agent']!;
        expect(CloudBrowserUa.pooled(ua), CloudBrowserUa.supports(platform));
      }
      for (final ua in [
        QuarkConnector.cloudUa,
        QuarkConnector.webUa,
        UcConnector.cloudUa,
        UcTvProtocol.userAgent,
        XunleiProtocol.appUa,
        '${WebLoginTarget.desktopUserAgent} 115Browser/27.0.5.7',
        'netdisk;13.15.4;device;android-android;13;',
        'ANDROID-com.pikcloud.pikpak/1.21.0',
        'Dart/3.12 (dart:io)',
        WebLoginTarget.mobileUserAgent,
        'parser-supplied-browser',
      ]) {
        await BrowserUaJsonHttp(
          http,
          identities,
          CloudPlatform.uc,
        ).get('https://example.test/file', {'User-Agent': ua});
        expect(http.calls.last.headers['User-Agent'], ua);
      }
    },
  );

  test(
    'saved accounts retain UA across restarts and account switches',
    () async {
      const p = CloudPlatform.weiyun;
      await vault.putCredential(p, Credential('one', {'primary': 'token-one'}));
      final first = vault.activeAccountId(p)!;
      final http = FakeHttp();
      await BrowserUaJsonHttp(
        http,
        identities,
        p,
      ).get('https://example.test', browserHeaders);
      final firstUa = http.calls.last.headers['User-Agent'];
      expect(vault.secret(CloudBrowserUa.secretKey(p)), firstUa);
      final second = await vault.createAccount(p);
      await vault.withAccount(
        p,
        second,
        () =>
            vault.putCredential(p, Credential('two', {'primary': 'token-two'})),
      );
      await vault.withAccount(
        p,
        second,
        () => BrowserUaJsonHttp(
          http,
          identities,
          p,
        ).get('https://example.test', browserHeaders),
      );
      final secondUa = http.calls.last.headers['User-Agent'];
      expect(secondUa, isNot(firstUa));
      final restarted = CloudBrowserUa(vault);
      expect(vault.withAccount(p, first, () => restarted.selected(p)), firstUa);
      expect(
        vault.withAccount(p, second, () => restarted.selected(p)),
        secondUa,
      );
      expect(vault.activeAccountId(p), first);
    },
  );

  test(
    'login binds validation UA to credentials without disturbing old account',
    () async {
      const p = CloudPlatform.ctfile;
      final old = Credential('old', {'primary': 'old-token'}, updatedAt: 42);
      await vault.putCredential(p, old);
      final ua = DesktopBrowserUa.builtIn.last.value;
      final http = FakeHttp();
      final login = AccountLoginService(
        vault,
        (_, _) async => const CloudAccount('new'),
        browserUa: identities,
      );
      final result = await login.submit(p, (_) async {
        await BrowserUaJsonHttp(
          http,
          identities,
          p,
        ).postJson('https://example.test/login', {}, browserHeaders);
        expect(vault.credential(p)!.sameAs(old), isTrue);
        return LoginResult(
          Credential('new', {'primary': 'new-token'}),
          const CloudAccount('new'),
        );
      }, browserUserAgent: ua);
      expect(http.calls.single.headers['User-Agent'], ua);
      expect(result.credential.field(CloudBrowserUa.credentialField), ua);
      expect(CloudBrowserUa(vault).selected(p), ua);
    },
  );

  test('failed login does not save its new browser identity', () async {
    const p = CloudPlatform.ctfile;
    final oldUa = DesktopBrowserUa.builtIn.first.value;
    final old = Credential('old', {
      'primary': 'old-token',
      CloudBrowserUa.credentialField: oldUa,
    }, updatedAt: 42);
    await vault.putCredential(p, old);
    final login = AccountLoginService(
      vault,
      (_, _) async => const CloudAccount(''),
      browserUa: identities,
    );
    await expectLater(
      login.submit(p, (_) async {
        await BrowserUaJsonHttp(
          FakeHttp(),
          identities,
          p,
        ).get('https://example.test', browserHeaders);
        throw const FormatException('login failed');
      }, browserUserAgent: DesktopBrowserUa.builtIn.last.value),
      throwsFormatException,
    );
    expect(vault.credential(p)!.sameAs(old), isTrue);
    expect(identities.selected(p), oldUa);
    expect(vault.secret(CloudBrowserUa.secretKey(p)), isNull);
  });

  test(
    'nested operations on two accounts of the same cloud keep separate UA',
    () async {
      const p = CloudPlatform.wopan;
      final one = DesktopBrowserUa.builtIn.first.value;
      final two = DesktopBrowserUa.builtIn.last.value;
      await vault.putCredential(
        p,
        Credential('one', {
          'primary': 'one',
          CloudBrowserUa.credentialField: one,
        }),
      );
      final first = vault.activeAccountId(p)!;
      final second = await vault.createAccount(p);
      await vault.withAccount(
        p,
        second,
        () => vault.putCredential(
          p,
          Credential('two', {
            'primary': 'two',
            CloudBrowserUa.credentialField: two,
          }),
        ),
      );
      final http = FakeHttp();
      final client = BrowserUaJsonHttp(http, identities, p);
      await vault.withAccount(
        p,
        first,
        () => identities.run(p, () async {
          await client.get('https://example.test/one', browserHeaders);
          await vault.withAccount(
            p,
            second,
            () => client.get('https://example.test/two', browserHeaders),
          );
          await client.get('https://example.test/one-again', browserHeaders);
        }),
      );
      expect(http.calls.map((r) => r.headers['User-Agent']), [one, two, one]);
      expect(
        vault.withAccount(
          p,
          first,
          () => vault.secret(CloudBrowserUa.secretKey(p)),
        ),
        one,
      );
      expect(
        vault.withAccount(
          p,
          second,
          () => vault.secret(CloudBrowserUa.secretKey(p)),
        ),
        two,
      );
    },
  );

  test(
    'guest HTML filtering rotates at most three distinct identities',
    () async {
      final http = FakeHttp((_) => blocked);
      final response = await BrowserUaJsonHttp(
        http,
        identities,
        CloudPlatform.ctfile,
      ).get('https://example.test/list', browserHeaders);
      expect(response.status, 403);
      expect(http.calls, hasLength(3));
      expect(
        http.calls.map((r) => r.headers['User-Agent']).toSet(),
        hasLength(3),
      );
    },
  );

  test(
    'permission, expiry, rate limit and mutations never rotate or replay',
    () async {
      for (final response in [
        jsonResponse({'error': 'permission denied'}, 403),
        const HttpResult(403, ''),
        const HttpResult(401, ''),
        const HttpResult(429, ''),
      ]) {
        final http = FakeHttp((_) => response);
        await BrowserUaJsonHttp(
          http,
          identities,
          CloudPlatform.ctfile,
        ).get('https://example.test/list', browserHeaders);
        expect(http.calls, hasLength(1));
      }
      for (final verb in ['POST', 'PUT', 'DELETE']) {
        final http = FakeHttp((_) => blocked);
        await BrowserUaJsonHttp(
          http,
          identities,
          CloudPlatform.ctfile,
        ).request(verb, 'https://example.test/mutate', headers: browserHeaders);
        expect(http.calls, hasLength(1));
      }
      final http = FakeHttp((_) => blocked);
      await BrowserUaJsonHttp(
        http,
        identities,
        CloudPlatform.ctfile,
      ).mutationRequest(
        'GET',
        'https://example.test/delete',
        headers: browserHeaders,
      );
      expect(http.calls, hasLength(1));
      await vault.putCredential(
        CloudPlatform.ctfile,
        Credential('old', {'primary': 'token'}),
      );
      await BrowserUaJsonHttp(
        http,
        identities,
        CloudPlatform.ctfile,
      ).get('https://example.test/list', browserHeaders);
      expect(http.calls, hasLength(2));
    },
  );

  test(
    'independent asynchronous guest chains retain their own successful UA',
    () async {
      final release = Completer<void>();
      final starts = <String>[];
      final http = FakeHttp((r) async {
        if (r.uri.path == '/start') {
          starts.add(r.headers['User-Agent']!);
          if (starts.length == 2) release.complete();
          await release.future;
        }
        return const HttpResult(200, '{}');
      });
      final client = BrowserUaJsonHttp(http, identities, CloudPlatform.ctfile);
      Future<void> chain() => identities.run(CloudPlatform.ctfile, () async {
        await client.get('https://example.test/start', browserHeaders);
        final ua = identities.current;
        await client.get('https://example.test/end', browserHeaders);
        expect(
          identities.headers(
            CloudPlatform.ctfile,
            browserHeaders,
          )['User-Agent'],
          ua,
        );
      }, fresh: true);
      await Future.wait([chain(), chain()]);
      expect(starts.toSet(), hasLength(2));
      expect(
        http.calls
            .where((r) => r.uri.path == '/end')
            .map((r) => r.headers['User-Agent'])
            .toSet(),
        starts.toSet(),
      );
    },
  );

  test(
    'ILanzou metadata matches pooled UA without re-encoding signed tokens',
    () async {
      final http = FakeHttp();
      final ua = DesktopBrowserUa.builtIn.last;
      await identities.run(
        CloudPlatform.ilanzou,
        () => BrowserUaJsonHttp(http, identities, CloudPlatform.ilanzou).get(
          'https://apis.ilanzou.com/read?devModel=chrome&devVersion=125&appToken=A%2FB+%3D',
          browserHeaders,
        ),
        userAgent: ua.value,
        locked: true,
      );
      expect(http.calls.single.uri.queryParameters['devModel'], ua.model);
      expect(http.calls.single.uri.queryParameters['devVersion'], ua.version);
      expect(http.calls.single.url, endsWith('appToken=A%2FB+%3D'));
      expect(http.calls.single.headers['User-Agent'], ua.value);
    },
  );

  test('139 device metadata follows the selected desktop browser', () async {
    final http = FakeHttp();
    final ua = DesktopBrowserUa.builtIn.last;
    await identities.run(
      CloudPlatform.c139,
      () => BrowserUaJsonHttp(http, identities, CloudPlatform.c139).get(
        'https://yun.139.com/read',
        {
          ...browserHeaders,
          'X-Deviceinfo':
              '||9|7.17.9|chrome|116.0.0.0|device||windows 10||zh-CN|||',
          'x-yun-client-info':
              '||9|7.17.9|chrome|116.0.0.0|device||windows 10||zh-CN|||encoded||',
        },
      ),
      userAgent: ua.value,
    );
    for (final key in ['X-Deviceinfo', 'x-yun-client-info']) {
      expect(
        http.calls.single.headers[key],
        contains('|firefox|145.0.0.0|device||linux||'),
      );
    }
  });

  test(
    'verified POST reads can rotate; an explicitly pinned chain cannot',
    () async {
      final http = FakeHttp((_) => blocked);
      final client = BrowserUaJsonHttp(http, identities, CloudPlatform.ctfile);
      await client.postJsonRead(
        'https://example.test/list',
        {},
        browserHeaders,
      );
      expect(http.calls, hasLength(3));
      http.calls.clear();
      await identities.run(
        CloudPlatform.ctfile,
        () => client.get('https://example.test/list', browserHeaders),
        userAgent: DesktopBrowserUa.builtIn.first.value,
      );
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'repository share parse, download spec and restored session keep one UA',
    () async {
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('get_down_url.php')
            ? jsonResponse({
                'code': 200,
                'downurl': 'https://cdn.example/sample.bin',
              })
            : jsonResponse({
                'code': 200,
                'file': {
                  'file_id': '17569901563698',
                  'file_name': 'sample.bin',
                  'file_size': 400,
                  'userid': 66485969,
                  'file_chk': 'check',
                  'wait_seconds': 0,
                  'start_time': 100,
                },
              }),
      );
      final repository = CloudRepository(
        http,
        vault,
        CleanupOutbox(vault.store, http),
      );
      final session = await repository.share(
        LinkParser.parse(
          'https://url69.ctfile.com/f/66485969-17569901563698-90650b?p=1664',
        ).single,
      );
      final file = (await repository.list(session, session.rootId)).single;
      final spec = await repository.prepare(session, file);
      final ua = http.calls.first.headers['User-Agent'];
      expect(CloudBrowserUa.pooled(ua!), isTrue);
      expect(http.calls.map((r) => r.headers['User-Agent']).toSet(), {ua});
      expect(spec.headers['User-Agent'], ua);
      final restored = BrowseSession.fromJson(session.toJson());
      expect(restored.meta(CloudBrowserUa.sessionField), ua);
      final restarted = CloudRepository(
        http,
        vault,
        CleanupOutbox(vault.store, http),
      );
      expect(
        (await restarted.prepare(restored, file)).headers['User-Agent'],
        ua,
      );
      expect(DownloadSpec.fromJson(spec.toJson()).headers['User-Agent'], ua);
    },
  );

  test('CTfile captcha headers share native password login identity', () async {
    final http = FakeHttp(
      (r) => jsonResponse({
        'code': 200,
        'captcha_type': 'image',
        'always_required': true,
      }),
    );
    final client = CtfileConnector(
      BrowserUaJsonHttp(http, identities, CloudPlatform.ctfile),
    );
    final ua = DesktopBrowserUa.builtIn.last.value;
    await expectLater(
      identities.run(
        CloudPlatform.ctfile,
        () => client.password(
          'test@example.com',
          'test-password',
          verifyCaptcha: (challenge) async {
            expect(challenge.imageHeaders['User-Agent'], ua);
            return null;
          },
        ),
        userAgent: ua,
        locked: true,
      ),
      throwsA(anything),
    );
    expect(http.calls.single.headers['User-Agent'], ua);
  });
}
