import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/tianyi_web_login.dart';
import 'support.dart';

const _id = '0123456789abcdef0123456789abcdef';
const _cloud = CloudPlatform.tianyi;
const _identity =
    'https://cloud.189.cn/api/open/user/getUserInfoForPortal.action';

void main() {
  test(
    'Tianyi web login keeps the official parent that creates the portal browser binding',
    () {
      final target = WebLoginTarget.targets[_cloud]!;
      final login = Uri.parse(target.url);
      expect(login.host, 'cloud.189.cn');
      expect(login.path, '/web/login.html');
      expect(login.hasQuery, false);
      expect(target.desktopMode, true);
      expect(target.userAgent, WebLoginTarget.desktopUserAgent);
      for (final page in [
        'https://m.cloud.189.cn/main.action?menu=true',
        'https://h5.cloud.189.cn/main.html',
      ]) {
        expect(TianyiWebLogin.trusted(page), true);
        expect(target.cookieUrls(page).first, _identity);
        expect(target.cookieUrls(page), TianyiWebLogin.cookieUrls);
      }
      expect(TianyiWebLogin.trusted('https://open.e.189.cn/'), false);
      expect(
        TianyiWebLogin.trusted('https://h5.cloud.189.cn.attacker.invalid/'),
        false,
      );
    },
  );

  test(
    'Tianyi identifies post-login landings without treating a callback as completion',
    () {
      for (final url in [
        'https://cloud.189.cn/web/redirect.html',
        'https://cloud.189.cn/web/main/',
        'https://m.cloud.189.cn/main.action?menu=true',
        'https://h5.cloud.189.cn/',
        'https://h5.cloud.189.cn/home.html',
      ]) {
        expect(TianyiWebLogin.isCompletionLanding(url), true, reason: url);
      }
      for (final url in [
        TianyiWebLogin.loginUrl,
        'https://m.cloud.189.cn/callbackUnifyV2.action?ticket=fixture',
        'https://cloud.189.cn/api/portal/callbackUnify.action?ticket=fixture',
        'https://open.e.189.cn/api/logbox/separate/wap/index.html',
        'https://h5.cloud.189.cn/app/auth.js',
        'https://h5.cloud.189.cn.attacker.invalid/home.html',
        'https://cloud.189.cn:444/web/redirect.html',
        'http://cloud.189.cn/web/redirect.html',
      ]) {
        expect(TianyiWebLogin.isCompletionLanding(url), false, reason: url);
      }
    },
  );

  test(
    'Tianyi captures the login browser binding with the account API cookies',
    () {
      final target = WebLoginTarget.targets[_cloud]!;
      const page = 'https://cloud.189.cn/web/main/';
      final urls = target.cookieUrls(page);
      expect(urls.first, _identity);
      final raw = LoginCredentials.fromBrowser(
        _cloud,
        storage: jsonEncode({'browserId': _id, 'unrelated': 'discard'}),
        cookies: [
          for (final url in urls)
            url == _identity
                ? 'COOKIE_LOGIN_USER=api-session; JSESSIONID=api-transient'
                : 'COOKIE_LOGIN_USER=page-session',
        ],
      );
      final candidate = LoginCredentials.candidate(_cloud, raw, null);
      expect(
        candidate.primary,
        'COOKIE_LOGIN_USER=api-session; JSESSIONID=api-transient',
      );
      expect(candidate.field('browserId'), _id);
      expect(candidate.fields.containsKey('unrelated'), false);
    },
  );

  for (final id in [_id, '']) {
    test(
      'Tianyi authenticated operations preserve the original browser binding: bound=${id.isNotEmpty}',
      () async {
        final candidate = LoginCredentials.candidate(
          _cloud,
          TianyiWebLogin.encode('COOKIE_LOGIN_USER=cloud-session', id),
          null,
        );
        final http = FakeHttp((r) {
          expect(r.headers['Browser-Id'], id.isEmpty ? null : id);
          expect(r.headers['Cookie'], 'COOKIE_LOGIN_USER=cloud-session');
          expect(r.uri.queryParameters.containsKey('browserId'), false);
          if (r.uri.path.endsWith('/getUserInfoForPortal.action')) {
            return jsonResponse({
              'res_code': 0,
              'userId': 'fixture-user',
              'loginName': 'fixture-name',
            });
          }
          if (r.uri.path.endsWith('/getUserSizeInfo.action')) {
            return jsonResponse({
              'res_code': 0,
              'cloudCapacityInfo': {'totalSize': 100, 'usedSize': 30},
            });
          }
          if (r.uri.path.endsWith('/listFiles.action')) {
            return jsonResponse({
              'res_code': 0,
              'fileListAO': {'count': 0, 'fileList': [], 'folderList': []},
            });
          }
          if (r.uri.path.endsWith('/createFolder.action')) {
            return jsonResponse({
              'res_code': 0,
              'id': 'new-folder',
              'name': 'fixture-folder',
            });
          }
          throw StateError('Unexpected route');
        });
        final connector = TianyiConnector(http);
        final login = await connector.authenticate(candidate);
        expect(login.credential.field('browserId'), id);
        expect(login.account.total, 100);
        final session = await connector.openPersonal(login.credential);
        expect(
          await connector.list(session, session.rootId, login.credential),
          isEmpty,
        );
        expect(
          (await connector.createFolder(
            session,
            session.rootId,
            'fixture-folder',
            login.credential,
          )).id,
          'new-folder',
        );
      },
    );
  }

  test('Tianyi login saves validated identity when quota never responds', () {
    fakeAsync((time) {
      final quota = Completer<HttpResult>();
      var quotaCancelled = false;
      final http = FakeHttp((request) {
        if (request.uri.path.endsWith('/getUserInfoForPortal.action')) {
          return jsonResponse({
            'res_code': 0,
            'userId': 'fixture-user',
            'loginName': 'fixture-name',
          });
        }
        expect(request.uri.path, '/api/portal/getUserSizeInfo.action');
        RequestScope.current!.whenCancel.then((_) => quotaCancelled = true);
        return quota.future;
      });
      final vault = Vault(StateStore.memory());
      final connector = TianyiConnector(http);
      final login = AccountLoginService(
        vault,
        (_, _) async => const CloudAccount('unused'),
        webAuthenticators: {_cloud: connector.authenticate},
      );
      LoginResult? result;
      Object? failure;
      login
          .submitWeb(_cloud, 'COOKIE_LOGIN_USER=fixture-session')
          .then<void>(
            (value) {
              result = value;
            },
            onError: (Object error) {
              failure = error;
            },
          );
      time.flushMicrotasks();
      expect(result, isNull);
      time.elapse(const Duration(seconds: 3));
      time.flushMicrotasks();
      expect(failure, isNull);
      expect(result!.account.nickname, 'fixture-name');
      expect(result!.account.total, 0);
      expect(vault.credential(_cloud)!.field('userId'), 'fixture-user');
      expect(quotaCancelled, isTrue);
      quota.complete(
        jsonResponse({
          'res_code': 0,
          'cloudCapacityInfo': {'totalSize': 100, 'usedSize': 30},
        }),
      );
      time.flushMicrotasks();
      expect(
        vault.credential(_cloud)!.primary,
        'COOKIE_LOGIN_USER=fixture-session',
      );
    });
  });

  test('Tianyi validation timeout preserves the account and permits retry', () {
    fakeAsync((time) {
      final vault = Vault(StateStore.memory());
      final previous = Credential('previous', {
        'primary': 'COOKIE_LOGIN_USER=previous',
      }, updatedAt: 1);
      vault.putCredential(_cloud, previous);
      time.flushMicrotasks();
      final response = Completer<LoginResult>();
      var calls = 0, cancelled = false;
      final login = AccountLoginService(
        vault,
        (_, _) async => const CloudAccount('unused'),
        webAuthenticators: {
          _cloud: (credential) {
            calls++;
            if (calls == 1) {
              RequestScope.current!.whenCancel.then((_) => cancelled = true);
              return response.future;
            }
            return Future.value(
              LoginResult(credential, const CloudAccount('retry')),
            );
          },
        },
      );
      Object? failure;
      login
          .submitWeb(
            _cloud,
            'COOKIE_LOGIN_USER=timed-out',
            validationTimeout: const Duration(seconds: 15),
          )
          .then<void>(
            (_) => fail('Timed-out login must not succeed'),
            onError: (Object error) {
              failure = error;
            },
          );
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 15));
      time.flushMicrotasks();
      expect(failure, isA<AppException>());
      expect((failure as AppException).message, contains('登录验证超时'));
      expect(cancelled, isTrue);
      expect(vault.credential(_cloud)!.sameAs(previous), isTrue);

      LoginResult? retry;
      login
          .submitWeb(_cloud, 'COOKIE_LOGIN_USER=retry')
          .then((value) => retry = value);
      time.flushMicrotasks();
      expect(retry, isNotNull);
      expect(vault.credential(_cloud)!.primary, 'COOKIE_LOGIN_USER=retry');
      response.complete(
        LoginResult(
          Credential('late', {'primary': 'COOKIE_LOGIN_USER=timed-out'}),
          const CloudAccount('late'),
        ),
      );
      time.flushMicrotasks();
      expect(vault.credential(_cloud)!.primary, 'COOKIE_LOGIN_USER=retry');
    });
  });

  test(
    'Tianyi rejects expired portal cookies without replacing the account and allows a new session',
    () async {
      final vault = Vault(StateStore.memory());
      final previous = Credential('previous', {
        'primary': 'COOKIE_LOGIN_USER=previous',
      }, updatedAt: 1);
      await vault.putCredential(_cloud, previous);
      final http = FakeHttp((request) {
        if (request.headers['Cookie'] == 'COOKIE_LOGIN_USER=expired') {
          return jsonResponse({'errorCode': 'InvalidSessionKey'}, 400);
        }
        if (request.uri.path.endsWith('/getUserInfoForPortal.action')) {
          return jsonResponse({
            'res_code': 0,
            'userId': 'fixture-user',
            'loginName': 'fixture-name',
          });
        }
        if (request.uri.path.endsWith('/getUserSizeInfo.action')) {
          return jsonResponse({
            'res_code': 0,
            'cloudCapacityInfo': {'totalSize': 100, 'usedSize': 30},
          });
        }
        throw StateError('Unexpected Tianyi route');
      });
      final login = AccountLoginService(
        vault,
        (_, _) async => const CloudAccount('unused'),
        webAuthenticators: {_cloud: TianyiConnector(http).authenticate},
      );
      await expectLater(
        login.submitWeb(_cloud, 'COOKIE_LOGIN_USER=expired'),
        throwsA(
          isA<AccountLoginRequired>().having(
            (error) => error.message,
            'message',
            contains('登录已失效'),
          ),
        ),
      );
      expect(vault.credential(_cloud)!.sameAs(previous), isTrue);
      final result = await login.submitWeb(
        _cloud,
        'COOKIE_LOGIN_USER=portal-retry',
      );
      expect(result.credential.primary, 'COOKIE_LOGIN_USER=portal-retry');
      expect(vault.credential(_cloud)!.primary, result.credential.primary);
    },
  );

  test('Browser metadata never makes an incomplete Cookie a valid account', () {
    for (final value in ['', 'SSO_TOKEN=not-a-cloud-session']) {
      expect(
        LoginCredentials.plausible(_cloud, TianyiWebLogin.encode(value, _id)),
        false,
      );
    }
    expect(TianyiWebLogin.browserId('value\r\nInjected: true'), isEmpty);
    final previous = Credential('fixture', {
      'primary': 'COOKIE_LOGIN_USER=old',
      'browserId': _id,
    });
    final replacement = LoginCredentials.candidate(
      _cloud,
      'COOKIE_LOGIN_USER=new',
      previous,
    );
    expect(replacement.field('browserId'), isEmpty);
    for (final address in [
      'http://cloud.189.cn/',
      'https://cloud.189.cn.attacker.invalid/',
      'https://user@cloud.189.cn/',
      'https://cloud.189.cn:444/',
    ]) {
      expect(TianyiWebLogin.trusted(address), false);
    }
  });
}
