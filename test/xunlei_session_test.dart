import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/xunlei_login.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/redaction.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/xunlei_web_login.dart';
import 'support.dart';
import 'xunlei_login_support.dart';

const _p = xunleiTestPlatform;
Matcher get _loginRequired => throwsA(isA<AccountLoginRequired>());
Matcher get _accountChanged => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains('账号已变化')),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Web login validates and renews tokens with the official web client',
    () async {
      final f = XunleiLoginFixture();
      f.tokenRefresh = jsonResponse({
        'access_token': 'refreshed-access',
        'refresh_token': 'new-web-refresh-token',
      });
      final result = await f.login.submitWeb(
        _p,
        jsonEncode({
          'refresh_token': 'fixture-web-refresh-token',
          'sub': 'web-user',
          'device_id': 'web-device-0123456789',
        }),
      );
      expect(result.account.total, 1000);
      expect(f.saved.field('accessToken'), 'refreshed-access');
      expect(f.saved.field('refreshToken'), 'new-web-refresh-token');
      expect(f.saved.field('authType'), 'webToken');
      expect(f.saved.field('password'), isEmpty);
      expect(f.passwordCalls, 0);
      final request = f.http.calls.singleWhere(
        (r) => r.uri.path == '/v1/auth/token',
      );
      expect(request.json, {
        'grant_type': 'refresh_token',
        'client_id': XunleiWebLogin.clientId,
        'refresh_token': 'fixture-web-refresh-token',
      });
      expect(request.headers['X-Device-Id'], 'web-device-0123456789');
    },
  );

  test(
    'Failed web validation preserves the previously saved account',
    () async {
      final f = XunleiLoginFixture();
      await f.seed();
      await expectLater(
        f.login.submitWeb(
          _p,
          jsonEncode({
            'access_token': 'rejected-web-access-token',
            'refresh_token': 'rejected-web-refresh-token',
          }),
        ),
        _loginRequired,
      );
      expect(f.saved.sameAs(f.initial), isTrue);
      expect(f.passwordCalls, 0);
    },
  );

  test(
    'Remembered password is committed only after a successful login',
    () async {
      final f = XunleiLoginFixture();
      final result = await f.submit();
      expect(result.credential.field('username'), xunleiTestUsername);
      expect(f.saved.field('password'), xunleiTestPassword);
      expect(f.saved.field('authType'), 'passwordToken');
      expect(f.saved.field('userId'), 'user-1');
      expect(
        LogRedactor.json(f.saved.toJson()),
        isNot(contains('SamplePassword')),
      );
      expect(
        LogRedactor.json(f.saved.toJson()),
        isNot(contains(xunleiTestUsername)),
      );
      expect(f.http.calls.first.json['passWord'], xunleiTestPassword);
      expect(LoginCredentials.stored(_p, f.saved), isTrue);
    },
  );

  test(
    'Opting out removes a previously remembered password on successful login',
    () async {
      final f = XunleiLoginFixture();
      await f.seed();
      await f.submit(remember: false);
      expect(f.saved.field('password'), isEmpty);
      expect(f.saved.field('username'), isEmpty);
      expect(LoginCredentials.hasXunleiPassword(f.saved), isFalse);
      expect(f.saved.primary, 'signed-access');
    },
  );

  test(
    'SMS login never carries a previously remembered password into the replacement',
    () async {
      final f = XunleiLoginFixture();
      await f.seed();
      final device = await XunleiDevices(f.vault).get();
      await f.login.submit(
        _p,
        (_) => f.repository.xunleiLogin.verifySms(
          SmsChallenge('13800000000', 'credit', 'sms-token', device.id),
          '123456',
        ),
      );
      expect(f.saved.field('password'), isEmpty);
      expect(f.saved.field('authType'), isEmpty);
      expect(f.passwordCalls, 0);
    },
  );

  test(
    'Refresh token is tried before remembered password and preserves it',
    () async {
      final f = XunleiLoginFixture();
      f.tokenRefresh = jsonResponse({
        'access_token': 'refreshed-access',
        'refresh_token': 'next-refresh',
      });
      await f.seed();
      expect(await f.list(), hasLength(1));
      expect(f.refreshCalls, 1);
      expect(f.passwordCalls, 0);
      expect(f.saved.field('password'), xunleiTestPassword);
      expect(f.saved.updatedAt, 42);
    },
  );

  test(
    'Expired refresh token triggers one password login and repairs download credentials',
    () async {
      final f = XunleiLoginFixture();
      await f.seed();
      expect(await f.list(), hasLength(1));
      final download = await f.connector.download(
        f.personal,
        f.file,
        f.initial,
      );
      expect(download.url, 'https://cdn.example/fixture');
      expect(f.refreshCalls, 1);
      expect(f.passwordCalls, 1);
      expect(f.saved.primary, 'signed-access');
      expect(f.saved.secondary, 'signed-refresh');
      expect(f.saved.updatedAt, 42);
      expect(f.saved.field('password'), xunleiTestPassword);
      expect(
        f.http.calls.last.headers['X-Device-Id'],
        f.saved.field('deviceId'),
      );
      expect(f.saved.field('deviceId'), isNot('old-device'));
    },
  );

  test(
    'Password login also recovers when the renewed access token is rejected',
    () async {
      final f = XunleiLoginFixture();
      f.tokenRefresh = jsonResponse({
        'access_token': 'still-invalid-access',
        'refresh_token': 'next-refresh',
      });
      await f.seed();
      expect(await f.list(), hasLength(1));
      expect(f.refreshCalls, 1);
      expect(f.passwordCalls, 1);
      expect(f.saved.primary, 'signed-access');
      expect(f.saved.updatedAt, 42);
    },
  );

  test(
    'Temporary action captcha failure after password renewal does not disable login',
    () async {
      final f = XunleiLoginFixture();
      f.intercept = (r) =>
          r.uri.path == '/v1/shield/captcha/init' &&
              r.json.str('action') == 'GET:/drive/v1/files'
          ? const HttpResult(503, '{}')
          : null;
      await f.seed();
      await expectLater(f.list(), throwsA(isA<HttpRequestFailure>()));
      expect(f.saved.primary, 'signed-access');
      expect(f.saved.field('autoLoginBlocked'), isEmpty);
      f.intercept = null;
      expect(await f.list(), hasLength(1));
      expect(f.passwordCalls, 1);
    },
  );

  for (final missing in [false, true]) {
    test(
      'Saved password recovers ${missing ? 'missing' : 'expired JWT'} access before a cloud request',
      () async {
        final f = XunleiLoginFixture();
        final token = missing
            ? ''
            : 'e30.${base64Url.encode(utf8.encode('{"exp":1,"sub":"user-1"}'))}.sig';
        final initial = f.initial.withFields({
          'primary': token,
          'accessToken': token,
        }, preserveRevision: true);
        await f.seed(initial);
        expect(LoginCredentials.stored(_p, initial), isTrue);
        await f.connector.account(initial);
        expect(f.http.calls.first.uri.path, '/v1/auth/token');
        expect(f.passwordCalls, 1);
        expect(f.saved.updatedAt, initial.updatedAt);
      },
    );
  }

  test(
    'Concurrent browsing, quota and download preparation share one login',
    () async {
      final f = XunleiLoginFixture();
      final entered = Completer<void>(), reply = Completer<HttpResult>();
      f.intercept = (r) {
        if (r.uri.path == '/xluser.core.login/v3/login') {
          entered.complete();
          return reply.future;
        }
        return null;
      };
      await f.seed();
      final first = f.list();
      await entered.future;
      final others = Future.wait<Object>([
        f.connector.account(f.initial),
        f.connector.download(f.personal, f.file, f.initial),
      ]);
      reply.complete(jsonResponse(f.signIn));
      expect(await first, hasLength(1));
      await others;
      expect(f.passwordCalls, 1);
      expect(f.refreshCalls, 1);
    },
  );

  test(
    'A late 401 uses the newly saved session without another login or refresh',
    () async {
      final f = XunleiLoginFixture();
      final entered = Completer<void>(), reply = Completer<HttpResult>();
      f.intercept = (r) {
        if (r.uri.path == '/drive/v1/about' &&
            r.headers['Authorization'] == 'Bearer old-access') {
          entered.complete();
          return reply.future;
        }
        return null;
      };
      await f.seed();
      final quota = f.connector.account(f.initial);
      await entered.future;
      await f.list();
      reply.complete(jsonResponse({'error': 'unauthenticated'}, 401));
      expect((await quota).total, 1000);
      expect(f.passwordCalls, 1);
      expect(f.refreshCalls, 1);
    },
  );

  for (final reason in ['password', 'verification', 'identity', 'new-token']) {
    test(
      'Rejected automatic login ($reason) becomes actionable and does not loop',
      () async {
        final f = XunleiLoginFixture();
        if (reason == 'password') {
          f.signIn = {'errorCode': 6, 'errorDesc': xunleiTestPassword};
        }
        if (reason == 'verification') {
          f.signIn = {
            'errorCode': 1007,
            'reviewurl': 'https://i.xunlei.com/verify',
          };
        }
        if (reason == 'identity') f.signIn['userID'] = 'different-user';
        if (reason == 'new-token') f.acceptedTokens.clear();
        await f.seed();
        await expectLater(f.list(), _loginRequired);
        expect(f.saved.field('autoLoginBlocked'), '1');
        expect(f.saved.updatedAt, 42);
        final calls = f.http.calls.length;
        await expectLater(f.list(), _loginRequired);
        await expectLater(f.connector.account(f.saved), _loginRequired);
        expect(f.http.calls.length, calls);
        expect(f.passwordCalls, 1);
      },
    );
  }

  for (final path in ['/v1/auth/token', '/xluser.core.login/v3/login']) {
    test(
      'Temporary network failure at $path does not disable automatic login',
      () async {
        final f = XunleiLoginFixture();
        f.intercept = (r) {
          if (r.uri.path == path) {
            throw const HttpRequestFailure(
              'temporary connection failure',
              kind: 'connectionError',
              retryable: true,
            );
          }
          return null;
        };
        await f.seed();
        await expectLater(f.list(), throwsA(isA<HttpRequestFailure>()));
        expect(f.saved.sameAs(f.initial), isTrue);
        if (path == '/v1/auth/token') expect(f.passwordCalls, 0);
        f.intercept = null;
        expect(await f.list(), hasLength(1));
        expect(f.saved.field('autoLoginBlocked'), isEmpty);
      },
    );
  }

  for (final path in [
    '/xluser.core.login/v3/login',
    '/v1/shield/captcha/init',
    '/v1/auth/signin/token',
  ]) {
    test(
      'Unavailable login service at $path remains retryable without blocking the account',
      () async {
        final f = XunleiLoginFixture();
        f.intercept = (r) => r.uri.path == path
            ? const HttpResult(503, '<html>temporary outage</html>', {
                'retry-after': ['15'],
              })
            : null;
        await f.seed();
        await expectLater(
          f.list(),
          throwsA(
            isA<HttpRequestFailure>().having(
              (e) => e.retryAfter,
              'retryAfter',
              '15',
            ),
          ),
        );
        expect(f.saved.field('autoLoginBlocked'), isEmpty);
        f.intercept = null;
        expect(await f.list(), hasLength(1));
      },
    );
  }

  test('A token-only account never attempts a password login', () async {
    final f = XunleiLoginFixture();
    final initial = f.initial.withFields({
      'password': '',
      'username': '',
      'authType': '',
    }, preserveRevision: true);
    await f.seed(initial);
    await expectLater(f.list(initial), _loginRequired);
    expect(f.passwordCalls, 0);
    expect(f.saved.sameAs(initial), isTrue);
  });

  test(
    'Remembered account and password can restore a session without either token',
    () async {
      final f = XunleiLoginFixture();
      final initial = f.initial.withFields({
        'primary': '',
        'accessToken': '',
        'secondary': '',
        'refreshToken': '',
      }, preserveRevision: true);
      await f.seed(initial);
      expect(LoginCredentials.stored(_p, initial), isTrue);
      expect(await f.list(initial), hasLength(1));
      expect(f.refreshCalls, 0);
      expect(f.passwordCalls, 1);
    },
  );

  for (final status in [429, 503]) {
    test(
      'Refresh service HTTP $status does not fall through to password login',
      () async {
        final f = XunleiLoginFixture();
        f.tokenRefresh = HttpResult(status, '{}', {
          'retry-after': ['15'],
        });
        await f.seed();
        await expectLater(
          f.list(),
          throwsA(
            isA<HttpRequestFailure>().having((e) => e.status, 'status', status),
          ),
        );
        expect(f.passwordCalls, 0);
        expect(f.saved.sameAs(f.initial), isTrue);
      },
    );
  }

  for (final replace in [false, true]) {
    test(
      'A late automatic login cannot ${replace ? 'overwrite a new account' : 'restore a removed account'}',
      () async {
        final f = XunleiLoginFixture();
        final entered = Completer<void>(), reply = Completer<HttpResult>();
        f.intercept = (r) {
          if (r.uri.path == '/xluser.core.login/v3/login') {
            entered.complete();
            return reply.future;
          }
          return null;
        };
        await f.seed();
        final work = expectLater(f.list(), _accountChanged);
        await entered.future;
        final replacement = Credential('other', {
          'primary': 'other-token',
        }, updatedAt: 43);
        if (replace) {
          await f.vault.putCredential(_p, replacement);
        } else {
          await f.login.remove(_p);
        }
        final count = f.http.calls.length;
        reply.complete(jsonResponse(f.signIn));
        await work;
        expect(f.http.calls.length, count);
        expect(f.vault.credential(_p)?.primary, replace ? 'other-token' : null);
        await expectLater(f.list(), _accountChanged);
        expect(f.http.calls.length, count);
      },
    );
  }

  test(
    'Cancelling a queued request does not cancel the other request login',
    () async {
      final f = XunleiLoginFixture();
      final entered = Completer<void>(), reply = Completer<HttpResult>();
      f.intercept = (r) {
        if (r.uri.path == '/xluser.core.login/v3/login') {
          entered.complete();
          return reply.future;
        }
        return null;
      };
      await f.seed();
      final first = f.list();
      await entered.future;
      final scope = RequestScope();
      final second = expectLater(
        scope.run(f.list),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
      scope.cancel();
      await second;
      reply.complete(jsonResponse(f.signIn));
      await first;
      expect(f.passwordCalls, 1);
      expect(f.saved.field('autoLoginBlocked'), isEmpty);
    },
  );

  test(
    'Cancelling an active login cannot commit its late response or disable the saved account',
    () async {
      final f = XunleiLoginFixture();
      final entered = Completer<void>(), reply = Completer<HttpResult>();
      f.intercept = (r) {
        if (r.uri.path == '/xluser.core.login/v3/login') {
          entered.complete();
          return reply.future;
        }
        return null;
      };
      await f.seed();
      final scope = RequestScope();
      final work = expectLater(
        scope.run(f.list),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
      await entered.future;
      scope.cancel();
      await work;
      reply.complete(jsonResponse(f.signIn));
      f.intercept = null;
      expect(await f.list(), hasLength(1));
      expect(f.passwordCalls, 2);
      expect(f.saved.field('autoLoginBlocked'), isEmpty);
    },
  );

  test(
    'Explicit login can replace a session whose tokens renewed while the form was submitted',
    () async {
      final f = XunleiLoginFixture();
      final entered = Completer<void>(), reply = Completer<LoginResult>();
      await f.seed();
      final manual = f.login.submit(_p, (_) {
        entered.complete();
        return reply.future;
      });
      await entered.future;
      await f.list();
      reply.complete(
        LoginResult(
          Credential('other', {'primary': 'other-access', 'userId': 'user-2'}),
          const CloudAccount('other'),
        ),
      );
      await manual;
      expect(f.saved.primary, 'other-access');
      expect(f.saved.updatedAt, greaterThan(42));
      expect(f.saved.field('password'), isEmpty);
    },
  );

  test(
    'A successful explicit login clears a previous automatic-login block',
    () async {
      final f = XunleiLoginFixture();
      await f.seed(
        f.initial.withFields({'autoLoginBlocked': '1'}, preserveRevision: true),
      );
      await expectLater(f.list(), _loginRequired);
      expect(f.http.calls, isEmpty);
      await f.submit();
      expect(f.saved.field('autoLoginBlocked'), isEmpty);
      expect(await f.list(f.saved), hasLength(1));
    },
  );

  test(
    'Renewing a background account cannot update the active account credentials',
    () async {
      final f = XunleiLoginFixture();
      await f.seed();
      await f.vault.initializeAccounts();
      final active = f.vault.activeAccountId(_p);
      final secondId = await f.vault.createAccount(_p);
      final second = Credential(f.initial.label, {
        ...f.initial.fields,
        'username': 'other@example.com',
        'userId': 'user-2',
      }, updatedAt: 43);
      f.signIn['userID'] = 'user-2';
      await f.vault.withAccount(_p, secondId, () => f.seed(second));
      await f.vault.withAccount(_p, secondId, () => f.list(second));
      expect(f.vault.activeAccountId(_p), active);
      expect(f.saved.sameAs(f.initial), isTrue);
      expect(f.vault.credentialFor(_p, secondId)!.primary, 'signed-access');
      expect(
        f.http.calls
            .firstWhere((r) => r.uri.path.endsWith('/v3/login'))
            .json['userName'],
        'other@example.com',
      );
    },
  );

  test(
    'Plain-state restart keeps the password and can renew without a login page',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-xunlei-auto-login-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = await StateStore.open(directory);
      final f = XunleiLoginFixture(store: store);
      await f.submit();
      await store.flush();
      expect(store.file!.path, endsWith('state-v2.json'));
      final snapshot = StateStore.memory(
        decodePlainState(await store.file!.readAsBytes()),
      );
      addTearDown(snapshot.dispose);
      final saved = Vault(snapshot).credential(_p)!;
      expect(saved.field('username'), xunleiTestUsername);
      expect(saved.field('password'), xunleiTestPassword);
      expect(saved.field('accessToken'), 'signed-access');
      final reopened = await StateStore.open(directory);
      final next = XunleiLoginFixture(store: reopened);
      next.acceptedTokens.remove('signed-access');
      next.intercept = (r) => r.uri.path == '/v1/auth/signin/token'
          ? jsonResponse({
              'access_token': 'newer-access',
              'refresh_token': 'newer-refresh',
            })
          : null;
      expect(next.saved.field('password'), xunleiTestPassword);
      expect(await next.list(next.saved), hasLength(1));
      expect(next.passwordCalls, 1);
      await next.login.remove(_p);
      expect(next.vault.credential(_p), isNull);
      await reopened.flush();
      reopened.dispose();
      store.dispose();
    },
  );

  test(
    'App startup restores the account and a later login failure updates its cloud card',
    () async {
      final f = XunleiLoginFixture();
      await f.seed();
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-xunlei-services-',
      );
      final services = AppServices(
        controlEnabled: false,
        store: f.store,
        dataDirectory: directory,
        cacheDirectory: Directory('${directory.path}/cache'),
        transport: FakeNative(),
        files: FakeFiles(Directory('${directory.path}/saved')),
        platformFeatures: false,
        http: f.http,
      );
      addTearDown(() async {
        await services.close();
        await directory.delete(recursive: true);
      });
      await services.initialize();
      await until(() => services.accounts[_p]?.total == 1000);
      expect(f.passwordCalls, 1);
      expect(services.accountNeedsLogin, isEmpty);
      f.acceptedTokens.clear();
      f.signIn = {'errorCode': 1007};
      await expectLater(
        services.cloud.connector(_p).list(f.personal, '', f.saved),
        _loginRequired,
      );
      expect(services.accountNeedsLogin, contains(_p));
      expect(services.accountErrors[_p], contains('自动登录失败'));
      expect(services.accounts[_p], isNull);
      final count = f.http.calls.length;
      await services.refreshAccount(_p);
      expect(f.http.calls.length, count);
    },
  );
}
