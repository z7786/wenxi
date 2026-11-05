import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/crypto_box.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/app_log.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';

const _platform = CloudPlatform.tianyi;
const _password = ' Password + 文 ';
const _info = '/api/open/user/getUserInfoForPortal.action';
const _list = '/api/open/file/listFiles.action';
const _download = '/api/open/file/getFileDownloadUrl.action';
const _create = '/api/open/file/createFolder.action';
const _personal = BrowseSession(
  platform: _platform,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: '-11',
);
const _file = CloudFile(id: '101', name: 'fixture.mp4', size: 42);
HttpResult _expired() => jsonResponse({'errorCode': 'InvalidSessionKey'}, 400);
String _cookie(RecordedRequest r) => r.headers['Cookie'] ?? '';
Matcher _loginRequired([String message = '自动登录失败']) => throwsA(
  isA<AccountLoginRequired>().having(
    (e) => e.message,
    'message',
    contains(message),
  ),
);
HttpResult _identity([String userId = 'fixture-user-id']) => jsonResponse({
  'res_code': 0,
  'userId': userId,
  'loginName': 'fixture-user',
  'userExtResp': {'nickName': '天翼测试用户'},
});

class _Fixture {
  _Fixture(LoginTestKey key, {StateStore? store})
    : login = TianyiLoginFixture(key, store: store) {
    login.override = respond;
  }
  final TianyiLoginFixture login;
  late Credential initial;
  bool expired = false;
  FutureOr<HttpResult?> Function(RecordedRequest)? override;
  int get signIns => login.http.calls
      .where((r) => r.uri.path.endsWith('/loginSubmit.do'))
      .length;
  Future<void> seed() async {
    initial = (await login.submit()).credential;
    expired = true;
    login.http.calls.clear();
    login.http.redirects.clear();
  }

  Future<List<CloudFile>> list() =>
      login.connector.list(_personal, '-11', initial);
  Future<DownloadSpec> download() =>
      login.connector.download(_personal, _file, initial);
  Credential get saved => login.vault.credential(_platform)!;
  Future<HttpResult?> respond(RecordedRequest r) async {
    final custom = await override?.call(r);
    if (custom != null) return custom;
    if (expired && _cookie(r).contains('COOKIE_LOGIN_USER=cloud-login')) {
      return _expired();
    }
    if (expired && r.uri.path == '/api/portal/callbackUnify.action') {
      return loginRedirect('/web/redirect.html', [
        'COOKIE_LOGIN_USER=renewed; Domain=cloud.189.cn; Path=/; Secure; HttpOnly',
      ]);
    }
    return switch (r.uri.path) {
      _list => jsonResponse({
        'res_code': 0,
        'fileListAO': {
          'count': 1,
          'fileList': [
            {'id': _file.id, 'name': _file.name, 'size': _file.size},
          ],
        },
      }),
      _download => jsonResponse({
        'res_code': 0,
        'fileDownloadUrl': 'https://download.invalid/fixture.mp4',
      }),
      _create => jsonResponse({
        'res_code': 0,
        'id': '202',
        'name': loginForm(r).str('folderName'),
      }),
      _ => null,
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final key = LoginTestKey();

  for (final (name, rejection) in <(String, HttpResult)>[
    ('HTTP 401', const HttpResult(401, '<html>expired</html>')),
    ('login redirect', loginRedirect(tianyiFixtureSso)),
    for (final code in [
      'InvalidSessionKey',
      'CommonInvalidSessionKey',
      'SafeAccessLoginTimeout',
      'InvalidAccessToken',
      'UserNotLogin',
    ])
      (code, jsonResponse({'errorCode': code}, 400)),
    ('code field', jsonResponse({'code': 'InvalidSessionKey'})),
  ]) {
    test(
      '$name logs in once and continues account, file and download requests',
      () async {
        final f = _Fixture(key);
        await f.seed();
        f.override = (r) => _cookie(r).contains('COOKIE_LOGIN_USER=cloud-login')
            ? rejection
            : null;
        expect((await f.login.connector.account(f.initial)).used, 120);
        expect((await f.list()).single.id, _file.id);
        expect(
          (await f.download()).url,
          startsWith('https://download.invalid/'),
        );
        expect(f.signIns, 1);
        expect(f.saved.primary, contains('COOKIE_LOGIN_USER=renewed'));
        expect(f.saved.updatedAt, f.initial.updatedAt);
        expect(f.saved.field('password'), _password);
        expect(f.saved.field('userId'), f.initial.field('userId'));
        final fields = loginForm(
          f.login.http.calls.singleWhere(
            (r) => r.uri.path.endsWith('/loginSubmit.do'),
          ),
        );
        expect(key.decryptTianyi(fields.str('epd')), _password);
        expect(key.decryptTianyi(fields.str('userName')), 'fixture-user');
        expect(f.login.http.redirects, everyElement(isFalse));
      },
    );
  }

  test(
    'Concurrent quota, list and download requests share a single password login',
    () async {
      final f = _Fixture(key),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      await f.seed();
      f.override = (r) {
        if (!r.uri.path.endsWith('/loginSubmit.do')) return null;
        entered.complete();
        return answer.future;
      };
      final pending = Future.wait<Object?>([
        f.login.connector.account(f.initial),
        f.list(),
        f.download(),
        f.list(),
      ]);
      await entered.future;
      expect(f.signIns, 1);
      expect(f.saved.sameAs(f.initial), isTrue);
      answer.complete(jsonResponse(f.login.signIn));
      await pending;
      expect(f.signIns, 1);
      expect(f.saved.updatedAt, f.initial.updatedAt);
    },
  );

  test(
    'Canceling one waiter leaves shared renewal available to another request',
    () async {
      final f = _Fixture(key),
          scope = RequestScope(),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      await f.seed();
      f.override = (r) {
        if (!r.uri.path.endsWith('/loginSubmit.do')) return null;
        entered.complete();
        return answer.future;
      };
      final canceled = expectLater(
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
      final other = f.download();
      scope.cancel();
      await canceled;
      answer.complete(jsonResponse(f.login.signIn));
      await other;
      expect(f.signIns, 1);
      expect(f.saved.primary, contains('renewed'));
    },
  );

  for (final logout in [true, false]) {
    test(
      '${logout ? 'Logout' : 'Account replacement'} rejects late renewal writes',
      () async {
        final f = _Fixture(key),
            entered = Completer<void>(),
            answer = Completer<HttpResult>();
        await f.seed();
        f.override = (r) {
          if (!r.uri.path.endsWith('/loginSubmit.do')) return null;
          entered.complete();
          return answer.future;
        };
        final pending = expectLater(f.list(), _loginRequired('账号已变化'));
        await entered.future;
        final replacement = Credential('other', {
          'primary': 'COOKIE_LOGIN_USER=other',
        }, updatedAt: f.initial.updatedAt + 1);
        if (logout) {
          await f.login.login.remove(_platform);
        } else {
          await f.login.vault.putCredential(_platform, replacement);
        }
        answer.complete(jsonResponse(f.login.signIn));
        await pending;
        expect(
          f.login.vault.credential(_platform)?.primary,
          logout ? isNull : replacement.primary,
        );
      },
    );
  }

  test(
    'A late expired response uses concurrently rotated cookies without password login',
    () async {
      final f = _Fixture(key),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      await f.seed();
      f.override = (r) {
        if (r.uri.path == _list && _cookie(r).contains('=cloud-login')) {
          entered.complete();
          return answer.future;
        }
        if (r.uri.path == _download) {
          return HttpResult(
            200,
            encoded({
              'res_code': 0,
              'fileDownloadUrl': 'https://download.invalid/fixture.mp4',
            }),
            {
              'set-cookie': ['COOKIE_LOGIN_USER=rotated; Path=/'],
            },
          );
        }
        return null;
      };
      final pending = f.list();
      await entered.future;
      await f.download();
      answer.complete(_expired());
      expect((await pending).single.id, _file.id);
      expect(f.signIns, 0);
      expect(f.saved.primary, contains('rotated'));
    },
  );

  test(
    'Rejected fresh cookies stop after one retry without replaying a successful mutation',
    () async {
      final f = _Fixture(key);
      await f.seed();
      final folder = await f.login.connector.createFolder(
        _personal,
        '-11',
        'fixture-folder',
        f.initial,
      );
      expect(folder.id, '202');
      expect(
        f.login.http.calls.where((r) => r.uri.path == _create),
        hasLength(2),
      );
      expect(f.signIns, 1);
      f.override = (r) => r.uri.path == _list ? _expired() : null;
      await expectLater(f.list(), _loginRequired());
      expect(
        f.login.http.calls.where((r) => r.uri.path == _list),
        hasLength(2),
      );
      expect(f.signIns, 2);
      final count = f.login.http.calls.length;
      await expectLater(f.download(), _loginRequired());
      expect(f.login.http.calls.length, count);
      expect(f.saved.field('autoLoginBlocked'), '1');
    },
  );

  for (final rejection in [
    const HttpResult(403, '{}'),
    const HttpResult(429, '{}'),
    const HttpResult(503, 'unavailable'),
    jsonResponse({'errorCode': 'InvalidDeviceStatus'}, 400),
    jsonResponse({'errorCode': 'InsufficientSpace'}, 400),
  ]) {
    test(
      'Non-expiry rejection ${rejection.status} ${rejection.body} never submits passwords',
      () async {
        final f = _Fixture(key);
        await f.seed();
        f.override = (r) => r.uri.path == _list ? rejection : null;
        await expectLater(f.list(), throwsA(isA<AppException>()));
        expect(f.signIns, 0);
        expect(f.saved.sameAs(f.initial), isTrue);
        expect(f.login.http.calls, hasLength(1));
      },
    );
  }

  for (final reason in ['password', 'captcha', 'sms', 'identity']) {
    test(
      '$reason renewal failure stops further automatic attempts and manual login recovers',
      () async {
        final f = _Fixture(key), log = DiagnosticLog.open(null);
        DiagnosticLog.active = log;
        addTearDown(() {
          DiagnosticLog.active = null;
          log.close();
        });
        await f.seed();
        if (reason == 'captcha') f.login.needCaptcha = 1;
        if (reason == 'password') f.login.signIn = {'result': -69};
        if (reason == 'sms') f.login.signIn = {'result': -133};
        if (reason == 'identity') {
          f.override = (r) =>
              r.uri.path == _info && _cookie(r).contains('=renewed')
              ? _identity('another-user-id')
              : null;
        }
        await expectLater(f.list(), _loginRequired());
        expect(f.saved.field('autoLoginBlocked'), '1');
        expect(f.saved.field('password'), _password);
        expect(f.saved.updatedAt, f.initial.updatedAt);
        final count = f.login.http.calls.length;
        await expectLater(f.download(), _loginRequired());
        expect(f.login.http.calls.length, count);
        final errors = log
            .entries(errorsOnly: true)
            .where((e) => e.event == 'login.auto.failed');
        expect(errors, hasLength(1));
        expect(log.exportFiles().values.join(), isNot(contains(_password)));
        expect(
          log.exportFiles().values.join(),
          isNot(contains('fixture-user')),
        );
        final restarted = TianyiLoginFixture(key, store: f.login.store);
        await expectLater(
          restarted.connector.account(f.saved),
          _loginRequired(),
        );
        expect(restarted.http.calls, isEmpty);
        f.override = null;
        f.login.needCaptcha = 0;
        f.login.signIn = {'result': 0, 'toUrl': tianyiFixtureCallback};
        final manual = await f.login.submit();
        expect(manual.credential.updatedAt, greaterThan(f.initial.updatedAt));
        expect(manual.credential.field('autoLoginBlocked'), isEmpty);
      },
    );
  }

  test(
    'A web login waiting on validation can replace a session renewed in the meantime',
    () async {
      final f = _Fixture(key),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      await f.seed();
      f.override = (r) {
        if (r.uri.path != _info || !_cookie(r).contains('=web-login')) {
          return null;
        }
        entered.complete();
        return answer.future;
      };
      final web = f.login.login.submitWeb(
        _platform,
        'COOKIE_LOGIN_USER=web-login',
      );
      await entered.future;
      await f.list();
      expect(f.saved.updatedAt, f.initial.updatedAt);
      answer.complete(_identity());
      final result = await web;
      expect(result.credential.updatedAt, greaterThan(f.initial.updatedAt));
      expect(result.credential.primary, contains('web-login'));
      expect(result.credential.field('username'), isEmpty);
      expect(result.credential.field('password'), isEmpty);
    },
  );

  for (final authType in ['', 'passwordCookie']) {
    test(
      'Imported or legacy $authType cookies without saved passwords require manual login',
      () async {
        final f = _Fixture(key);
        await f.seed();
        f.initial = Credential('legacy', {
          'primary': f.initial.primary,
          'authType': authType,
        }, updatedAt: f.initial.updatedAt + 1);
        await f.login.vault.putCredential(_platform, f.initial);
        await expectLater(f.list(), _loginRequired('登录已失效'));
        expect(f.signIns, 0);
        expect(f.saved.sameAs(f.initial), isTrue);
      },
    );
  }

  test(
    'Saved credentials survive a plain store restart and can renew again',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'asterlink-tianyi-session-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final testKey = CryptoBox.random(32);
      final store = await StateStore.open(directory, testKey: testKey);
      final f = _Fixture(key, store: store);
      await f.seed();
      await f.list();
      await store.flush();
      final snapshots = directory.listSync().whereType<File>().where(
        (file) => file.path.endsWith('.json'),
      );
      expect(snapshots, isNotEmpty);
      for (final file in snapshots) {
        final snapshot = jsonDecode(utf8.decode(file.readAsBytesSync())) as Map;
        expect(snapshot['format'], 'asterlink-state-v2');
        expect(
          snapshot['sha256'],
          isA<String>().having((s) => s.length, 'length', 64),
        );
      }
      final restored = await StateStore.open(directory, testKey: testKey);
      final next = TianyiLoginFixture(key, store: restored);
      final saved = next.vault.credential(_platform)!;
      next.override = (r) =>
          _cookie(r).contains('COOKIE_LOGIN_USER=renewed') ? _expired() : null;
      expect(saved.field('password'), _password);
      expect((await next.connector.account(saved)).total, 1000);
      expect(
        next.http.calls.where((r) => r.uri.path.endsWith('/loginSubmit.do')),
        hasLength(1),
      );
      expect(next.vault.credential(_platform)!.updatedAt, saved.updatedAt);
      store.dispose();
      restored.dispose();
    },
  );
}
