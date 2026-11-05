import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/redaction.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'native_login_support.dart';
import 'support.dart';

const _platform = CloudPlatform.pan123;
const _password = ' Example password + 文 ';
const _personal = BrowseSession(
  platform: _platform,
  mode: BrowseMode.personal,
  title: 'personal',
  rootId: '0',
);
const _share = BrowseSession(
  platform: _platform,
  mode: BrowseMode.share,
  title: 'share',
  rootId: '0',
  metadata: {'shareKey': 'fixture', 'passcode': 'test'},
);
final _file = CloudFile(
  id: '10',
  name: 'fixture.mp4',
  size: 100,
  token: encoded({'s3': '123456-0', 'etag': 'fixture', 'storage': '123456'}),
);
const _info = '/b/api/user/info';
const _list = '/b/api/file/list/new';
const _download = '/api/file/download_info';
const _copy = '/b/api/restful/goapi/v1/file/copy/save';

String _bearer(RecordedRequest r) =>
    r.headers.entries
        .where((e) => e.key.toLowerCase() == 'authorization')
        .firstOrNull
        ?.value ??
    '';
Matcher _loginRequired(String message) => throwsA(
  isA<AccountLoginRequired>().having(
    (e) => e.message,
    'message',
    contains(message),
  ),
);
HttpResult _ok(Json data) => jsonResponse({'code': 0, 'data': data});
HttpResult _signedIn([String token = 'renewed-token']) => jsonResponse({
  'code': 200,
  'data': {'token': token},
});

class _Fixture {
  _Fixture({
    StateStore? store,
    String? token = 'old-token',
    String authType = 'password',
    Duration listDelay = Duration.zero,
    Future<void> Function(Duration)? listWait,
  }) : store = store ?? StateStore.memory() {
    vault = Vault(this.store);
    initial = Credential('123', {
      'primary': 'fixture-phone',
      'secondary': _password,
      'authType': authType,
      'userId': '12345',
      'accessToken': ?token,
    }, updatedAt: 42);
    http = LoginHttp(respond);
    connector = Pan123Connector(
      http,
      vault,
      taskDelay: Duration.zero,
      listDelay: listDelay,
      listWait: listWait ?? RequestScope.wait,
      now: () => now,
    );
    login = AccountLoginService(
      vault,
      (_, c) => connector.account(c),
      webAuthenticators: {_platform: connector.authenticate},
    );
  }
  final StateStore store;
  late final Vault vault;
  late final LoginHttp http;
  late final Pan123Connector connector;
  late final AccountLoginService login;
  late final Credential initial;
  var now = DateTime.utc(2030, 1, 2);
  bool oldAccepted = false;
  FutureOr<HttpResult?> Function(RecordedRequest)? override;
  Future<void> seed() => vault.putCredential(_platform, initial);
  int get signIns =>
      http.calls.where((r) => r.uri.path.endsWith('/sign_in')).length;

  Future<HttpResult> respond(RecordedRequest r) async {
    final custom = await override?.call(r);
    if (custom != null) return custom;
    if (r.uri.path.endsWith('/sign_in')) return _signedIn();
    if (r.uri.host == 'download.invalid') return const HttpResult(206, 'bytes');
    if (!oldAccepted && _bearer(r) != 'Bearer renewed-token') {
      return jsonResponse({'code': 401});
    }
    return switch (r.uri.path) {
      _info => _ok({
        'UID': 12345,
        'Nickname': 'fixture user',
        'SpaceUsed': 5,
        'SpacePermanent': 1000,
        'SpaceTemp': 0,
      }),
      _list => _ok({
        'InfoList': [
          {
            'FileId': 11,
            'FileName': _file.name,
            'Size': _file.size,
            'Type': 0,
            'ParentFileId': 88,
            'S3KeyFlag': '123456-0',
            'Etag': 'fixture',
          },
        ],
        'Next': '-1',
      }),
      _download => _ok({'DownloadUrl': 'https://download.invalid/video.mp4'}),
      '/b/api/file/upload_request' => _ok({
        'Info': {'FileId': 88},
      }),
      _copy => _ok({'taskID': 'copy-task'}),
      '$_copy/get' => _ok({'finished': true}),
      '/b/api/share/create' => _ok({'ShareKey': 'created'}),
      _ => _ok({}),
    };
  }
}

void main() {
  test(
    'Code 100011 retries the same listing page without losing earlier files',
    () async {
      final waits = <Duration>[];
      late _Fixture f;
      f = _Fixture(
        listWait: (delay) async {
          waits.add(delay);
          f.now = f.now.add(delay);
        },
      )..oldAccepted = true;
      await f.seed();
      var secondAttempts = 0;
      f.override = (r) {
        if (r.uri.path != _list) return null;
        final first = r.uri.queryParameters['next'] == '0';
        if (!first && secondAttempts++ == 0) {
          return jsonResponse({'code': 100011, 'message': '请勿频繁操作，请稍后再试'});
        }
        return _ok({
          'InfoList': [
            {
              'FileId': first ? 1 : 2,
              'FileName': first ? 'first.txt' : 'second.txt',
              'Type': 0,
              'ParentFileId': 8,
              'Etag': first ? 'first-hash' : 'second-hash',
            },
          ],
          'Next': first ? 'next-page' : '-1',
        });
      };
      final files = await f.connector.list(_personal, '8', f.initial);
      expect(files.map((file) => file.id), ['1', '2']);
      expect(files.every((file) => file.parentId == '8'), isTrue);
      expect(files.last.token, contains('second-hash'));
      expect(f.http.calls.map((r) => r.uri.queryParameters['next']), [
        '0',
        'next-page',
        'next-page',
      ]);
      expect(waits, [const Duration(seconds: 2)]);
      expect(f.signIns, 0);
    },
  );

  test(
    'Repeated listing throttling stops after two retries and keeps cooldown',
    () async {
      final waits = <Duration>[];
      late _Fixture f;
      f = _Fixture(
        listWait: (delay) async {
          waits.add(delay);
          f.now = f.now.add(delay);
        },
      )..oldAccepted = true;
      await f.seed();
      f.override = (_) => jsonResponse({'code': 100011});
      await expectLater(
        f.connector.list(_personal, '0', f.initial),
        throwsA(
          isA<HttpRequestFailure>().having((e) => e.status, 'status', 429),
        ),
      );
      expect(f.http.calls, hasLength(3));
      expect(waits, [const Duration(seconds: 2), const Duration(seconds: 5)]);
      expect(f.signIns, 0);
      f.override = null;
      await f.connector.list(_personal, '0', f.initial);
      expect(waits.last, const Duration(seconds: 10));
      expect(f.http.calls, hasLength(4));
    },
  );

  for (final dateHeader in [false, true]) {
    test('Listing HTTP 429 honors Retry-After (date: $dateHeader)', () async {
      final waits = <Duration>[];
      late _Fixture f;
      f = _Fixture(
        listWait: (delay) async {
          waits.add(delay);
          f.now = f.now.add(delay);
        },
      )..oldAccepted = true;
      await f.seed();
      var requests = 0;
      f.override = (_) => requests++ == 0
          ? HttpResult(429, 'not-json', {
              'retry-after': [
                dateHeader
                    ? HttpDate.format(f.now.add(const Duration(seconds: 7)))
                    : '7',
              ],
            })
          : null;
      expect(await f.connector.list(_personal, '0', f.initial), hasLength(1));
      expect(waits, [const Duration(seconds: 7)]);
      expect(f.http.calls, hasLength(2));
      expect(f.signIns, 0);
    });
  }

  test(
    'Concurrent directory listings pace every page and keep their parents',
    () async {
      final starts = <DateTime>[];
      late _Fixture f;
      f = _Fixture(
        listDelay: const Duration(milliseconds: 600),
        listWait: (delay) async => f.now = f.now.add(delay),
      )..oldAccepted = true;
      await f.seed();
      var active = 0, peak = 0;
      f.override = (r) async {
        if (r.uri.path != _list) return null;
        starts.add(f.now);
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(Duration.zero);
        active--;
        final parent = r.uri.queryParameters['parentFileId']!;
        final first = r.uri.queryParameters['next'] == '0';
        return _ok({
          'InfoList': [
            {
              'FileId': '$parent-${first ? 1 : 2}',
              'FileName': 'file.txt',
              'Type': 0,
              'ParentFileId': parent,
            },
          ],
          'Next': first ? 'next' : '-1',
        });
      };
      final results = await Future.wait([
        f.connector.list(_personal, 'a', f.initial),
        f.connector.list(_personal, 'b', f.initial),
      ]);
      expect(peak, 1);
      expect(starts, hasLength(4));
      for (var i = 1; i < starts.length; i++) {
        expect(
          starts[i].difference(starts[i - 1]),
          const Duration(milliseconds: 600),
        );
      }
      expect(results[0].map((file) => file.id), ['a-1', 'a-2']);
      expect(results[1].map((file) => file.id), ['b-1', 'b-2']);
    },
  );

  test(
    'Cancelling a listing cooldown returns promptly without another request',
    () async {
      final waiting = Completer<void>();
      final f = _Fixture(
        listWait: (delay) {
          waiting.complete();
          return RequestScope.wait(delay);
        },
      )..oldAccepted = true;
      await f.seed();
      f.override = (_) => jsonResponse({'code': 100011});
      final scope = RequestScope();
      final failed = expectLater(
        scope.run(() => f.connector.list(_personal, '0', f.initial)),
        throwsA(
          isA<AppException>().having((e) => e.message, 'message', '请求已取消'),
        ),
      );
      await waiting.future;
      scope.cancel();
      await failed.timeout(const Duration(seconds: 1));
      expect(f.http.calls, hasLength(1));
    },
  );

  test(
    'Cancelling a queued listing skips its network request and frees the queue',
    () async {
      final first = Completer<HttpResult>();
      final f = _Fixture()..oldAccepted = true;
      await f.seed();
      f.override = (r) => r.uri.queryParameters['parentFileId'] == 'first'
          ? first.future
          : null;
      final initial = f.connector.list(_personal, 'first', f.initial);
      await until(() => f.http.calls.length == 1);
      final scope = RequestScope();
      final cancelled = expectLater(
        scope.run(() => f.connector.list(_personal, 'cancelled', f.initial)),
        throwsA(isA<AppException>()),
      );
      scope.cancel();
      await cancelled.timeout(const Duration(seconds: 1));
      first.complete(_ok({'InfoList': [], 'Next': '-1'}));
      await initial;
      await f.connector.list(_personal, 'next', f.initial);
      expect(f.http.calls.map((r) => r.uri.queryParameters['parentFileId']), [
        'first',
        'next',
      ]);
    },
  );

  test(
    'Provider rate limiting never retries a mutation or reauthenticates',
    () async {
      final f = _Fixture()..oldAccepted = true;
      await f.seed();
      f.override = (_) => jsonResponse({'code': 100011});
      await expectLater(
        f.connector.delete(_personal, [_file], f.initial),
        throwsA(isA<HttpRequestFailure>()),
      );
      expect(f.http.calls, hasLength(1));
      expect(f.signIns, 0);
    },
  );

  for (final seconds in [-60, 30]) {
    test(
      'JWT expiry $seconds seconds from now renews before an API request and preserves ownership',
      () async {
        final expiry =
            DateTime.utc(2030, 1, 2).millisecondsSinceEpoch ~/ 1000 + seconds;
        final jwt =
            'e30.${base64UrlEncode(utf8.encode(encoded({'exp': expiry})))}.fixture';
        final f = _Fixture(token: jwt);
        await f.seed();
        expect((await f.connector.account(f.initial)).used, 5);
        expect(f.http.calls.first.uri.path, '/api/user/sign_in');
        expect(f.http.calls.first.json['password'], _password);
        expect(f.vault.credential(_platform)!.updatedAt, 42);
        expect(f.vault.credential(_platform)!.field('secondary'), _password);
        await f.connector.list(_personal, '0', f.initial);
        await f.connector.download(_personal, _file, f.initial);
        expect(f.signIns, 1);
        expect(f.http.calls.where((r) => _bearer(r) == 'Bearer $jwt'), isEmpty);
        for (var i = 0; i < f.http.calls.length; i++) {
          if (_bearer(f.http.calls[i]).isNotEmpty) {
            expect(f.http.redirects[i], isFalse);
          }
        }
      },
    );
  }

  test(
    'Unexpired and opaque tokens avoid a separate validation request on every operation',
    () async {
      for (final token in [
        'opaque-token',
        'e30.${base64UrlEncode(utf8.encode('{"exp":2000000000}'))}.signature',
        'malformed.jwt.signature',
      ]) {
        final f = _Fixture(token: token)..oldAccepted = true;
        await f.seed();
        expect((await f.connector.account(f.initial)).total, 1000);
        await f.connector.list(_personal, '0', f.initial);
        expect(f.signIns, 0);
        expect(f.http.calls.where((r) => r.uri.path == _info), hasLength(1));
      }
    },
  );

  for (final http401 in [false, true]) {
    test(
      '${http401 ? 'HTTP 401 with a non-JSON body' : 'JSON code 401'} renews once and retries the original request',
      () async {
        final f = _Fixture();
        f.override = (r) => _bearer(r) == 'Bearer old-token'
            ? http401
                  ? const HttpResult(401, '<html>expired</html>')
                  : jsonResponse({'code': 401})
            : null;
        await f.seed();
        expect((await f.connector.account(f.initial)).nickname, 'fixture user');
        expect(f.signIns, 1);
        expect(f.http.calls.where((r) => r.uri.path == _info), hasLength(3));
        expect(
          f.vault.credential(_platform)!.field('accessToken'),
          'renewed-token',
        );
      },
    );
  }

  test(
    'Personal-list code 20101 renews once and retries with the same account',
    () async {
      final f = _Fixture();
      f.override = (r) => _bearer(r) == 'Bearer old-token'
          ? jsonResponse({'code': 20101, 'message': '未登录'})
          : null;
      await f.seed();
      expect(await f.connector.list(_personal, '0', f.initial), hasLength(1));
      expect(f.signIns, 1);
      expect(f.http.calls.where((r) => r.uri.path == _list), hasLength(2));
      expect(f.vault.credential(_platform)!.updatedAt, f.initial.updatedAt);
      expect(f.vault.credential(_platform)!.field('userId'), '12345');
      await f.connector.list(_personal, '0', f.initial);
      expect(f.signIns, 1);
    },
  );

  test('Code 20101 cannot reuse a password for a web login', () async {
    final f = _Fixture(authType: 'webToken');
    f.override = (_) => jsonResponse({'code': 20101, 'message': '未登录'});
    await f.seed();
    await expectLater(
      f.connector.list(_personal, '0', f.initial),
      _loginRequired('重新登录'),
    );
    await expectLater(
      f.connector.authenticate(f.initial),
      _loginRequired('重新登录'),
    );
    expect(f.signIns, 0);
    expect(f.vault.credential(_platform)!.sameAs(f.initial), isTrue);
  });

  test(
    'Code 20101 with a rejected saved password stops automatic retries',
    () async {
      final f = _Fixture();
      f.override = (r) => r.uri.path.endsWith('/sign_in')
          ? jsonResponse({'code': 11000, 'message': '登录失败'})
          : jsonResponse({'code': 20101, 'message': '未登录'});
      await f.seed();
      await expectLater(
        f.connector.list(_personal, '0', f.initial),
        _loginRequired('自动登录失败'),
      );
      expect(f.signIns, 1);
      final saved = f.vault.credential(_platform)!;
      expect(saved.field('autoLoginBlocked'), '1');
      expect(saved.updatedAt, f.initial.updatedAt);
      final requests = f.http.calls.length;
      await expectLater(
        Pan123Connector(f.http, f.vault).list(_personal, '0', saved),
        _loginRequired('重新登录'),
      );
      expect(f.http.calls.length, requests);
    },
  );

  test(
    'Concurrent quota, list and download requests share one password login',
    () async {
      final f = _Fixture(),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      f.override = (r) {
        if (!r.uri.path.endsWith('/sign_in')) return null;
        entered.complete();
        return answer.future;
      };
      await f.seed();
      final pending = Future.wait<Object?>([
        for (var i = 0; i < 4; i++) f.connector.account(f.initial),
        f.connector.list(_personal, '0', f.initial),
        f.connector.download(_personal, _file, f.initial),
      ]);
      await entered.future;
      await until(
        () =>
            f.http.calls
                .where((r) => _bearer(r) == 'Bearer old-token')
                .length ==
            6,
      );
      answer.complete(_signedIn());
      await pending;
      expect(f.signIns, 1);
      expect(f.vault.credential(_platform)!.updatedAt, f.initial.updatedAt);
      final before = f.http.calls.length;
      await f.connector.createShare(
        _personal,
        [_file],
        const ShareOptions('fixture'),
        f.initial,
      );
      expect(_bearer(f.http.calls[before]), 'Bearer renewed-token');
      expect(f.signIns, 1);
    },
  );

  test(
    'A late rejection of an old token reuses an already completed renewal',
    () async {
      final f = _Fixture(),
          entered = Completer<void>(),
          delayed = Completer<HttpResult>();
      f.override = (r) {
        if (r.uri.path == _list && _bearer(r) == 'Bearer old-token') {
          entered.complete();
          return delayed.future;
        }
        return null;
      };
      await f.seed();
      final pending = f.connector.list(_personal, '0', f.initial);
      await entered.future;
      await f.connector.account(f.initial);
      delayed.complete(jsonResponse({'code': 401}));
      expect(await pending, hasLength(1));
      expect(f.signIns, 1);
    },
  );

  test(
    'A cancelled login finishing late cannot release the newer login lock',
    () async {
      final f = _Fixture();
      final entered = Completer<void>(), oldResult = Completer<LoginResult>();
      final old = expectLater(
        f.login.submit(_platform, (_) {
          entered.complete();
          return oldResult.future;
        }),
        throwsA(isA<AppException>()),
      );
      await entered.future;
      f.login.invalidate(_platform);
      final nextEntered = Completer<void>(),
          nextResult = Completer<LoginResult>();
      final next = f.login.submit(_platform, (_) {
        nextEntered.complete();
        return nextResult.future;
      });
      await nextEntered.future;
      oldResult.complete(LoginResult(f.initial, const CloudAccount('old')));
      await old;
      await expectLater(
        f.login.submitWeb(_platform, 'renewed-token'),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('正在提交'),
          ),
        ),
      );
      nextResult.complete(LoginResult(f.initial, const CloudAccount('new')));
      expect((await next).account.nickname, 'new');
    },
  );

  final operations = <String, Future<void> Function(_Fixture)>{
    _list: (f) async {
      await f.connector.list(_personal, '0', f.initial);
    },
    _download: (f) async {
      await f.connector.download(_personal, _file, f.initial);
    },
    '/b/api/file/rename': (f) =>
        f.connector.rename(_personal, _file, 'renamed', f.initial),
    '/b/api/file/mod_pid': (f) =>
        f.connector.move(_personal, [_file], '8', f.initial),
    '/b/api/file/trash': (f) =>
        f.connector.delete(_personal, [_file], f.initial),
    '/b/api/share/create': (f) async {
      await f.connector.createShare(
        _personal,
        [_file],
        const ShareOptions('fixture'),
        f.initial,
      );
    },
    '/b/api/file/upload_request': (f) async {
      final spec = await f.connector.download(_share, _file, f.initial);
      expect(spec.cleanup!.action!['accountRevision'], f.initial.updatedAt);
    },
    _copy: (f) => f.connector.saveShare(_share, [_file], '8', f.initial),
    '$_copy/get': (f) => f.connector.saveShare(_share, [_file], '8', f.initial),
  };
  for (final operation in operations.entries) {
    test('Auth expiry is handled at ${operation.key}', () async {
      final f = _Fixture()..oldAccepted = true;
      f.override = (r) =>
          r.uri.path == operation.key && _bearer(r) == 'Bearer old-token'
          ? jsonResponse({'code': 401})
          : null;
      await f.seed();
      await operation.value(f);
      expect(f.signIns, 1);
      final calls = f.http.calls
          .where((r) => r.uri.path == operation.key)
          .toList();
      expect(calls, hasLength(2));
      expect(_bearer(calls.first), 'Bearer old-token');
      expect(_bearer(calls.last), 'Bearer renewed-token');
    });
  }

  for (final status in [403, 429, 500]) {
    test(
      'HTTP $status does not trigger a login or replay a file mutation',
      () async {
        final f = _Fixture();
        f.override = (_) =>
            jsonResponse({'code': 401, 'message': 'service error'}, status);
        await f.seed();
        await expectLater(
          f.connector.delete(_personal, [_file], f.initial),
          throwsA(isA<AppException>()),
        );
        expect(f.signIns, 0);
        expect(f.http.calls, hasLength(1));
        expect(f.vault.credential(_platform)!.sameAs(f.initial), isTrue);
      },
    );
  }

  test(
    'Network failures do not silently replay a mutation or trigger password login',
    () async {
      final f = _Fixture();
      f.override = (_) => throw const AppException('network unavailable');
      await f.seed();
      await expectLater(
        f.connector.delete(_personal, [_file], f.initial),
        throwsA(isA<AppException>()),
      );
      expect(f.signIns, 0);
      expect(f.http.calls, hasLength(1));
    },
  );

  test(
    'A rejected saved password prompts manual login and stays blocked across restarts until explicit login',
    () async {
      final f = _Fixture();
      f.override = (r) => r.uri.path.endsWith('/sign_in')
          ? jsonResponse({'code': 401, 'message': 'rejected $_password'})
          : null;
      await f.seed();
      await expectLater(
        f.connector.account(f.initial),
        _loginRequired('自动登录失败'),
      );
      expect(f.signIns, 1);
      final saved = f.vault.credential(_platform)!;
      expect(saved.field('accessToken'), 'old-token');
      expect(saved.field('autoLoginBlocked'), '1');
      expect(saved.updatedAt, f.initial.updatedAt);
      final restarted = Pan123Connector(f.http, f.vault);
      final count = f.http.calls.length;
      await expectLater(restarted.account(saved), _loginRequired('重新登录'));
      expect(f.http.calls.length, count);
      f.override = null;
      final result = await f.login.submit(
        _platform,
        (_) => f.connector.password('fixture-phone', _password),
      );
      expect(result.credential.field('autoLoginBlocked'), isEmpty);
      expect(result.credential.updatedAt, greaterThan(f.initial.updatedAt));
      expect((await restarted.account(result.credential)).used, 5);
    },
  );

  for (final invalid in [
    'rejected-token',
    'empty-identity',
    'different-account',
  ]) {
    test(
      'A renewed token with $invalid cannot replace the saved token',
      () async {
        final f = _Fixture();
        f.override = (r) {
          if (r.uri.path != _info || _bearer(r) != 'Bearer renewed-token') {
            return null;
          }
          return switch (invalid) {
            'rejected-token' => jsonResponse({'code': 401}),
            'empty-identity' => _ok({}),
            _ => _ok({'UID': 987, 'Nickname': 'someone else'}),
          };
        };
        await f.seed();
        await expectLater(
          f.connector.list(_personal, '0', f.initial),
          _loginRequired('自动登录失败'),
        );
        expect(f.signIns, 1);
        expect(
          f.vault.credential(_platform)!.field('accessToken'),
          'old-token',
        );
        expect(f.http.calls.where((r) => r.uri.path == _list), hasLength(1));
      },
    );
  }

  test(
    'A repeated 401 after renewal stops after one retry and requires manual login',
    () async {
      final f = _Fixture();
      f.override = (r) =>
          r.uri.path == _list ? jsonResponse({'code': 401}) : null;
      await f.seed();
      await expectLater(
        f.connector.list(_personal, '0', f.initial),
        _loginRequired('自动登录失败'),
      );
      expect(f.signIns, 1);
      expect(f.http.calls.where((r) => r.uri.path == _list), hasLength(2));
      final count = f.http.calls.length;
      await expectLater(
        f.connector.list(_personal, '0', f.initial),
        _loginRequired('重新登录'),
      );
      expect(f.http.calls.length, count);
    },
  );

  test(
    'Legacy saved passwords use their matching cached token and migrate it on expiry',
    () async {
      final f = _Fixture(token: null, authType: '')..oldAccepted = true;
      await f.seed();
      await f.vault.putSecret('pan123.access_token', 'old-token');
      await f.connector.account(f.initial);
      expect(f.signIns, 0);
      f.oldAccepted = false;
      await f.connector.list(_personal, '0', f.initial);
      expect(f.signIns, 1);
      expect(f.vault.secret('pan123.access_token'), isNull);
      expect(
        f.vault.credential(_platform)!.field('accessToken'),
        'renewed-token',
      );
      await f.connector.account(f.initial);
      expect(f.signIns, 1);
    },
  );

  test(
    'Saved credentials with no token sign in once and validate before first use',
    () async {
      final f = _Fixture(token: null);
      await f.seed();
      await f.connector.account(f.initial);
      expect(f.http.calls.first.uri.path, '/api/user/sign_in');
      expect(f.signIns, 1);
    },
  );

  for (final authType in ['webToken', 'passwordToken']) {
    test(
      '$authType cannot borrow the previous password or auto-login',
      () async {
        final f = _Fixture();
        await f.seed();
        final candidate = Credential('web', {
          'primary': 'web-token',
          'accessToken': 'web-token',
          'authType': authType,
        }, updatedAt: 123);
        await f.vault.replaceCredential(_platform, f.initial, candidate);
        await expectLater(
          f.connector.account(candidate),
          _loginRequired('登录已失效'),
        );
        expect(f.signIns, 0);
        expect(f.vault.credential(_platform)!.field('secondary'), isEmpty);
      },
    );
  }

  test(
    'A rejected explicit web candidate never gets repaired with the saved password',
    () async {
      final f = _Fixture();
      await f.seed();
      await expectLater(
        f.login.submitWeb(_platform, 'invalid-web-token'),
        _loginRequired('登录已失效'),
      );
      expect(f.signIns, 0);
      expect(f.vault.credential(_platform)!.sameAs(f.initial), isTrue);
    },
  );

  test(
    'Successful web fallback clears saved passwords even for a previous blocked account',
    () async {
      final f = _Fixture();
      await f.seed();
      await f.vault.putCredential(
        _platform,
        f.initial.withFields({'autoLoginBlocked': '1'}, preserveRevision: true),
      );
      final result = await f.login.submitWeb(_platform, 'renewed-token');
      expect(result.credential.field('authType'), 'webToken');
      expect(result.credential.field('secondary'), isEmpty);
      expect(result.credential.field('autoLoginBlocked'), isEmpty);
      expect(f.signIns, 0);
    },
  );

  test(
    'Logout during automatic login cannot resurrect an account or resume its request',
    () async {
      final f = _Fixture(),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      f.override = (r) {
        if (!r.uri.path.endsWith('/sign_in')) return null;
        entered.complete();
        return answer.future;
      };
      await f.seed();
      final pending = expectLater(
        f.connector.list(_personal, '0', f.initial),
        _loginRequired('账号已退出'),
      );
      await entered.future;
      await f.login.remove(_platform);
      answer.complete(_signedIn());
      await pending;
      expect(f.vault.credential(_platform), isNull);
      expect(f.http.calls.where((r) => r.uri.path == _info), isEmpty);
      final count = f.http.calls.length;
      await expectLater(
        f.connector.account(f.initial),
        _loginRequired('账号已退出'),
      );
      expect(f.http.calls.length, count);
    },
  );

  test(
    'Account replacement during new-token validation prevents a late refresh commit',
    () async {
      final f = _Fixture(),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      f.override = (r) {
        if (r.uri.path != _info || _bearer(r) != 'Bearer renewed-token') {
          return null;
        }
        entered.complete();
        return answer.future;
      };
      await f.seed();
      final pending = expectLater(
        f.connector.list(_personal, '0', f.initial),
        _loginRequired('发生变化'),
      );
      await entered.future;
      final replacement = Credential('second', {
        'primary': 'new-user',
        'secondary': 'new-password',
        'accessToken': 'second-token',
        'authType': 'password',
      }, updatedAt: 100);
      await f.vault.putCredential(_platform, replacement);
      answer.complete(_ok({'UID': 12345, 'Nickname': 'old user'}));
      await pending;
      expect(f.vault.credential(_platform)!.sameAs(replacement), isTrue);
      expect(f.http.calls.where((r) => r.uri.path == _list), hasLength(1));
    },
  );

  test(
    'Cancelling one waiting request does not cancel a shared automatic login',
    () async {
      final f = _Fixture(),
          entered = Completer<void>(),
          answer = Completer<HttpResult>();
      final firstScope = RequestScope(), secondScope = RequestScope();
      f.override = (r) {
        if (!r.uri.path.endsWith('/sign_in')) return null;
        expect(RequestScope.current, isNot(same(firstScope.token)));
        expect(RequestScope.current, isNot(same(secondScope.token)));
        entered.complete();
        return answer.future;
      };
      await f.seed();
      final first = expectLater(
        firstScope.run(() => f.connector.account(f.initial)),
        throwsA(
          isA<AppException>().having(
            (e) => e.message,
            'message',
            contains('取消'),
          ),
        ),
      );
      final second = secondScope.run(
        () => f.connector.list(_personal, '0', f.initial),
      );
      await entered.future;
      firstScope.cancel();
      await first;
      answer.complete(_signedIn());
      expect(await second, hasLength(1));
      expect(f.signIns, 1);
      expect(
        f.vault.credential(_platform)!.field('accessToken'),
        'renewed-token',
      );
    },
  );

  test(
    'Explicit account switching can commit after the previous session renewed meanwhile',
    () async {
      final f = _Fixture(),
          entered = Completer<void>(),
          answer = Completer<LoginResult>();
      await f.seed();
      final pending = f.login.submit(_platform, (_) {
        entered.complete();
        return answer.future;
      });
      await entered.future;
      await f.connector.account(f.initial);
      answer.complete(
        LoginResult(
          Credential('new user', {
            'primary': 'second-account',
            'secondary': 'second-password',
            'accessToken': 'second-token',
            'authType': 'password',
          }),
          const CloudAccount('second user'),
        ),
      );
      final result = await pending;
      expect(result.credential.primary, 'second-account');
      expect(result.credential.updatedAt, greaterThan(f.initial.updatedAt));
    },
  );

  test(
    'Changing login method permits a new login while its cancelled predecessor is still finishing',
    () async {
      final f = _Fixture(),
          entered = Completer<void>(),
          answer = Completer<LoginResult>();
      final previous = expectLater(
        f.login.submit(_platform, (_) {
          entered.complete();
          return answer.future;
        }),
        throwsA(isA<AppException>()),
      );
      await entered.future;
      f.login.invalidate(_platform);
      final next = await f.login.submitWeb(_platform, 'renewed-token');
      answer.complete(
        LoginResult(f.initial, const CloudAccount('late account')),
      );
      await previous;
      expect(f.vault.credential(_platform)!.sameAs(next.credential), isTrue);
    },
  );

  test(
    'Remembered 123 passwords survive plain storage and remain redacted in diagnostics',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asterlink-123-vault-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = await StateStore.open(directory);
      final f = _Fixture(store: store);
      final result = await f.login.submit(
        _platform,
        (_) => f.connector.password('fixture-phone', _password),
      );
      await store.flush();
      expect(store.file!.path, endsWith('state-v2.json'));
      final snapshot = StateStore.memory(
        decodePlainState(await store.file!.readAsBytes()),
      );
      addTearDown(snapshot.dispose);
      final saved = Vault(snapshot).credential(_platform)!;
      expect(saved.primary, 'fixture-phone');
      expect(saved.field('secondary'), _password);
      expect(saved.field('accessToken'), 'renewed-token');
      final reopened = await StateStore.open(directory);
      expect(
        Vault(reopened).credential(_platform)!.field('secondary'),
        _password,
      );
      final diagnostic = LogRedactor.json(result.credential.toJson());
      expect(diagnostic, isNot(contains('Example password')));
      expect(diagnostic, isNot(contains('fixture-phone')));
      expect(
        LogRedactor.text('secondary="$_password" primary="fixture-phone"'),
        isNot(contains('Example password')),
      );
      await f.login.remove(_platform);
      expect(f.vault.credential(_platform), isNull);
      reopened.dispose();
      store.dispose();
    },
  );
}
