import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/providers/quark.dart';
import 'package:asterlink/data/providers/uc.dart';
import 'package:asterlink/data/providers/pan123.dart';
import 'package:asterlink/data/providers/c139.dart';
import 'package:asterlink/data/providers/xunlei.dart';
import 'package:asterlink/data/providers/xunlei_protocol.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/ui/cloud_page.dart';
import 'support.dart';

class _LocalIo extends HttpOverrides {}

const _now = 1700000000000;
BrowseSession _personal(CloudPlatform platform) => BrowseSession(
  platform: platform,
  mode: BrowseMode.personal,
  title: 'fixture',
  rootId: platform == CloudPlatform.c139
      ? 'root'
      : platform == CloudPlatform.baidu
      ? '/'
      : '0',
);
BrowseSession _share(CloudPlatform platform) => BrowseSession(
  platform: platform,
  mode: BrowseMode.share,
  title: 'fixture',
  rootId: '0',
  metadata: const {
    'shareId': 'share',
    'shareKey': 'share',
    'stoken': 's+t/=',
    'passCodeToken': 'pass-token',
    'passcode': '1234',
    'linkId': 'link',
    'password': '1234',
  },
);
Credential _credential(CloudPlatform platform, {int revision = 42}) =>
    Credential(platform.label, switch (platform) {
      CloudPlatform.github => {
        'primary': 'github_pat_fixture0123456789',
        'username': 'fixture-user',
      },
      CloudPlatform.ctfile => {'primary': 'fixture-session-token'},
      CloudPlatform.baidu => {'primary': 'BDUSS=fixture'},
      CloudPlatform.quark || CloudPlatform.uc => {
        'primary': '__pus=account; __puus=old',
        'ucSessionRefreshedAt': '$_now',
        'quarkSessionRefreshedAt': '$_now',
      },
      CloudPlatform.pan123 => {
        'primary': 'token',
        'accessToken': 'token',
        'authType': 'webToken',
      },
      CloudPlatform.xunlei => {
        'primary': 'old-access',
        'accessToken': 'old-access',
        'refreshToken': 'old-refresh',
        'deviceId': 'device',
        'clientId': 'fixture-client',
        'clientSecret': 'fixture-secret',
      },
      CloudPlatform.c139 => {
        'primary': 'skey=fixture; ud_id=domain',
        'authorization':
            'Basic ${base64Encode(utf8.encode('pc:13800000000:fixture'))}',
      },
      CloudPlatform.tianyi => {'primary': 'COOKIE_LOGIN_USER=fixture'},
      CloudPlatform.pan115 => {
        'primary': 'UID=fixture; CID=fixture; SEID=fixture',
      },
      CloudPlatform.pikpak || CloudPlatform.guangya || CloudPlatform.aliyun => {
        'primary': 'fixture-refresh-token',
        'accessToken': 'fixture-access-token',
        'refreshToken': 'fixture-refresh-token',
        'userId': 'fixture-user',
      },
      CloudPlatform.feijipan || CloudPlatform.ilanzou => {
        'primary': 'fixture-app-token:0123456789',
        'accessToken': 'fixture-app-token:0123456789',
        'uuid': 'fixture-device-123',
      },
      CloudPlatform.weiyun => {
        'primary': 'uin=o12345; p_skey=fixture; wyctoken=fixture-csrf',
        'rootId': 'main-root',
      },
      CloudPlatform.wopan => {
        'primary': 'fixture-refresh-token',
        'accessToken': 'fixture-access-token',
        'refreshToken': 'fixture-refresh-token',
      },
      CloudPlatform.lanzou => {
        'primary': 'ylogin=fixture; phpdisk_info=fixture-cookie',
      },
    }, updatedAt: revision);
const _file = CloudFile(
  id: 'file',
  name: 'example.zip',
  size: 4,
  parentId: '0',
  token: 'file-token',
);
CloudFile get _file123 => CloudFile(
  id: '42',
  name: 'example.zip',
  size: 4,
  token: encoded({
    's3': '123456-0',
    'etag': '0123456789abcdef0123456789abcdef',
    'storage': 'node',
  }),
);
HttpResult _cookieResult(Object data, [String? session]) => HttpResult(
  200,
  encoded({'status': 200, 'code': 0, 'data': data}),
  session == null
      ? {}
      : {
          'set-cookie': ['__puus=$session; Path=/; HttpOnly'],
        },
);
HttpResult _downloadResult([String? session, String fid = 'file']) =>
    _cookieResult([
      {
        'fid': fid,
        'file_name': _file.name,
        'size': 4,
        'download_url': 'https://cdn.example/file?sign=a%2bb&key=1&key=2',
      },
    ], session);
HttpResult _xunleiFile() => jsonResponse({
  'id': 'file',
  'name': _file.name,
  'size': 4,
  'links': {
    'application/octet-stream': {'url': 'https://cdn.example/file?sign=a%2bb'},
  },
});
Matcher _error(String fragment) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(fragment)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('All YunX-backed cloud entries', () {
    test('Implemented entries expose their supported account flows', () {
      expect(
        cloudEntries
            .where((entry) => entry.$3 != null)
            .map((entry) => entry.$3)
            .toSet(),
        CloudPlatform.values.toSet(),
      );
      expect(
        cloudEntries
            .where((entry) => entry.$3 == null)
            .map((entry) => entry.$2),
        isEmpty,
      );
      expect(
        WebLoginTarget.targets.keys.toSet(),
        CloudPlatform.values
            .where(
              (platform) =>
                  platform.requiresAccount && platform != CloudPlatform.github,
            )
            .toSet(),
      );
      expect(
        WebLoginTarget.targets[CloudPlatform.pan123]!.localStorageKey,
        'authorToken',
      );
    });

    for (final platform in CloudPlatform.values.where(
      (p) => p.requiresAccount,
    )) {
      test(
        '${platform.key} personal browsing does not depend on quota availability',
        () async {
          final store = StateStore.memory(), vault = Vault(store);
          await vault.putCredential(platform, _credential(platform));
          final http = FakeHttp((r) {
            if (platform == CloudPlatform.aliyun &&
                r.uri.path == '/v2/user/get') {
              return jsonResponse({
                'user_id': 'fixture-user',
                'default_drive_id': 'fixture-drive',
              });
            }
            throw const AppException('quota service unavailable');
          });
          final repository = CloudRepository(
            http,
            vault,
            CleanupOutbox(store, http),
          );
          expect((await repository.personal(platform)).platform, platform);
          expect(
            http.calls.map((r) => r.uri.path),
            platform == CloudPlatform.aliyun
                ? [
                    '/v2/user/get',
                    // Optional album discovery also attempts device setup.
                    '/users/v1/users/device/create_session',
                  ]
                : isEmpty,
          );
          final openedRequests = http.calls.length;
          await vault.removeCredential(platform);
          expect(
            () => repository.list(_personal(platform), '0'),
            throwsA(isA<AccountLoginRequired>()),
          );
          await expectLater(
            repository.prepare(_personal(platform), _file),
            throwsA(isA<AccountLoginRequired>()),
          );
          expect(http.calls.length, openedRequests);
        },
      );

      test(
        '${platform.key} HTTP 401 is recognized as expired login, including non-JSON bodies',
        () async {
          final store = StateStore.memory(), vault = Vault(store);
          await vault.putCredential(platform, _credential(platform));
          final http = FakeHttp(
            (_) => const HttpResult(401, '<html>login required</html>'),
          );
          final repository = CloudRepository(
            http,
            vault,
            CleanupOutbox(store, http),
          );
          await expectLater(
            repository.connector(platform).account(vault.credential(platform)!),
            throwsA(isA<AccountLoginRequired>()),
          );
        },
      );
    }
  });

  group('Quark sessions and transfer protocol', () {
    test(
      'Refresh and every response Cookie reach the actual final download headers',
      () async {
        final vault = Vault(StateStore.memory()),
            old = _credential(CloudPlatform.quark);
        await vault.putCredential(CloudPlatform.quark, old);
        final http = FakeHttp(
          (r) => r.uri.path.endsWith('/config')
              ? _cookieResult({}, 'refreshed')
              : _downloadResult('final'),
        );
        final connector = QuarkConnector(
          http,
          store: vault,
          now: () => _now + 100 * 60000,
        );
        final spec = await connector.download(
          _personal(CloudPlatform.quark),
          _file,
          old,
        );
        expect(
          http.calls.first.uri.toString(),
          'https://drive-pc.quark.cn/1/clouddrive/config?pr=ucpro&fr=pc',
        );
        expect(http.calls.first.headers['Cookie'], '__pus=account');
        expect(http.calls.last.headers['Cookie'], contains('__puus=refreshed'));
        expect(http.calls.last.uri.queryParameters['ve'], '3.23.2');
        expect(spec.headers['Cookie'], contains('__puus=final'));
        expect(spec.headers['User-Agent'], QuarkConnector.cloudUa);
        expect(spec.headers['Referer'], 'https://pan.quark.cn/');
        expect(spec.url, 'https://cdn.example/file?sign=a%2bb&key=1&key=2');
        expect(vault.credential(CloudPlatform.quark)!.updatedAt, old.updatedAt);
      },
    );

    test(
      'Share transfer keeps one renewed session through nested personal listing and task polling',
      () async {
        final vault = Vault(StateStore.memory()),
            old = _credential(CloudPlatform.quark);
        await vault.putCredential(CloudPlatform.quark, old);
        final cleanups = <DownloadCleanup>[];
        var polls = 0;
        final http = FakeHttp((r) {
          switch (r.uri.path) {
            case '/1/clouddrive/file/sort':
              expect(r.uri.queryParameters['fetch_all_file'], '1');
              expect(r.uri.queryParameters['_fetch_sub_dirs'], '0');
              return _cookieResult({
                'list': [
                  {'fid': 'base', 'file_name': '文析助手临时转存', 'dir': true},
                ],
              }, 'from-list');
            case '/1/clouddrive/file':
              expect(r.headers['Cookie'], contains('__puus=from-list'));
              expect(r.json['pdir_fid'], 'base');
              return _cookieResult({'fid': 'temporary'});
            case '/1/clouddrive/share/sharepage/save':
              expect(r.json['stoken'], 's+t/=');
              expect(r.json['fid_token_list'], ['file-token']);
              expect(r.json['to_pdir_fid'], 'temporary');
              return _cookieResult({'task_id': 'save-task'});
            case '/1/clouddrive/task':
              polls++;
              return _cookieResult(
                polls == 1
                    ? {'status': 1}
                    : {
                        'status': 2,
                        'save_as': {
                          'save_as_top_fids': ['saved-file'],
                        },
                      },
              );
            case '/1/clouddrive/file/download':
              expect(r.json['fids'], ['saved-file']);
              expect(r.headers['Cookie'], contains('__puus=from-list'));
              return _downloadResult('from-download', 'saved-file');
            default:
              throw StateError('Unexpected request ${r.uri.path}');
          }
        });
        final spec = await QuarkConnector(
          http,
          store: vault,
          now: () => _now,
          taskDelay: Duration.zero,
          stageCleanup: (cleanup) async => cleanups.add(cleanup),
        ).downloadFallback(_share(CloudPlatform.quark), _file, old);
        expect(polls, 2);
        expect(spec.headers['Cookie'], contains('__puus=from-download'));
        expect(spec.cleanup, same(cleanups.single));
        expect(jsonDecode(spec.cleanup!.body!)['filelist'], ['temporary']);
        expect(
          http.calls.where((r) => r.uri.path.endsWith('/file/delete')),
          isEmpty,
        );
      },
    );

    test('Quark and UC requests cannot exchange account cookies', () async {
      final vault = Vault(StateStore.memory());
      for (final platform in [CloudPlatform.quark, CloudPlatform.uc]) {
        await vault.putCredential(platform, _credential(platform));
      }
      final http = FakeHttp((r) async {
        await Future<void>.delayed(Duration.zero);
        return _downloadResult(
          r.uri.host.contains('quark') ? 'quark-new' : 'uc-new',
        );
      });
      final specs = await Future.wait([
        QuarkConnector(http, store: vault, now: () => _now).download(
          _personal(CloudPlatform.quark),
          _file,
          vault.credential(CloudPlatform.quark),
        ),
        UcConnector(http, store: vault, now: () => _now).download(
          _personal(CloudPlatform.uc),
          _file,
          vault.credential(CloudPlatform.uc),
        ),
      ]);
      expect(specs[0].headers['Cookie'], contains('quark-new'));
      expect(specs[1].headers['Cookie'], contains('uc-new'));
      expect(
        vault.credential(CloudPlatform.quark)!.primary,
        contains('quark-new'),
      );
      expect(vault.credential(CloudPlatform.uc)!.primary, contains('uc-new'));
    });

    test(
      'Quark business errors and failed finished tasks cannot report success',
      () async {
        final c = _credential(CloudPlatform.quark);
        final bad = QuarkConnector(
          FakeHttp(
            (_) => jsonResponse({
              'status': 200,
              'code': 21001,
              'message': 'file missing',
            }),
          ),
          now: () => _now,
        );
        await expectLater(
          bad.download(_personal(CloudPlatform.quark), _file, c),
          _error('file missing'),
        );
        final task = QuarkConnector(
          FakeHttp(
            (r) => _cookieResult(
              r.uri.path.endsWith('/task')
                  ? {'status': 3, 'finished_at': 123, 'share_id': 'bad'}
                  : {'task_id': 'task'},
            ),
          ),
          taskDelay: Duration.zero,
        );
        await expectLater(
          task.createShare(
            _personal(CloudPlatform.quark),
            [_file],
            const ShareOptions('x'),
            c,
          ),
          _error('异步任务失败'),
        );
      },
    );
  });

  group('123 pagination, download and save completion', () {
    test(
      'HTTP 200 with business code 401 still requires a new login',
      () async {
        for (final code in <Object>[401, '401']) {
          final connector = Pan123Connector(
            FakeHttp(
              (_) => jsonResponse({
                'code': code,
                'message': 'cookie token is empty',
              }),
            ),
            Vault(StateStore.memory()),
          );
          await expectLater(
            connector.authenticate(_credential(CloudPlatform.pan123)),
            throwsA(isA<AccountLoginRequired>()),
          );
        }
      },
    );

    test('Personal empty cursors stay empty and Page stays one', () async {
      var requests = 0;
      final http = FakeHttp((r) {
        requests++;
        expect(r.uri.queryParameters['next'], requests == 1 ? '0' : '');
        expect(r.uri.queryParameters['Page'], '1');
        return jsonResponse({
          'code': 0,
          'data': {
            'Next': requests == 1 ? '' : '-1',
            'InfoList': [
              {'FileId': requests, 'FileName': '$requests', 'Type': 0},
            ],
          },
        });
      });
      final files = await Pan123Connector(http, Vault(StateStore.memory()))
          .list(
            _personal(CloudPlatform.pan123),
            '0',
            _credential(CloudPlatform.pan123),
          );
      expect(files.map((file) => file.id), ['1', '2']);
      expect(requests, 2);
    });

    test(
      'Shares follow the YunX caller: fixed next=0 and incrementing Page',
      () async {
        var requests = 0;
        final http = FakeHttp((r) {
          requests++;
          expect(r.uri.queryParameters['next'], '0');
          expect(r.uri.queryParameters['Page'], '$requests');
          expect(r.uri.queryParameters['SharePwd'], '1234');
          expect(r.headers.containsKey('authorization'), isFalse);
          return jsonResponse({
            'code': 0,
            'data': {
              'Next': requests == 1 ? 'ignored-for-share' : '-1',
              'InfoList': [
                {'FileId': requests, 'FileName': '$requests'},
              ],
            },
          });
        });
        final files = await Pan123Connector(
          http,
          Vault(StateStore.memory()),
        ).list(_share(CloudPlatform.pan123), '19', null);
        expect(files.length, 2);
        expect(requests, 2);
      },
    );

    test(
      'Successful envelopes on HTTP failures cannot validate an account',
      () async {
        final connector = Pan123Connector(
          FakeHttp(
            (_) => jsonResponse({
              'code': 0,
              'data': {'Nickname': 'bad'},
            }, 503),
          ),
          Vault(StateStore.memory()),
        );
        await expectLater(
          connector.authenticate(_credential(CloudPlatform.pan123)),
          _error('503'),
        );
      },
    );

    test(
      'A valid nickname can finish login while unavailable quota remains an explicit error',
      () async {
        final connector = Pan123Connector(
          FakeHttp(
            (_) => jsonResponse({
              'code': 0,
              'data': {'Nickname': 'name'},
            }),
          ),
          Vault(StateStore.memory()),
        );
        expect(
          (await connector.authenticate(
            _credential(CloudPlatform.pan123),
          )).account.nickname,
          'name',
        );
        await expectLater(
          connector.account(_credential(CloudPlatform.pan123)),
          _error('容量'),
        );
      },
    );

    test(
      'Personal download supplies type=0 and unwraps every JSON redirect without changing signatures',
      () async {
        const first = 'https://cdn.example/start?auto_redirect=0&sign=a%2bb';
        const last = 'https://cdn.example/final?sign=b%2fc&key=1&key=2';
        final http = FakeHttp((r) {
          if (r.method == 'POST') {
            expect(r.uri.path, '/api/file/download_info');
            expect(r.json['type'], 0);
            expect(r.json['fileId'], 42);
            expect(r.headers['platform'], 'web');
            return jsonResponse({
              'code': 0,
              'data': {
                'DownloadUrl':
                    'https://yun.123pan.cn/download-v2?params=${Uri.encodeQueryComponent(base64UrlEncode(utf8.encode(first)))}',
              },
            });
          }
          if (r.url == first) {
            return jsonResponse({
              'code': 0,
              'data': {'redirect_url': last},
            });
          }
          expect(r.url, last);
          return const HttpResult(206, 'file');
        });
        final spec = await Pan123Connector(http, Vault(StateStore.memory()))
            .download(
              _personal(CloudPlatform.pan123),
              _file123,
              _credential(CloudPlatform.pan123),
            );
        expect(spec.url, last);
        expect(spec.headers['User-Agent'], Pan123Connector.webUa);
        expect(spec.headers['Referer'], 'https://yun.123pan.cn/');
        expect(spec.checksumValue, '0123456789abcdef0123456789abcdef');
        expect(http.calls.length, 3);
      },
    );

    test(
      'Malformed and undecodable wrapper URLs fail before reading a file',
      () async {
        for (final url in [
          'https://[broken/download-v2?params=invalid',
          'https://yun.123pan.cn/download-v2?params=invalid',
          'https://yun.123pan.cn/download-v2?params=${base64Encode(utf8.encode('file:///private/file'))}',
        ]) {
          final http = FakeHttp((r) {
            expect(r.method, 'POST');
            return jsonResponse({
              'code': 0,
              'data': {'DownloadUrl': url},
            });
          });
          await expectLater(
            Pan123Connector(http, Vault(StateStore.memory())).download(
              _personal(CloudPlatform.pan123),
              _file123,
              _credential(CloudPlatform.pan123),
            ),
            _error('地址'),
          );
          expect(http.calls.length, 1);
        }
      },
    );

    test(
      'Save is asynchronous, has no signature headers on mshare, and waits for completion',
      () async {
        var polls = 0;
        final http = FakeHttp((r) {
          expect(r.uri.host, '123456.mshare.123pan.cn');
          expect(r.headers.containsKey('auth-key'), isFalse);
          expect(r.headers['Authorization'], 'Bearer token');
          if (r.method == 'POST') {
            expect(r.json.list('fileList').single['parentFileID'], 7);
            expect(r.json['sharePwd'], '1234');
            return jsonResponse({
              'code': 0,
              'data': {'taskID': '123'},
            });
          }
          polls++;
          expect(r.uri.queryParameters['taskID'], '123');
          return jsonResponse({
            'code': 0,
            'data': polls == 1 ? {'status': 1} : {'status': 2, 'newFileId': 43},
          });
        });
        await Pan123Connector(
          http,
          Vault(StateStore.memory()),
          taskDelay: Duration.zero,
        ).saveShare(
          _share(CloudPlatform.pan123),
          [_file123],
          '7',
          _credential(CloudPlatform.pan123),
        );
        expect(polls, 2);
      },
    );

    for (final outcome in ['failed', 'timeout', 'missing-task']) {
      test('123 save reports $outcome instead of success', () async {
        final http = FakeHttp(
          (r) => jsonResponse({
            'code': 0,
            'data': r.method == 'POST'
                ? outcome == 'missing-task'
                      ? {}
                      : {'taskID': 123}
                : outcome == 'failed'
                ? {'state': 'failed', 'status': 2, 'finished': true}
                : {'status': 1},
          }),
        );
        await expectLater(
          Pan123Connector(
            http,
            Vault(StateStore.memory()),
            taskDelay: Duration.zero,
          ).saveShare(
            _share(CloudPlatform.pan123),
            [_file123],
            '0',
            _credential(CloudPlatform.pan123),
          ),
          _error(
            outcome == 'failed'
                ? '失败'
                : outcome == 'timeout'
                ? '超时'
                : '任务 ID',
          ),
        );
        expect(http.calls.length, lessThanOrEqualTo(16));
      });
    }

    test('Cancelling a save poll stops the remaining requests', () async {
      final scope = RequestScope();
      final http = FakeHttp((r) {
        if (r.method == 'GET') scope.cancel();
        return jsonResponse({
          'code': 0,
          'data': r.method == 'POST' ? {'taskID': 123} : {'status': 1},
        });
      });
      await expectLater(
        scope.run(
          () =>
              Pan123Connector(
                http,
                Vault(StateStore.memory()),
                taskDelay: Duration.zero,
              ).saveShare(
                _share(CloudPlatform.pan123),
                [_file123],
                '0',
                _credential(CloudPlatform.pan123),
              ),
        ),
        _error('已取消'),
      );
      expect(http.calls.length, 2);
    });
  });

  group('Xunlei download authentication', () {
    test(
      'Renewal after HTML 401 persists tokens and uses the official App UA for the file stream',
      () async {
        final vault = Vault(StateStore.memory()),
            c = _credential(CloudPlatform.xunlei);
        await vault.putCredential(CloudPlatform.xunlei, c);
        var refreshes = 0;
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/auth/token')) {
            refreshes++;
            expect(
              Uri.splitQueryString(r.body as String)['refresh_token'],
              'old-refresh',
            );
            return jsonResponse({
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
            });
          }
          return r.headers['Authorization'] == 'Bearer old-access'
              ? const HttpResult(401, '<html>login</html>')
              : _xunleiFile();
        });
        final spec = await XunleiConnector(
          http,
          vault,
          XunleiDevices(vault),
        ).download(_personal(CloudPlatform.xunlei), _file, c);
        expect(refreshes, 1);
        expect(spec.headers, {'User-Agent': XunleiProtocol.appUa});
        expect(spec.url, 'https://cdn.example/file?sign=a%2bb');
        expect(vault.credential(CloudPlatform.xunlei)!.primary, 'new-access');
        expect(vault.credential(CloudPlatform.xunlei)!.updatedAt, c.updatedAt);
      },
    );

    test('Concurrent expired downloads share one token refresh', () async {
      final vault = Vault(StateStore.memory()),
          c = _credential(CloudPlatform.xunlei);
      await vault.putCredential(CloudPlatform.xunlei, c);
      var refreshes = 0;
      final http = FakeHttp((r) async {
        if (r.uri.path.endsWith('/auth/token')) {
          refreshes++;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return jsonResponse({
            'access_token': 'new-access',
            'refresh_token': 'new-refresh',
          });
        }
        return r.headers['Authorization'] == 'Bearer old-access'
            ? jsonResponse({'error': 'unauthenticated'}, 401)
            : _xunleiFile();
      });
      final connector = XunleiConnector(http, vault, XunleiDevices(vault));
      final specs = await Future.wait(
        List.generate(
          2,
          (_) => connector.download(_personal(CloudPlatform.xunlei), _file, c),
        ),
      );
      expect(specs.length, 2);
      expect(refreshes, 1);
    });

    for (final action in ['cancel', 'logout', 'replace']) {
      test(
        'Late token refresh after $action cannot persist or retry the cloud operation',
        () async {
          final vault = Vault(StateStore.memory()),
              c = _credential(CloudPlatform.xunlei);
          await vault.putCredential(CloudPlatform.xunlei, c);
          final entered = Completer<void>(),
              reply = Completer<HttpResult>(),
              scope = RequestScope();
          final http = FakeHttp((r) {
            if (r.uri.path.endsWith('/auth/token')) {
              entered.complete();
              return reply.future;
            }
            return jsonResponse({'error': 'unauthenticated'}, 401);
          });
          final operation = scope.run(
            () => XunleiConnector(
              http,
              vault,
              XunleiDevices(vault),
            ).download(_personal(CloudPlatform.xunlei), _file, c),
          );
          final expectation = expectLater(
            operation,
            _error(action == 'cancel' ? '取消' : '账号已变化'),
          );
          await entered.future;
          if (action == 'cancel') scope.cancel();
          if (action == 'logout') {
            await vault.removeCredential(CloudPlatform.xunlei);
          }
          if (action == 'replace') {
            await vault.putCredential(
              CloudPlatform.xunlei,
              _credential(CloudPlatform.xunlei, revision: 100),
            );
          }
          reply.complete(
            jsonResponse({
              'access_token': 'late-access',
              'refresh_token': 'late-refresh',
            }),
          );
          await expectation;
          expect(http.calls.length, 2);
          expect(
            vault.credential(CloudPlatform.xunlei)?.primary,
            action == 'logout' ? isNull : 'old-access',
          );
        },
      );
    }

    test(
      'Manual token validation returns the renewed candidate and leaves the old account untouched',
      () async {
        final vault = Vault(StateStore.memory()),
            old = _credential(CloudPlatform.xunlei);
        await vault.putCredential(CloudPlatform.xunlei, old);
        final candidate = _credential(CloudPlatform.xunlei, revision: 99);
        final http = FakeHttp((r) {
          if (r.uri.path.endsWith('/auth/token')) {
            return jsonResponse({
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
            });
          }
          if (r.headers['Authorization'] == 'Bearer old-access') {
            return jsonResponse({'error': 'unauthenticated'}, 401);
          }
          return jsonResponse({
            'quota': {'limit': '100', 'usage': '4'},
          });
        });
        final result = await XunleiConnector(
          http,
          vault,
          XunleiDevices(vault),
        ).authenticate(candidate);
        expect(result.credential.primary, 'new-access');
        expect(result.credential.field('refreshToken'), 'new-refresh');
        expect(vault.credential(CloudPlatform.xunlei)!.sameAs(old), isTrue);
      },
    );

    test(
      'Partial restore mappings cannot report all selected files saved',
      () async {
        final vault = Vault(StateStore.memory());
        final http = FakeHttp(
          (_) => jsonResponse({
            'params': {'trace_file_ids': '{"file":"saved"}'},
          }),
        );
        await expectLater(
          XunleiConnector(http, vault, XunleiDevices(vault)).saveShare(
            _share(CloudPlatform.xunlei),
            [_file, const CloudFile(id: 'other', name: 'other')],
            '',
            _credential(CloudPlatform.xunlei),
          ),
          _error('全部文件'),
        );
      },
    );
  });

  group('Mobile 139 list and operation results', () {
    test(
      'String null cursor is terminal and cannot repeatedly fetch the first page',
      () async {
        final http = FakeHttp((r) {
          expect(r.json.obj('pageInfo')['pageCursor'], isNull);
          return jsonResponse({
            'code': '0000',
            'data': {
              'nextPageCursor': 'null',
              'items': [
                {'fileId': 'file', 'name': 'file', 'type': 'file'},
              ],
            },
          });
        });
        expect(
          (await C139Connector(http).list(
            _personal(CloudPlatform.c139),
            'root',
            _credential(CloudPlatform.c139),
          )).length,
          1,
        );
        expect(http.calls.length, 1);
      },
    );

    for (final result in ['failed', 'partial', 'missing-task']) {
      test(
        'Mobile 139 $result operations cannot show successful deletion',
        () async {
          final http = FakeHttp(
            (r) => jsonResponse({
              'code': '0000',
              'data': r.uri.path.endsWith('/batchTrash')
                  ? result == 'missing-task'
                        ? {}
                        : {'taskId': 'task'}
                  : {
                      'taskInfo': {
                        'status': result == 'failed' ? 'failed' : 'success',
                        'progress': 100,
                      },
                      'batchFileResults': [
                        {
                          'fileId': 'file',
                          'errCode': result == 'partial'
                              ? 'permission_denied'
                              : '0000',
                        },
                      ],
                    },
            }),
          );
          await expectLater(
            C139Connector(http, taskDelay: Duration.zero).delete(
              _personal(CloudPlatform.c139),
              [_file],
              _credential(CloudPlatform.c139),
            ),
            _error(result == 'missing-task' ? '任务 ID' : '失败'),
          );
        },
      );
    }

    test(
      'Transfer checks per-file result codes after overall completion',
      () async {
        final http = FakeHttp(
          (r) => jsonResponse({
            'resultCode': '0',
            'data': r.uri.path.endsWith('/createOuterLinkBatchOprTask')
                ? {'taskID': 'task'}
                : {
                    'batchOprTask': {'taskStatus': 2, 'progress': 100},
                    'contentList': {
                      'idRspInfo': [
                        {
                          'srcId': 'file',
                          'rstId': '',
                          'reason': 'permission_denied',
                        },
                      ],
                    },
                  },
          }),
        );
        await expectLater(
          C139Connector(http, taskDelay: Duration.zero).saveShare(
            _share(CloudPlatform.c139),
            [_file],
            'root',
            _credential(CloudPlatform.c139),
          ),
          _error('部分文件转存失败'),
        );
      },
    );

    test(
      'Downloads carry the reference desktop UA and do not export account authorization to CDN',
      () async {
        final http = FakeHttp((r) {
          expect(r.uri.path, '/hcy/file/getDownloadUrl');
          expect(r.headers['Authorization'], isNotEmpty);
          return jsonResponse({
            'code': '0000',
            'data': {'url': 'https://cdn.example/file?sign=a%2bb', 'size': 4},
          });
        });
        final spec = await C139Connector(http).download(
          _personal(CloudPlatform.c139),
          _file,
          _credential(CloudPlatform.c139),
        );
        expect(spec.headers['User-Agent'], C139Connector.ua);
        expect(spec.headers.containsKey('Authorization'), isFalse);
        expect(spec.headers.containsKey('Cookie'), isFalse);
      },
    );

    test(
      'Generated share passwords come only from the service response',
      () async {
        final http = FakeHttp((r) {
          expect(r.json.obj('getOutLinkReq').containsKey('passcode'), isFalse);
          expect(r.headers['mcloud-skey'], 'fixture');
          return jsonResponse({
            'code': '0',
            'data': {
              'getOutLinkRes': {
                'getOutLinkResSet': [
                  {'linkUrl': 'https://yun.139.com/shareweb/#/w/i/share'},
                ],
              },
            },
          });
        });
        final share = await C139Connector(http).createShare(
          _personal(CloudPlatform.c139),
          [_file],
          const ShareOptions('files', passcode: 'not-supported'),
          _credential(CloudPlatform.c139),
        );
        expect(share.passcode, isEmpty);
      },
    );

    test(
      'Sharing accepts an authenticated account without optional skey',
      () async {
        final original = _credential(CloudPlatform.c139);
        final credential = Credential(original.label, {
          ...original.fields,
          'primary': 'ud_id=domain; auth_token=fixture',
        }, updatedAt: original.updatedAt);
        final http = FakeHttp((r) {
          expect(r.headers['Authorization'], isNotEmpty);
          expect(r.headers['Cookie'], credential.primary);
          expect(r.headers.containsKey('mcloud-skey'), isFalse);
          return jsonResponse({
            'code': '0',
            'data': {
              'getOutLinkRes': {
                'getOutLinkResSet': [
                  {'linkUrl': 'https://yun.139.com/shareweb/#/w/i/share'},
                ],
              },
            },
          });
        });
        final share = await C139Connector(http).createShare(
          _personal(CloudPlatform.c139),
          [_file],
          const ShareOptions('files'),
          credential,
        );
        expect(share.url, 'https://yun.139.com/shareweb/#/w/i/share');
        expect(http.calls, hasLength(1));
      },
    );
  });

  test(
    'A real streaming HTTP probe is cancelled with its parent request scope',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final entered = Completer<void>(), release = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.binary;
        request.response.add([1]);
        await request.response.flush();
        entered.complete();
        await release.future;
        await request.response.close();
      });
      final http = DioJsonHttp(), scope = RequestScope();
      try {
        final future = scope.run(
          () => http.peek('http://127.0.0.1:${server.port}/file', {}),
        );
        final expectation = expectLater(future, _error('取消'));
        await entered.future.timeout(const Duration(seconds: 5));
        scope.cancel();
        await expectation.timeout(const Duration(seconds: 5));
      } finally {
        release.complete();
        http.dio.close(force: true);
        await server.close(force: true);
      }
    }, _LocalIo()),
  );
}
