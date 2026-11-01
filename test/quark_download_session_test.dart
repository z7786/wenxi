import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'support.dart';

const _now = 1700000000000;
const _session = BrowseSession(
  platform: CloudPlatform.quark,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '0',
);
const _file = CloudFile(id: 'file', name: 'fixture.bin', size: 4);
Credential _account({bool fresh = true}) => Credential('fixture', {
  'primary': '__pus=account; __puus=old',
  if (fresh) 'quarkSessionRefreshedAt': '$_now',
}, updatedAt: 42);
HttpResult _ok(Object data, {String? cookie}) => HttpResult(
  200,
  jsonResponse({'status': 200, 'code': 0, 'data': data}).body,
  {
    if (cookie != null) 'set-cookie': ['__puus=$cookie; Path=/; Secure'],
  },
);
HttpResult _download() => _ok([
  {'fid': 'file', 'size': 4, 'download_url': 'https://cdn.quark.cn/file'},
]);
HttpResult _expired() => jsonResponse({'status': 401, 'code': 31001}, 401);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'A download uses the current cookie when its account snapshot was renewed',
    () async {
      final old = _account();
      final vault = Vault(StateStore.memory());
      await vault.putCredential(CloudPlatform.quark, old);
      final latest = old.withFields({
        'primary': '__pus=account; __puus=current',
      }, preserveRevision: true);
      await vault.replaceCredential(CloudPlatform.quark, old, latest);
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('/config')) return _ok({});
        if (request.headers['Cookie']!.contains('__puus=current')) {
          return _download();
        }
        return _expired();
      });
      final spec = await QuarkConnector(
        http,
        store: vault,
        now: () => _now,
      ).download(_session, _file, old);
      expect(spec.headers['Cookie'], latest.primary);
      expect(http.calls, hasLength(1));
      expect(vault.credential(CloudPlatform.quark)!.updatedAt, old.updatedAt);
    },
  );

  test(
    'A late login rejection retries a cookie already renewed by another request',
    () async {
      final old = _account(fresh: false);
      final vault = Vault(StateStore.memory());
      await vault.putCredential(CloudPlatform.quark, old);
      final response = Completer<HttpResult>();
      final sent = Completer<void>();
      var configCalls = 0, downloadCalls = 0;
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('/config')) {
          configCalls++;
          return _ok({});
        }
        downloadCalls++;
        if (downloadCalls == 1) {
          sent.complete();
          return response.future;
        }
        expect(request.headers['Cookie'], contains('__puus=current'));
        return _download();
      });
      final pending = QuarkConnector(
        http,
        store: vault,
        now: () => _now,
      ).download(_session, _file, old);
      final verified = expectLater(pending, completes);
      await sent.future;
      await vault.replaceCredential(
        CloudPlatform.quark,
        old,
        old.withFields({
          'primary': '__pus=account; __puus=current',
          'quarkSessionRefreshedAt': '$_now',
        }, preserveRevision: true),
      );
      response.complete(_expired());
      await verified;
      final spec = await pending;
      expect(spec.headers['Cookie'], contains('__puus=current'));
      expect(configCalls, 1);
      expect(downloadCalls, 2);
    },
  );

  test(
    'A genuinely expired account still requires login after one refresh',
    () async {
      var configCalls = 0, downloadCalls = 0;
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('/config')) {
          configCalls++;
          return _ok({}, cookie: 'refreshed-but-invalid');
        }
        downloadCalls++;
        return _expired();
      });
      await expectLater(
        QuarkConnector(
          http,
          now: () => _now,
        ).download(_session, _file, _account()),
        throwsA(isA<AccountLoginRequired>()),
      );
      expect(configCalls, 1);
      expect(downloadCalls, 2);
    },
  );

  test(
    'Parallel downloads share an account refresh without invalidating its cookie',
    () async {
      final old = _account(fresh: false);
      final vault = Vault(StateStore.memory());
      await vault.putCredential(CloudPlatform.quark, old);
      var configCalls = 0;
      var activeCookie = '';
      final http = FakeHttp((request) async {
        if (request.uri.path.endsWith('/config')) {
          final issued = 'renewed-${++configCalls}';
          activeCookie = issued;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return _ok({}, cookie: issued);
        }
        return request.headers['Cookie']!.contains('__puus=$activeCookie')
            ? _download()
            : _expired();
      });
      final connector = QuarkConnector(http, store: vault, now: () => _now);
      final specs = await Future.wait([
        connector.download(_session, _file, old),
        connector.download(_session, _file, old),
        connector.download(_session, _file, old),
      ]);
      expect(configCalls, 1);
      expect(
        specs.map((spec) => spec.headers['Cookie']),
        everyElement(contains('__puus=renewed-1')),
      );
      expect(
        vault.credential(CloudPlatform.quark)!.primary,
        contains('__puus=renewed-1'),
      );
    },
  );

  test(
    'Cancelling a download waiting for refresh does not cancel the other download',
    () async {
      final old = _account(fresh: false);
      final vault = Vault(StateStore.memory());
      await vault.putCredential(CloudPlatform.quark, old);
      final started = Completer<void>();
      final response = Completer<HttpResult>();
      final scope = RequestScope();
      var configCalls = 0, downloadCalls = 0;
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('/config')) {
          configCalls++;
          started.complete();
          return response.future;
        }
        downloadCalls++;
        return _download();
      });
      final connector = QuarkConnector(http, store: vault, now: () => _now);
      final first = connector.download(_session, _file, old);
      await started.future;
      final waiting = scope.run(() => connector.download(_session, _file, old));
      final cancelled = expectLater(
        waiting,
        throwsA(
          isA<AppException>().having(
            (error) => error.message,
            'message',
            contains('取消'),
          ),
        ),
      );
      scope.cancel();
      await cancelled;
      response.complete(_ok({}, cookie: 'current'));
      expect((await first).headers['Cookie'], contains('__puus=current'));
      expect(configCalls, 1);
      expect(downloadCalls, 1);
    },
  );

  for (final action in ['logout', 'relogin']) {
    test(
      '$action while a download waits prevents a stale response retry',
      () async {
        final old = _account();
        final vault = Vault(StateStore.memory());
        await vault.putCredential(CloudPlatform.quark, old);
        final response = Completer<HttpResult>();
        final sent = Completer<void>();
        final http = FakeHttp((request) {
          sent.complete();
          return response.future;
        });
        final pending = QuarkConnector(
          http,
          store: vault,
          now: () => _now,
        ).download(_session, _file, old);
        final verified = expectLater(pending, throwsA(isA<AppException>()));
        await sent.future;
        if (action == 'logout') {
          await vault.removeCredential(CloudPlatform.quark);
        } else {
          await vault.putCredential(
            CloudPlatform.quark,
            Credential('fixture', {
              'primary': '__pus=other; __puus=other',
            }, updatedAt: 43),
          );
        }
        response.complete(_expired());
        await verified;
        expect(http.calls, hasLength(1));
        if (action == 'logout') {
          expect(vault.credential(CloudPlatform.quark), isNull);
        } else {
          expect(vault.credential(CloudPlatform.quark)!.updatedAt, 43);
          expect(
            vault.credential(CloudPlatform.quark)!.primary,
            contains('__pus=other'),
          );
        }
      },
    );
  }

  test(
    'Candidate validation does not replace its cookie with an existing account',
    () async {
      final saved = _account();
      final vault = Vault(StateStore.memory());
      await vault.putCredential(CloudPlatform.quark, saved);
      final candidate = Credential('fixture', {
        'primary': '__pus=candidate; __puus=candidate',
      }, updatedAt: 43);
      final http = FakeHttp((request) {
        expect(request.headers['Cookie'], candidate.primary);
        return _ok({
          'nickname': 'candidate',
          'use_capacity': 0,
          'total_capacity': 100,
        });
      });
      final result = await QuarkConnector(
        http,
        store: vault,
        now: () => _now,
      ).authenticate(candidate);
      expect(result.credential.primary, candidate.primary);
      expect(vault.credential(CloudPlatform.quark)!.sameAs(saved), isTrue);
      expect(http.calls, hasLength(1));
    },
  );

  test(
    'A remembered account remains isolated when another account is active',
    () async {
      final old = _account();
      final vault = Vault(StateStore.memory());
      await vault.putCredential(CloudPlatform.quark, old);
      final owner = vault.activeAccountId(CloudPlatform.quark)!;
      final latest = old.withFields({
        'primary': '__pus=account; __puus=current',
      }, preserveRevision: true);
      await vault.replaceCredential(CloudPlatform.quark, old, latest);
      final other = await vault.createAccount(CloudPlatform.quark);
      await vault.withAccount(
        CloudPlatform.quark,
        other,
        () => vault.putCredential(
          CloudPlatform.quark,
          Credential('other', {
            'primary': '__pus=other; __puus=other',
          }, updatedAt: 43),
        ),
      );
      await vault.activate(CloudPlatform.quark, other);
      final http = FakeHttp((request) {
        expect(request.headers['Cookie'], latest.primary);
        return _download();
      });
      final spec = await vault.withAccount(
        CloudPlatform.quark,
        owner,
        () => QuarkConnector(
          http,
          store: vault,
          now: () => _now,
        ).download(_session, _file, old),
      );
      expect(spec.headers['Cookie'], latest.primary);
      expect(vault.activeAccountId(CloudPlatform.quark), other);
      expect(
        vault.credential(CloudPlatform.quark)!.primary,
        contains('__pus=other'),
      );
      expect(http.calls, hasLength(1));
    },
  );
}
