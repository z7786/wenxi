import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asterlink/app_services.dart';
import 'package:asterlink/core/json.dart';
import 'package:asterlink/data/cleanup_outbox.dart';
import 'package:asterlink/data/cloud_repository.dart';
import 'package:asterlink/data/http.dart';
import 'package:asterlink/data/http_retry.dart';
import 'package:asterlink/data/providers/tianyi.dart';
import 'package:asterlink/data/state_store.dart';
import 'package:asterlink/diagnostics/redaction.dart';
import 'package:asterlink/domain/auth.dart';
import 'package:asterlink/domain/links.dart';
import 'package:asterlink/domain/models.dart';
import 'package:asterlink/domain/settings.dart';
import 'package:asterlink/ui/browser_page.dart';
import 'support.dart';

const _platform = CloudPlatform.tianyi;
const _personal = BrowseSession(
  platform: _platform,
  mode: BrowseMode.personal,
  title: '天翼',
  rootId: '-11',
);
const _md5 = '0123456789abcdef0123456789abcdef';
const _file = CloudFile(
  id: '101',
  name: '演示视频.mp4',
  size: 42,
  parentId: '101',
  hashType: 'md5',
  hashValue: _md5,
);
const _signedUrl =
    'https://download.example.test/video?sign=a%2bb&name=%e4%b8%ad&key=1&key=2';
const _largeVideo = CloudFile(
  id: '623463190579123491',
  name: '演示大视频.MKV',
  size: 63964203701,
  parentId: '723463190579123488',
  hashType: 'md5',
  hashValue: _md5,
);
Credential _credential([
  int revision = 1,
  String cookie = 'COOKIE_LOGIN_USER=original; keep=a=b',
]) => Credential('天翼', {'primary': cookie}, updatedAt: revision);
BrowseSession _share({bool folder = false}) => BrowseSession(
  platform: _platform,
  mode: BrowseMode.share,
  title: '分享',
  rootId: folder ? '100' : '101',
  metadata: {
    'shareId': '123456',
    'shareCode': 'TestShare123',
    'shareMode': '1',
    'accessCode': 'a1B2',
    'isFolder': '$folder',
  },
  sourceLink: LinkParser.parse(
    'https://cloud.189.cn/web/share?code=TestShare123 访问码：a1B2',
  ).single,
);
Json _params(RecordedRequest r) => r.method == 'GET'
    ? r.uri.queryParameters
    : Uri.splitQueryString(r.body as String);
HttpResult _ok(Json data, {List<String> cookies = const []}) =>
    HttpResult(200, encoded({'res_code': 0, ...data}), {'set-cookie': cookies});
HttpResult _identity({List<String> cookies = const []}) => _ok({
  'loginName': 'fixture-account',
  'userExtResp': {'nickName': '测试用户'},
}, cookies: cookies);
HttpResult _quota() => _ok({
  'cloudCapacityInfo': {'totalSize': '1000', 'usedSize': '300'},
  'familyCapacityInfo': {'totalSize': 9000, 'usedSize': 1000},
});
Json _row([String id = '101', String name = '演示视频.mp4', int size = 42]) => {
  'id': id,
  'name': name,
  'size': '$size',
  'md5': _md5,
  'lastOpTime': '2026-01-01 12:00:00',
};
HttpResult _listing(
  List<Json> files, {
  int? count,
  List<Json> folders = const [],
}) => _ok({
  'fileListAO': {
    'count': count ?? files.length + folders.length,
    'fileList': files,
    'folderList': folders,
  },
});
Matcher _message(String value) => throwsA(
  isA<AppException>().having((e) => e.message, 'message', contains(value)),
);
TianyiConnector _connector(FakeHttp http, {Vault? store}) => TianyiConnector(
  http,
  store: store,
  taskDelay: Duration.zero,
  maxTaskPolls: 3,
);
AccountLoginService _login(Vault vault, TianyiConnector connector) =>
    AccountLoginService(
      vault,
      (_, c) => connector.account(c),
      webAuthenticators: {_platform: connector.authenticate},
    );

String _signature(Map<String, Object?> values) {
  final pairs = values.entries.map((e) => '${e.key}=${e.value}').toList()
    ..sort();
  return md5.convert(utf8.encode(pairs.join('&'))).toString();
}

void _expectMobileRequest(RecordedRequest r) {
  expect(r.method, 'GET');
  expect(r.uri.host, 'api.cloud.189.cn');
  expect(r.headers['Accept'], 'application/json;charset=UTF-8');
  expect(r.headers['Sign-Type'], '1');
  expect(r.headers['Timestamp'], matches(r'^\d{13}$'));
  expect(r.headers['X-Request-ID'], matches(r'^[0-9a-f]{32}$'));
  expect(r.headers['Origin'], 'https://h5.cloud.189.cn');
  expect(r.headers['Referer'], 'https://h5.cloud.189.cn/share.html');
  expect(r.headers['User-Agent'], contains('Android'));
  expect(r.headers['User-Agent'], contains('Mobile'));
  expect(r.uri.queryParameters.containsKey('noCache'), isFalse);
  expect(
    r.headers.keys.map((key) => key.toLowerCase()),
    isNot(anyOf(contains('cookie'), contains('browser-id'))),
  );
  expect(
    r.headers['Signature'],
    _signature({
      ...r.uri.queryParameters,
      'AccessToken': r.headers['AccessToken'],
      'Timestamp': r.headers['Timestamp'],
    }),
  );
}

class _Transfer {
  _Transfer({bool retryReads = false}) {
    http = FakeHttp(respond);
    outbox = CleanupOutbox(store, http);
    repository = CloudRepository(
      http,
      vault,
      outbox,
      retryWait: retryReads ? (_) async {} : null,
    );
    connector = TianyiConnector(
      retryReads ? repository.http : http,
      store: vault,
      taskDelay: Duration.zero,
      maxTaskPolls: 3,
    );
    repository.connectors[_platform] = connector;
  }
  final store = StateStore.memory();
  late final vault = Vault(store);
  late final FakeHttp http;
  late final CleanupOutbox outbox;
  late final CloudRepository repository;
  late final TianyiConnector connector;
  String folderName = '';
  final pollCounts = <String, int>{};
  bool shareDirect = false;
  bool mobileDirect = false;
  CloudFile file = _file;
  int exchanges = 0;
  Json? completedTask;
  FutureOr<HttpResult?> Function(RecordedRequest)? override;
  Future<void> initialize() => vault.putCredential(_platform, _credential());
  Future<void> saveShare() => repository.saveShare(_share(), [_file], '900');

  Future<DownloadCleanup> historicalCleanup({bool retained = false}) async {
    folderName = 'AsterLink临时转存_00000000-0000-4000-8000-000000000000';
    final cleanup = DownloadCleanup(
      url: '',
      action: {
        'kind': 'temporary-folder',
        'platform': _platform.key,
        'folderId': '900',
        'name': folderName,
        'accountRevision': 1,
      },
    );
    await outbox.stage(cleanup, accountId: vault.accountId(_platform));
    if (retained) outbox.retain(cleanup);
    return cleanup;
  }

  Future<HttpResult> respond(RecordedRequest r) async {
    final replacement = await override?.call(r);
    if (replacement != null) return replacement;
    final p = _params(r);
    switch (r.uri.path) {
      case '/api/open/file/createFolder.action':
        expect(p['parentFolderId'], '-11');
        folderName = p.str('folderName');
        return _ok({'id': '900', 'name': folderName});
      case '/api/open/batch/createBatchTask.action':
        final type = p.str('type');
        expect(r.method, 'POST');
        if (type == 'SHARE_SAVE') {
          expect(outbox.pendingCount, 0);
          expect(p['targetFolderId'], '900');
          expect(p['shareId'], '123456');
          expect(p['copyType'], '1');
          expect(jsonDecode(p.str('taskInfos')), [
            {'fileId': '101', 'fileName': _file.name, 'isFolder': 0},
          ]);
        }
        return _ok({'taskId': 'task-$type'});
      case '/api/open/batch/checkBatchTask.action':
        final type = p.str('type');
        expect(p['taskId'], 'task-$type');
        final count = pollCounts[type] = (pollCounts[type] ?? 0) + 1;
        if (completedTask != null) return _ok(completedTask!);
        return _ok({
          'taskStatus': count == 1 ? 1 : 4,
          'successedCount': count == 1 ? 0 : 1,
          'failedCount': 0,
          'subTaskCount': 1,
        });
      case '/api/open/file/listFiles.action':
        if (p['folderId'] == '-11') {
          return _listing(
            [],
            folders: [
              {'id': '900', 'name': folderName},
            ],
          );
        }
        throw StateError(
          'Downloads must not inspect a personal transfer folder',
        );
      case '/api/open/file/getFileDownloadUrl.action':
        if (p.containsKey('shareId')) {
          expect(p['shareId'], '123456');
          expect(p['fileId'], file.id);
          expect(p['dt'], '1');
          expect(r.headers['Cookie'], contains('share_123456=a1B2'));
          return shareDirect
              ? _ok({'fileDownloadUrl': _signedUrl})
              : jsonResponse({'res_code': 'FileTooLarge'}, 400);
        }
        expect(p['fileId'], file.id);
        expect(p.containsKey('dt'), isFalse);
        expect(p.containsKey('shareId'), isFalse);
        return _ok({'fileDownloadUrl': _signedUrl});
      case '/api/portal/v2/getUserBriefInfo.action':
        expect(r.headers['Cookie'], vault.credential(_platform)!.primary);
        return _ok({'sessionKey': 'mobile-session'});
      case '/api/open/oauth2/getAccessTokenBySsKey.action':
        expect(p['sessionKey'], 'mobile-session');
        expect(r.headers['AppKey'], '600100422');
        expect(r.headers.containsKey('AccessToken'), isFalse);
        expect(
          r.headers['Signature'],
          _signature({
            'sessionKey': 'mobile-session',
            'AppKey': '600100422',
            'Timestamp': r.headers['Timestamp'],
          }),
        );
        return _ok({'accessToken': 'mobile-access-${++exchanges}'});
      case '/open/file/getFileDownloadUrl.action':
        _expectMobileRequest(r);
        expect(r.headers['AccessToken'], 'mobile-access-$exchanges');
        expect(p['fileId'], file.id);
        expect(p.containsKey('familyId'), isFalse);
        if (p.containsKey('shareId')) {
          expect(p['shareId'], '123456');
          expect(p['dt'], '1');
        } else {
          expect(p.containsKey('dt'), isFalse);
        }
        return mobileDirect
            ? _ok({'fileDownloadUrl': _signedUrl})
            : jsonResponse({'res_code': 'FileTooLarge'}, 400);
      case '/api/portal/getNewVlcVideoPlayUrl.action':
        expect(p['fileId'], file.id);
        expect(p['type'], '4');
        expect(p['shareId'], '123456');
        expect(r.headers['Cookie'], contains('share_123456=a1B2'));
        return _ok({
          'success': true,
          'normal': {},
          'transcode': {
            'code': 2,
            'url': 'https://download.example.test/transcoded.m3u8',
          },
        });
      default:
        throw StateError('Unexpected request ${r.uri.path}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Transient transfer-status POST failure retries polling without submitting another transfer',
    () async {
      final fixture = _Transfer(retryReads: true);
      await fixture.initialize();
      var polls = 0;
      fixture.override = (request) =>
          request.uri.path.endsWith('/checkBatchTask.action') && ++polls == 1
          ? const HttpResult(503, '<html>unavailable</html>')
          : null;
      await ReadRetryScope(
        retries: 1,
        checkpoint: RequestScope.checkpoint,
        wait: (_) async {},
      ).run(fixture.saveShare);
      expect(polls, 3);
      expect(
        fixture.http.calls.where(
          (r) => r.uri.path.endsWith('/createFolder.action'),
        ),
        isEmpty,
      );
      expect(
        fixture.http.calls.where(
          (r) => r.uri.path.endsWith('/createBatchTask.action'),
        ),
        hasLength(1),
      );
    },
  );

  group('Tianyi links and login routing', () {
    test('Official copied links separate parenthesized access codes', () {
      for (final url in [
        'https://cloud.189.cn/web/share?code=TestShare123',
        'https://cloud.189.cn/t/TestShare123',
        'https://h5.cloud.189.cn/share.html#/t/TestShare123',
        'https://h5.cloud.189.cn/share.html#/share?code=TestShare123',
      ]) {
        for (final suffix in ['（访问码：a1B2）', '(访问码:a1B2)']) {
          final source = '$url$suffix';
          final link = LinkParser.parse(source).single;
          expect(link.kind, LinkKind.cloudShare, reason: source);
          expect(link.platform, _platform);
          expect(link.shareId, 'TestShare123');
          expect(link.passcode, 'a1B2');
          expect(link.url, url);
          expect(link.source, source);
        }
      }
    });

    test('Query code identifies the share and never becomes its password', () {
      for (final url in [
        'https://cloud.189.cn/web/share?code=TestShare123',
        'https://h5.cloud.189.cn/share.html#/t/TestShare123',
        'cloud.189.cn/t/TestShare123',
        '分享文件：h5.cloud.189.cn/share.html#/t/TestShare123',
      ]) {
        final link = LinkParser.parse(url).single;
        expect(link.platform, _platform);
        expect(link.shareId, 'TestShare123');
        expect(link.passcode, isNull);
      }
      for (final suffix in ['访问码：a1B2', '&accessCode=a1B2', '\n密码 a1B2']) {
        final link = LinkParser.parse(
          'https://cloud.189.cn/web/share?code=TestShare123$suffix',
        ).single;
        expect(link.passcode, 'a1B2');
      }
      expect(
        LinkParser.parse(
          'https://h5.cloud.189.cn/share.html#/share?code=TestShare123&accessCode=a1B2',
        ).single.passcode,
        'a1B2',
      );
    });
    test('Cloud cookies are polled separately from cleared SSO cookies', () {
      final target = WebLoginTarget.targets[_platform]!;
      expect(Uri.parse(target.url).host, 'm.cloud.189.cn');
      expect(Uri.parse(target.url).path, '/udb/udb_login.jsp');
      expect(target.desktopMode, isFalse);
      expect(target.cookieDomains, contains('https://cloud.189.cn/api/'));
      expect(
        target.cookieDomains.every(
          (url) => {
            'cloud.189.cn',
            'm.cloud.189.cn',
            'h5.cloud.189.cn',
            'api.cloud.189.cn',
          }.contains(Uri.parse(url).host),
        ),
        isTrue,
      );
      expect(target.clearCookieDomains, contains('https://open.e.189.cn/'));
      expect(
        LoginCredentials.plausible(_platform, 'COOKIE_LOGIN_USER='),
        isFalse,
      );
      expect(LoginCredentials.plausible(_platform, 'SSO_TOKEN=early'), isFalse);
      expect(LoginCredentials.plausible(_platform, 'LOGIN_USER=ready'), isTrue);
      expect(
        LoginCredentials.plausible(
          _platform,
          'COOKIE_LOGIN_USER=ready\r\nInjected: value',
        ),
        isFalse,
      );
      expect(const AppSettings().connectionsFor(_platform), 64);
      expect(
        const AppSettings(
          threadOverrides: {'tianyi': 32},
        ).connectionsFor(_platform),
        32,
      );
    });
    test('Tianyi secrets are redacted from structured and free-text logs', () {
      final redacted = LogRedactor.json({
        'accessCode': 'secret-code',
        'LOGIN_USER': 'secret-login',
        'COOKIE_LOGIN_USER': 'secret-cookie',
        'sessionKey': 'secret-key',
      });
      expect(redacted, isNot(contains('secret-')));
      expect(
        LogRedactor.text(
          'accessCode=hidden-code LOGIN_USER=hidden-login sessionKey=hidden-key',
        ),
        isNot(contains('hidden-')),
      );
    });
  });

  group('Tianyi account validation and session ownership', () {
    test(
      'Authentication failure on quota is never treated as an optional quota outage',
      () async {
        for (final code in ['InvalidSessionKey', 'InvalidDeviceStatus']) {
          final vault = Vault(StateStore.memory());
          final http = FakeHttp(
            (r) => r.uri.path.contains('getUserInfo')
                ? _identity()
                : jsonResponse({'errorCode': code}, 400),
          );
          await expectLater(
            _login(
              vault,
              _connector(http, store: vault),
            ).submitWeb(_platform, 'COOKIE_LOGIN_USER=candidate'),
            throwsA(isA<AccountLoginRequired>()),
          );
          expect(vault.credential(_platform), isNull);
        }
      },
    );
    test(
      'Personal capacity excludes family storage and uses the server nickname',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.contains('getUserInfo') ? _identity() : _quota(),
        );
        final account = await _connector(http).account(_credential());
        expect(account.nickname, '测试用户');
        expect(account.total, 1000);
        expect(account.used, 300);
        expect(
          http.calls.last.uri.queryParameters['needClassification'],
          'true',
        );
      },
    );
    test(
      'Missing quota stays an error while an authenticated login can finish',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.contains('getUserInfo')
              ? _identity()
              : _ok({
                  'cloudCapacityInfo': {'totalSize': 0},
                }),
        );
        final connector = _connector(http);
        await expectLater(connector.account(_credential()), _message('容量'));
        final login = await connector.authenticate(_credential());
        expect(login.account.nickname, '测试用户');
        expect(login.account.total, 0);
      },
    );
    for (final (label, response) in <(String, HttpResult)>[
      ('malformed identity', _ok({})),
      ('HTTP login page', const HttpResult(200, '<html>login</html>')),
      (
        'expired session',
        jsonResponse({'errorCode': 'InvalidSessionKey'}, 400),
      ),
      (
        'device verification',
        jsonResponse({'errorCode': 'InvalidDeviceStatus'}, 400),
      ),
      ('service outage', const HttpResult(503, 'unavailable')),
    ]) {
      test('$label cannot replace a previously saved account', () async {
        final vault = Vault(StateStore.memory()), original = _credential();
        await vault.putCredential(_platform, original);
        final connector = _connector(FakeHttp((_) => response), store: vault);
        await expectLater(
          _login(
            vault,
            connector,
          ).submitWeb(_platform, 'COOKIE_LOGIN_USER=candidate'),
          throwsA(isA<AppException>()),
        );
        expect(vault.credential(_platform)!.sameAs(original), isTrue);
      });
    }
    test(
      'AppServices actually registers strict Tianyi candidate validation',
      () async {
        final services = AppServices(
          controlEnabled: false,
          store: StateStore.memory(),
          dataDirectory: Directory('fixture'),
          cacheDirectory: Directory('fixture/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('fixture/saved')),
          platformFeatures: false,
          http: FakeHttp((_) => _ok({})),
        );
        addTearDown(services.close);
        await expectLater(
          services.login.submitWeb(_platform, 'COOKIE_LOGIN_USER=candidate'),
          _message('账号信息'),
        );
        expect(services.vault.credential(_platform), isNull);
      },
    );
    test(
      'Candidate renewal is passed to quota and saved only after validation',
      () async {
        final vault = Vault(StateStore.memory());
        final http = FakeHttp((r) {
          expect(vault.credential(_platform), isNull);
          if (r.uri.path.contains('getUserInfo')) {
            return _identity(
              cookies: [
                'COOKIE_LOGIN_USER=renewed; Domain=.cloud.189.cn; Path=/; HttpOnly',
                'LOGIN_USER=foreign; Domain=open.e.189.cn; Path=/',
                'tracking=ignored; Path=/',
              ],
            );
          }
          expect(r.headers['Cookie'], contains('COOKIE_LOGIN_USER=renewed'));
          expect(r.headers['Cookie'], isNot(contains('foreign')));
          expect(r.headers['Cookie'], isNot(contains('tracking')));
          return _quota();
        });
        final result = await _login(
          vault,
          _connector(http, store: vault),
        ).submitWeb(_platform, 'COOKIE_LOGIN_USER=candidate');
        expect(
          result.credential.primary,
          contains('COOKIE_LOGIN_USER=renewed'),
        );
        expect(vault.credential(_platform)!.sameAs(result.credential), isTrue);
      },
    );
    test(
      'Renewed stored cookies preserve revision and do not reach CDN requests',
      () async {
        final vault = Vault(StateStore.memory()), original = _credential();
        await vault.putCredential(_platform, original);
        final http = FakeHttp(
          (_) => _ok(
            {'fileDownloadUrl': _signedUrl},
            cookies: ['COOKIE_LOGIN_USER=renewed; Path=/'],
          ),
        );
        final spec = await _connector(
          http,
          store: vault,
        ).download(_personal, _file, original);
        expect(vault.credential(_platform)!.updatedAt, original.updatedAt);
        expect(vault.credential(_platform)!.primary, contains('renewed'));
        expect(
          spec.headers.keys.map((e) => e.toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(
          spec.headers.keys.map((e) => e.toLowerCase()),
          isNot(contains('authorization')),
        );
        expect(spec.url, _signedUrl);
        expect(spec.expectedSize, 42);
        expect(spec.checksumValue, _md5);
        expect(spec.profile, 'tianyi');
      },
    );
    test(
      'Late responses cannot overwrite another concurrent session renewal',
      () async {
        final vault = Vault(StateStore.memory()), original = _credential();
        await vault.putCredential(_platform, original);
        final first = Completer<HttpResult>(), sent = Completer<void>();
        final http = FakeHttp((r) {
          if (r.uri.queryParameters['fileId'] == '101') {
            sent.complete();
            return first.future;
          }
          return _ok(
            {'fileDownloadUrl': _signedUrl},
            cookies: ['COOKIE_LOGIN_USER=newer; Path=/'],
          );
        });
        final connector = _connector(http, store: vault);
        final pending = connector.download(_personal, _file, original);
        await sent.future;
        await connector.download(
          _personal,
          const CloudFile(id: '102', name: 'other'),
          original,
        );
        first.complete(
          _ok(
            {'fileDownloadUrl': _signedUrl},
            cookies: ['COOKIE_LOGIN_USER=stale; Path=/'],
          ),
        );
        await pending;
        expect(vault.credential(_platform)!.primary, contains('newer'));
      },
    );
    test(
      'Account replacement during download rejects late URL and cookie writes',
      () async {
        final vault = Vault(StateStore.memory()),
            original = _credential(),
            replacement = _credential(2, 'COOKIE_LOGIN_USER=new-account');
        await vault.putCredential(_platform, original);
        final http = FakeHttp((_) async {
          await vault.putCredential(_platform, replacement);
          return _ok(
            {'fileDownloadUrl': _signedUrl},
            cookies: ['COOKIE_LOGIN_USER=late; Path=/'],
          );
        });
        await expectLater(
          _connector(http, store: vault).download(_personal, _file, original),
          _message('账号已变化'),
        );
        expect(vault.credential(_platform)!.sameAs(replacement), isTrue);
      },
    );
    test('Canceling candidate login never commits renewed cookies', () async {
      final vault = Vault(StateStore.memory());
      late AccountLoginService login;
      final http = FakeHttp((_) {
        login.invalidate(_platform);
        return _identity(cookies: ['COOKIE_LOGIN_USER=late; Path=/']);
      });
      login = _login(vault, _connector(http, store: vault));
      await expectLater(
        login.submitWeb(_platform, 'COOKIE_LOGIN_USER=candidate'),
        _message('取消'),
      );
      expect(vault.credential(_platform), isNull);
      expect(http.calls, hasLength(1));
    });
  });

  group('Tianyi share and directory browsing', () {
    test(
      'Protected single file uses checked shareId and isFolder=false even with count=0',
      () async {
        final http = FakeHttp((r) {
          final p = r.uri.queryParameters;
          expect(
            r.headers['Cookie'] ?? '',
            isNot(contains('COOKIE_LOGIN_USER')),
          );
          if (r.uri.path.contains('getShareInfo')) {
            expect(p['shareCode'], 'TestShare123');
            return _ok({
              'fileId': 101,
              'fileName': _file.name,
              'isFolder': false,
              'shareMode': 1,
              'needAccessCode': 1,
            });
          }
          if (r.uri.path.contains('checkAccessCode')) {
            expect(p['accessCode'], 'a1B2');
            return _ok({'shareId': 123456});
          }
          expect(p['isFolder'], 'false');
          expect(p['shareId'], '123456');
          expect(p['accessCode'], 'a1B2');
          expect(p.containsKey('shareDirFileId'), isFalse);
          expect(r.headers['Cookie'], 'share_123456=a1B2');
          return _listing([_row()], count: 0);
        });
        final connector = _connector(http);
        final session = await connector.openShare(
          _share().sourceLink!,
          _credential(),
        );
        expect(session.metadata.keys, isNot(contains('cookie')));
        final files = await connector.list(
          session,
          session.rootId,
          _credential(),
        );
        expect(files.single.id, '101');
        expect(files.single.size, 42);
        expect(files.single.hashValue, _md5);
      },
    );
    test(
      'Missing access code prompts before attempting password verification',
      () async {
        final http = FakeHttp(
          (_) => _ok({'fileId': '101', 'isFolder': false, 'needAccessCode': 1}),
        );
        await expectLater(
          _connector(
            http,
          ).openShare(_share().sourceLink!.withPasscode(''), null),
          _message('需要访问码'),
        );
        expect(http.calls, hasLength(1));
      },
    );
    test(
      'An explicit access-code failure cannot become an empty share listing',
      () async {
        final http = FakeHttp(
          (r) => r.uri.path.contains('getShareInfo')
              ? _ok({'fileId': '101', 'isFolder': false, 'needAccessCode': 1})
              : jsonResponse({'res_code': 'ShareAccessCodeError'}),
        );
        await expectLater(
          _connector(http).openShare(_share().sourceLink!, null),
          _message('访问码错误'),
        );
        expect(http.calls, hasLength(2));
      },
    );
    test(
      'Public directory shares need no login and skip unnecessary verification',
      () async {
        final http = FakeHttp((r) {
          if (r.uri.path.contains('getShareInfo')) {
            return _ok({
              'fileId': '100',
              'isFolder': 'true',
              'shareId': '123456',
              'shareType': 1,
              'needAccessCode': 1,
            });
          }
          expect(r.uri.queryParameters['isFolder'], 'true');
          expect(r.uri.queryParameters['fileId'], 'child');
          expect(r.uri.queryParameters['shareDirFileId'], 'child');
          return _listing(
            [_row()],
            folders: [
              {'id': '200', 'name': '子文件夹'},
            ],
          );
        });
        final connector = _connector(http);
        final session = await connector.openShare(
          _share().sourceLink!.withPasscode(''),
          null,
        );
        final files = await connector.list(session, 'child', null);
        expect(files, hasLength(2));
        expect(files.first.isDirectory, isTrue);
        expect(files.every((f) => f.parentId == 'child'), isTrue);
        expect(http.calls, hasLength(2));
      },
    );
    test('Personal lists advance pages until total is satisfied', () async {
      final http = FakeHttp((r) {
        final p = r.uri.queryParameters;
        expect(p['folderId'], '-11');
        expect(p['mediaType'], '0');
        expect(p['descending'], 'true');
        return p['pageNum'] == '1'
            ? _listing([_row('101')], count: 2)
            : _listing([_row('102')], count: 2);
      });
      final files = await _connector(
        http,
      ).list(_personal, '-11', _credential());
      expect(files.map((f) => f.id), ['101', '102']);
      expect(http.calls, hasLength(2));
    });
    for (final stage in ['getShareInfoByCodeV2', 'listShareDir']) {
      test(
        'Public $stage requires login only after an explicit rejection',
        () async {
          final http = FakeHttp((r) {
            final authenticated = (r.headers['Cookie'] ?? '').contains(
              'COOKIE_LOGIN_USER=original',
            );
            if (r.uri.path.contains(stage) && !authenticated) {
              return jsonResponse({'res_code': 'UserNotLogin'});
            }
            if (r.uri.path.contains('getShareInfo')) {
              return _ok({
                'fileId': '100',
                'isFolder': true,
                'shareId': '123456',
              });
            }
            return _listing([_row()]);
          });
          final connector = _connector(http);
          final session = await connector.openShare(
            _share().sourceLink!.withPasscode(''),
            _credential(),
          );
          await connector.list(session, session.rootId, _credential());
          final calls = http.calls
              .where((r) => r.uri.path.contains(stage))
              .toList();
          expect(calls, hasLength(2));
          expect(
            calls.first.headers['Cookie'] ?? '',
            isNot(contains('COOKIE_LOGIN_USER')),
          );
          expect(
            calls.last.headers['Cookie'],
            contains('COOKIE_LOGIN_USER=original'),
          );
          expect(
            http.calls.where((r) => r.uri.path.contains('getUserInfo')),
            isEmpty,
          );
        },
      );
    }
    test(
      'Public login requirement without an account returns a useful login prompt',
      () async {
        final http = FakeHttp(
          (_) => jsonResponse({'res_code': 'UserNotLogin'}),
        );
        await expectLater(
          _connector(http).openShare(_share().sourceLink!, null),
          throwsA(
            isA<AccountLoginRequired>().having(
              (e) => e.message,
              'prompt',
              contains('先登录天翼'),
            ),
          ),
        );
        expect(http.calls, hasLength(1));
      },
    );
    test('Public share failures never retry with a saved account', () async {
      for (final code in ['ShareCanceled', 'ShareAccessCodeError']) {
        final http = FakeHttp((r) {
          expect(
            r.headers['Cookie'] ?? '',
            isNot(contains('COOKIE_LOGIN_USER')),
          );
          return jsonResponse({'res_code': code});
        });
        await expectLater(
          _connector(http).openShare(_share().sourceLink!, _credential()),
          throwsA(isA<AppException>()),
        );
        expect(http.calls, hasLength(1));
      }
    });
    for (final (label, data) in <(String, Json)>[
      ('missing list', {}),
      (
        'missing nonempty arrays',
        {
          'fileListAO': {'count': 2},
        },
      ),
      (
        'invalid size',
        {
          'fileListAO': {
            'count': 1,
            'fileList': [
              {'id': '101', 'name': 'x', 'size': 'unknown'},
            ],
          },
        },
      ),
      (
        'invalid row',
        {
          'fileListAO': {
            'count': 1,
            'fileList': [null],
          },
        },
      ),
      (
        'invalid count',
        {
          'fileListAO': {'count': 'unknown'},
        },
      ),
    ]) {
      test('$label is rejected instead of silently hiding files', () async {
        await expectLater(
          _connector(
            FakeHttp((_) => _ok(data)),
          ).list(_personal, '-11', _credential()),
          throwsA(isA<AppException>()),
        );
      });
    }
    test('Empty folders without list arrays are valid', () async {
      final files = await _connector(
        FakeHttp(
          (_) => _ok({
            'fileListAO': {'count': 0},
          }),
        ),
      ).list(_personal, '-11', _credential());
      expect(files, isEmpty);
    });
    test(
      'Repeated pages and prematurely empty pages do not return partial results',
      () async {
        final repeated = FakeHttp((_) => _listing([_row()], count: 3));
        await expectLater(
          _connector(repeated).list(_personal, '-11', _credential()),
          _message('重复分页'),
        );
        expect(repeated.calls, hasLength(2));
        final truncated = FakeHttp(
          (r) => r.uri.queryParameters['pageNum'] == '1'
              ? _listing([_row()], count: 3)
              : _listing([], count: 3),
        );
        await expectLater(
          _connector(truncated).list(_personal, '-11', _credential()),
          _message('不完整'),
        );
        expect(truncated.calls, hasLength(2));
      },
    );
    test(
      'A single-file response cannot silently return another file',
      () async {
        await expectLater(
          _connector(
            FakeHttp((_) => _listing([_row('999')])),
          ).list(_share(), '101', null),
          _message('内容已变化'),
        );
      },
    );
  });

  group('Tianyi transfer, operations and cleanup', () {
    test(
      'Share direct download works without creating a temporary folder or using account space',
      () async {
        final f = _Transfer()..shareDirect = true;
        await f.initialize();
        final spec = await f.repository.prepare(_share(), _file);
        expect(spec.url, _signedUrl);
        expect(spec.expectedSize, _file.size);
        expect(spec.checksumValue, _md5);
        expect(spec.cleanup, isNull);
        expect(
          spec.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains('cookie')),
        );
        expect(f.folderName, isEmpty);
        expect(f.outbox.pendingCount, 0);
        expect(f.http.calls, hasLength(1));
      },
    );

    for (final folder in [false, true]) {
      for (final video in [false, true]) {
        test(
          'Mobile direct download uses the original ${folder ? 'folder child' : 'shared file'} ID for a large ${video ? 'video' : 'archive'}',
          () async {
            final file = video
                ? _largeVideo
                : CloudFile(
                    id: _largeVideo.id,
                    name: '大型文件.zip',
                    size: _largeVideo.size,
                    hashType: 'md5',
                    hashValue: _md5,
                  );
            final f = _Transfer()
              ..file = file
              ..mobileDirect = true;
            await f.initialize();
            final spec = await f.repository.prepare(
              _share(folder: folder),
              file,
            );
            expect(spec.url, _signedUrl);
            expect(spec.fileName, file.name);
            expect(spec.expectedSize, file.size);
            expect(spec.checksumType, 'md5');
            expect(spec.checksumValue, _md5);
            expect(spec.cleanup, isNull);
            expect(spec.source!['file'], file.toJson());
            expect(spec.headers['User-Agent'], contains('Android'));
            expect(spec.headers['Referer'], 'https://h5.cloud.189.cn/');
            expect(
              spec.headers.keys.map((key) => key.toLowerCase()),
              isNot(
                anyOf(
                  contains('cookie'),
                  contains('access-token'),
                  contains('accesstoken'),
                  contains('signature'),
                  contains('browser-id'),
                ),
              ),
            );
            expect(f.folderName, isEmpty);
            expect(f.pollCounts, isEmpty);
            expect(f.outbox.pendingCount, 0);
            expect(f.http.calls, hasLength(4));
          },
        );
      }
    }

    test('Folder collection downloads child files without transfer', () async {
      final f = _Transfer()
        ..file = _largeVideo
        ..mobileDirect = true;
      await f.initialize();
      f.override = (r) {
        if (r.uri.path == '/api/open/share/listShareDir.action') {
          final parent = _params(r).str('shareDirFileId');
          if (parent == '100') {
            return _listing(
              [],
              folders: [
                {'id': '200', 'name': '子目录'},
              ],
            );
          }
          expect(parent, '200');
          return _listing([
            _row(_largeVideo.id, _largeVideo.name, _largeVideo.size),
          ]);
        }
        return null;
      };
      final session = _share(folder: true);
      final selected = await f.repository.collect(session, const [
        CloudFile(id: '100', name: '资源', isDirectory: true),
      ]);
      expect(selected, hasLength(1));
      expect(selected.single.$1.id, _largeVideo.id);
      expect(selected.single.$2, '资源/子目录');
      final spec = await f.repository.prepare(session, selected.single.$1);
      expect(spec.url, _signedUrl);
      expect(spec.expectedSize, _largeVideo.size);
      expect(spec.cleanup, isNull);
      expect(f.folderName, isEmpty);
      expect(f.outbox.pendingCount, 0);
    });

    test(
      'A restricted personal file receives a mobile direct link without share parameters',
      () async {
        final f = _Transfer()
          ..file = _largeVideo
          ..mobileDirect = true;
        await f.initialize();
        f.override = (r) =>
            r.uri.path == '/api/open/file/getFileDownloadUrl.action'
            ? jsonResponse({'errorCode': 'FileTooLarge'}, 400)
            : null;
        final spec = await f.repository.prepare(_personal, _largeVideo);
        expect(spec.url, _signedUrl);
        expect(spec.expectedSize, _largeVideo.size);
        expect(spec.checksumValue, _md5);
        expect(spec.headers['User-Agent'], contains('Android'));
        expect(spec.cleanup, isNull);
        expect(f.http.calls, hasLength(4));
        expect(f.folderName, isEmpty);
        expect(f.pollCounts, isEmpty);
        expect(f.outbox.pendingCount, 0);
      },
    );

    for (final status in [429, 503]) {
      test(
        'A mobile HTTP $status retry repeats only the download read',
        () async {
          final f = _Transfer(retryReads: true)..mobileDirect = true;
          await f.initialize();
          var requests = 0;
          f.override = (r) =>
              r.uri.host == 'api.cloud.189.cn' && ++requests == 1
              ? HttpResult(status, '<html>temporarily unavailable</html>')
              : null;
          final spec = await f.repository.prepare(_share(), _file);
          expect(spec.url, _signedUrl);
          expect(requests, 2);
          expect(f.exchanges, 1);
          expect(f.http.calls, hasLength(5));
          expect(f.pollCounts, isEmpty);
          expect(f.outbox.pendingCount, 0);
        },
      );
    }

    test(
      'Expired mobile tokens refresh once and keep the original share ID',
      () async {
        final f = _Transfer()..mobileDirect = true;
        await f.initialize();
        f.override = (r) => r.headers['AccessToken'] == 'mobile-access-1'
            ? jsonResponse({'errorCode': 'AccessTokenHasExpired'}, 400)
            : null;
        expect((await f.repository.prepare(_share(), _file)).url, _signedUrl);
        expect(f.exchanges, 2);
        final requests = f.http.calls.where(
          (r) => r.uri.host == 'api.cloud.189.cn',
        );
        expect(requests, hasLength(2));
        for (final request in requests) {
          _expectMobileRequest(request);
          expect(request.uri.queryParameters['fileId'], _file.id);
          expect(request.uri.queryParameters['shareId'], '123456');
        }
        expect(
          requests.map((r) => r.headers['X-Request-ID']).toSet(),
          hasLength(2),
        );
        expect(f.outbox.pendingCount, 0);
      },
    );

    test(
      'Repeated rejected mobile tokens stop without transfer or preview',
      () async {
        final f = _Transfer();
        await f.initialize();
        f.override = (r) => r.uri.host == 'api.cloud.189.cn'
            ? jsonResponse({'errorCode': 'InvalidAccessToken'}, 400)
            : null;
        await expectLater(
          f.repository.prepare(_share(), _file),
          _message('下载授权已失效'),
        );
        expect(f.exchanges, 2);
        expect(
          f.http.calls.where((r) => r.uri.host == 'api.cloud.189.cn'),
          hasLength(2),
        );
        expect(f.pollCounts, isEmpty);
        expect(f.outbox.pendingCount, 0);
      },
    );

    test(
      'Rotated cookies discard the cached mobile token without changing download ownership',
      () async {
        final f = _Transfer()..mobileDirect = true;
        await f.initialize();
        final first = await f.repository.prepare(_share(), _file);
        final old = f.vault.credential(_platform)!;
        await f.vault.replaceCredential(
          _platform,
          old,
          old.withFields({
            'primary': 'COOKIE_LOGIN_USER=renewed',
          }, preserveRevision: true),
        );
        final second = await f.repository.prepare(_share(), _file);
        expect(first.url, second.url);
        expect(
          first.source!['accountRevision'],
          second.source!['accountRevision'],
        );
        expect(f.exchanges, 2);
        expect(f.outbox.pendingCount, 0);
      },
    );

    for (final code in [
      'ShareAccessCodeError',
      'PermissionDenied',
      'InvalidDeviceStatus',
    ]) {
      test(
        'Mobile $code does not fall through to preview or transfer',
        () async {
          final f = _Transfer();
          await f.initialize();
          f.override = (r) => r.uri.host == 'api.cloud.189.cn'
              ? jsonResponse({'errorCode': code}, 400)
              : null;
          await expectLater(
            f.repository.prepare(_share(), _file),
            throwsA(isA<AppException>()),
          );
          expect(f.http.calls, hasLength(4));
          expect(f.folderName, isEmpty);
          expect(f.outbox.pendingCount, 0);
        },
      );
    }

    for (final stage in [
      'getUserBriefInfo',
      'getAccessTokenBySsKey',
      'mobile-download',
    ]) {
      for (final cancel in [false, true]) {
        test(
          '${cancel ? 'Cancellation' : 'Account replacement'} during $stage discards the late mobile link',
          () async {
            final f = _Transfer()..mobileDirect = true;
            final scope = RequestScope();
            await f.initialize();
            f.override = (r) async {
              final matches = stage == 'mobile-download'
                  ? r.uri.host == 'api.cloud.189.cn'
                  : r.uri.path.endsWith('/$stage.action');
              if (matches) {
                if (cancel) {
                  scope.cancel();
                } else {
                  await f.vault.putCredential(_platform, _credential(2));
                }
              }
              return null;
            };
            await expectLater(
              scope.run(() => f.repository.prepare(_share(), _file)),
              _message(cancel ? '取消' : '账号已变化'),
            );
            expect(f.folderName, isEmpty);
            expect(f.outbox.pendingCount, 0);
          },
        );
      }
    }

    for (final folder in [false, true]) {
      test(
        'A large ${folder ? 'folder-shared' : 'single-shared'} MKV uses the verified original video URL without transfer',
        () async {
          final f = _Transfer()..file = _largeVideo;
          await f.initialize();
          f.override = (r) {
            if (r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action') {
              expect(_params(r)['fileId'], _largeVideo.id);
              expect(_params(r)['type'], '4');
              expect(_params(r)['shareId'], '123456');
              expect(_params(r)['dt'], folder ? '1' : null);
              expect(r.headers['Cookie'], contains('share_123456=a1B2'));
              return _ok({
                'success': true,
                'normal': {'url': _signedUrl.replaceAll('&', '&amp;')},
                'transcode': {
                  'code': 2,
                  'url': 'https://download.example.test/lower-quality.m3u8',
                },
              });
            }
            if (r.uri.host == 'download.example.test') {
              expect(r.url, _signedUrl);
              expect(r.headers['Range'], 'bytes=0-511');
              expect(
                r.headers.keys.map((key) => key.toLowerCase()),
                isNot(anyOf(contains('cookie'), contains('browser-id'))),
              );
              return HttpResult(206, 'original video bytes', {
                'content-range': ['bytes 0-511/${_largeVideo.size}'],
                'content-length': ['512'],
                'content-type': ['video/x-matroska'],
              });
            }
            return null;
          };
          final spec = await f.repository.prepare(
            _share(folder: folder),
            _largeVideo,
          );
          expect(spec.url, _signedUrl);
          expect(spec.fileName, _largeVideo.name);
          expect(spec.expectedSize, _largeVideo.size);
          expect(spec.checksumType, 'md5');
          expect(spec.checksumValue, _md5);
          expect(spec.cleanup, isNull);
          expect(f.folderName, isEmpty);
          expect(f.outbox.pendingCount, 0);
          expect(f.http.calls, hasLength(6));
        },
      );
    }

    test(
      'A size-restricted personal video tries the mobile link before its original video without share parameters',
      () async {
        final http = FakeHttp((r) {
          if (r.uri.host == 'download.example.test') {
            expect(r.url, _signedUrl);
            expect(r.headers['Range'], 'bytes=0-511');
            expect(r.headers.containsKey('Cookie'), isFalse);
            return HttpResult(200, 'original video bytes', {
              'content-length': ['${_largeVideo.size}'],
              'content-type': ['application/octet-stream'],
            });
          }
          expect(_params(r).containsKey('dt'), isFalse);
          expect(_params(r).containsKey('shareId'), isFalse);
          if (r.uri.path == '/api/portal/v2/getUserBriefInfo.action') {
            return _ok({'sessionKey': 'personal-session'});
          }
          if (r.uri.path == '/api/open/oauth2/getAccessTokenBySsKey.action') {
            return _ok({'accessToken': 'personal-access'});
          }
          if (r.uri.path == '/open/file/getFileDownloadUrl.action') {
            _expectMobileRequest(r);
            expect(_params(r)['fileId'], _largeVideo.id);
            return jsonResponse({'res_code': 'FileTooLarge'}, 400);
          }
          expect(r.headers['Cookie'], _credential().primary);
          if (r.uri.path == '/api/open/file/getFileDownloadUrl.action') {
            return jsonResponse({'res_code': 'FileTooLarge'}, 400);
          }
          expect(r.uri.path, '/api/portal/getNewVlcVideoPlayUrl.action');
          expect(_params(r)['fileId'], _largeVideo.id);
          expect(_params(r)['type'], '2');
          return _ok({
            'success': true,
            'normal': {'url': _signedUrl},
          });
        });
        final spec = await _connector(
          http,
        ).download(_personal, _largeVideo, _credential());
        expect(spec.url, _signedUrl);
        expect(spec.expectedSize, _largeVideo.size);
        expect(spec.checksumValue, _md5);
        expect(http.calls, hasLength(6));
      },
    );

    for (final (name, response) in <(String, HttpResult)>[
      (
        'a different file length',
        HttpResult(206, 'bytes', {
          'content-range': ['bytes 0-511/1000'],
        }),
      ),
      ('an unknown file length', const HttpResult(206, 'bytes')),
      (
        'a playlist',
        HttpResult(200, '#EXTM3U\n', {
          'content-length': ['${_file.size}'],
        }),
      ),
      (
        'an HTML notice',
        HttpResult(200, '<html>notice</html>', {
          'content-length': ['${_file.size}'],
          'content-type': ['text/html; charset=utf-8'],
        }),
      ),
      ('an expired CDN link', const HttpResult(403, 'Forbidden')),
    ]) {
      test(
        'Original video fallback rejects $name without transferring the file',
        () async {
          final f = _Transfer();
          await f.initialize();
          f.override = (r) {
            if (r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action') {
              return _ok({
                'success': true,
                'normal': {'url': 'https://download.example.test/original'},
              });
            }
            if (r.uri.host == 'download.example.test') return response;
            return null;
          };
          await expectLater(
            f.repository.prepare(_share(), _file),
            _message('文件大小限制'),
          );
          expect(f.folderName, isEmpty);
          expect(f.pollCounts, isEmpty);
          expect(f.outbox.pendingCount, 0);
        },
      );
    }

    test(
      'An unsupported video preview cannot trigger an automatic transfer',
      () async {
        final f = _Transfer();
        await f.initialize();
        f.override = (r) =>
            r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action'
            ? _ok({'success': false})
            : null;
        await expectLater(
          f.repository.prepare(_share(), _file),
          _message('文件大小限制'),
        );
        expect(f.folderName, isEmpty);
        expect(f.pollCounts, isEmpty);
        expect(f.outbox.pendingCount, 0);
      },
    );

    for (final url in [
      'javascript:alert(1)',
      'https://user:password@example.test/file',
    ]) {
      test(
        'An invalid optional video address is rejected without transfer: $url',
        () async {
          final f = _Transfer();
          await f.initialize();
          f.override = (r) =>
              r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action'
              ? _ok({
                  'success': true,
                  'normal': {'url': url},
                })
              : null;
          await expectLater(
            f.repository.prepare(_share(), _file),
            _message('文件大小限制'),
          );
          expect(
            f.http.calls.every(
              (r) => {'cloud.189.cn', 'api.cloud.189.cn'}.contains(r.uri.host),
            ),
            isTrue,
          );
          expect(f.pollCounts, isEmpty);
          expect(f.outbox.pendingCount, 0);
        },
      );
    }

    for (final status in [429, 503]) {
      test(
        'A temporary video endpoint HTTP $status response stops after one optional attempt without transfer',
        () async {
          final f = _Transfer(retryReads: true);
          await f.initialize();
          f.override = (r) =>
              r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action'
              ? HttpResult(status, '<html>temporarily unavailable</html>')
              : null;
          await expectLater(
            f.repository.prepare(_share(), _file),
            _message('文件大小限制'),
          );
          expect(
            f.http.calls.where(
              (r) => r.uri.path.contains('getNewVlcVideoPlayUrl'),
            ),
            hasLength(1),
          );
          expect(f.pollCounts, isEmpty);
          expect(f.outbox.pendingCount, 0);
        },
      );
    }

    test(
      'A video endpoint size restriction cannot start an automatic transfer',
      () async {
        final f = _Transfer();
        await f.initialize();
        f.override = (r) =>
            r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action'
            ? jsonResponse({'errorCode': 'FileTooLarge'}, 400)
            : null;
        await expectLater(
          f.repository.prepare(_share(), _file),
          _message('文件大小限制'),
        );
        expect(f.pollCounts, isEmpty);
        expect(f.outbox.pendingCount, 0);
      },
    );

    for (final atCdn in [false, true]) {
      test(
        'A ${atCdn ? 'CDN probe' : 'video endpoint'} timeout cannot trigger transfer',
        () async {
          final f = _Transfer(retryReads: true);
          await f.initialize();
          f.override = (r) {
            if (r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action') {
              if (!atCdn) {
                throw const HttpRequestFailure(
                  '连接超时',
                  kind: 'receiveTimeout',
                  retryable: true,
                );
              }
              return _ok({
                'success': true,
                'normal': {'url': _signedUrl},
              });
            }
            if (r.uri.host == 'download.example.test') {
              throw const HttpRequestFailure(
                '连接超时',
                kind: 'receiveTimeout',
                retryable: true,
              );
            }
            return null;
          };
          await expectLater(
            f.repository.prepare(_share(), _file),
            _message('文件大小限制'),
          );
          expect(
            f.http.calls.where((r) => r.uri.host == 'download.example.test'),
            hasLength(atCdn ? 1 : 0),
          );
          expect(f.pollCounts, isEmpty);
          expect(f.outbox.pendingCount, 0);
        },
      );
    }

    test(
      'A size-restricted archive fails without transfer or video probing',
      () async {
        final f = _Transfer();
        await f.initialize();
        const archive = CloudFile(id: '101', name: '文件.zip', size: 42);
        await expectLater(
          f.repository.prepare(_share(), archive),
          _message('文件大小限制'),
        );
        expect(f.outbox.pendingCount, 0);
        expect(f.folderName, isEmpty);
        expect(
          f.http.calls.any((r) => r.uri.path.contains('getNewVlcVideoPlayUrl')),
          isFalse,
        );
      },
    );

    for (final (code, message) in [
      ('ShareAccessCodeError', '访问码错误'),
      ('InvalidSessionKey', '登录已失效'),
      ('PermissionDenied', 'PermissionDenied'),
    ]) {
      test(
        'A video endpoint $code response cannot trigger a transfer',
        () async {
          final f = _Transfer();
          await f.initialize();
          f.override = (r) =>
              r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action'
              ? jsonResponse({'errorCode': code, 'success': false}, 400)
              : null;
          await expectLater(
            f.repository.prepare(_share(), _file),
            _message(message),
          );
          expect(f.folderName, isEmpty);
          expect(f.outbox.pendingCount, 0);
          expect(f.http.calls, hasLength(5));
        },
      );
    }

    test(
      'A canceled original-video probe cannot return a URL or create a transfer',
      () async {
        final f = _Transfer(), scope = RequestScope();
        await f.initialize();
        f.override = (r) {
          if (r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action') {
            return _ok({
              'success': true,
              'normal': {'url': _signedUrl},
            });
          }
          if (r.uri.host == 'download.example.test') {
            scope.cancel();
            return HttpResult(206, 'bytes', {
              'content-range': ['bytes 0-511/${_file.size}'],
            });
          }
          return null;
        };
        await expectLater(
          scope.run(() => f.repository.prepare(_share(), _file)),
          _message('取消'),
        );
        expect(f.http.calls, hasLength(6));
        expect(f.outbox.pendingCount, 0);
      },
    );

    test(
      'An account change during an original-video probe rejects the stale URL',
      () async {
        final f = _Transfer();
        await f.initialize();
        f.override = (r) async {
          if (r.uri.path == '/api/portal/getNewVlcVideoPlayUrl.action') {
            return _ok({
              'success': true,
              'normal': {'url': _signedUrl},
            });
          }
          if (r.uri.host == 'download.example.test') {
            await f.vault.putCredential(_platform, _credential(2));
            return HttpResult(206, 'bytes', {
              'content-range': ['bytes 0-511/${_file.size}'],
            });
          }
          return null;
        };
        await expectLater(
          f.repository.prepare(_share(), _file),
          _message('账号已变化'),
        );
        expect(f.http.calls, hasLength(6));
        expect(f.outbox.pendingCount, 0);
      },
    );

    test(
      'Size limits from non-download operations do not describe a download restriction',
      () async {
        final http = FakeHttp(
          (_) => jsonResponse({'errorCode': 'FileTooLarge'}, 400),
        );
        final result = _connector(
          http,
        ).rename(_personal, _file, '更名.mp4', _credential());
        await expectLater(result, _message('当前操作触发文件大小限制'));
        expect(http.calls, hasLength(1));
      },
    );

    test(
      'A rejected share access code never creates a transfer as fallback',
      () async {
        final f = _Transfer();
        await f.initialize();
        f.override = (r) => r.uri.path.endsWith('/getFileDownloadUrl.action')
            ? jsonResponse({'res_code': 'ShareAccessCodeError'}, 400)
            : null;
        await expectLater(
          f.repository.prepare(_share(), _file),
          _message('访问码错误'),
        );
        expect(f.http.calls, hasLength(1));
        expect(f.outbox.pendingCount, 0);
      },
    );

    test(
      'InsufficientStorageSpace during an explicit share save reports account capacity',
      () async {
        final f = _Transfer()
          ..completedTask = {
            'res_code': 0,
            'taskStatus': 4,
            'failedCount': 1,
            'successedCount': 0,
            'errorCode': 'InsufficientStorageSpace',
          };
        await f.initialize();
        await expectLater(f.saveShare(), _message('网盘空间不足'));
        expect(f.outbox.pendingCount, 0);
        expect(
          f.http.calls.where(
            (r) => r.uri.path.endsWith('/createBatchTask.action'),
          ),
          hasLength(1),
        );
      },
    );

    test(
      'System directories cannot be renamed, moved, deleted or shared',
      () async {
        final http = FakeHttp(), credential = _credential();
        final connector = _connector(http);
        for (final id in [
          '-11',
          '0',
          '-10',
          '-12',
          '-13',
          '-14',
          '-15',
          '-16',
        ]) {
          final folder = CloudFile(id: id, name: '系统目录', isDirectory: true);
          await expectLater(
            connector.rename(_personal, folder, 'other', credential),
            throwsA(isA<AppException>()),
          );
          await expectLater(
            connector.move(_personal, [folder], '200', credential),
            throwsA(isA<AppException>()),
          );
          await expectLater(
            connector.delete(_personal, [folder], credential),
            throwsA(isA<AppException>()),
          );
          await expectLater(
            connector.createShare(
              _personal,
              [folder],
              const ShareOptions('system'),
              credential,
            ),
            throwsA(isA<AppException>()),
          );
        }
        expect(http.calls, isEmpty);
      },
    );
    test(
      'A historical temporary folder retains cleanup until its download releases it',
      () async {
        final f = _Transfer();
        await f.initialize();
        final cleanup = await f.historicalCleanup(retained: true);
        expect(cleanup.action!['folderId'], '900');
        expect(encoded(cleanup.toJson()), isNot(contains('COOKIE_LOGIN_USER')));
        await f.outbox.ready(cleanup);
        await f.outbox.drain();
        expect(
          f.pollCounts.containsKey('DELETE'),
          isFalse,
          reason: 'active download holds a lease',
        );
        await f.outbox.release(cleanup);
        await f.outbox.ready(cleanup);
        await f.outbox.drain();
        expect(f.pollCounts['DELETE'], 2);
        expect(f.outbox.pendingCount, 0);
      },
    );
    for (final (name, status) in <(String, Json)>[
      ('conflict', {'taskStatus': 2}),
      ('failed', {'taskStatus': -1}),
      ('cancelled', {'taskStatus': 5}),
      ('unknown', {'taskStatus': 9}),
      (
        'partial failure',
        {
          'taskStatus': 4,
          'successedCount': 1,
          'failedCount': 1,
          'subTaskCount': 2,
        },
      ),
      ('missing success count', {'taskStatus': 4, 'failedCount': 0}),
      (
        'incomplete count',
        {
          'taskStatus': 4,
          'successedCount': 1,
          'failedCount': 0,
          'subTaskCount': 2,
        },
      ),
      (
        'still pending',
        {
          'taskStatus': 3,
          'successedCount': 0,
          'failedCount': 0,
          'subTaskCount': 1,
        },
      ),
      (
        'error envelope',
        {
          'taskStatus': 4,
          'successedCount': 1,
          'failedCount': 0,
          'errorCode': 'PermissionDeny',
        },
      ),
    ]) {
      test(
        '$name during an explicit share save never reports success or requests a download link',
        () async {
          final f = _Transfer()..completedTask = status;
          await f.initialize();
          await expectLater(f.saveShare(), throwsA(isA<AppException>()));
          expect(
            f.http.calls.any((r) => r.uri.path.contains('getFileDownloadUrl')),
            isFalse,
          );
          expect(f.outbox.pendingCount, 0);
          expect(f.folderName, isEmpty);
        },
      );
    }
    test(
      'A failed historical asynchronous DELETE keeps cleanup retryable',
      () async {
        final f = _Transfer()..completedTask = {'taskStatus': -1};
        await f.initialize();
        final cleanup = await f.historicalCleanup();
        await f.outbox.ready(cleanup);
        await f.outbox.drain();
        expect(f.outbox.pendingCount, 1);
        expect(f.pollCounts['DELETE'], 1);
        expect(
          asJson(f.store.data.obj('cleanups').values.single).boolean('ready'),
          isTrue,
        );
      },
    );
    test(
      'Account switch pauses historical cleanup instead of deleting from the replacement account',
      () async {
        final f = _Transfer();
        await f.initialize();
        final cleanup = await f.historicalCleanup();
        await f.outbox.ready(cleanup);
        await f.vault.putCredential(_platform, _credential(2));
        final before = f.http.calls.length;
        await f.outbox.drain();
        expect(f.http.calls.length, before);
        expect(f.outbox.pendingCount, 1);
      },
    );
    test(
      'Canceling an explicit folder creation cannot trigger an automatic transfer or cleanup',
      () async {
        final f = _Transfer(), scope = RequestScope();
        await f.initialize();
        f.override = (r) {
          if (r.uri.path.contains('createFolder')) scope.cancel();
          return null;
        };
        await expectLater(
          scope.run(
            () => f.connector.createFolder(
              _personal,
              '-11',
              '新目录',
              _credential(),
            ),
          ),
          _message('取消'),
        );
        expect(f.http.calls, hasLength(1));
        expect(f.outbox.pendingCount, 0);
        expect(f.pollCounts, isEmpty);
      },
    );
    test(
      'Account switch during an explicit folder creation submits no transfer',
      () async {
        final f = _Transfer();
        await f.initialize();
        f.override = (r) async {
          if (r.uri.path.contains('createFolder')) {
            await f.vault.putCredential(_platform, _credential(2));
          }
          return null;
        };
        await expectLater(
          f.connector.createFolder(_personal, '-11', '新目录', _credential()),
          _message('账号已变化'),
        );
        expect(f.http.calls, hasLength(1));
        expect(f.outbox.pendingCount, 0);
        expect(f.pollCounts, isEmpty);
      },
    );
    test(
      'No account means no temporary folder or share download request',
      () async {
        final f = _Transfer();
        await expectLater(
          f.repository.prepare(_share(), _file),
          throwsA(isA<AccountLoginRequired>()),
        );
        expect(f.http.calls, isEmpty);
      },
    );
    test('File and folder renames use their separate form endpoints', () async {
      final http = FakeHttp((r) {
        final p = _params(r);
        expect(r.method, 'POST');
        if (r.uri.path.endsWith('/renameFile.action')) {
          expect(p['fileId'], '101');
          expect(p['destFileName'], '新名.mp4');
          expect(p.containsKey('folderId'), isFalse);
        } else {
          expect(r.uri.path, '/api/open/file/renameFolder.action');
          expect(p['folderId'], '200');
          expect(p['destFolderName'], '新目录');
        }
        return _ok({});
      });
      final connector = _connector(http);
      await connector.rename(_personal, _file, '新名.mp4', _credential());
      await connector.rename(
        _personal,
        const CloudFile(id: '200', name: 'old', isDirectory: true),
        '新目录',
        _credential(),
      );
    });
    test(
      'Move and delete wait through running status, and DELETE has no destination',
      () async {
        final types = <String>[];
        var polls = 0;
        final http = FakeHttp((r) {
          final p = _params(r);
          if (r.uri.path.contains('createBatchTask')) {
            types.add(p.str('type'));
            expect(p.containsKey('targetFolderId'), p['type'] == 'MOVE');
            expect(jsonDecode(p.str('taskInfos')), [
              {'fileId': '101', 'fileName': _file.name, 'isFolder': 0},
            ]);
            polls = 0;
            return _ok({'taskId': 'task'});
          }
          return _ok({
            'taskStatus': ++polls == 1 ? 3 : 4,
            'successedCount': polls == 1 ? 0 : 1,
            'failedCount': 0,
            'subTaskCount': 1,
          });
        });
        final connector = _connector(http);
        await connector.move(_personal, [_file], '200', _credential());
        expect(polls, 2);
        await connector.delete(_personal, [_file], _credential());
        expect(polls, 2);
        expect(types, ['MOVE', 'DELETE']);
      },
    );
    test('Creation and sharing validate server acknowledgements', () async {
      final http = FakeHttp((r) {
        if (r.uri.path.contains('createFolder')) {
          expect(_params(r)['folderName'], '新目录');
          return _ok({'id': '200', 'name': '新目录'});
        }
        if (r.uri.path.contains('createShareLink')) {
          expect(r.method, 'GET');
          expect(_params(r)['expireTime'], '2099');
          expect(_params(r)['shareType'], '3');
          return _ok({
            'shareLinkList': [
              {'url': 'https://cloud.189.cn/t/NewShare', 'accessCode': 'b2C3'},
            ],
          });
        }
        expect(r.uri.path, '/api/open/share/createBatchShare.action');
        expect(r.method, 'POST');
        expect(r.json['fileIdList'], ['101', '102']);
        expect(r.json['expireTime'], 7);
        return jsonResponse({
          'code': 'success',
          'data': {
            'url': 'https://cloud.189.cn/t/BatchShare',
            'accessCode': 'd4E5',
          },
        });
      });
      final connector = _connector(http);
      final folder = await connector.createFolder(
        _personal,
        '-11',
        '新目录',
        _credential(),
      );
      expect(folder.id, '200');
      final single = await connector.createShare(
        _personal,
        [_file],
        const ShareOptions('标题'),
        _credential(),
      );
      expect(single.passcode, 'b2C3');
      final multi = await connector.createShare(
        _personal,
        [_file, const CloudFile(id: '102', name: 'other')],
        const ShareOptions('多个', expiryDays: 7),
        _credential(),
      );
      expect(multi.passcode, 'd4E5');
      expect(multi.title, '多个');
    });
    test(
      'Unsupported expiry and custom access codes fail before network mutations',
      () async {
        final http = FakeHttp();
        final connector = _connector(http);
        await expectLater(
          connector.createShare(
            _personal,
            [_file],
            const ShareOptions('title', expiryDays: 30),
            _credential(),
          ),
          _message('有效期'),
        );
        await expectLater(
          connector.createShare(
            _personal,
            [_file],
            const ShareOptions('title', passcode: 'a123'),
            _credential(),
          ),
          _message('自动生成'),
        );
        await expectLater(
          connector.delete(_personal, const [
            CloudFile(id: '-11', name: 'root', isDirectory: true),
          ], _credential()),
          throwsA(isA<AppException>()),
        );
        await expectLater(
          connector.rename(_share(), _file, 'new', _credential()),
          _message('个人天翼'),
        );
        expect(http.calls, isEmpty);
      },
    );
    test('Malformed download URLs never reach the download engine', () async {
      for (final url in [
        '',
        'javascript:alert(1)',
        'https://user:password@example.test/file',
      ]) {
        await expectLater(
          _connector(
            FakeHttp((_) => _ok({'fileDownloadUrl': url})),
          ).download(_personal, _file, _credential()),
          _message('下载地址'),
        );
      }
    });
  });

  testWidgets(
    'Tianyi sharing UI offers server-supported durations and a generated access code',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final http = FakeHttp((r) {
        expect(r.uri.path, '/api/open/share/createShareLink.action');
        expect(r.uri.queryParameters['expireTime'], '7');
        expect(r.uri.queryParameters.containsKey('accessCode'), isFalse);
        return _ok({
          'shareLinkList': [
            {'url': 'https://cloud.189.cn/t/Created', 'accessCode': 'a1B2'},
          ],
        });
      });
      final services = (await tester.runAsync(() async {
        final result = AppServices(
          controlEnabled: false,
          store: StateStore.memory(),
          dataDirectory: Directory('fixture'),
          cacheDirectory: Directory('fixture/cache'),
          transport: FakeNative(),
          files: FakeFiles(Directory('fixture/saved')),
          platformFeatures: false,
          http: http,
        );
        await result.vault.putCredential(_platform, _credential());
        return result;
      }))!;
      addTearDown(() => tester.runAsync(services.close));
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserPage(services, _personal, initialItems: const [_file]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('${_file.name}操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建分享'));
      await tester.pumpAndSettle();
      expect(find.text('访问码由天翼云盘自动生成'), findsOneWidget);
      expect(find.text('提取码（可选）'), findsNothing);
      final dropdown = tester.widget<DropdownButtonFormField<int>>(
        find.byType(DropdownButtonFormField<int>),
      );
      // Assert the actual visible options, then select the existing default.
      expect(dropdown.initialValue, 7);
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      expect(find.text('30 天'), findsNothing);
      expect(find.text('1 天'), findsWidgets);
      expect(find.text('永久'), findsWidgets);
      await tester.tap(find.text('7 天').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(http.calls, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
